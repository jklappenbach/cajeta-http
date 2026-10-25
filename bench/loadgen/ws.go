package main

import (
	"bytes"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Per-round-trip stall limit: a server that stops echoing costs one client
// this long and counts as an error, instead of hanging the run.
const wsStallTimeout = 10 * time.Second

type wsResult struct {
	Clients           int    `json:"clients"`
	Connected         int    `json:"connected"`
	DeflateNegotiated int    `json:"deflate_negotiated"`
	Messages          int64  `json:"messages"`
	Mismatches        int64  `json:"mismatches"`
	Errors            int64  `json:"errors"`
	ElapsedNs         int64  `json:"elapsed_ns"`
	Bytes             int64  `json:"bytes"`
	FirstError        string `json:"first_error,omitempty"`
}

type wsClientStats struct {
	messages, mismatches, errors, bytes int64
	err                                 error
	stopped                             time.Time
}

func cmdWS(args []string) int {
	if len(args) != 5 {
		usageExit("ws takes <url> <clients> <seconds> <size> <deflate 0|1>")
	}
	target := wsURL(args[0])
	clients := intArg("clients", args[1], 1)
	seconds := intArg("seconds", args[2], 1)
	size := intArg("size", args[3], 1)
	if args[4] != "0" && args[4] != "1" {
		usageExit("deflate must be 0 or 1")
	}
	deflate := args[4] == "1"

	dialer := websocket.Dialer{
		HandshakeTimeout:  10 * time.Second,
		EnableCompression: deflate, // false: no Sec-WebSocket-Extensions offered at all
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
		ReadBufferSize:    min(max(size+64, 4096), 1<<20),
		WriteBufferSize:   min(max(size+64, 4096), 1<<20),
	}

	res := wsResult{Clients: clients}
	var firstErr error
	noteErr := func(err error) {
		if firstErr == nil && err != nil {
			firstErr = err
		}
	}

	// Phase 1: dial every client before the clock starts.
	conns := make([]*websocket.Conn, clients)
	dialErrs := make([]error, clients)
	negotiated := make([]bool, clients)
	var wg sync.WaitGroup
	for i := 0; i < clients; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, resp, err := dialer.Dial(target, nil)
			if err != nil {
				if resp != nil {
					err = fmt.Errorf("%w (HTTP %d)", err, resp.StatusCode)
				}
				dialErrs[i] = err
				return
			}
			if deflate && hasDeflate(resp.Header) {
				negotiated[i] = true
				c.EnableWriteCompression(true)
			}
			c.SetReadLimit(int64(size) + 1)
			conns[i] = c
		}(i)
	}
	wg.Wait()
	for i := 0; i < clients; i++ {
		if conns[i] != nil {
			res.Connected++
		} else {
			res.Errors++
			noteErr(dialErrs[i])
		}
		if negotiated[i] {
			res.DeflateNegotiated++
		}
	}

	// Phase 2: echo loops.
	stats := make([]wsClientStats, clients)
	start := time.Now()
	deadline := start.Add(time.Duration(seconds) * time.Second)
	for i := 0; i < clients; i++ {
		if conns[i] == nil {
			continue
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			wsClient(conns[i], i, size, deadline, &stats[i])
		}(i)
	}
	wg.Wait()

	last := start
	for i := range stats {
		s := &stats[i]
		res.Messages += s.messages
		res.Mismatches += s.mismatches
		res.Errors += s.errors
		res.Bytes += s.bytes
		noteErr(s.err)
		if s.stopped.After(last) {
			last = s.stopped
		}
	}
	res.ElapsedNs = last.Sub(start).Nanoseconds()
	if firstErr != nil {
		res.FirstError = firstErr.Error()
	}
	emit(res)
	return 0
}

