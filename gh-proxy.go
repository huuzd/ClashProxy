package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"time"
)

var proxyClient = &http.Client{
	Timeout: 60 * time.Second,
	Transport: &http.Transport{
		MaxIdleConns:        50,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	},
}

func checkAuth(user, pass string) bool {
	f, err := os.Open(".users")
	if err != nil { return false }
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		parts := strings.Split(scanner.Text(), ":")
		if len(parts) == 2 {
			if subtle.ConstantTimeCompare([]byte(user), []byte(parts[0])) == 1 &&
				subtle.ConstantTimeCompare([]byte(pass), []byte(parts[1])) == 1 {
				return true
			}
		}
	}
	return false
}

func main() {
	port := os.Getenv("PORT")
	if port == "" { port = "9090" }

	http.HandleFunc("/raw/", func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || !checkAuth(u, p) {
			w.Header().Set("WWW-Authenticate", `Basic realm="gh-proxy"`)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		cleanPath := path.Clean(r.URL.Path)
		trimmed := strings.TrimPrefix(cleanPath, "/raw")
		parts := strings.Split(strings.Trim(trimmed, "/"), "/")
		if len(parts) < 4 {
			http.Error(w, "Invalid Path Format", http.StatusBadRequest)
			return
		}

		upstream := &url.URL{
			Scheme: "https",
			Host:   "raw.githubusercontent.com",
			Path:   path.Join("/", parts[0], parts[1], parts[2], strings.Join(parts[3:], "/")),
			RawQuery: r.URL.RawQuery,
		}

		ctx, cancel := context.WithTimeout(r.Context(), 55*time.Second)
		defer cancel()

		req, _ := http.NewRequestWithContext(ctx, r.Method, upstream.String(), nil)
		req.Header.Set("User-Agent", "Mozilla/5.0 (GH-Proxy/2.0)")

		resp, err := proxyClient.Do(req)
		if err != nil {
			http.Error(w, "Proxy Error", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		for k, vv := range resp.Header {
			for _, v := range vv { w.Header().Add(k, v) }
		}
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	log.Printf("Proxy Service running on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
