package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"time"
)

const (
	userFile     = ".users"
	defaultPort  = "9090"
	defaultHost  = "127.0.0.1"
	serverName   = "GH-Proxy/2.1"
	upstreamHost = "raw.githubusercontent.com"
)

var proxyClient = &http.Client{
	Timeout: 60 * time.Second,
	Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          50,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	},
}

func checkAuth(user, pass string) bool {
	f, err := os.Open(userFile)
	if err != nil {
		log.Printf("open %s failed: %v", userFile, err)
		return false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}

		fileUser := strings.TrimSpace(parts[0])
		filePass := parts[1]

		if subtle.ConstantTimeCompare([]byte(user), []byte(fileUser)) == 1 &&
			subtle.ConstantTimeCompare([]byte(pass), []byte(filePass)) == 1 {
			return true
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("scan %s failed: %v", userFile, err)
	}

	return false
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Basic realm="gh-proxy"`)
	http.Error(w, "Unauthorized", http.StatusUnauthorized)
}

func isAllowedMethod(method string) bool {
	return method == http.MethodGet || method == http.MethodHead
}

func copyResponseHeaders(dst, src http.Header) {
	hopByHop := map[string]struct{}{
		"Connection":          {},
		"Keep-Alive":          {},
		"Proxy-Authenticate":  {},
		"Proxy-Authorization": {},
		"TE":                  {},
		"Trailer":             {},
		"Transfer-Encoding":   {},
		"Upgrade":             {},
	}

	for k, vv := range src {
		if _, blocked := hopByHop[http.CanonicalHeaderKey(k)]; blocked {
			continue
		}
		for _, v := range vv {
			dst.Add(k, v)
		}
	}
}

func buildUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	cleanPath := path.Clean(rawPath)
	trimmed := strings.TrimPrefix(cleanPath, "/raw")
	parts := strings.Split(strings.Trim(trimmed, "/"), "/")

	// 格式要求：
	// /raw/{owner}/{repo}/{branch}/{file...}
	if len(parts) < 4 {
		return nil, errors.New("invalid path format")
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     upstreamHost,
		Path:     path.Join("/", parts[0], parts[1], parts[2], strings.Join(parts[3:], "/")),
		RawQuery: rawQuery,
	}
	return upstream, nil
}

func proxyRawHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	if !isAllowedMethod(r.Method) {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		log.Printf("method rejected: remote=%s method=%s path=%s", r.RemoteAddr, r.Method, r.URL.Path)
		return
	}

	user, pass, ok := r.BasicAuth()
	if !ok || !checkAuth(user, pass) {
		unauthorized(w)
		log.Printf("auth failed: remote=%s method=%s path=%s", r.RemoteAddr, r.Method, r.URL.Path)
		return
	}

	upstream, err := buildUpstreamURL(r.URL.Path, r.URL.RawQuery)
	if err != nil {
		http.Error(w, "Invalid Path Format", http.StatusBadRequest)
		log.Printf("bad path: remote=%s user=%s path=%s err=%v", r.RemoteAddr, user, r.URL.Path, err)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 55*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, r.Method, upstream.String(), nil)
	if err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		log.Printf("build upstream request failed: user=%s upstream=%s err=%v", user, upstream.String(), err)
		return
	}

	req.Header.Set("User-Agent", "Mozilla/5.0 ("+serverName+")")

	// 保留部分常见有用请求头
	if v := r.Header.Get("Range"); v != "" {
		req.Header.Set("Range", v)
	}
	if v := r.Header.Get("If-None-Match"); v != "" {
		req.Header.Set("If-None-Match", v)
	}
	if v := r.Header.Get("If-Modified-Since"); v != "" {
		req.Header.Set("If-Modified-Since", v)
	}

	resp, err := proxyClient.Do(req)
	if err != nil {
		http.Error(w, "Proxy Error", http.StatusBadGateway)
		log.Printf("proxy failed: user=%s upstream=%s err=%v", user, upstream.String(), err)
		return
	}
	defer resp.Body.Close()

	copyResponseHeaders(w.Header(), resp.Header)
	w.WriteHeader(resp.StatusCode)

	if _, err := io.Copy(w, resp.Body); err != nil {
		log.Printf("copy response failed: user=%s upstream=%s err=%v", user, upstream.String(), err)
	}

	log.Printf(
		"ok: remote=%s user=%s method=%s path=%s upstream=%s status=%d cost=%s",
		r.RemoteAddr,
		user,
		r.Method,
		r.URL.Path,
		upstream.String(),
		resp.StatusCode,
		time.Since(start).Round(time.Millisecond),
	)
}

func main() {
	port := strings.TrimSpace(os.Getenv("PORT"))
	if port == "" {
		port = defaultPort
	}

	host := strings.TrimSpace(os.Getenv("LISTEN_HOST"))
	if host == "" {
		host = defaultHost
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/raw/", proxyRawHandler)

	addr := net.JoinHostPort(host, port)
	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("Proxy Service running on http://%s", addr)
	log.Fatal(server.ListenAndServe())
}
