#!/usr/bin/env bash
set -euo pipefail

# --- 1. 配置参数 ---
APP_NAME="gh-proxy"
INSTALL_DIR="/opt/github-proxy"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
SRC_FILE="${INSTALL_DIR}/${APP_NAME}.go"
ENV_FILE="${INSTALL_DIR}/.env"
USER_FILE="${INSTALL_DIR}/.users"
GO_LOCAL_DIR="${INSTALL_DIR}/go"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

PORT="9090"
LISTEN_HOST="127.0.0.1"
GO_VERSION="1.22.5"

# --- 2. 基础检查 ---
[[ "${EUID}" -ne 0 ]] && { echo "错误：请使用 root 权限运行"; exit 1; }

mkdir -p "$INSTALL_DIR"
touch "$USER_FILE"
chmod 600 "$USER_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<EOF
PORT=${PORT}
LISTEN_HOST=${LISTEN_HOST}
EOF
    chmod 600 "$ENV_FILE"
fi

# --- 3. 工具函数 ---
pause() {
    read -r -p "按回车继续..."
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "错误：缺少命令 $cmd"
        exit 1
    }
}

is_valid_username() {
    local u="$1"
    [[ "$u" =~ ^[A-Za-z0-9_.-]+$ ]]
}

user_exists() {
    local u="$1"
    awk -F: -v user="$u" '$1==user{found=1} END{exit !found}' "$USER_FILE"
}

write_source() {
    echo "[gh-proxy] 写入内置最新版源码..."
    cat > "$SRC_FILE" <<'GOEOF'
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
	serverName          = "GH-Proxy/2.3"
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
	cleanPath := path.Clean("/" + strings.TrimPrefix(rawPath, "/"))
	trimmed := strings.TrimPrefix(cleanPath, prefix)
	trimmed = strings.Trim(trimmed, "/")
	if trimmed == "" {
		return nil
	}
	return strings.Split(trimmed, "/")
}

func buildRawUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	parts := splitProxyPath(rawPath, "/raw")

	// 代理格式：
	// /raw/{owner}/{repo}/{branch}/{file...}
	// 上游格式：
	// https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{file...}
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

	// 代理格式 1：
	// /release/{owner}/{repo}/{tag}/{asset-file...}
	// 上游格式：
	// https://github.com/{owner}/{repo}/releases/download/{tag}/{asset-file...}
	//
	// 代理格式 2：
	// /release/{owner}/{repo}/latest/{asset-file...}
	// 上游格式：
	// https://github.com/{owner}/{repo}/releases/latest/download/{asset-file...}
	if len(parts) < 4 {
		return nil, errors.New("invalid release path format")
	}

	owner := parts[0]
	repo := parts[1]
	tag := parts[2]
	asset := strings.Join(parts[3:], "/")

	var upstreamPath string
	if tag == "latest" {
		upstreamPath = path.Join("/", owner, repo, "releases", "latest", "download", asset)
	} else {
		upstreamPath = path.Join("/", owner, repo, "releases", "download", tag, asset)
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     releaseUpstreamHost,
		Path:     upstreamPath,
		RawQuery: rawQuery,
	}
	return upstream, nil
}

func buildGithubLikeUpstreamURL(rawPath, rawQuery string) (*url.URL, error) {
	cleanPath := path.Clean("/" + strings.TrimPrefix(rawPath, "/"))
	parts := strings.Split(strings.Trim(cleanPath, "/"), "/")

	// 支持你希望的这种格式：
	// /{owner}/{repo}/releases/latest/download/{asset-file...}
	// 对应上游：
	// https://github.com/{owner}/{repo}/releases/latest/download/{asset-file...}
	//
	// 同时支持普通 release：
	// /{owner}/{repo}/releases/download/{tag}/{asset-file...}
	// 对应上游：
	// https://github.com/{owner}/{repo}/releases/download/{tag}/{asset-file...}
	if len(parts) < 6 {
		return nil, errors.New("invalid github-like release path format")
	}

	if parts[2] != "releases" {
		return nil, errors.New("only github release path is allowed")
	}

	if parts[3] == "latest" {
		if len(parts) < 6 || parts[4] != "download" {
			return nil, errors.New("invalid latest release path format")
		}
	} else if parts[3] == "download" {
		if len(parts) < 6 {
			return nil, errors.New("invalid tagged release path format")
		}
	} else {
		return nil, errors.New("only releases/latest/download or releases/download paths are allowed")
	}

	upstream := &url.URL{
		Scheme:   "https",
		Host:     releaseUpstreamHost,
		Path:     cleanPath,
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
	mux.HandleFunc("/", proxyHandler(buildGithubLikeUpstreamURL))

	addr := net.JoinHostPort(host, port)
	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("Proxy Service running on http://%s", addr)
	log.Printf("Raw proxy path: /raw/{owner}/{repo}/{branch}/{file...}")
	log.Printf("Release proxy path: /release/{owner}/{repo}/{tag-or-latest}/{asset-file...}")
	log.Printf("GitHub-like latest release path: /{owner}/{repo}/releases/latest/download/{asset-file...}")
	log.Printf("GitHub-like tagged release path: /{owner}/{repo}/releases/download/{tag}/{asset-file...}")
	log.Fatal(server.ListenAndServe())
}
GOEOF
    chmod 644 "$SRC_FILE"
}

