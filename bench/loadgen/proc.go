package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// ---------------------------------------------------------------- probes

// newProbeClient returns an HTTP/1.1 client that opens a fresh connection for
// every request and skips certificate verification (the bench cert is
// self-signed).
func newProbeClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:              nil,
			DisableKeepAlives:  true,
			DisableCompression: true,
			ForceAttemptHTTP2:  false,
			TLSClientConfig:    &tls.Config{InsecureSkipVerify: true},
			TLSNextProto:       map[string]func(string, *tls.Conn) http.RoundTripper{},
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// probeH1 performs one GET and returns its status code.
func probeH1(c *http.Client, target string, timeout time.Duration) (int, error) {
	c.Timeout = timeout
	resp, err := c.Get(target)
	if err != nil {
		return 0, err
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return resp.StatusCode, fmt.Errorf("HTTP status %d", resp.StatusCode)
	}
	return resp.StatusCode, nil
}

func hostPort(u *url.URL) string {
	if u.Port() != "" {
		return u.Host
	}
	if u.Scheme == "https" || u.Scheme == "wss" {
		return net.JoinHostPort(u.Hostname(), "443")
	}
	return net.JoinHostPort(u.Hostname(), "80")
}

func parseHTTPURL(s string) *url.URL {
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		usageExit("bad url " + strconv.Quote(s) + " (want http:// or https://)")
	}
	return u
}

func attemptTimeout(deadline time.Time, cap time.Duration) time.Duration {
	if left := time.Until(deadline); left < cap {
		return max(left, time.Millisecond)
	}
	return cap
}

// ---------------------------------------------------------------- wait

func cmdWait(args []string) int {
	if len(args) != 3 {
		usageExit("wait takes <url> <timeout_ms> <h1|tcp>")
	}
	u := parseHTTPURL(args[0])
	timeout := time.Duration(intArg("timeout_ms", args[1], 0)) * time.Millisecond
	mode := args[2]
	if mode != "h1" && mode != "tcp" {
		usageExit("mode must be h1 or tcp")
	}
	addr := hostPort(u)
	client := newProbeClient()
	start := time.Now()
	deadline := start.Add(timeout)
	var lastErr error
	for {
		ok := false
		if mode == "h1" {
			_, lastErr = probeH1(client, u.String(), attemptTimeout(deadline, 250*time.Millisecond))
			ok = lastErr == nil
		} else {
			c, err := net.DialTimeout("tcp", addr, attemptTimeout(deadline, 250*time.Millisecond))
			if err == nil {
				c.Close()
				ok = true
			}
			lastErr = err
		}
		if ok {
			emit(struct {
				Ready    bool  `json:"ready"`
				WaitedNs int64 `json:"waited_ns"`
			}{true, time.Since(start).Nanoseconds()})
			return 0
		}
		if !time.Now().Add(2 * time.Millisecond).Before(deadline) {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	msg := ""
	if lastErr != nil {
		msg = lastErr.Error()
	}
	emit(struct {
		Ready     bool   `json:"ready"`
		WaitedNs  int64  `json:"waited_ns"`
		LastError string `json:"last_error,omitempty"`
	}{false, time.Since(start).Nanoseconds(), msg})
	return 1
}

// ---------------------------------------------------------------- child processes

// child is a command started in its own process group. Its pid is never
// reaped until the group has been killed, so the pgid cannot be recycled
// under us: the only thing loadgen ever signals is -pid of a process it
// started and still holds.
type child struct {
	cmd *exec.Cmd
	pid int
}

var livePgid atomic.Int64 // process group to kill if loadgen itself is interrupted

func init() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		s := <-sig
		if pg := livePgid.Load(); pg > 0 {
			syscall.Kill(-int(pg), syscall.SIGKILL)
		}
		fmt.Fprintf(os.Stderr, "loadgen: interrupted by %v\n", s)
		os.Exit(130)
	}()
}

func splitCommand(args []string, fixed int, form string) ([]string, []string) {
	for i, a := range args {
		if a == "--" {
			if i != fixed || i+1 >= len(args) {
				break
			}
			return args[:i], args[i+1:]
		}
	}
	usageExit(form)
	return nil, nil
}

// startChild starts argv in a new process group, stdout to /dev/null and
// stderr inherited. It returns t0, taken immediately before the exec.
func startChild(argv []string) (*child, time.Time, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = nil
	cmd.Stdout = nil // /dev/null
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	if p, err := exec.LookPath(argv[0]); err == nil {
		cmd.Path = p // resolve before t0 so lookup cost is not measured
	} else {
		return nil, time.Time{}, err
	}
	t0 := time.Now()
	if err := cmd.Start(); err != nil {
		return nil, t0, err
	}
	c := &child{cmd: cmd, pid: cmd.Process.Pid}
	livePgid.Store(int64(c.pid))
	return c, t0, nil
}

// exited reports whether the child has terminated (zombie or gone) without
// reaping it.
func (c *child) exited() bool {
	st, err := procState(c.pid)
	return err != nil || st == 'Z' || st == 'X'
}

// kill SIGKILLs the whole process group, then reaps the child.
func (c *child) kill() {
	syscall.Kill(-c.pid, syscall.SIGKILL)
	c.cmd.Wait()
	livePgid.Store(0)
}

