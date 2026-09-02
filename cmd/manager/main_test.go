/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func TestApplyLogDevelopmentInvalidValueWritesStderr(t *testing.T) {
	t.Setenv("LOG_DEVELOPMENT", "maybe")

	var buf bytes.Buffer
	opts := zap.Options{}
	err := applyLogDevelopment(&opts, &buf)
	if err == nil {
		t.Fatal("expected error for invalid LOG_DEVELOPMENT")
	}
	got := buf.String()
	if !strings.Contains(got, "maybe") {
		t.Fatalf("stderr %q does not mention the invalid value", got)
	}
	if !strings.Contains(got, "invalid LOG_DEVELOPMENT") {
		t.Fatalf("stderr %q does not explain the failure", got)
	}
}

func TestApplyLogDevelopmentTrue(t *testing.T) {
	t.Setenv("LOG_DEVELOPMENT", "true")

	opts := zap.Options{}
	if err := applyLogDevelopment(&opts, io.Discard); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !opts.Development {
		t.Fatal("Development = false, want true")
	}
}

func TestApplyLogDevelopmentFalse(t *testing.T) {
	t.Setenv("LOG_DEVELOPMENT", "false")

	opts := zap.Options{}
	if err := applyLogDevelopment(&opts, io.Discard); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Development {
		t.Fatal("Development = true, want false")
	}
}

func TestApplyLogDevelopmentUnsetLeavesDefault(t *testing.T) {
	t.Setenv("LOG_DEVELOPMENT", "true")
	if err := os.Unsetenv("LOG_DEVELOPMENT"); err != nil {
		t.Fatal(err)
	}

	opts := zap.Options{}
	var buf bytes.Buffer
	if err := applyLogDevelopment(&opts, &buf); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Development {
		t.Fatal("Development = true, want false when unset")
	}
	if buf.Len() != 0 {
		t.Fatalf("stderr write on unset: %q", buf.String())
	}
}
