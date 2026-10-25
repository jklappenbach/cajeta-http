// Command client is the Go net/http competitor load client for the cajeta-http bench.
package main

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

var want = []byte("Hello, World!")

func usage() {
	fmt.Fprintln(os.Stderr, "usage: client get <url> <total> <conns> <keepalive 0|1>")
	os.Exit(2)
}

func main() {
	if len(os.Args) != 6 || os.Args[1] != "get" {
		usage()
	}
	url := os.Args[2]
	total, err1 := strconv.Atoi(os.Args[3])
	conns, err2 := strconv.Atoi(os.Args[4])
	ka := os.Args[5]
	if err1 != nil || err2 != nil || total < 0 || conns < 1 || (ka != "0" && ka != "1") {
		usage()
	}
	keepalive := ka == "1"

	tr := &http.Transport{
		Proxy:              nil,
		DialContext:        (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:  false,
		DisableCompression: true,
		DisableKeepAlives:  !keepalive,
	}
	if keepalive {
		tr.MaxIdleConns = conns
		tr.MaxIdleConnsPerHost = conns
		tr.MaxConnsPerHost = conns
	}
	client := &http.Client{Transport: tr}

	var next, done, errs int64
	worker := func(wg *sync.WaitGroup) {
		defer wg.Done()
		buf := make([]byte, 0, 64)
		for atomic.AddInt64(&next, 1) <= int64(total) {
			resp, err := client.Get(url)
			if err != nil {
				atomic.AddInt64(&errs, 1)
				continue
			}
			atomic.AddInt64(&done, 1)
			b := bytes.NewBuffer(buf[:0])
			_, rerr := io.Copy(b, resp.Body)
			resp.Body.Close()
			if rerr != nil || resp.StatusCode != 200 || !bytes.Equal(b.Bytes(), want) {
				atomic.AddInt64(&errs, 1)
			}
		}
	}

	var wg sync.WaitGroup
	wg.Add(conns)
	start := time.Now()
	for i := 0; i < conns; i++ {
		go worker(&wg)
	}
	wg.Wait()
	elapsed := time.Since(start)
	fmt.Printf("{\"requests\":%d,\"errors\":%d,\"elapsed_ns\":%d}\n", done, errs, elapsed.Nanoseconds())
}
