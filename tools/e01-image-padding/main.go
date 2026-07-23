package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
)

const paddingBlockSize = 1 << 20

func main() {
	mib := flag.Int64("mib", -1, "padding size in MiB")
	byteCount := flag.Int64("bytes", -1, "exact padding size in bytes")
	output := flag.String("output", "", "output file")
	seed := flag.String("seed", "", "stable experiment/version/variant identity")
	flag.Parse()
	if *output == "" || *seed == "" || (*mib >= 0) == (*byteCount >= 0) {
		fmt.Fprintln(os.Stderr, "--output, --seed, and exactly one of --mib/--bytes are required")
		os.Exit(2)
	}
	var size int64
	if *byteCount >= 0 {
		size = *byteCount
	} else {
		if *mib > math.MaxInt64/(1<<20) {
			fmt.Fprintln(os.Stderr, "--mib overflows the byte count")
			os.Exit(2)
		}
		size = *mib * (1 << 20)
	}

	file, err := os.OpenFile(*output, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	digest, writeErr := writePadding(file, size, *seed)
	closeErr := file.Close()
	if writeErr != nil {
		fmt.Fprintln(os.Stderr, writeErr)
		os.Exit(1)
	}
	if closeErr != nil {
		fmt.Fprintln(os.Stderr, closeErr)
		os.Exit(1)
	}
	fmt.Printf("bytes=%d sha256=%s\n", size, hex.EncodeToString(digest[:]))
}

// writePadding writes a stable AES-CTR byte stream. Unlike a zero-filled file,
// it remains effectively incompressible in an OCI layer, so the configured
// image-size factor represents real registry transfer and unpack work.
func writePadding(w io.Writer, size int64, seed string) ([sha256.Size]byte, error) {
	if size < 0 {
		return [sha256.Size]byte{}, fmt.Errorf("padding size cannot be negative")
	}
	if seed == "" {
		return [sha256.Size]byte{}, fmt.Errorf("padding seed cannot be empty")
	}
	key := sha256.Sum256([]byte("cloud-elastic-pilot/e01-image-padding/key/v1/" + seed))
	iv := sha256.Sum256([]byte("cloud-elastic-pilot/e01-image-padding/iv/v1/" + seed))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	stream := cipher.NewCTR(block, iv[:aes.BlockSize])
	zeros := make([]byte, paddingBlockSize)
	encoded := make([]byte, paddingBlockSize)
	hash := sha256.New()
	remaining := size
	for remaining > 0 {
		chunk := int64(len(encoded))
		if remaining < chunk {
			chunk = remaining
		}
		stream.XORKeyStream(encoded[:chunk], zeros[:chunk])
		if _, err := w.Write(encoded[:chunk]); err != nil {
			return [sha256.Size]byte{}, err
		}
		if _, err := hash.Write(encoded[:chunk]); err != nil {
			return [sha256.Size]byte{}, err
		}
		remaining -= chunk
	}
	var digest [sha256.Size]byte
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}
