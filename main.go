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

// Build-time vars injected via -ldflags.
var (
	buildSHA  = "unknown"
	buildTime = "unknown"
)

const shutdownGrace = 10 * time.Second

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

type ctxKeyRequestID struct{}

func errEnvelope(msg, rid string) map[string]string {
	return map[string]string{"error": msg, "request_id": rid}
}

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

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Getenv, os.Stdout, os.Stderr))
}