// waitReady polls GET target every 1 ms until a 200 arrives, the child exits,
// or the deadline passes. It returns the time the 200 arrived.
func waitReady(c *child, target string, deadline time.Time) (time.Time, error) {
	client := newProbeClient()
	var lastErr error
	for {
		_, err := probeH1(client, target, attemptTimeout(deadline, 250*time.Millisecond))
		if err == nil {
			return time.Now(), nil
		}
		lastErr = err
		if c.exited() {
			return time.Time{}, fmt.Errorf("child exited before ready (last probe: %v)", lastErr)
		}
		if !time.Now().Before(deadline) {
			return time.Time{}, fmt.Errorf("not ready within timeout (last probe: %v)", lastErr)
		}
		time.Sleep(time.Millisecond)
	}
}

// ---------------------------------------------------------------- startup

func cmdStartup(args []string) int {
	const form = "startup takes <url> <timeout_ms> -- <cmd> [args...]"
	fixed, argv := splitCommand(args, 2, form)
	u := parseHTTPURL(fixed[0])
	timeout := time.Duration(intArg("timeout_ms", fixed[1], 1)) * time.Millisecond

	c, t0, err := startChild(argv)
	if err != nil {
		return emitError("start: " + err.Error())
	}
	ready, err := waitReady(c, u.String(), t0.Add(timeout))
	c.kill()
	if err != nil {
		return emitError(err.Error())
	}
	emit(struct {
		StartupNs int64 `json:"startup_ns"`
		Status    int   `json:"status"`
		Pid       int   `json:"pid"`
	}{ready.Sub(t0).Nanoseconds(), 200, c.pid})
	return 0
}

// ---------------------------------------------------------------- idle-rss

func cmdIdleRSS(args []string) int {
	const form = "idle-rss takes <url> <timeout_ms> <settle_ms> -- <cmd> [args...]"
	fixed, argv := splitCommand(args, 3, form)
	u := parseHTTPURL(fixed[0])
	timeout := time.Duration(intArg("timeout_ms", fixed[1], 1)) * time.Millisecond
	settle := time.Duration(intArg("settle_ms", fixed[2], 0)) * time.Millisecond

	c, t0, err := startChild(argv)
	if err != nil {
		return emitError("start: " + err.Error())
	}
	ready, err := waitReady(c, u.String(), t0.Add(timeout))
	if err != nil {
		c.kill()
		return emitError(err.Error())
	}
	time.Sleep(settle)
	if c.exited() {
		c.kill()
		return emitError("child exited during settle")
	}
	pids := descendants(c.pid)
	var rss, hwm int64
	for _, p := range pids {
		r, h := procMem(p)
		rss += r
		hwm += h
	}
	alive := !c.exited()
	c.kill()
	if !alive {
		return emitError("child exited while sampling")
	}
	emit(struct {
		RssKB     int64 `json:"rss_kb"`
		HwmKB     int64 `json:"hwm_kb"`
		Processes int   `json:"processes"`
		Alive     bool  `json:"alive"`
		StartupNs int64 `json:"startup_ns"`
	}{rss, hwm, len(pids), alive, ready.Sub(t0).Nanoseconds()})
	return 0
}

// ---------------------------------------------------------------- /proc

// procStat returns the state char and ppid from /proc/<pid>/stat.
func procStat(pid int) (byte, int, error) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0, 0, err
	}
	// comm may contain spaces and parens: fields resume after the LAST ')'.
	i := bytes.LastIndexByte(b, ')')
	if i < 0 {
		return 0, 0, errors.New("malformed stat")
	}
	f := strings.Fields(string(b[i+1:]))
	if len(f) < 2 || len(f[0]) != 1 {
		return 0, 0, errors.New("malformed stat")
	}
	ppid, err := strconv.Atoi(f[1])
	return f[0][0], ppid, err
}

func procState(pid int) (byte, error) {
	st, _, err := procStat(pid)
	return st, err
}

// descendants returns root and every live process below it (by ppid links).
func descendants(root int) []int {
	kids := map[int][]int{}
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		st, ppid, err := procStat(pid)
		if err != nil || st == 'Z' || st == 'X' {
			continue
		}
		kids[ppid] = append(kids[ppid], pid)
	}
	out := []int{root}
	for i := 0; i < len(out); i++ {
		out = append(out, kids[out[i]]...)
	}
	return out
}

// procMem returns VmRSS and VmHWM in kB from /proc/<pid>/status.
func procMem(pid int) (rss, hwm int64) {
	f, err := os.Open("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		var dst *int64
		switch {
		case strings.HasPrefix(line, "VmRSS:"):
			dst = &rss
		case strings.HasPrefix(line, "VmHWM:"):
			dst = &hwm
		default:
			continue
		}
		if f := strings.Fields(line); len(f) >= 2 {
			*dst, _ = strconv.ParseInt(f[1], 10, 64)
		}
	}
	return rss, hwm
}

// ---------------------------------------------------------------- free

func cmdFree(args []string) int {
	if len(args) != 1 {
		usageExit("free takes <port>")
	}
	port := intArg("port", args[0], 1)
	if port > 65535 {
		usageExit("port out of range")
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 500*time.Millisecond)
	free := false
	if err == nil {
		c.Close()
	} else if errors.Is(err, syscall.ECONNREFUSED) {
		free = true
	} // any other failure (e.g. a timeout on a full backlog): something is there
	emit(struct {
		Free bool `json:"free"`
	}{free})
	if free {
		return 0
	}
	return 1
}
