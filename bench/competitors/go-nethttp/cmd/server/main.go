// Command server is the Go net/http competitor server for the cajeta-http bench.
package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"

	"github.com/gorilla/websocket"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

type message struct {
	Message string `json:"message"`
}

var helloBody = []byte("Hello, World!")

func plaintext(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h["Date"] = nil
	h["Content-Type"] = []string{"text/plain"}
	h["Content-Length"] = []string{"13"}
	w.WriteHeader(http.StatusOK)
	w.Write(helloBody)
}

func jsonHandler(w http.ResponseWriter, r *http.Request) {
	b, err := json.Marshal(&message{Message: "Hello, World!"})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h["Date"] = nil
	h["Content-Type"] = []string{"application/json"}
	h["Content-Length"] = []string{strconv.Itoa(len(b))}
	w.WriteHeader(http.StatusOK)
	w.Write(b)
}

func sse(w http.ResponseWriter, r *http.Request) {
	n := 1000
	if s := r.URL.Query().Get("n"); s != "" {
		v, err := strconv.Atoi(s)
		if err != nil || v < 0 {
			http.Error(w, "bad n", http.StatusBadRequest)
			return
		}
		n = v
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "no flusher", http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h["Date"] = nil
	h["Content-Type"] = []string{"text/event-stream"}
	h["Cache-Control"] = []string{"no-cache"}
	w.WriteHeader(http.StatusOK)
	buf := make([]byte, 0, 32)
	for i := 0; i < n; i++ {
		buf = append(buf[:0], "data: "...)
		buf = strconv.AppendInt(buf, int64(i), 10)
		buf = append(buf, '\n', '\n')
		if _, err := w.Write(buf); err != nil {
			return
		}
		if i%100 == 99 {
			fl.Flush()
		}
	}
	fl.Flush()
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:    4096,
	WriteBufferSize:   4096,
	EnableCompression: true,
	CheckOrigin:       func(*http.Request) bool { return true },
}

func ws(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetReadLimit(64 << 20)
	// gorilla compresses every message (no size threshold) once write
	// compression is enabled on a connection that negotiated the extension.
	conn.EnableWriteCompression(true)
	conn.SetCompressionLevel(defaultCompressionLevel)
	for {
		mt, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if err := conn.WriteMessage(mt, data); err != nil {
			return
		}
	}
}

// flate.DefaultCompression
const defaultCompressionLevel = -1

func mux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/plaintext", plaintext)
	m.HandleFunc("/json", jsonHandler)
	m.HandleFunc("/sse", sse)
	m.HandleFunc("/ws", ws)
	m.HandleFunc("/", http.NotFound)
	return m
}

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "server: "+format+"\n", a...)
	os.Exit(2)
}

func main() {
	if len(os.Args) < 3 {
		die("usage: server <h1|h2c|tls> <port> [<cert.pem> <key.pem>]")
	}
	mode, port := os.Args[1], os.Args[2]
	addr := "127.0.0.1:" + port
	var err error
	switch mode {
	case "h1":
		srv := &http.Server{Addr: addr, Handler: mux()}
		err = srv.ListenAndServe()
	case "h2c":
		h2s := &http2.Server{MaxConcurrentStreams: 250}
		srv := &http.Server{Addr: addr, Handler: h2c.NewHandler(mux(), h2s)}
		err = srv.ListenAndServe()
	case "tls":
		if len(os.Args) < 5 {
			die("tls mode needs <cert.pem> <key.pem>")
		}
		cert, cerr := tls.LoadX509KeyPair(os.Args[3], os.Args[4])
		if cerr != nil {
			die("loading key pair: %v", cerr)
		}
		srv := &http.Server{
			Addr:    addr,
			Handler: mux(),
			TLSConfig: &tls.Config{
				Certificates: []tls.Certificate{cert},
				MinVersion:   tls.VersionTLS12,
				MaxVersion:   tls.VersionTLS13,
				NextProtos:   []string{"http/1.1"},
			},
			// Non-nil empty map disables net/http's automatic h2 over TLS.
			TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){},
		}
		err = srv.ListenAndServeTLS("", "")
	default:
		die("unknown mode %q", mode)
	}
	die("%v", err)
}
