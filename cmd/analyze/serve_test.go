//go:build darwin

package main

// analyze --serve 协议用例（设计 §5.4 / §11 契约）。

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	events := runServeScript(t, []string{
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
