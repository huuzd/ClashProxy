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

// 实时校验用户数据库
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
		// 1. 身份校验
		u, p, ok := r.BasicAuth()
		if !ok || !checkAuth(u, p) {
			w.Header().Set("WWW-Authenticate", `Basic realm="gh-proxy"`)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		// 2. 路径解析与容错
		cleanPath := path.Clean(r.URL.Path)
		trimmed := strings.TrimPrefix(cleanPath, "/raw")
		parts := strings.Split(strings.Trim(trimmed, "/"), "/")
		if len(parts) < 4 {
			http.Error(w, "Invalid Path Format", http.StatusBadRequest)
			return
		}

		// 3. 构建目标 GitHub URL
		upstream := &url.URL{
			Scheme: "https",
			Host:   "raw.githubusercontent.com",
			Path:   path.Join("/", parts[0], parts[1], parts[2], strings.Join(parts[3:], "/")),
			RawQuery: r.URL.RawQuery,
		}

		ctx, cancel := context.WithTimeout(r.Context(), 55*time.Second)
		defer cancel()

		req, _ := http.NewRequestWithContext(ctx, r.Method, upstream.String(), nil)
		req.Header.Set("User-Agent", "Mozilla/5.0 (GH-Proxy/2.0; 自建加速服务)")

		// 4. 执行转发
		resp, err := proxyClient.Do(req)
		if err != nil {
			log.Printf("转发失败: %v", err)
			http.Error(w, "Proxy Error", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		// 5. 响应输出
		for k, vv := range resp.Header {
			for _, v := range vv { w.Header().Add(k, v) }
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
	})

	log.Printf("GitHub Proxy 已在端口 %s 启动", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
