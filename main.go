// Package main implements the InsiderOne case-study HTTP service.
//
// Layout & why:
//   - stdlib net/http only — three trivial endpoints don't justify a framework
//     and the dependency surface stays minimal for the container scan.
//   - All side effects (env, signals, IO) injected into run() so main_test.go
//     can drive the binary end-to-end without exec'ing it.
//   - main() is a 3-liner that wires signals into run() and forwards the exit
//     code; nothing testable lives in main itself.
//
// Endpoints:
//   - GET /ping     -> "pong"                       (liveness-style smoke)
//   - GET /healthz  -> {"status":"ok"} | "draining" (readiness; flips to 503 during shutdown)
//   - GET /version  -> {"sha":..,"build_time":..}   (build-time vars via -ldflags)
//   - GET /metrics  -> Prometheus text exposition   (private registry, no global leakage)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Build-time vars injected by the Dockerfile via:
//
//	go build -ldflags "-X main.buildSHA=$SHA -X main.buildTime=$TIME" ...
//
// They default to "unknown" so `go run .` outside Docker still produces a valid /version.
var (
	buildSHA  = "unknown"
	buildTime = "unknown"
)

// shutdownGrace is the SIGTERM → in-flight-drain window.
// Slightly longer than terminationGracePeriodSeconds in the chart on purpose,
// so the pod is actually killed by Kubernetes if Shutdown ever hangs.
const shutdownGrace = 10 * time.Second

// server holds per-process state. `draining` is read by /healthz to flip
// readiness to 503 once SIGTERM arrives — without this, k8s keeps sending
// traffic into the shutdown window.
type server struct {
	logger     *slog.Logger
	draining   atomic.Bool
	reqCounter *prometheus.CounterVec
	reqLatency *prometheus.HistogramVec
}

func newServer(logger *slog.Logger, reg prometheus.Registerer) *server {
	factory := promauto.With(reg)
	return &server{
		logger: logger,
		reqCounter: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests.",
		}, []string{"method", "path", "status"}),
		reqLatency: factory.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency.",
			Buckets: prometheus.DefBuckets,
		}, []string{"method", "path"}),
	}
}

// routes wires the mux. /metrics intentionally skips the middleware so the
// scrape itself doesn't get counted in request metrics (avoids self-referential
// inflation when Prometheus scrapes every 30s).
func (s *server) routes(reg *prometheus.Registry) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /ping", s.middleware(http.HandlerFunc(s.handlePing)))
	mux.Handle("GET /healthz", s.middleware(http.HandlerFunc(s.handleHealthz)))
	mux.Handle("GET /version", s.middleware(http.HandlerFunc(s.handleVersion)))
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}))
	return s.notFoundOrMethodNotAllowed(mux)
}

func (s *server) handlePing(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("pong"))
}

func (s *server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if s.draining.Load() {
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "draining"})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"sha":        buildSHA,
		"build_time": buildTime,
	})
}

// notFoundOrMethodNotAllowed maps Go 1.22+ mux 404/405 to spec error envelope.
//
// Go's ServeMux returns plain-text "404 page not found" by default, which:
//  1. leaks the framework
//  2. doesn't include the request_id (forensics impossible)
//  3. doesn't distinguish unknown path (404) from wrong method (405)
//
// This wrapper renders a JSON envelope and sets the Allow header on 405.
func (s *server) notFoundOrMethodNotAllowed(next http.Handler) http.Handler {
	knownPaths := map[string]map[string]bool{
		"/ping":    {"GET": true},
		"/healthz": {"GET": true},
		"/version": {"GET": true},
		"/metrics": {"GET": true},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if methods, known := knownPaths[r.URL.Path]; known {
			if !methods[r.Method] {
				rid, _ := r.Context().Value(ctxKeyRequestID{}).(string)
				w.Header().Set("Allow", "GET")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				_ = json.NewEncoder(w).Encode(errEnvelope("method not allowed", rid))
				return
			}
			next.ServeHTTP(w, r)
			return
		}
		rid, _ := r.Context().Value(ctxKeyRequestID{}).(string)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(errEnvelope("not found", rid))
	})
}

// ctxKeyRequestID is a zero-size unique key so other packages can't accidentally
// collide on a context value (the standard Go idiom — never use a string key).
type ctxKeyRequestID struct{}

func errEnvelope(msg, rid string) map[string]string {
	return map[string]string{"error": msg, "request_id": rid}
}

// statusRecorder intercepts the response status so middleware can label
// Prometheus metrics + access logs with it. Needed because the stdlib
// ResponseWriter doesn't expose the chosen status after the handler runs.
type statusRecorder struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (sr *statusRecorder) WriteHeader(code int) {
	if !sr.wrote {
		sr.status = code
		sr.wrote = true
	}
	sr.ResponseWriter.WriteHeader(code)
}

