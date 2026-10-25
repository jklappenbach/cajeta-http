package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Whole-stream limit per client; a server that stalls costs this, not forever.
const sseStreamTimeout = 120 * time.Second

type sseResult struct {
	Clients    int    `json:"clients"`
	Complete   int    `json:"complete"`
	Events     int64  `json:"events"`
	Errors     int    `json:"errors"`
	ElapsedNs  int64  `json:"elapsed_ns"`
	FirstError string `json:"first_error,omitempty"`
}

func cmdSSE(args []string) int {
	if len(args) != 3 {
		usageExit("sse takes <url> <clients> <events>")
	}
	u, err := url.Parse(args[0])
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		usageExit("bad url " + strconv.Quote(args[0]))
	}
	clients := intArg("clients", args[1], 1)
	events := intArg("events", args[2], 0)
	q := u.Query()
	q.Set("n", strconv.Itoa(events))
	u.RawQuery = q.Encode()
	target := u.String()

	tr := &http.Transport{
		Proxy:               nil,
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		MaxConnsPerHost:     0, // unlimited
		MaxIdleConns:        clients,
		MaxIdleConnsPerHost: clients,
		DisableCompression:  true,
		ForceAttemptHTTP2:   false,
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: true},
		TLSNextProto:        map[string]func(string, *tls.Conn) http.RoundTripper{}, // HTTP/1.1 only
	}
	client := &http.Client{Transport: tr}

	got := make([]int64, clients)
	errs := make([]error, clients)
	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < clients; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			got[i], errs[i] = sseClient(client, target, events)
		}(i)
	}
	wg.Wait()
	elapsed := time.Since(start)

	res := sseResult{Clients: clients, ElapsedNs: elapsed.Nanoseconds()}
	for i := 0; i < clients; i++ {
		res.Events += got[i]
		if errs[i] == nil {
			res.Complete++
		} else {
			res.Errors++
			if res.FirstError == "" {
				res.FirstError = fmt.Sprintf("client %d: %v", i, errs[i])
			}
		}
	}
	emit(res)
	return 0
}

// sseClient reads one stream and returns the number of events received and a
// non-nil error unless exactly data: 0 .. data: events-1 arrived, in order,
// followed by the end of the response.
func sseClient(client *http.Client, target string, events int) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), sseStreamTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "text/event-stream")
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return 0, fmt.Errorf("HTTP status %d", resp.StatusCode)
	}
	if mt, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type")); err != nil || mt != "text/event-stream" {
		return 0, fmt.Errorf("Content-Type %q, want text/event-stream", resp.Header.Get("Content-Type"))
	}

	br := bufio.NewReaderSize(resp.Body, 32<<10)
	var next int64    // next expected value
	var data []byte   // data of the event being assembled
	haveData := false // a data: line was seen since the last blank line
	for {
		line, err := br.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			return next, fmt.Errorf("line longer than %d bytes", br.Size())
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				if len(line) > 0 || haveData {
					return next, fmt.Errorf("stream ended inside an event after %d events", next)
				}
				break
			}
			return next, fmt.Errorf("after %d events: %w", next, err)
		}
		line = bytes.TrimSuffix(bytes.TrimSuffix(line, []byte("\n")), []byte("\r"))
		switch {
		case len(line) == 0: // end of event
			if !haveData {
				continue // stray blank line: no event (per the SSE dispatch rules)
			}
			v, perr := strconv.ParseInt(string(data), 10, 64)
			if perr != nil {
				return next, fmt.Errorf("event %d: data %q is not an integer", next, data)
			}
			if v != next {
				return next, fmt.Errorf("event %d: got data %d", next, v)
			}
			if next >= int64(events) {
				return next, fmt.Errorf("extra event %d beyond n=%d", v, events)
			}
			next++
			haveData = false
		case line[0] == ':': // comment
		case bytes.HasPrefix(line, []byte("data:")):
			if haveData {
				return next, fmt.Errorf("event %d: more than one data line", next)
			}
			data = append(data[:0], bytes.TrimPrefix(line[len("data:"):], []byte(" "))...)
			haveData = true
		default:
			field, _, _ := strings.Cut(string(line), ":")
			switch field {
			case "event", "id", "retry":
				// legal SSE fields that carry no payload here
			default:
				return next, fmt.Errorf("event %d: unexpected line %q", next, truncate(line, 64))
			}
		}
	}
	if next != int64(events) {
		return next, fmt.Errorf("stream ended after %d of %d events", next, events)
	}
	return next, nil
}

func truncate(b []byte, n int) string {
	if len(b) > n {
		return string(b[:n]) + "..."
	}
	return string(b)
}
