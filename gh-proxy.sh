#!/usr/bin/env bash
set -euo pipefail

# --- 1. 配置参数 ---
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

# --- 2. 辅助函数 ---
log() { printf '[\033[32m%s\033[0m] %s\n' "$APP_NAME" "$*"; }
die() { printf '[\033[31m%s\033[0m] ERROR: %s\n' "$APP_NAME" "$*" >&2; exit 1; }

# --- 3. 核心逻辑函数 ---
init_setup() {
    mkdir -p "$INSTALL_DIR"
    if [[ ! -f "$SRC_FILE" ]]; then
        log "正在同步远程源码..."
        wget -qO "$SRC_FILE" "https://raw.githubusercontent.com/${GH_REPO}/main/gh-proxy.go" || die "无法获取源码，请检查网络"
    fi
    [[ ! -f "$ENV_FILE" ]] && echo "PORT=$PORT" > "$ENV_FILE"
    touch "$USER_FILE"
}

ensure_go() {
    if [[ ! -x "${GO_LOCAL_DIR}/bin/go" ]]; then
        log "下载私有编译环境 (Go 1.22.5)..."
        local arch="amd64"
        [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        wget -qO /tmp/go.tar.gz "https://go.dev/dl/go1.22.5.linux-${arch}.tar.gz"
        tar -C "$INSTALL_DIR" -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
    fi
}

build_app() {
    log "开始编译程序并配置系统服务..."
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
    ln -sf "$INSTALL_DIR/$APP_NAME.sh" "/usr/local/bin/$APP_NAME"
    log "服务安装/更新成功！"
}

add_user() {
    read -p "请输入新用户名: " username
    grep -q "^${username}:" "$USER_FILE" && { log "错误：用户已存在"; return; }
    read -s -p "请输入密码: " pass; echo
    read -s -p "请确认密码: " pass2; echo
    [[ "$pass" == "$pass2" ]] && { echo "${username}:${pass}" >> "$USER_FILE"; log "用户添加成功"; } || log "两次密码输入不一致"
    systemctl restart "$APP_NAME"
}

manage_users() {
    local users=($(awk -F: '{print $1}' "$USER_FILE"))
    [[ ${#users[@]} -eq 0 ]] && { log "当前暂无用户"; return; }
    echo "--- 当前用户列表 ---"
    for i in "${!users[@]}"; do echo "$((i+1)). ${users[$i]}"; done
    read -p "请选择用户编号 (输入0返回): " idx
    [[ "$idx" == "0" ]] && return
    local target_user="${users[$((idx-1))]:-}"
    [[ -z "$target_user" ]] && return
    
    echo "1. 修改用户名  2. 修改密码  3. 删除用户  0. 返回"
    read -p "选择操作: " opt
    case $opt in
        1) read -p "新用户名: " n; sed -i "s/^${target_user}:/${n}:/" "$USER_FILE" ;;
        2) read -s -p "新密码: " p; echo; sed -i "s/^${target_user}:.*/${target_user}:${p}/" "$USER_FILE" ;;
        3) sed -i "/^${target_user}:/d" "$USER_FILE" ;;
        *) return ;;
    esac
    systemctl restart "$APP_NAME"
    log "操作成功，服务已重启。"
}

show_help() {
    clear
    local ip=$(curl -s -m 5 https://api64.ipify.org || echo "你的服务器IP")
    echo "===================================================="
    echo "           GH-PROXY 使用指南"
    echo "===================================================="
    echo "1. 代理链接格式："
    echo "   http://用户名:密码@${ip}:${PORT}/raw/owner/repo/branch/path"
    echo ""
    echo "2. 安全建议："
    echo "   建议使用 Nginx 对 http://127.0.0.1:${PORT} 进行反向代理并开启 HTTPS。"
    echo ""
    echo "3. 快捷管理："
    echo "   安装后，直接运行命令 ${APP_NAME} 即可打开此菜单。"
    echo "===================================================="
    read -n 1 -s -r -p "按回车键返回主菜单..."
}

uninstall() {
    echo -e "\033[31m确定要卸载程序并删除所有数据吗？(y/N)\033[0m"
    read -p "> " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    systemctl stop "$APP_NAME" || true
    systemctl disable "$APP_NAME" || true
    rm -f "$SERVICE_FILE" "/usr/local/bin/$APP_NAME"
    rm -rf "$INSTALL_DIR"
    log "卸载完成。"
    exit 0
}

# --- 4. 脚本执行引擎 (核心：不在函数内的直接调用) ---

# 检查 Root 权限
if [[ "$EUID" -ne 0 ]]; then
    die "请使用 root 权限运行此脚本"
fi

# 初始化目录环境
init_setup

# 如果主程序文件不存在，则强制执行安装流程
if [[ ! -f "$BIN_PATH" ]]; then
    ensure_go
    build_app
fi

# 进入无限循环主菜单
while true; do
    clear
    echo "============================="
    echo "    GH-PROXY 交互管理工具"
    echo "============================="
    echo " 1. 新建用户"
    echo " 2. 用户管理 (修改/删除)"
    echo " 3. 强制重新编译程序"
    echo " 4. 查看使用说明 (Help)"
    echo " 5. 卸载脚本"
    echo " 0. 退出脚本"
    echo "============================="
    read -p "请输入选项 [0-5]: " choice
    case $choice in
        1) add_user ;;
        2) manage_users ;;
        3) ensure_go && build_app ;;
        4) show_help ;;
        5) uninstall ;;
        0) exit 0 ;;
        *) log "无效选项" ;;
    esac
done
