//go:build darwin

package main

// analyze --serve 协议用例（设计 §5.4 / §11 契约）。

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeServeFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	mustWrite := func(rel string, size int) {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, bytes.Repeat([]byte("x"), size), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite("docs/a.txt", 1000)
	mustWrite("docs/b.txt", 2000)
	mustWrite("media/big.bin", 50_000)
	mustWrite("top.txt", 500)
	return root
}

type serveEvent map[string]any

func runServeScript(t *testing.T, requests []string) []serveEvent {
	t.Helper()
	in := strings.NewReader(strings.Join(requests, "\n") + "\n")
	var out bytes.Buffer
	runServe(in, &out)

	var events []serveEvent
	scanner := bufio.NewScanner(&out)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var ev serveEvent
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			t.Fatalf("non-JSON line in protocol stream: %q", scanner.Text())
		}
		events = append(events, ev)
	}
	return events
}

func filterEvents(events []serveEvent, id, kind string) []serveEvent {
	var got []serveEvent
	for _, ev := range events {
		if ev["id"] == id && ev["event"] == kind {
			got = append(got, ev)
		}
	}
	return got
}

// runServeConversation drives runServe interactively over a pair of pipes,
// waiting for each request's scan_done event before writing the next
// request to stdin. This mirrors how the real GUI client behaves: it never
// issues a follow-up request for a path before the prior one settles.
//
// runServeScript, by contrast, writes every request to stdin up front.
// scan/children/rescan are dispatched onto goroutines concurrently by
// design (cancel needs to interrupt an in-flight scan), so a later
// children/rescan request for the same path can start racing the earlier
// scan before that scan has populated the cache. runServeConversation
// restores the real ordering by only sending request N+1 after request N's
// scan_done event has actually been observed on stdout.
func runServeConversation(t *testing.T, requests []string) []serveEvent {
	t.Helper()

	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()

	serveDone := make(chan struct{})
	go func() {
		defer close(serveDone)
		runServe(stdinR, stdoutW)
	}()

	type scannedLine struct {
		ev  serveEvent
		err error
	}
	lines := make(chan scannedLine, 64)
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		defer close(lines)
		scanner := bufio.NewScanner(stdoutR)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			var ev serveEvent
			if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
				lines <- scannedLine{err: fmt.Errorf("non-JSON line in protocol stream: %q", scanner.Text())}
				continue
			}
			lines <- scannedLine{ev: ev}
		}
	}()

	const stepTimeout = 10 * time.Second
	var all []serveEvent
	waitForScanDone := func(id string) {
		timeout := time.NewTimer(stepTimeout)
		defer timeout.Stop()
		for {
			select {
			case line, ok := <-lines:
				if !ok {
					t.Fatalf("event stream closed before scan_done for id=%s", id)
					return
				}
				if line.err != nil {
					t.Fatal(line.err)
				}
				all = append(all, line.ev)
				if line.ev["id"] == id && line.ev["event"] == "scan_done" {
					return
				}
			case <-timeout.C:
				t.Fatalf("timed out waiting for scan_done id=%s", id)
				return
			}
		}
	}

	for _, req := range requests {
		var parsed serveRequest
		if err := json.Unmarshal([]byte(req), &parsed); err != nil {
			t.Fatalf("bad test request json %q: %v", req, err)
		}
		if _, err := io.WriteString(stdinW, req+"\n"); err != nil {
			t.Fatalf("write request %q: %v", req, err)
		}
		waitForScanDone(parsed.ID)
	}

	if err := stdinW.Close(); err != nil {
		t.Fatalf("close stdin: %v", err)
	}

	select {
	case <-serveDone:
	case <-time.After(stepTimeout):
		t.Fatal("runServe did not return after stdin was closed")
	}
	if err := stdoutW.Close(); err != nil {
		t.Fatalf("close stdout: %v", err)
	}

	select {
	case <-readerDone:
	case <-time.After(stepTimeout):
		t.Fatal("stdout reader did not finish after runServe returned")
	}
	// Drain anything buffered after the last scan_done we waited on (e.g. a
	// trailing scan_progress tick emitted before that scan's cleanup ran).
	for line := range lines {
		if line.err != nil {
			t.Fatal(line.err)
		}
		all = append(all, line.ev)
	}

	return all
}

