package redisresp

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"reflect"
	"testing"
	"time"
)

func TestWriteCommand(t *testing.T) {
	var output bytes.Buffer
	if err := writeCommand(&output, "RPUSH", "queue", "message"); err != nil {
		t.Fatal(err)
	}
	const expected = "*3\r\n$5\r\nRPUSH\r\n$5\r\nqueue\r\n$7\r\nmessage\r\n"
	if output.String() != expected {
		t.Fatalf("command = %q, want %q", output.String(), expected)
	}
}

func TestReadValue(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  any
	}{
		{name: "simple", input: "+PONG\r\n", want: "PONG"},
		{name: "integer", input: ":3\r\n", want: int64(3)},
		{name: "bulk", input: "$7\r\nmessage\r\n", want: "message"},
		{name: "nil bulk", input: "$-1\r\n", want: nil},
		{name: "array", input: "*2\r\n$5\r\nqueue\r\n$7\r\nmessage\r\n", want: []any{"queue", "message"}},
		{name: "nil array", input: "*-1\r\n", want: nil},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := readValue(bufio.NewReader(bytes.NewBufferString(test.input)))
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("value = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestClientAuthenticatesAndRunsCommand(t *testing.T) {
	clientConnection, serverConnection := net.Pipe()
	defer serverConnection.Close()
	client := &Client{
		address:  "redis.test:6379",
		password: "secret",
		dialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientConnection, nil
		},
	}
	serverDone := make(chan error, 1)
	go func() {
		reader := bufio.NewReader(serverConnection)
		auth, err := readValue(reader)
		if err != nil {
			serverDone <- err
			return
		}
		if !reflect.DeepEqual(auth, []any{"AUTH", "secret"}) {
			t.Errorf("AUTH command = %#v", auth)
		}
		if _, err := serverConnection.Write([]byte("+OK\r\n")); err != nil {
			serverDone <- err
			return
		}
		command, err := readValue(reader)
		if err != nil {
			serverDone <- err
			return
		}
		if !reflect.DeepEqual(command, []any{"LLEN", "queue"}) {
			t.Errorf("LLEN command = %#v", command)
		}
		_, err = serverConnection.Write([]byte(":4\r\n"))
		serverDone <- err
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	length, err := client.LLen(ctx, "queue")
	if err != nil {
		t.Fatal(err)
	}
	if length != 4 {
		t.Fatalf("length = %d, want 4", length)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestBLPopTimeoutReturnsNoValue(t *testing.T) {
	clientConnection, serverConnection := net.Pipe()
	defer serverConnection.Close()
	client := &Client{
		address: "redis.test:6379",
		dialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientConnection, nil
		},
	}
	go func() {
		reader := bufio.NewReader(serverConnection)
		_, _ = readValue(reader)
		_, _ = serverConnection.Write([]byte("*-1\r\n"))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	value, found, err := client.BLPop(ctx, "queue", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if found || value != "" {
		t.Fatalf("got value=%q found=%v, want timeout", value, found)
	}
}
