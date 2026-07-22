package main

import (
	"bytes"
	"compress/gzip"
	"testing"
)

func TestWritePaddingIsDeterministic(t *testing.T) {
	const size = int64((1 << 20) + 17)
	var first, second bytes.Buffer
	firstDigest, err := writePadding(&first, size, "e01/v1/commit/large")
	if err != nil {
		t.Fatal(err)
	}
	secondDigest, err := writePadding(&second, size, "e01/v1/commit/large")
	if err != nil {
		t.Fatal(err)
	}
	if first.Len() != int(size) || !bytes.Equal(first.Bytes(), second.Bytes()) || firstDigest != secondDigest {
		t.Fatal("padding stream is not stable")
	}
}

func TestWritePaddingChangesWithSeed(t *testing.T) {
	var first, second bytes.Buffer
	if _, err := writePadding(&first, 4096, "e01/v1/commit-a/large"); err != nil {
		t.Fatal(err)
	}
	if _, err := writePadding(&second, 4096, "e01/v1/commit-b/large"); err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first.Bytes(), second.Bytes()) {
		t.Fatal("different source identities produced the same padding")
	}
}

func TestWritePaddingIsNotEffectivelyCompressible(t *testing.T) {
	const size = int64(1 << 20)
	var raw bytes.Buffer
	if _, err := writePadding(&raw, size, "e01/v1/commit/large"); err != nil {
		t.Fatal(err)
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(raw.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if compressed.Len() < int(size*98/100) {
		t.Fatalf("padding compressed from %d to %d bytes", size, compressed.Len())
	}
}

func TestWritePaddingRejectsNegativeSize(t *testing.T) {
	if _, err := writePadding(ioDiscard{}, -1, "seed"); err == nil {
		t.Fatal("expected negative size error")
	}
	if _, err := writePadding(ioDiscard{}, 0, ""); err == nil {
		t.Fatal("expected empty seed error")
	}
}

type ioDiscard struct{}

func (ioDiscard) Write(payload []byte) (int, error) { return len(payload), nil }
