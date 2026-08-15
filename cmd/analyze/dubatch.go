package main

// --du-batch: batch physical-size measurement for the shell cleanup preview.
//
// stdin:  NUL-delimited paths.
// stdout: one NUL-delimited record per input path, in input order:
//         "<idx>\t<kb>"  measured (KB, du -sk basis: 1024-byte units, ceil)
//         "<idx>\tT"     per-path timeout hit (shell treats as size unknown)
//         "<idx>\tE"     measurement error (unreadable etc.; shell treats as 0)
//
// Semantics mirror `du -skP` / get_path_size_kb (lib/core/file_ops.sh):
// physical allocation from st_blocks (512-byte units), no symlink following,
// hardlinks deduplicated per input path by (dev, ino), directories contribute
// their own blocks, other devices are crossed (du has no -x there). Regular
// files and symlinks are a single lstat. The shell routes *.app bundles to
// its mdls path before calling us, so no Spotlight logic here.
//
// The index prefix lets the shell verify alignment: sizes feed display and
// stats only (never the delete set), but a misaligned batch would still show
// wrong numbers, so the consumer falls back to per-path sizing on any gap.

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
)

var (
	duBatchMode    = flag.Bool("du-batch", false, "batch size measurement: NUL paths on stdin, NUL records on stdout")
	duBatchTimeout = flag.Int("du-batch-timeout", 30, "per-path measurement budget in seconds")
)

func runDuBatch(in io.Reader, out io.Writer) int {
	reader := bufio.NewReaderSize(in, 256*1024)
	var paths []string
	for {
		chunk, err := reader.ReadString(0)
		if len(chunk) > 0 {
			p := chunk
			if p[len(p)-1] == 0 {
				p = p[:len(p)-1]
			}
			if p != "" {
				paths = append(paths, p)
			}
		}
		if err != nil {
			break
		}
	}

	results := make([]string, len(paths))
	budget := time.Duration(*duBatchTimeout) * time.Second

	workers := runtime.NumCPU()
	if workers > 8 {
		workers = 8
	}
	if workers < 1 {
		workers = 1
	}
	var wg sync.WaitGroup
	jobs := make(chan int)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range jobs {
				results[idx] = measurePathKB(paths[idx], budget)
			}
		}()
	}
	for idx := range paths {
		jobs <- idx
	}
	close(jobs)
	wg.Wait()

	writer := bufio.NewWriterSize(out, 64*1024)
	for idx, res := range results {
		fmt.Fprintf(writer, "%d\t%s\x00", idx, res)
	}
	writer.Flush()
	return 0
}

// measurePathKB returns the du -sk equivalent for one path: decimal KB,
// "T" on budget exhaustion, "E" on measurement failure. A timeout is
// cancellation, not a zero-byte measurement (same rule as get_path_size_kb):
// the shell keeps the item and reports its size as unknown.
func measurePathKB(path string, budget time.Duration) string {
	deadline := time.Now().Add(budget)

	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return "E"
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		// Regular file / symlink / device: one lstat, same as the shell's
		// stat -f%b fast path. ceil(blocks/2) converts 512B units to KB.
		return fmt.Sprintf("%d", (st.Blocks+1)/2)
	}

	var totalBlocks int64
	seen := make(map[[2]uint64]struct{})
	checked := 0
	timedOut := false
	walkErr := filepath.WalkDir(path, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			// du reports a nonzero status for unreadable children and the
			// shell refuses the partial aggregate; mirror that.
			return err
		}
		checked++
		if checked%256 == 0 && time.Now().After(deadline) {
			timedOut = true
			return filepath.SkipAll
		}
		info, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		sys, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return fmt.Errorf("no stat for %q", d.Name())
		}
		if sys.Nlink > 1 && !d.IsDir() {
			key := [2]uint64{uint64(uint32(sys.Dev)), sys.Ino}
			if _, dup := seen[key]; dup {
				return nil
			}
			seen[key] = struct{}{}
		}
		totalBlocks += sys.Blocks
		return nil
	})
	if timedOut {
		return "T"
	}
	if walkErr != nil {
		return "E"
	}
	return fmt.Sprintf("%d", (totalBlocks+1)/2)
}