func TestServeScanEmitsNodesAndDone(t *testing.T) {
	root := writeServeFixture(t)
	events := runServeScript(t, []string{
		`{"op":"scan","id":"q1","path":"` + root + `"}`,
	})

	nodes := filterEvents(events, "q1", "node")
	// 流式协议：同一路径会有多次更新事件（初值→终值），按 name 取最后一次
	byName := map[string]serveEvent{}
	for _, n := range nodes {
		byName[n["name"].(string)] = n
	}
	if len(byName) != 3 { // docs, media, top.txt
		t.Fatalf("expected 3 unique nodes, got %d: %v", len(byName), byName)
	}
	if byName["docs"] == nil || byName["docs"]["is_dir"] != true {
		t.Fatalf("docs node missing or not dir: %v", byName["docs"])
	}
	if byName["top.txt"] == nil || byName["top.txt"]["is_dir"] != false {
		t.Fatalf("top.txt node wrong: %v", byName["top.txt"])
	}
	if size := byName["media"]["size"].(float64); size < 50_000 {
		t.Fatalf("media size too small: %v", size)
	}

	done := filterEvents(events, "q1", "scan_done")
	if len(done) != 1 {
		t.Fatalf("expected one scan_done, got %d", len(done))
	}
	if done[0]["cached"] != false {
		t.Fatalf("first scan must not be cached")
	}
	if int(done[0]["item_count"].(float64)) != 3 {
		t.Fatalf("item_count = %v, want 3", done[0]["item_count"])
	}
}

func TestServeChildrenHitsCacheAndRescanBypasses(t *testing.T) {
	root := writeServeFixture(t)
	// scan/children/rescan for the same path only exercise the cache
	// correctly if each request is sent after the previous one's scan_done
	// lands, so this test drives runServe interactively rather than through
	// runServeScript's fire-and-forget stdin dump (see runServeConversation).
	events := runServeConversation(t, []string{
		`{"op":"scan","id":"q1","path":"` + root + `"}`,
		`{"op":"children","id":"q2","path":"` + root + `"}`,
		`{"op":"rescan","id":"q3","path":"` + root + `"}`,
	})

	// 下钻回退命中缓存（AC-2）
	done2 := filterEvents(events, "q2", "scan_done")
	if len(done2) != 1 || done2[0]["cached"] != true {
		t.Fatalf("children should hit cache: %v", done2)
	}
	// 缓存命中也必须携带完整 node 列表（缓存回放为单次终值，无更新流）
	uniq := map[string]bool{}
	for _, n := range filterEvents(events, "q2", "node") {
		uniq[n["name"].(string)] = true
	}
	if len(uniq) != 3 {
		t.Fatalf("cached children nodes = %d, want 3", len(uniq))
	}
	// rescan 绕过缓存
	done3 := filterEvents(events, "q3", "scan_done")
	if len(done3) != 1 || done3[0]["cached"] != false {
		t.Fatalf("rescan must bypass cache: %v", done3)
	}
}

func TestServeErrors(t *testing.T) {
	events := runServeScript(t, []string{
		`{"op":"scan","id":"e1","path":"/definitely/not/here/xyz"}`,
		`{"op":"scan","id":"e2"}`,
		`{"op":"frobnicate","id":"e3","path":"/tmp"}`,
		`not json at all`,
	})
	for _, id := range []string{"e1", "e2", "e3"} {
		if len(filterEvents(events, id, "error")) != 1 {
			t.Fatalf("expected error event for %s", id)
		}
	}
}

func TestServeCancelSuppressesEvents(t *testing.T) {
	root := writeServeFixture(t)
	// cancel 先于 scan 入队：结果事件必须被抑制（node/scan_done 均不发）
	events := runServeScript(t, []string{
		`{"op":"cancel","id":"q1"}`,
		`{"op":"scan","id":"q1","path":"` + root + `"}`,
	})
	if n := len(filterEvents(events, "q1", "node")); n != 0 {
		t.Fatalf("cancelled scan leaked %d node events", n)
	}
	if n := len(filterEvents(events, "q1", "scan_done")); n != 0 {
		t.Fatalf("cancelled scan leaked scan_done")
	}
}

var _ io.Reader = (*strings.Reader)(nil)