func wsClient(c *websocket.Conn, id, size int, deadline time.Time, s *wsClientStats) {
	defer c.Close()
	out := make([]byte, 0, size+128)
	in := make([]byte, size+1)
	for seq := 0; time.Now().Before(deadline); seq++ {
		out = fillPayload(out, id, seq, size)
		c.SetWriteDeadline(time.Now().Add(wsStallTimeout))
		if err := c.WriteMessage(websocket.BinaryMessage, out); err != nil {
			s.errors++
			s.err = fmt.Errorf("client %d write: %w", id, err)
			s.stopped = time.Now()
			return
		}
		c.SetReadDeadline(time.Now().Add(wsStallTimeout))
		mt, r, err := c.NextReader()
		if err != nil {
			s.errors++
			s.err = fmt.Errorf("client %d read: %w", id, err)
			s.stopped = time.Now()
			return
		}
		n, err := io.ReadFull(r, in) // in is size+1: exact-size message ends in ErrUnexpectedEOF
		switch {
		case err == nil, errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, io.EOF):
			// n bytes of message read (n == size+1 means it was too long)
		default:
			s.errors++
			s.err = fmt.Errorf("client %d read: %w", id, err)
			s.stopped = time.Now()
			return
		}
		if mt == websocket.BinaryMessage && n == size && bytes.Equal(in[:n], out) {
			s.messages++
			s.bytes += int64(n)
		} else {
			s.mismatches++
			if s.err == nil {
				s.err = fmt.Errorf("client %d seq %d: echo mismatch (opcode %d, %d bytes)", id, seq, mt, n)
			}
		}
	}
	s.stopped = time.Now()
	// Orderly shutdown: close frame 1000, wait briefly for the peer's close.
	c.SetWriteDeadline(time.Now().Add(time.Second))
	if c.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "")) == nil {
		c.SetReadDeadline(time.Now().Add(time.Second))
		for {
			if _, _, err := c.NextReader(); err != nil {
				break
			}
		}
	}
}

var payloadWords = [...]string{
	"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
	"india", "juliett", "kilo", "lima", "mike", "november", "oscar", "papa",
	"quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray",
}

// fillPayload builds a deterministic, compressible-but-not-trivial message of
// exactly size bytes: JSON-ish lines that lead with the sequence number and
// client id, so every message differs and a stale echo cannot match.
func fillPayload(buf []byte, client, seq, size int) []byte {
	buf = buf[:0]
	for k := 0; len(buf) < size; k++ {
		h := uint64(client)*0x9E3779B97F4A7C15 ^ uint64(seq)*0xBF58476D1CE4E5B9 ^ uint64(k)*0x94D049BB133111EB
		h ^= h >> 31
		h *= 0xD6E8FEB86659FD93
		h ^= h >> 32
		buf = append(buf, `{"seq":`...)
		buf = strconv.AppendInt(buf, int64(seq), 10)
		buf = append(buf, `,"client":`...)
		buf = strconv.AppendInt(buf, int64(client), 10)
		buf = append(buf, `,"line":`...)
		buf = strconv.AppendInt(buf, int64(k), 10)
		buf = append(buf, `,"word":"`...)
		buf = append(buf, payloadWords[h%uint64(len(payloadWords))]...)
		buf = append(buf, `","value":`...)
		buf = strconv.AppendUint(buf, h%1000003, 10)
		buf = append(buf, "}\n"...)
	}
	return buf[:size]
}

func hasDeflate(h http.Header) bool {
	for _, v := range h.Values("Sec-WebSocket-Extensions") {
		if strings.Contains(strings.ToLower(v), "permessage-deflate") {
			return true
		}
	}
	return false
}

// wsURL accepts ws://, wss://, http:// or https://.
func wsURL(s string) string {
	u, err := url.Parse(s)
	if err != nil || u.Host == "" {
		usageExit("bad url " + strconv.Quote(s))
	}
	switch u.Scheme {
	case "ws", "wss":
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	default:
		usageExit("ws url must be ws://, wss://, http:// or https://")
	}
	return u.String()
}
