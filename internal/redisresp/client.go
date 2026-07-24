package redisresp

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"strconv"
	"strings"
	"time"
)

const (
	maxBulkBytes     = 64 << 20
	defaultIOTimeout = 30 * time.Second
)

type dialContextFunc func(context.Context, string, string) (net.Conn, error)

// Client implements the small RESP2 subset used by the E04 Redis workload.
// A fresh connection is used for every operation so a blocked BLPOP cannot
// stall queue-depth or completion observations.
type Client struct {
	address     string
	password    string
	dialContext dialContextFunc
}

func New(address, password string) (*Client, error) {
	if strings.TrimSpace(address) == "" {
		return nil, errors.New("Redis address is required")
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	return &Client{
		address:     address,
		password:    password,
		dialContext: dialer.DialContext,
	}, nil
}

func (c *Client) Ping(ctx context.Context) error {
	value, err := c.do(ctx, "PING")
	if err != nil {
		return err
	}
	if text, ok := value.(string); !ok || text != "PONG" {
		return fmt.Errorf("unexpected PING response: %#v", value)
	}
	return nil
}

func (c *Client) Delete(ctx context.Context, keys ...string) (int64, error) {
	if len(keys) == 0 {
		return 0, errors.New("at least one Redis key is required")
	}
	args := append([]string{"DEL"}, keys...)
	return integer(c.do(ctx, args...))
}

func (c *Client) RPush(ctx context.Context, key, value string) (int64, error) {
	if key == "" {
		return 0, errors.New("Redis list key is required")
	}
	return integer(c.do(ctx, "RPUSH", key, value))
}

func (c *Client) LLen(ctx context.Context, key string) (int64, error) {
	if key == "" {
		return 0, errors.New("Redis list key is required")
	}
	return integer(c.do(ctx, "LLEN", key))
}

func (c *Client) BLPop(ctx context.Context, key string, timeout time.Duration) (string, bool, error) {
	if key == "" {
		return "", false, errors.New("Redis list key is required")
	}
	if timeout <= 0 {
		return "", false, errors.New("BLPOP timeout must be positive")
	}
	seconds := int64(math.Ceil(timeout.Seconds()))
	value, err := c.do(ctx, "BLPOP", key, strconv.FormatInt(seconds, 10))
	if err != nil {
		return "", false, err
	}
	if value == nil {
		return "", false, nil
	}
	items, ok := value.([]any)
	if !ok || len(items) != 2 {
		return "", false, fmt.Errorf("unexpected BLPOP response: %#v", value)
	}
	return stringValue(items[1])
}

func (c *Client) do(ctx context.Context, args ...string) (any, error) {
	if len(args) == 0 || args[0] == "" {
		return nil, errors.New("Redis command is required")
	}
	conn, err := c.dialContext(ctx, "tcp", c.address)
	if err != nil {
		return nil, fmt.Errorf("connect to Redis: %w", err)
	}
	defer conn.Close()
	deadline := time.Now().Add(defaultIOTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return nil, fmt.Errorf("set Redis deadline: %w", err)
	}
	reader := bufio.NewReader(conn)
	if c.password != "" {
		if err := writeCommand(conn, "AUTH", c.password); err != nil {
			return nil, fmt.Errorf("write Redis AUTH: %w", err)
		}
		response, err := readValue(reader)
		if err != nil {
			return nil, fmt.Errorf("Redis AUTH: %w", err)
		}
		if response != "OK" {
			return nil, fmt.Errorf("unexpected Redis AUTH response: %#v", response)
		}
	}
	if err := writeCommand(conn, args...); err != nil {
		return nil, fmt.Errorf("write Redis %s: %w", args[0], err)
	}
	value, err := readValue(reader)
	if err != nil {
		return nil, fmt.Errorf("Redis %s: %w", args[0], err)
	}
	return value, nil
}

func integer(value any, err error) (int64, error) {
	if err != nil {
		return 0, err
	}
	number, ok := value.(int64)
	if !ok {
		return 0, fmt.Errorf("unexpected Redis integer response: %#v", value)
	}
	return number, nil
}

func stringValue(value any) (string, bool, error) {
	text, ok := value.(string)
	if !ok {
		return "", false, fmt.Errorf("unexpected Redis string response: %#v", value)
	}
	return text, true, nil
}

func writeCommand(writer io.Writer, args ...string) error {
	var payload bytes.Buffer
	fmt.Fprintf(&payload, "*%d\r\n", len(args))
	for _, arg := range args {
		fmt.Fprintf(&payload, "$%d\r\n", len(arg))
		payload.WriteString(arg)
		payload.WriteString("\r\n")
	}
	_, err := writer.Write(payload.Bytes())
	return err
}

func readValue(reader *bufio.Reader) (any, error) {
	prefix, err := reader.ReadByte()
	if err != nil {
		return nil, err
	}
	switch prefix {
	case '+':
		return readLine(reader)
	case '-':
		message, err := readLine(reader)
		if err != nil {
			return nil, err
		}
		return nil, errors.New(message)
	case ':':
		line, err := readLine(reader)
		if err != nil {
			return nil, err
		}
		return strconv.ParseInt(line, 10, 64)
	case '$':
		line, err := readLine(reader)
		if err != nil {
			return nil, err
		}
		length, err := strconv.ParseInt(line, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid RESP bulk length %q: %w", line, err)
		}
		if length == -1 {
			return nil, nil
		}
		if length < 0 || length > maxBulkBytes {
			return nil, fmt.Errorf("RESP bulk length out of range: %d", length)
		}
		payload := make([]byte, length+2)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return nil, err
		}
		if !bytes.Equal(payload[length:], []byte("\r\n")) {
			return nil, errors.New("RESP bulk value is missing CRLF")
		}
		return string(payload[:length]), nil
	case '*':
		line, err := readLine(reader)
		if err != nil {
			return nil, err
		}
		count, err := strconv.ParseInt(line, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid RESP array length %q: %w", line, err)
		}
		if count == -1 {
			return nil, nil
		}
		if count < 0 || count > 1_000_000 {
			return nil, fmt.Errorf("RESP array length out of range: %d", count)
		}
		items := make([]any, 0, count)
		for index := int64(0); index < count; index++ {
			item, err := readValue(reader)
			if err != nil {
				return nil, err
			}
			items = append(items, item)
		}
		return items, nil
	default:
		return nil, fmt.Errorf("unknown RESP prefix %q", prefix)
	}
}

func readLine(reader *bufio.Reader) (string, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	if !strings.HasSuffix(line, "\r\n") {
		return "", errors.New("RESP line is missing CRLF")
	}
	return strings.TrimSuffix(line, "\r\n"), nil
}
