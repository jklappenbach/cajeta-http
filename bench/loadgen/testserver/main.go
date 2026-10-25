// testserver is a minimal reference implementation of the bench contract's h1
// routes (/plaintext, /json, /sse, /ws), used to self-test loadgen.
//
//	testserver <port>
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	EnableCompression: true,
	ReadBufferSize:    4096,
	WriteBufferSize:   4096,
	CheckOrigin:       func(*http.Request) bool { return true },
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: testserver <port>")
		os.Exit(2)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", "13")
		io.WriteString(w, "Hello, World!")
	})
	mux.HandleFunc("GET /json", func(w http.ResponseWriter, r *http.Request) {
		b, _ := json.Marshal(struct {
			Message string `json:"message"`
		}{"Hello, World!"})
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		w.Write(b)
	})
	mux.HandleFunc("GET /sse", func(w http.ResponseWriter, r *http.Request) {
		n := 1000
		if s := r.URL.Query().Get("n"); s != "" {
			v, err := strconv.Atoi(s)
			if err != nil || v < 0 {
				http.Error(w, "bad n", http.StatusBadRequest)
				return
			}
			n = v
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		fl := w.(http.Flusher)
		buf := make([]byte, 0, 64)
		for i := 0; i < n; i++ {
			buf = append(buf[:0], "data: "...)
			buf = strconv.AppendInt(buf, int64(i), 10)
			buf = append(buf, "\n\n"...)
			if _, err := w.Write(buf); err != nil {
				return
			}
			if i%100 == 99 {
				fl.Flush()
			}
		}
	})
	mux.HandleFunc("GET /ws", func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		c.SetReadLimit(1 << 20)
		c.EnableWriteCompression(true) // only takes effect when negotiated; no size threshold
		for {
			mt, rd, err := c.NextReader()
			if err != nil {
				return
			}
			wr, err := c.NextWriter(mt)
			if err != nil {
				return
			}
			if _, err := io.Copy(wr, rd); err != nil {
				return
			}
			if err := wr.Close(); err != nil {
				return
			}
		}
	})
	mux.HandleFunc("/", http.NotFound)
	log.Fatal(http.ListenAndServe("127.0.0.1:"+os.Args[1], mux))
}
