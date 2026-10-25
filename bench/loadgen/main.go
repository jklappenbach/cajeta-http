// loadgen drives the cajeta-http benchmark rows that oha cannot: WebSocket
// echo, SSE fan-out, start-up time, idle RSS, and readiness polling. It is
// run against every competitor stack, so it treats them all the same way and
// never relies on anything beyond the bench contract.
//
// Every subcommand prints exactly one line of JSON on stdout. Usage errors
// exit 2 (message on stderr). A measured failure is reported inside the JSON
// with exit 0, except where a subcommand documents exit 1 (wait timeout,
// startup / idle-rss failure, port in use).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"syscall"
)

const usage = `usage:
  loadgen ws <url> <clients> <seconds> <size> <deflate 0|1>
  loadgen sse <url> <clients> <events>
  loadgen wait <url> <timeout_ms> <h1|tcp>
  loadgen startup <url> <timeout_ms> -- <cmd> [args...]
  loadgen idle-rss <url> <timeout_ms> <settle_ms> -- <cmd> [args...]
  loadgen free <port>
`

func main() {
	raiseNofile()
	if len(os.Args) < 2 {
		usageExit("missing subcommand")
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "ws":
		os.Exit(cmdWS(args))
	case "sse":
		os.Exit(cmdSSE(args))
	case "wait":
		os.Exit(cmdWait(args))
	case "startup":
		os.Exit(cmdStartup(args))
	case "idle-rss":
		os.Exit(cmdIdleRSS(args))
	case "free":
		os.Exit(cmdFree(args))
	case "-h", "--help", "help":
		fmt.Fprint(os.Stdout, usage)
		os.Exit(0)
	default:
		usageExit("unknown subcommand " + strconv.Quote(os.Args[1]))
	}
}

func usageExit(msg string) {
	fmt.Fprintf(os.Stderr, "loadgen: %s\n%s", msg, usage)
	os.Exit(2)
}

// emit writes v as exactly one line of JSON on stdout.
func emit(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loadgen: json: %v\n", err)
		os.Exit(2)
	}
	b = append(b, '\n')
	os.Stdout.Write(b)
}

// emitError prints {"error":msg} and returns exit status 1.
func emitError(msg string) int {
	emit(struct {
		Error string `json:"error"`
	}{msg})
	return 1
}

func intArg(name, s string, min int) int {
	v, err := strconv.Atoi(s)
	if err != nil || v < min {
		usageExit(fmt.Sprintf("%s must be an integer >= %d, got %q", name, min, s))
	}
	return v
}

// raiseNofile lifts RLIMIT_NOFILE to the hard limit: 1000 SSE clients or 512
// WebSocket connections need more descriptors than the usual soft 1024.
func raiseNofile() {
	var lim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		return
	}
	if lim.Cur < lim.Max {
		lim.Cur = lim.Max
		if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
			fmt.Fprintf(os.Stderr, "loadgen: warning: cannot raise RLIMIT_NOFILE: %v\n", err)
		}
	}
}