install_go_local() {
    echo "[gh-proxy] 准备编译环境..."
    local arch="amd64"
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            echo "不支持的系统架构: $(uname -m)"
            exit 1
            ;;
    esac

    rm -rf "$GO_LOCAL_DIR"
    wget -qO- "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" | tar -C "$INSTALL_DIR" -xz
}

build_binary() {
    [[ -x "${GO_LOCAL_DIR}/bin/go" ]] || {
        echo "Go 编译环境不存在，请先安装"
        exit 1
    }

    [[ -f "$SRC_FILE" ]] || {
        echo "源码不存在，正在重新写入源码"
        write_source
    }

    echo "[gh-proxy] 正在编译二进制文件..."
    "${GO_LOCAL_DIR}/bin/go" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" "$SRC_FILE"
    chmod 755 "$BIN_PATH"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GitHub Proxy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_PATH
Restart=always
RestartSec=3

# 基础安全项
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME"
}

install_global_command() {
    cp "$0" "${INSTALL_DIR}/${APP_NAME}.sh"
    chmod 755 "${INSTALL_DIR}/${APP_NAME}.sh"
    ln -sf "${INSTALL_DIR}/${APP_NAME}.sh" "/usr/local/bin/${APP_NAME}"
}

initial_install() {
    echo "[gh-proxy] 检测到未安装，开始初始化..."

    require_cmd wget
    require_cmd tar
    require_cmd systemctl

    write_source
    install_go_local
    build_binary
    write_service
    install_global_command

    if [[ "$0" == "/tmp/gh-proxy.sh" ]]; then
        rm -f "/tmp/gh-proxy.sh"
        echo "[gh-proxy] 临时安装脚本已清理。"
    fi

    echo "[gh-proxy] 安装成功！已生成全局命令: ${APP_NAME}"
}

show_usage() {
    clear
    echo "使用说明："
    echo
    echo "1. raw.githubusercontent.com 文件代理："
    echo "   原始链接："
    echo "   https://raw.githubusercontent.com/owner/repo/branch/file"
    echo "   代理链接："
    echo "   https://用户名:密码@你的域名/raw/owner/repo/branch/file"
    echo
    echo "2. GitHub Release 下载代理，兼容旧格式："
    echo "   原始链接："
    echo "   https://github.com/owner/repo/releases/download/tag/file"
    echo "   代理链接："
    echo "   https://用户名:密码@你的域名/release/owner/repo/tag/file"
    echo
    echo "3. GitHub Release latest 下载代理，兼容旧入口："
    echo "   原始链接："
    echo "   https://github.com/owner/repo/releases/latest/download/file"
    echo "   代理链接："
    echo "   https://用户名:密码@你的域名/release/owner/repo/latest/file"
    echo
    echo "4. GitHub Release latest 下载代理，GitHub 原路径镜像格式："
    echo "   原始链接："
    echo "   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    echo "   代理链接："
    echo "   https://用户名:密码@你的域名/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    echo
    echo "5. GitHub Release 普通 tag 下载代理，GitHub 原路径镜像格式："
    echo "   原始链接："
    echo "   https://github.com/owner/repo/releases/download/tag/file"
    echo "   代理链接："
    echo "   https://用户名:密码@你的域名/owner/repo/releases/download/tag/file"
    echo
    echo "6. 说明："
    echo "   - 当前程序默认仅监听 ${LISTEN_HOST}:${PORT}"
    echo "   - 请通过你自己的 Nginx / Caddy 反代访问"
    echo "   - Release 下载会由本服务跟随 GitHub 跳转后再转发给客户端"
    echo "   - 支持 GET / HEAD，并保留 Range 请求头，适合断点续传"
    echo "   - 若你修改了 .env 中的端口或监听地址，请重启服务"
    echo
    pause
}

