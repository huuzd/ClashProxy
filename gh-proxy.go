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
	userFile            = ".users"
	defaultPort         = "9090"
	defaultHost         = "127.0.0.1"
	serverName          = "GH-Proxy/2.2"
	rawUpstreamHost     = "raw.githubusercontent.com"
	releaseUpstreamHost = "github.com"
)

var proxyClient = &http.Client{
	Timeout: 10 * time.Minute,
	Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          50,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 60 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		DisableCompression:    true,
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

func splitProxyPath(rawPath, prefix string) []string {
	cleanPath := path.Clean(rawPath)
	trimmed := strings.TrimPrefix(cleanPath, prefix)
	return strings.Split(strings.Trim(trimmed, "/"), "/")
}

func buildRawUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	parts := splitProxyPath(rawPath, "/raw")

	// 格式要求：
	// /raw/{owner}/{repo}/{branch}/{file...}
	if len(parts) < 4 {
		return nil, errors.New("invalid raw path format")
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     rawUpstreamHost,
		Path:     path.Join("/", parts[0], parts[1], parts[2], strings.Join(parts[3:], "/")),
		RawQuery: rawQuery,
	}
	return upstream, nil
}

func buildReleaseUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	parts := splitProxyPath(rawPath, "/release")

	// 格式要求：
	// /release/{owner}/{repo}/{tag}/{asset-file...}
	// 对应上游：
	// https://github.com/{owner}/{repo}/releases/download/{tag}/{asset-file...}
	if len(parts) < 4 {
		return nil, errors.New("invalid release path format")
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     releaseUpstreamHost,
		Path:     path.Join("/", parts[0], parts[1], "releases", "download", parts[2], strings.Join(parts[3:], "/")),
		RawQuery: rawQuery,
	}
	return upstream, nil
}

func setForwardHeaders(req *http.Request, r *http.Request) {
	req.Header.Set("User-Agent", "Mozilla/5.0 ("+serverName+")")
	req.Header.Set("Accept", "application/octet-stream,*/*")

	// 保留下载、缓存、断点续传相关请求头
	forwardHeaders := []string{
		"Range",
		"If-Range",
		"If-None-Match",
		"If-Modified-Since",
	}

	for _, h := range forwardHeaders {
		if v := r.Header.Get(h); v != "" {
			req.Header.Set(h, v)
		}
	}
}

func proxyHandler(buildUpstream func(string, string) (*url.URL, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
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

		upstream, err := buildUpstream(r.URL.Path, r.URL.RawQuery)
		if err != nil {
			http.Error(w, "Invalid Path Format", http.StatusBadRequest)
			log.Printf("bad path: remote=%s user=%s path=%s err=%v", r.RemoteAddr, user, r.URL.Path, err)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
		defer cancel()

		req, err := http.NewRequestWithContext(ctx, r.Method, upstream.String(), nil)
		if err != nil {
			http.Error(w, "Bad Request", http.StatusBadRequest)
			log.Printf("build upstream request failed: user=%s upstream=%s err=%v", user, upstream.String(), err)
			return
		}

		setForwardHeaders(req, r)

		resp, err := proxyClient.Do(req)
		if err != nil {
			http.Error(w, "Proxy Error", http.StatusBadGateway)
			log.Printf("proxy failed: user=%s upstream=%s err=%v", user, upstream.String(), err)
			return
		}
		defer resp.Body.Close()

		copyResponseHeaders(w.Header(), resp.Header)
		w.WriteHeader(resp.StatusCode)

		if r.Method != http.MethodHead {
			if _, err := io.Copy(w, resp.Body); err != nil {
				log.Printf("copy response failed: user=%s upstream=%s err=%v", user, upstream.String(), err)
			}
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
	mux.HandleFunc("/raw/", proxyHandler(buildRawUpstreamURL))
	mux.HandleFunc("/release/", proxyHandler(buildReleaseUpstreamURL))

	addr := net.JoinHostPort(host, port)
	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("Proxy Service running on http://%s", addr)
	log.Printf("Raw proxy path: /raw/{owner}/{repo}/{branch}/{file...}")
	log.Printf("Release proxy path: /release/{owner}/{repo}/{tag}/{asset-file...}")
	log.Fatal(server.ListenAndServe())
}
