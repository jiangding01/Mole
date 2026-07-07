package main

import "testing"

func TestDecodePSVis(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// Real-world sample: 企业微信 as emitted by macOS ps vis escaping.
		{"cjk app name", "M-dM-<M^AM-dM-8M^ZM-eM->M-.M-dM-?M-!", "企业微信"},
		{"mixed path", "/Applications/M-dM-<M^AM-dM-8M^ZM-eM->M-.M-dM-?M-!.app/Contents/MacOS/helper", "/Applications/企业微信.app/Contents/MacOS/helper"},
		{"plain ascii untouched", "/usr/libexec/trustd --agent", "/usr/libexec/trustd --agent"},
		// A literal M- in a genuine name must survive: decoding would produce
		// invalid UTF-8, so the original is kept.
		{"literal M- name kept", "M-Audio Helper", "M-Audio Helper"},
		{"empty", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := decodePSVis(tc.in); got != tc.want {
				t.Fatalf("decodePSVis(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
