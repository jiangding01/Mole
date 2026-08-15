package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// measurePathKB must agree with `du -sk` (the shell's reference measurement)
// on a tree with regular files, subdirectories, a symlink, and a hardlink
// pair — the exact surfaces where naive implementations drift (logical vs
// physical size, link following, double-counted inodes).
func TestMeasurePathKBMatchesDu(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "sub dir")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	big := filepath.Join(root, "big.bin")
	if err := os.WriteFile(big, bytes.Repeat([]byte("x"), 300*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "small.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(big, filepath.Join(sub, "hardlink.bin")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(big, filepath.Join(sub, "symlink.bin")); err != nil {
		t.Fatal(err)
	}

	for _, target := range []string{root, big} {
		out, err := exec.Command("du", "-skP", target).Output()
		if err != nil {
			t.Fatalf("du -skP %s: %v", target, err)
		}
		duKB := strings.Fields(string(out))[0]
		got := measurePathKB(target, 30*time.Second)
		if got != duKB {
			t.Errorf("measurePathKB(%s) = %s, du -sk = %s", target, got, duKB)
		}
	}
}

func TestMeasurePathKBMarkers(t *testing.T) {
	if got := measurePathKB(filepath.Join(t.TempDir(), "missing"), time.Second); got != "E" {
		t.Errorf("missing path: want E, got %s", got)
	}
}

func TestRunDuBatchOrderAndFraming(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a.txt")
	if err := os.WriteFile(a, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(root, "gone")
	in := strings.NewReader(a + "\x00" + missing + "\x00" + root + "\x00")
	var out bytes.Buffer
	if rc := runDuBatch(in, &out); rc != 0 {
		t.Fatalf("rc = %d", rc)
	}
	records := strings.Split(strings.TrimSuffix(out.String(), "\x00"), "\x00")
	if len(records) != 3 {
		t.Fatalf("want 3 records, got %d: %q", len(records), records)
	}
	for i, rec := range records {
		var idx int
		var val string
		if _, err := fmt.Sscanf(rec, "%d\t%s", &idx, &val); err != nil {
			t.Fatalf("record %d unparsable: %q", i, rec)
		}
		if idx != i {
			t.Errorf("record %d has index %d (order broken)", i, idx)
		}
	}
	if !strings.HasSuffix(records[1], "\tE") {
		t.Errorf("missing path should be E, got %q", records[1])
	}
}
