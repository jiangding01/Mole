//go:build darwin

package main

// analyze --serve：GUI 常驻引擎（设计 §5.4）。
// stdin 每行一个 JSON 请求，stdout 回 NDJSON 事件；纯只读——delete 不在
// 本协议内（GUI 走 mole robot，保证 Trash/oplog/保护判定单源）。
//
// 请求:  {"op":"scan"|"children"|"rescan"|"cancel","id":"q1","path":"/Users/x"}
// 事件:  scan_progress（200ms 节流）/ node（当前层子项逐个）/ scan_done / error
//
// 缓存：会话内 map[path]，scan/children 命中即回（cached:true）；rescan 绕过。
// 流式：复用 TUI live 机制——首帧立刻发当前层全部条目（文件即终值、目录先挂
// 缓存/估值），子目录逐个算完推送更新（GUI 按 path 合并），complete 发权威
// 终值 + scan_done。取消：cancel op 触发 context 真中断 + 事件抑制。

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

type serveRequest struct {
	Op   string `json:"op"`
	ID   string `json:"id"`
	Path string `json:"path"`
}

type serveNode struct {
	Event      string `json:"event"`
	ID         string `json:"id"`
	Name       string `json:"name"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	IsDir      bool   `json:"is_dir"`
	Cleanable  bool   `json:"cleanable"`
	LastAccess string `json:"last_access,omitempty"`
}

type serveProgress struct {
	Event   string `json:"event"`
	ID      string `json:"id"`
	Files   int64  `json:"files"`
	Dirs    int64  `json:"dirs"`
	Bytes   int64  `json:"bytes"`
	Current string `json:"current,omitempty"`
}

type serveDone struct {
	Event     string `json:"event"`
	ID        string `json:"id"`
	Dir       string `json:"dir"`
	TotalSize int64  `json:"total_size"`
	ItemCount int    `json:"item_count"`
	Cached    bool   `json:"cached"`
}

type serveError struct {
	Event   string `json:"event"`
	ID      string `json:"id"`
	Message string `json:"message"`
}

type serveState struct {
	mu        sync.Mutex // stdout 写锁
	out       io.Writer
	cacheMu   sync.Mutex
	cache     map[string]scanResult
	cancelled sync.Map // id -> struct{}
	cancels   sync.Map // id -> context.CancelFunc（在途扫描的真取消）
}

func (s *serveState) emit(v any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintf(s.out, "%s\n", data)
}

func (s *serveState) isCancelled(id string) bool {
	_, ok := s.cancelled.Load(id)
	return ok
}

// runServe 是 --serve 模式主循环；从 in 读请求直到 EOF。
func runServe(in io.Reader, out io.Writer) {
	state := &serveState{out: out, cache: make(map[string]scanResult)}
	var wg sync.WaitGroup
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req serveRequest
		if err := json.Unmarshal(line, &req); err != nil {
			state.emit(serveError{Event: "error", ID: "", Message: "bad request: " + err.Error()})
			continue
		}
		switch req.Op {
		case "cancel":
			state.cancelled.Store(req.ID, struct{}{})
			if cancel, ok := state.cancels.Load(req.ID); ok {
				cancel.(context.CancelFunc)()
			}
		case "scan", "children", "rescan":
			if req.Path == "" {
				state.emit(serveError{Event: "error", ID: req.ID, Message: "missing path"})
				continue
			}
			wg.Add(1)
			go func(req serveRequest) {
				defer wg.Done()
				state.handleScan(req, req.Op == "rescan")
			}(req)
		default:
			state.emit(serveError{Event: "error", ID: req.ID, Message: "unknown op: " + req.Op})
		}
	}
	wg.Wait()
}

func (s *serveState) handleScan(req serveRequest, bypassCache bool) {
	// 缓存命中：下钻/回退不重扫（AC-2）
	if !bypassCache {
		s.cacheMu.Lock()
		cached, ok := s.cache[req.Path]
		s.cacheMu.Unlock()
		if ok {
			s.emitResult(req.ID, req.Path, cached, true)
			return
		}
	}

	info, err := os.Stat(req.Path)
	if err != nil {
		s.emit(serveError{Event: "error", ID: req.ID, Message: err.Error()})
		return
	}
	if !info.IsDir() {
		s.emit(serveError{Event: "error", ID: req.ID, Message: "not a directory: " + req.Path})
		return
	}

	var filesScanned, dirsScanned, bytesScanned int64
	var currentPath atomic.Value
	currentPath.Store("")

	// 渐进式实时扫描（复用 TUI 的 live 机制）：首帧立刻发当前层全部条目
	// （文件即终值、目录先挂缓存/估值），每个子目录算完推送最终大小，
	// liveScanComplete 给出权威结果；ctx 支持真取消。
	limiter := newScanLimiter(0)
	entries, targets, totalSize, totalFiles, largeFiles, err := readLiveScanInitialEntries(req.Path, limiter)
	if err != nil {
		s.emit(serveError{Event: "error", ID: req.ID, Message: err.Error()})
		return
	}
	atomic.AddInt64(&filesScanned, totalFiles)
	atomic.AddInt64(&bytesScanned, totalSize)

	for _, entry := range entries {
		s.emitNode(req.ID, entry)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.cancels.Store(req.ID, cancel)
	defer s.cancels.Delete(req.ID)

	events := make(chan liveScanEventMsg, max(len(targets)*4, 8))
	go runLiveScan(ctx, 0, req.Path, entries, targets, totalSize, totalFiles, largeFiles,
		limiter, &filesScanned, &dirsScanned, &bytesScanned, &currentPath, events)

	// 进度节流：200ms 一条（设计性能策略）
	progressDone := make(chan struct{})
	var progressWG sync.WaitGroup
	progressWG.Add(1)
	go func() {
		defer progressWG.Done()
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-progressDone:
				return
			case <-ticker.C:
				if s.isCancelled(req.ID) {
					continue
				}
				current, _ := currentPath.Load().(string)
				s.emit(serveProgress{
					Event: "scan_progress", ID: req.ID,
					Files:   atomic.LoadInt64(&filesScanned),
					Dirs:    atomic.LoadInt64(&dirsScanned),
					Bytes:   atomic.LoadInt64(&bytesScanned),
					Current: current,
				})
			}
		}
	}()
	defer func() {
		close(progressDone)
		progressWG.Wait()
	}()

	for msg := range events {
		switch msg.kind {
		case liveScanChildProgress, liveScanChildDone:
			s.emitNode(req.ID, msg.entry)
		case liveScanComplete:
			s.cacheMu.Lock()
			s.cache[req.Path] = msg.result
			s.cacheMu.Unlock()
			s.emitResult(req.ID, req.Path, msg.result, false)
			return
		case liveScanFailed:
			s.emit(serveError{Event: "error", ID: req.ID, Message: "scan failed: " + errText(msg.err)})
			return
		case liveScanCanceled:
			return // 取消：不再发任何事件
		}
	}
}

func errText(err error) string {
	if err == nil {
		return "unknown"
	}
	return err.Error()
}

func (s *serveState) emitNode(id string, entry dirEntry) {
	if s.isCancelled(id) {
		return
	}
	node := serveNode{
		Event: "node", ID: id,
		Name: entry.Name, Path: entry.Path,
		Size: entry.Size, IsDir: entry.IsDir,
		Cleanable: entry.IsDir && isCleanableDir(entry.Path),
	}
	if !entry.LastAccess.IsZero() {
		node.LastAccess = entry.LastAccess.Format("2006-01-02")
	}
	s.emit(node)
}

func (s *serveState) emitResult(id, dir string, result scanResult, cached bool) {
	if s.isCancelled(id) {
		return // 取消后不再发事件；结果已进缓存供下次命中
	}
	for _, entry := range result.Entries {
		s.emitNode(id, entry)
	}
	s.emit(serveDone{
		Event: "scan_done", ID: id, Dir: dir,
		TotalSize: result.TotalSize, ItemCount: len(result.Entries),
		Cached: cached,
	})
}
