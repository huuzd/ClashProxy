#!/usr/bin/env bash
set -euo pipefail

# --- 配置参数 ---
APP_NAME="gh-proxy"
GH_REPO="huuzd/gh-proxy"
INSTALL_DIR="/opt/github-proxy"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
SRC_FILE="${INSTALL_DIR}/${APP_NAME}.go"
ENV_FILE="${INSTALL_DIR}/.env"
USER_FILE="${INSTALL_DIR}/.users"
GO_LOCAL_DIR="${INSTALL_DIR}/go"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
PORT="9090"

log() { printf '[\033[32m%s\033[0m] %s\n' "$APP_NAME" "$*"; }
die() { printf '[\033[31m%s\033[0m] ERROR: %s\n' "$APP_NAME" "$*" >&2; exit 1; }

# --- 核心功能 ---
init_setup() {
    mkdir -p "$INSTALL_DIR"
    # 如果本地没有源码，从 GitHub 下载
    if [[ ! -f "$SRC_FILE" ]]; then
        log "正在从 GitHub 获取源码..."
        wget -qO "$SRC_FILE" "https://raw.githubusercontent.com/${GH_REPO}/main/gh-proxy.go" || die "下载源码失败"
    fi
    [[ ! -f "$ENV_FILE" ]] && echo "PORT=$PORT" > "$ENV_FILE"
    touch "$USER_FILE"
}

ensure_go() {
    if [[ ! -x "${GO_LOCAL_DIR}/bin/go" ]]; then
        log "下载私有 Go 环境 (仅编译使用)..."
        local arch="amd64"
        [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        wget -qO /tmp/go.tar.gz "https://go.dev/dl/go1.22.5.linux-${arch}.tar.gz"
        tar -C "$INSTALL_DIR" -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
    fi
}

build_app() {
    log "正在编译并配置系统服务..."
    "${GO_LOCAL_DIR}/bin/go" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" "$SRC_FILE"
    chmod +x "$BIN_PATH"
    
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

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME"
    # 创建全局命令快捷方式
    ln -sf "$INSTALL_DIR/$APP_NAME.sh" "/usr/local/bin/$APP_NAME"
    log "部署成功！现在你可以直接输入 '$APP_NAME' 管理服务。"
}

# --- 菜单功能 ---
uninstall() {
    echo -e "\033[31m确定要卸载脚本并删除所有数据吗？(y/N)\033[0m"
    read -p "> " res
    if [[ "$res" == "y" || "$res" == "Y" ]]; then
        systemctl stop "$APP_NAME" && systemctl disable "$APP_NAME"
        rm -f "$SERVICE_FILE" "/usr/local/bin/$APP_NAME"
        rm -rf "$INSTALL_DIR"
        log "卸载完成。"
        exit 0
    fi
}

show_help() {
    clear
    local ip=$(curl -s -m 5 https://api64.ipify.org || echo "你的服务器IP")
    echo "===================================================="
    echo "           GH-PROXY 使用说明"
    echo "===================================================="
    echo "代理链接格式："
    echo "http://用户名:密码@${ip}:${PORT}/raw/owner/repo/branch/file"
    echo ""
    echo "示例："
    echo "http://admin:123@${ip}:${PORT}/raw/huuzd/gh-proxy/main/gh-proxy.sh"
    echo "===================================================="
    read -p "按回车返回菜单..."
}

# --- 用户管理 ---
add_user() {
    read -p "用户名: " u
    read -s -p "密码: " p; echo
    echo "${u}:${p}" >> "$USER_FILE" && log "用户 $u 已添加。"
}

manage_users() {
    local users=($(awk -F: '{print $1}' "$USER_FILE"))
    [[ ${#users[@]} -eq 0 ]] && { log "暂无用户"; return; }
    echo "--- 用户列表 ---"
    for i in "${!users[@]}"; do echo "$((i+1)). ${users[$i]}"; done
    read -p "请选择编号进行操作 (0返回): " idx
    [[ "$idx" == "0" ]] && return
    local target="${users[$((idx-1))]:-}"
    [[ -z "$target" ]] && return
    
    echo "1.修改用户名 2.修改密码 3.删除用户 0.返回"
    read -p "选择: " opt
    case $opt in
        1) read -p "新用户名: " n; sed -i "s/^${target}:/${n}:/" "$USER_FILE" ;;
        2) read -s -p "新密码: " p; echo; sed -i "s/^${target}:.*/${target}:${p}/" "$USER_FILE" ;;
        3) sed -i "/^${target}:/d" "$USER_FILE" ;;
    esac
    log "操作已完成。"
}

# --- 脚本入口 ---
[[ "$EUID" -ne 0 ]] && die "请使用 root 权限运行"

init_setup

# 如果是第一次运行（二进制文件不存在），自动安装
if [[ ! -f "$BIN_PATH" ]]; then
    ensure_go
    build_app
fi

# 交互菜单循环
while true; do
    clear
    echo "============================="
    echo "    GH-PROXY 交互管理工具"
    echo "============================="
    echo " 1. 新建用户"
    echo " 2. 用户管理 (修改/删除)"
    echo " 3. 强制重新编译程序"
    echo " 4. 查看使用说明"
    echo " 5. 卸载脚本"
    echo " 0. 退出菜单"
    echo "============================="
    read -p "请选择 [0-5]: " choice
    case $choice in
        1) add_user ;;
        2) manage_users ;;
        3) ensure_go && build_app ;;
        4) show_help ;;
        5) uninstall ;;
        0) exit 0 ;;
    esac
done