add_user() {
    local u p

    read -r -p "用户名: " u
    read -r -s -p "密码: " p
    echo

    if [[ -z "$u" || -z "$p" ]]; then
        echo "用户名和密码不能为空"
        pause
        return
    fi

    if ! is_valid_username "$u"; then
        echo "用户名非法：仅允许字母、数字、点、下划线、横线"
        pause
        return
    fi

    if user_exists "$u"; then
        echo "用户已存在，请使用“修改用户”功能"
        pause
        return
    fi

    echo "${u}:${p}" >> "$USER_FILE"
    chmod 600 "$USER_FILE"
    systemctl restart "$APP_NAME"

    echo "添加成功"
    pause
}

modify_user() {
    if [[ ! -s "$USER_FILE" ]]; then
        echo "暂无用户"
        sleep 1
        return
    fi

    mapfile -t users < <(awk -F: 'NF>=1 && $1 !~ /^#/ && $1 != "" {print $1}' "$USER_FILE")

    if [[ "${#users[@]}" -eq 0 ]]; then
        echo "暂无有效用户"
        sleep 1
        return
    fi

    echo "当前用户："
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    read -r -p "请选择编号: " idx

    if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#users[@]} )); then
        echo "编号无效"
        pause
        return
    fi

    local target="${users[$((idx-1))]}"
    local opt
    echo "1. 修改密码"
    echo "2. 删除用户"
    echo "0. 返回"
    read -r -p "操作: " opt

    case "${opt:-}" in
        1)
            local p
            read -r -s -p "新密码: " p
            echo
            if [[ -z "$p" ]]; then
                echo "密码不能为空"
                pause
                return
            fi

            awk -F: -v user="$target" -v pass="$p" 'BEGIN{OFS=":"} $1==user{$2=pass} {print}' "$USER_FILE" > "${USER_FILE}.tmp"
            mv "${USER_FILE}.tmp" "$USER_FILE"
            chmod 600 "$USER_FILE"
            systemctl restart "$APP_NAME"
            echo "密码修改完成"
            ;;
        2)
            awk -F: -v user="$target" '$1!=user {print}' "$USER_FILE" > "${USER_FILE}.tmp"
            mv "${USER_FILE}.tmp" "$USER_FILE"
            chmod 600 "$USER_FILE"
            systemctl restart "$APP_NAME"
            echo "用户已删除"
            ;;
        0)
            return
            ;;
        *)
            echo "无效操作"
            ;;
    esac

    pause
}

rebuild_local() {
    echo "[gh-proxy] 重新编译本地源码..."
    build_binary
    systemctl restart "$APP_NAME"
    echo "编译完成并重启"
    sleep 1
}

rewrite_source_and_rebuild() {
    echo "[gh-proxy] 重写内置源码并重新编译..."
    write_source
    build_binary
    systemctl restart "$APP_NAME"
    echo "源码已重写，编译完成并重启"
    sleep 1
}

show_service_status() {
    clear
    systemctl --no-pager --full status "$APP_NAME" || true
    echo
    pause
}

uninstall_all() {
    read -r -p "确定卸载吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    systemctl stop "$APP_NAME" || true
    systemctl disable "$APP_NAME" || true
    rm -f "$SERVICE_FILE" "/usr/local/bin/$APP_NAME"
    systemctl daemon-reload || true
    rm -rf "$INSTALL_DIR"

    echo "卸载完成，所有数据已清理。"
    exit 0
}

# --- 4. 首次安装逻辑 ---
if [[ ! -x "$BIN_PATH" ]] || [[ ! -d "$GO_LOCAL_DIR" ]] || [[ ! -f "$SERVICE_FILE" ]]; then
    initial_install
    sleep 1
fi

# --- 5. 交互菜单 ---
while true; do
    clear
    echo "============================="
    echo "    GH-PROXY 交互管理工具"
    echo "============================="
    echo " 1. 新建用户"
    echo " 2. 修改用户"
    echo " 3. 使用说明"
    echo " 4. 重新编译本地源码"
    echo " 5. 重写内置源码并重编译"
    echo " 6. 查看服务状态"
    echo " 7. 卸载脚本"
    echo " 0. 退出脚本"
    echo "============================="
    read -r -p "请输入选项 [0-7]: " choice

    case "${choice:-}" in
        1) add_user ;;
        2) modify_user ;;
        3) show_usage ;;
        4) rebuild_local ;;
        5) rewrite_source_and_rebuild ;;
        6) show_service_status ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