func (sr *statusRecorder) Write(b []byte) (int, error) {
	if !sr.wrote {
		sr.status = http.StatusOK
		sr.wrote = true
	}
	return sr.ResponseWriter.Write(b)
}

// middleware adds the three observability primitives every request gets:
//  1. request_id (echoes inbound X-Request-ID if present, else generates UUID)
//  2. JSON access log line (timestamp, level, msg, method, path, status, duration)
//  3. Prometheus metrics: http_requests_total + http_request_duration_seconds
//
// Order matters: the recorder must wrap the writer BEFORE next.ServeHTTP so
// it can capture WriteHeader/Write calls from inside the handler.
func (s *server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := r.Header.Get("X-Request-ID")
		if rid == "" {
			rid = uuid.NewString()
		}
		w.Header().Set("X-Request-ID", rid)
		ctx := context.WithValue(r.Context(), ctxKeyRequestID{}, rid)

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rec, r.WithContext(ctx))
		dur := time.Since(start)

		s.reqCounter.WithLabelValues(r.Method, r.URL.Path, strconv.Itoa(rec.status)).Inc()
		s.reqLatency.WithLabelValues(r.Method, r.URL.Path).Observe(dur.Seconds())

		s.logger.Info("http_access",
			slog.String("request_id", rid),
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.Int("status", rec.status),
			slog.Float64("duration_ms", float64(dur.Microseconds())/1000),
		)
	})
}

type config struct {
	port     uint16
	logLevel slog.Level
}

// loadConfig is pure (no os.Getenv) so tests can hand in a stub. Validation
// fails loudly — a typo in LOG_LEVEL should crash the pod, not silently
// fall back to info.
func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{port: 8080, logLevel: slog.LevelInfo}
	if v := getenv("PORT"); v != "" {
		n, err := strconv.ParseUint(v, 10, 16)
		if err != nil || n == 0 {
			return cfg, errors.New("PORT must be a valid TCP port (1-65535)")
		}
		cfg.port = uint16(n)
	}
	if v := getenv("LOG_LEVEL"); v != "" {
		switch v {
		case "debug":
			cfg.logLevel = slog.LevelDebug
		case "info":
			cfg.logLevel = slog.LevelInfo
		case "warn":
			cfg.logLevel = slog.LevelWarn
		case "error":
			cfg.logLevel = slog.LevelError
		default:
			return cfg, errors.New("LOG_LEVEL must be one of debug, info, warn, error")
		}
	}
	return cfg, nil
}

// run is the testable entry point.
//
// Lifecycle:
//  1. Load + validate config (exit 2 on bad config — distinguishes from runtime errors).
//  2. Build slog JSON logger + private Prometheus registry (no default Go collectors leak).
//  3. Start ListenAndServe in a goroutine; listenErr channel surfaces bind failures.
//  4. Block on either listen-error or ctx.Done() (SIGTERM/SIGINT from main).
//  5. On signal: flip draining flag → /healthz starts returning 503 → kube-proxy
//     stops routing new traffic → drain in-flight → Server.Shutdown (graceful).
//
// Exit codes: 0=clean, 1=runtime failure, 2=bad config.
func run(ctx context.Context, getenv func(string) string, stdout, stderr *os.File) int {
	cfg, err := loadConfig(getenv)
	if err != nil {
		fatalJSON(stderr, err.Error())
		return 2
	}

	logger := slog.New(slog.NewJSONHandler(stdout, &slog.HandlerOptions{Level: cfg.logLevel}))
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	srv := newServer(logger, reg)

	httpServer := &http.Server{
		Addr:              ":" + strconv.Itoa(int(cfg.port)),
		Handler:           srv.routes(reg),
		ReadHeaderTimeout: 5 * time.Second,
	}

	listenErr := make(chan error, 1)
	go func() {
		logger.Info("server_listening", slog.String("addr", httpServer.Addr), slog.String("sha", buildSHA))
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			listenErr <- err
		}
		close(listenErr)
	}()

	select {
	case err, ok := <-listenErr:
		if ok && err != nil {
			fatalJSON(stderr, err.Error())
			return 1
		}
		return 0
	case <-ctx.Done():
	}

	srv.draining.Store(true)
	logger.Info("server_draining", slog.Duration("grace", shutdownGrace))
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		fatalJSON(stderr, "graceful shutdown failed: "+err.Error())
		return 1
	}
	logger.Info("server_stopped")
	return 0
}

func fatalJSON(w *os.File, msg string) {
	rec := map[string]any{
		"ts":    time.Now().UTC().Format(time.RFC3339Nano),
		"level": "error",
		"msg":   msg,
	}
	_ = json.NewEncoder(w).Encode(rec)
}

// main: bind real OS signals + env to the testable run().
// Kept tiny on purpose — anything in here cannot be unit-tested.
func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Getenv, os.Stdout, os.Stderr))
}
