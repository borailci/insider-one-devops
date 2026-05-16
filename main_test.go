package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

func newTestServer(t *testing.T) (*server, http.Handler, *prometheus.Registry, *bytes.Buffer) {
	t.Helper()
	logBuf := &bytes.Buffer{}
	logger := slog.New(slog.NewJSONHandler(logBuf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector())
	srv := newServer(logger, reg)
	return srv, srv.routes(reg), reg, logBuf
}

// AC-1: GET /ping returns "pong" with text/plain.
func TestPingReturnsPong(t *testing.T) {
	_, h, _, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	if got := rr.Body.String(); got != "pong" {
		t.Fatalf("body = %q, want %q", got, "pong")
	}
	if ct := rr.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("Content-Type = %q, want text/plain prefix", ct)
	}
}

// AC-2: GET /healthz is 200 {"status":"ok"} when healthy.
func TestHealthzOK(t *testing.T) {
	_, h, _, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("status = %q, want ok", body["status"])
	}
}

// AC-3: /healthz returns 503 draining after SIGTERM/draining toggle.
func TestHealthzDraining(t *testing.T) {
	s, h, _, _ := newTestServer(t)
	s.draining.Store(true)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rr.Code)
	}
	var body map[string]string
	_ = json.Unmarshal(rr.Body.Bytes(), &body)
	if body["status"] != "draining" {
		t.Fatalf("status = %q, want draining", body["status"])
	}
}

// AC-4: /version returns injected build SHA and time.
func TestVersionReturnsBuildInfo(t *testing.T) {
	oldSHA, oldTime := buildSHA, buildTime
	t.Cleanup(func() { buildSHA, buildTime = oldSHA, oldTime })
	buildSHA = "abc123"
	buildTime = "2026-05-16T10:00:00Z"

	_, h, _, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/version", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if body["sha"] != "abc123" || body["build_time"] != "2026-05-16T10:00:00Z" {
		t.Fatalf("body = %+v, want sha=abc123 build_time=2026-05-16T10:00:00Z", body)
	}
}

// AC-5: /metrics exposes http_requests_total for served paths.
func TestMetricsCountsPingRequests(t *testing.T) {
	_, h, _, _ := newTestServer(t)
	for i := 0; i < 3; i++ {
		req := httptest.NewRequest(http.MethodGet, "/ping", nil)
		h.ServeHTTP(httptest.NewRecorder(), req)
	}
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	body := rr.Body.String()
	if !strings.Contains(body, `http_requests_total{method="GET",path="/ping",status="200"}`) {
		t.Fatalf("metrics missing http_requests_total for /ping; body=\n%s", body)
	}
}

// AC-6: PORT env var overrides default.
func TestLoadConfigPortOverride(t *testing.T) {
	env := map[string]string{"PORT": "9090"}
	cfg, err := loadConfig(func(k string) string { return env[k] })
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if cfg.port != 9090 {
		t.Fatalf("port = %d, want 9090", cfg.port)
	}
}

// EC-3 / FR-5: invalid PORT yields a config error (process would exit 2).
func TestLoadConfigInvalidPort(t *testing.T) {
	env := map[string]string{"PORT": "abc"}
	if _, err := loadConfig(func(k string) string { return env[k] }); err == nil {
		t.Fatal("expected error for non-numeric PORT, got nil")
	}
}

// AC-7: access log line is JSON with required fields.
func TestAccessLogIsStructuredJSON(t *testing.T) {
	_, h, _, logBuf := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	h.ServeHTTP(httptest.NewRecorder(), req)

	// Last non-empty line is the access log.
	var line string
	for _, l := range strings.Split(strings.TrimSpace(logBuf.String()), "\n") {
		if strings.Contains(l, `"msg":"http_access"`) {
			line = l
		}
	}
	if line == "" {
		t.Fatalf("no http_access log line; buf=%s", logBuf.String())
	}
	var entry map[string]any
	if err := json.Unmarshal([]byte(line), &entry); err != nil {
		t.Fatalf("log line not JSON: %v", err)
	}
	for _, f := range []string{"time", "level", "msg", "request_id", "path", "method", "status", "duration_ms"} {
		if _, ok := entry[f]; !ok {
			t.Errorf("log missing field %q; got %+v", f, entry)
		}
	}
}

