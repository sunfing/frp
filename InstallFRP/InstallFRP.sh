#!/bin/bash
# ============================================================
# FRP 二合一全能脚本 (服务端 frps / 客户端 frpc)
# 脚本功能: 一键部署 / 卸载 / 自动更新 / 自动生成配置
# 支持系统: Linux AMD64 / ARM64 (含 OpenWrt)
# GitHub：https://github.com/sunfing
# Telegram：https://t.me/i_chl
# ============================================================

# 公共变量
BASE_DIR="/opt"
# 颜色
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"

say() { echo -e "${C_B}[*]${C_0} $*"; }
ok()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
err() { echo -e "${C_R}[X]${C_0} $*"; }

# 检查 Root
if [ "$(id -u)" -ne 0 ]; then
  err "请使用 root 用户执行此脚本"
  exit 1
fi

# ============================================================
# 1. 核心安装逻辑 (通用)
# ============================================================
install_core() {
    local ROLE=$1  # 传入 frps 或 frpc
    local INSTALL_DIR="${BASE_DIR}/${ROLE}"
    local BIN_FILE="${INSTALL_DIR}/${ROLE}"
    local CONFIG_FILE="${INSTALL_DIR}/${ROLE}.toml"
    local LOG_FILE="${INSTALL_DIR}/${ROLE}.log"
    local SERVICE_NAME="${ROLE}"

    say "正在准备安装 ${ROLE} ..."

    # 1.1 系统检测
    if [ -f "/etc/openwrt_release" ]; then
        OS_TYPE="openwrt"
        opkg update && opkg install wget-ssl curl tar ca-certificates
    else
        OS_TYPE="linux"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y wget curl tar
        elif command -v yum >/dev/null 2>&1; then
            yum install -y wget curl tar
        fi
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FR_ARCH="amd64" ;;
        aarch64|arm64) FR_ARCH="arm64" ;;
        *) err "不支持的架构: $ARCH"; exit 1 ;;
    esac

    # 1.2 获取版本
    say "获取 GitHub 最新版本..."
    LATEST_TAG=$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest | grep tag_name | cut -d '"' -f4)
    [ -z "$LATEST_TAG" ] && LATEST_TAG="v0.60.0" && warn "获取失败，使用默认版本 $LATEST_TAG"
    VERSION_NO_V=${LATEST_TAG#v}

    # 1.3 清理旧版
    if [ -d "$INSTALL_DIR" ]; then
        say "检测到旧安装，正在清理..."
        if command -v systemctl >/dev/null 2>&1; then systemctl stop $SERVICE_NAME 2>/dev/null; else /etc/init.d/$SERVICE_NAME stop 2>/dev/null; fi
        rm -rf "$INSTALL_DIR"
    fi

    # 1.4 下载与解压
    mkdir -p "${INSTALL_DIR}" && cd "${INSTALL_DIR}"
    FILE_BASE="frp_${VERSION_NO_V}_linux_${FR_ARCH}"
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_TAG}/${FILE_BASE}.tar.gz"
    
    say "下载: ${DOWNLOAD_URL}"
    wget -O frp.tar.gz "${DOWNLOAD_URL}" --no-check-certificate || { err "下载失败"; exit 1; }
    
    tar -zxvf frp.tar.gz >/dev/null 2>&1
    
    # === 关键：根据 ROLE 提取对应的二进制文件 ===
    if [ -d "${FILE_BASE}" ]; then
        if [ -f "${FILE_BASE}/${ROLE}" ]; then
            mv "${FILE_BASE}/${ROLE}" .
            chmod +x "${ROLE}"
            rm -rf "${FILE_BASE}" frp.tar.gz
            ok "二进制文件 ${ROLE} 安装完成"
        else
            err "未在压缩包中找到 ${ROLE}，文件结构可能已变更"
            exit 1
        fi
    else
        err "解压异常"
        exit 1
    fi

    # 1.5 生成配置文件 (区分服务端和客户端)
    generate_config "$ROLE" "$CONFIG_FILE"

    # 1.6 配置服务
    setup_service "$ROLE" "$INSTALL_DIR" "$CONFIG_FILE" "$LOG_FILE" "$OS_TYPE"

    # 1.7 自动更新脚本
    create_updater "$ROLE" "$INSTALL_DIR" "$LATEST_TAG"

    say "部署完成！"
    ok "启动命令: systemctl start ${ROLE} (Linux) 或 /etc/init.d/${ROLE} start (OpenWrt)"
}

