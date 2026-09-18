package main

import (
	"fmt"
	"os"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/envelope"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: recompute_digest.go OVERLAY_JSON")
		os.Exit(2)
	}
	//nolint:gosec // this helper intentionally reads the caller-selected evidence file.
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	digest, err := envelope.ComputeDigestFromWire(raw)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(digest)
}
