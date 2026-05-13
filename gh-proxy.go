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
	serverName   = "GH-Proxy/2.2"

	rawHost      = "raw.githubusercontent.com"
	githubHost   = "github.com"
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

func buildRawUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	cleanPath := path.Clean(rawPath)
	trimmed := strings.TrimPrefix(cleanPath, "/raw")
	parts := strings.Split(strings.Trim(trimmed, "/"), "/")

	// 代理格式：
	// /raw/{owner}/{repo}/{branch}/{file...}
	//
	// 原始格式：
	// https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{file...}
	if len(parts) < 4 {
		return nil, errors.New("invalid raw path format")
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     rawHost,
		Path:     path.Join("/", parts[0], parts[1], parts[2], strings.Join(parts[3:], "/")),
		RawQuery: rawQuery,
	}

	return upstream, nil
}

func buildReleaseUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	cleanPath := path.Clean(rawPath)
	parts := strings.Split(strings.Trim(cleanPath, "/"), "/")

	// 代理格式：
	// /{owner}/{repo}/releases/download/{tag}/{file...}
	//
	// 原始格式：
	// https://github.com/{owner}/{repo}/releases/download/{tag}/{file...}
	if len(parts) < 6 {
		return nil, errors.New("invalid release path format")
	}

	if parts[2] != "releases" || parts[3] != "download" {
		return nil, errors.New("not a github release download path")
	}

	owner := parts[0]
	repo := parts[1]
	tag := parts[4]
	filePath := strings.Join(parts[5:], "/")

	if owner == "" || repo == "" || tag == "" || filePath == "" {
		return nil, errors.New("invalid release path")
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     githubHost,
		Path:     path.Join("/", owner, repo, "releases", "download", tag, filePath),
		RawQuery: rawQuery,
	}

	return upstream, nil
}

func proxyHandler(builder func(string, string) (*url.URL, error)) http.HandlerFunc {
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

		upstream, err := builder(r.URL.Path, r.URL.RawQuery)
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

		// 保留断点续传和缓存相关请求头
		if v := r.Header.Get("Range"); v != "" {
			req.Header.Set("Range", v)
		}
		if v := r.Header.Get("If-Range"); v != "" {
			req.Header.Set("If-Range", v)
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

	// Raw 文件代理：
	// https://用户名:密码@你的域名/raw/owner/repo/branch/file
	mux.HandleFunc("/raw/", proxyHandler(buildRawUpstreamURL))

	// GitHub Release 下载代理：
	// https://用户名:密码@你的域名/owner/repo/releases/download/tag/file
	mux.HandleFunc("/", proxyHandler(buildReleaseUpstreamURL))

	addr := net.JoinHostPort(host, port)
	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("Proxy Service running on http://%s", addr)
	log.Fatal(server.ListenAndServe())
}