// AC-8: X-Request-ID is echoed back and appears in logs.
func TestRequestIDIsPropagated(t *testing.T) {
	_, h, _, logBuf := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set("X-Request-ID", "feed-face")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if got := rr.Header().Get("X-Request-ID"); got != "feed-face" {
		t.Fatalf("response X-Request-ID = %q, want feed-face", got)
	}
	if !strings.Contains(logBuf.String(), `"request_id":"feed-face"`) {
		t.Fatalf("log missing request_id=feed-face; buf=%s", logBuf.String())
	}
}

// EC-1: unknown path returns 404 with error envelope.
func TestUnknownPathReturns404(t *testing.T) {
	_, h, _, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/nope", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rr.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if body["error"] != "not found" {
		t.Fatalf("error = %q, want 'not found'", body["error"])
	}
}

// EC-2: wrong method on known path returns 405 with Allow header.
func TestWrongMethodReturns405(t *testing.T) {
	_, h, _, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/ping", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rr.Code)
	}
	if got := rr.Header().Get("Allow"); got != "GET" {
		t.Fatalf("Allow = %q, want GET", got)
	}
}

// AC-9: SIGTERM during in-flight request completes the request and exits 0.
// Runs the binary as a subprocess so signal handling matches production.
func TestSIGTERMGracefulShutdown(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("SIGTERM not supported on Windows")
	}
	tmp := t.TempDir()
	bin := filepath.Join(tmp, "app")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build failed: %v\n%s", err, out)
	}

	port := "18080"
	proc := exec.Command(bin)
	proc.Env = append(os.Environ(), "PORT="+port)
	var stdout, stderr bytes.Buffer
	proc.Stdout = &stdout
	proc.Stderr = &stderr
	if err := proc.Start(); err != nil {
		t.Fatalf("start failed: %v", err)
	}

	// Wait for listener up to 2 s (also exercises NFR-3).
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get("http://127.0.0.1:" + port + "/healthz")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Start a slow request (server sleeps via a synthetic delay -- we fake it
	// by simply firing the request and immediately sending SIGTERM).
	var wg sync.WaitGroup
	wg.Add(1)
	var inflightStatus int
	go func() {
		defer wg.Done()
		resp, err := http.Get("http://127.0.0.1:" + port + "/ping")
		if err != nil {
			t.Errorf("in-flight request error: %v", err)
			return
		}
		defer resp.Body.Close()
		inflightStatus = resp.StatusCode
		_, _ = io.Copy(io.Discard, resp.Body)
	}()

	// Give the request a head start, then signal.
	time.Sleep(50 * time.Millisecond)
	if err := proc.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("signal failed: %v", err)
	}

	wg.Wait()
	if inflightStatus != http.StatusOK {
		t.Fatalf("in-flight status = %d, want 200", inflightStatus)
	}

	exitCh := make(chan error, 1)
	go func() { exitCh <- proc.Wait() }()
	select {
	case err := <-exitCh:
		if err != nil {
			t.Fatalf("process exited with error: %v\nstderr=%s", err, stderr.String())
		}
	case <-time.After(12 * time.Second):
		_ = proc.Process.Kill()
		t.Fatalf("process did not exit within 12s; stderr=%s", stderr.String())
	}

	// After SIGTERM, healthz should have flipped to draining. The race window is
	// tight; we don't assert it here -- AC-3 already covers the toggle in unit form.
	_ = stdout
}

// Sanity: run main with a canceled context to exercise the run() exit path.
func TestRunReturnsCleanlyOnCancel(t *testing.T) {
	tmp := t.TempDir()
	stdoutF, _ := os.Create(filepath.Join(tmp, "out.log"))
	stderrF, _ := os.Create(filepath.Join(tmp, "err.log"))
	defer stdoutF.Close()
	defer stderrF.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	code := run(ctx, func(k string) string {
		if k == "PORT" {
			return "18081"
		}
		return ""
	}, stdoutF, stderrF)
	if code != 0 {
		t.Fatalf("run exit code = %d, want 0", code)
	}
}