# ============================================================
# 2. 配置文件生成逻辑
# ============================================================
generate_config() {
    local ROLE=$1
    local FILE=$2

    if [ "$ROLE" = "frps" ]; then
        # --- 服务端配置 ---
        say "配置 FRPS (服务端)"
        read -p "请输入 绑定端口 (bindPort, 默认 7000): " BP; BP=${BP:-7000}
        read -p "请输入 验证 Token (默认 password123): " TK; TK=${TK:-password123}
        
        cat > "$FILE" <<EOF
# frps.toml
bindPort = ${BP}
auth.method = "token"
auth.token = "${TK}"
EOF
        # 仪表盘询问
        read -p "是否开启 Dashboard? (y/n): " DASH
        if [[ "$DASH" =~ [yY] ]]; then
            read -p "Dash端口 (7500): " DP; DP=${DP:-7500}
            read -p "Dash用户 (admin): " DU; DU=${DU:-admin}
            read -p "Dash密码 (admin): " DPW; DPW=${DPW:-admin}
            cat >> "$FILE" <<EOF
webServer.addr = "0.0.0.0"
webServer.port = ${DP}
webServer.user = "${DU}"
webServer.password = "${DPW}"
EOF
        fi

    elif [ "$ROLE" = "frpc" ]; then
        # --- 客户端配置 ---
        say "配置 FRPC (客户端)"
        read -p "请输入 服务器 IP 地址: " SIP
        [ -z "$SIP" ] && err "服务器 IP 不能为空" && exit 1
        read -p "请输入 服务器端口 (默认 7000): " SP; SP=${SP:-7000}
        read -p "请输入 验证 Token (默认 password123): " TK; TK=${TK:-password123}

        cat > "$FILE" <<EOF
# frpc.toml
serverAddr = "${SIP}"
serverPort = ${SP}
auth.method = "token"
auth.token = "${TK}"

# [示例] 开启一个 SSH 穿透 (默认关闭，需手动去掉注释)
# [[proxies]]
# name = "ssh-demo"
# type = "tcp"
# localIP = "127.0.0.1"
# localPort = 22
# remotePort = 6000
EOF
        warn "已生成基础配置。如需穿透特定端口，请编辑 $FILE 添加 [[proxies]] 规则。"
    fi
}

# ============================================================
# 3. 服务注册逻辑 (Systemd / Procd)
# ============================================================
setup_service() {
    local ROLE=$1; local IDIR=$2; local CONF=$3; local LOG=$4; local OS=$5
    
    say "注册系统服务..."
    if [ "$OS" = "openwrt" ]; then
        cat > "/etc/init.d/${ROLE}" <<EOF
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=${IDIR}/${ROLE}
CONF=${CONF}
start_service() {
    procd_open_instance
    procd_set_param command \$PROG -c \$CONF
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
        chmod +x "/etc/init.d/${ROLE}"
        /etc/init.d/${ROLE} enable
        /etc/init.d/${ROLE} restart
    else
        cat > "/etc/systemd/system/${ROLE}.service" <<EOF
[Unit]
Description=FRP ${ROLE} Service
After=network.target
[Service]
Type=simple
ExecStart=${IDIR}/${ROLE} -c ${CONF}
Restart=always
RestartSec=5
StandardOutput=append:${LOG}
StandardError=append:${LOG}
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${ROLE}
        systemctl restart ${ROLE}
    fi
}

# ============================================================
# 4. 自动更新脚本生成
# ============================================================
create_updater() {
    local ROLE=$1; local IDIR=$2; local TAG=$3
    local UPDATER="${IDIR}/${ROLE}_update.sh"
    
    cat > "$UPDATER" <<EOF
#!/bin/bash
# 简易自动更新脚本
IDIR="${IDIR}"
ROLE="${ROLE}"
cd "\$IDIR"
CUR=\$(./${ROLE} -v)
LATEST=\$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest | grep tag_name | cut -d '"' -f4)
NO_V=\${LATEST#v}
if [ "\$CUR" != "\$NO_V" ] && [ -n "\$LATEST" ]; then
    ARCH=\$(uname -m)
    [ "\$ARCH" = "x86_64" ] && A="amd64" || A="arm64"
    URL="https://github.com/fatedier/frp/releases/download/\${LATEST}/frp_\${NO_V}_linux_\${A}.tar.gz"
    wget -O update.tar.gz "\$URL" && tar -zxf update.tar.gz
    if [ -f "frp_\${NO_V}_linux_\${A}/\${ROLE}" ]; then
        mv "frp_\${NO_V}_linux_\${A}/\${ROLE}" .
        chmod +x \${ROLE}
        rm -rf frp_*.tar.gz frp_*/
        if command -v systemctl; then systemctl restart \${ROLE}; else /etc/init.d/\${ROLE} restart; fi
    fi
fi
EOF
    chmod +x "$UPDATER"
    
    read -p "启用 ${ROLE} 每日自动更新? (y/n): " AUTO
    if [[ "$AUTO" =~ [yY] ]]; then
        (crontab -l 2>/dev/null | grep -v "$UPDATER"; echo "0 4 * * * $UPDATER") | crontab -
        ok "已添加定时任务"
    fi
}

# ============================================================
# 5. 卸载逻辑
# ============================================================
uninstall() {
    local ROLE=$1
    say "正在卸载 ${ROLE} ..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ${ROLE} 2>/dev/null
        systemctl disable ${ROLE} 2>/dev/null
        rm -f "/etc/systemd/system/${ROLE}.service"
        systemctl daemon-reload
    else
        /etc/init.d/${ROLE} stop 2>/dev/null
        /etc/init.d/${ROLE} disable 2>/dev/null
        rm -f "/etc/init.d/${ROLE}"
    fi
    rm -rf "${BASE_DIR}/${ROLE}"
    ok "${ROLE} 已卸载"
}

# ============================================================
# 主菜单
# ============================================================
clear
echo -e "${C_B}========================================${C_0}"
echo -e "${C_B}    FRP (Server & Client) 管理脚本    ${C_0}"
echo -e "${C_B}========================================${C_0}"
echo "1. 安装/更新 FRP 服务端 (frps)"
echo "2. 安装/更新 FRP 客户端 (frpc)"
echo "3. 卸载 frps"
echo "4. 卸载 frpc"
echo "0. 退出"
echo -e "${C_B}========================================${C_0}"
read -p "请选择 (0-4): " CHOICE

case "$CHOICE" in
    1) install_core "frps" ;;
    2) install_core "frpc" ;;
    3) uninstall "frps" ;;
    4) uninstall "frpc" ;;
    0) exit 0 ;;
    *) err "无效输入" ;;
esac
