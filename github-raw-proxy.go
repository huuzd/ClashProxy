package main

import (
	"context"
	"crypto/subtle"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func main() {
	addr := env("PORT", "8080")
	user := os.Getenv("BASIC_AUTH_USER")
	pass := os.Getenv("BASIC_AUTH_PASS")

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/raw/", func(w http.ResponseWriter, r *http.Request) {
		if user != "" || pass != "" {
			u, p, ok := r.BasicAuth()
			if !ok || subtle.ConstantTimeCompare([]byte(u), []byte(user)) != 1 || subtle.ConstantTimeCompare([]byte(p), []byte(pass)) != 1 {
				w.Header().Set("WWW-Authenticate", `Basic realm="github-raw-proxy"`)
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}

		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		upstreamURL, err := buildUpstreamURL(r.URL.Path, r.URL.RawQuery)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		req, err := http.NewRequestWithContext(ctx, r.Method, upstreamURL, nil)
		if err != nil {
			http.Error(w, "failed to create upstream request", http.StatusBadGateway)
			return
		}

		copyRequestHeaders(req.Header, r.Header)
		req.Header.Set("User-Agent", "github-raw-proxy/1.0")

		client := &http.Client{Timeout: 30 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			http.Error(w, fmt.Sprintf("upstream request failed: %v", err), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		copyResponseHeaders(w.Header(), resp.Header)
		w.WriteHeader(resp.StatusCode)
		if r.Method == http.MethodHead {
			return
		}
		_, _ = io.Copy(w, resp.Body)
	})

	srv := &http.Server{
		Addr:              ":" + addr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("listening on :%s", addr)
	log.Fatal(srv.ListenAndServe())
}

func buildUpstreamURL(path, rawQuery string) (string, error) {
	// Expected format:
	// /raw/{owner}/{repo}/{ref}/{path...}
	parts := strings.Split(strings.TrimPrefix(path, "/raw/"), "/")
	if len(parts) < 4 {
		return "", fmt.Errorf("invalid path; use /raw/{owner}/{repo}/{ref}/{path}")
	}

	owner := parts[0]
	repo := parts[1]
	ref := parts[2]
	filePath := strings.Join(parts[3:], "/")

	if owner == "" || repo == "" || ref == "" || filePath == "" {
		return "", fmt.Errorf("invalid path; use /raw/{owner}/{repo}/{ref}/{path}")
	}

	base := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s/%s",
		url.PathEscape(owner),
		url.PathEscape(repo),
		url.PathEscape(ref),
		strings.TrimPrefix(filePath, "/"),
	)

	if rawQuery == "" {
		return base, nil
	}
	return base + "?" + rawQuery, nil
}

func copyRequestHeaders(dst, src http.Header) {
	for _, key := range []string{"Accept", "Accept-Encoding", "Accept-Language", "If-Modified-Since", "If-None-Match", "Range", "Referer"} {
		if v := src.Get(key); v != "" {
			dst.Set(key, v)
		}
	}
}

func copyResponseHeaders(dst, src http.Header) {
	for k, values := range src {
		if hopByHopHeader(k) {
			continue
		}
		for _, v := range values {
			dst.Add(k, v)
		}
	}
}

func hopByHopHeader(k string) bool {
	switch strings.ToLower(k) {
	case "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade":
		return true
	default:
		return false
	}
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Truncate(time.Millisecond))
	})
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
