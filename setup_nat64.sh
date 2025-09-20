#!/bin/sh
# Alpine Linux 一键 NAT64 + DNS + 网络测试
# 作者: chis
# 用法:
#   ./nat64_alpine.sh install  # 只安装 NAT64 + DNS
#   ./nat64_alpine.sh test     # 只测试网络
#   ./nat64_alpine.sh all      # 安装 + 测试（默认）

set -e

MODE=${1:-all}

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

DNS1="2001:67c:2b0::4"
DNS2="2001:67c:2b0::6"
NAT64_TEST="64:ff9b::c000:0201"

# ---------- 安装 Tayga 和依赖 ----------
install_tayga() {
    echo -e "${BLUE}=== 更新系统并安装依赖 ===${NC}"
    apk update
    apk add --no-cache build-base linux-headers autoconf automake libtool bash curl bind-tools iproute2 iptables git

    echo -e "${BLUE}=== 编译安装 Tayga ===${NC}"
    if [ ! -d "/usr/local/src/tayga" ]; then
        git clone https://gitlab.com/alcide/tayga.git /usr/local/src/tayga
    fi
    cd /usr/local/src/tayga
    ./autogen.sh
    ./configure
    make
    make install

    echo -e "${GREEN}Tayga 安装完成${NC}"
}

# ---------- 配置固定 IPv6 DNS ----------
configure_dns() {
    echo -e "${BLUE}=== 配置固定 IPv6 DNS ===${NC}"
    cp -f /etc/resolv.conf /etc/resolv.conf.bak
    cat << EOF > /etc/resolv.conf
nameserver $DNS1
nameserver $DNS2
EOF

    # 禁止 dhcpcd 覆盖 resolv.conf
    if [ -f /etc/dhcpcd.conf ]; then
        grep -q "nohook resolv.conf" /etc/dhcpcd.conf || echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    fi

    echo -e "${GREEN}DNS 配置完成:${NC}"
    cat /etc/resolv.conf
}

# ---------- 配置 NAT64 ----------
configure_nat64() {
    echo -e "${BLUE}=== 配置 Tayga NAT64 ===${NC}"

    cat << EOF > /etc/tayga.conf
ipv4-addr 192.168.255.1
prefix 64:ff9b::/96
dynamic-pool 192.168.255.0/24
data-dir /var/lib/tayga
EOF

    mkdir -p /var/lib/tayga

    # 自动检测默认出口接口
    IFACE=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1)}}}')
    if [ -z "$IFACE" ]; then
        echo -e "${RED}无法检测默认 IPv6 接口，请手动设置${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到默认出口接口: $IFACE${NC}"

    # 启用 IPv4 转发
    sysctl -w net.ipv4.ip_forward=1

    # 启动 Tayga
    /usr/local/sbin/tayga -c /etc/tayga.conf
    echo -e "${GREEN}Tayga NAT64 已启动${NC}"

    # 配置 NAT64 路由
    ip -6 route add 64:ff9b::/96 dev nat64 || true
    iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o $IFACE -j MASQUERADE || true
}

# ---------- 开机自启 ----------
setup_autostart() {
    echo -e "${BLUE}=== 配置开机自启 NAT64 + DNS ===${NC}"

    BOOT_SCRIPT="/usr/local/bin/nat64-dns-start.sh"
    cat << EOF > $BOOT_SCRIPT
#!/bin/sh
sysctl -w net.ipv4.ip_forward=1
/usr/local/sbin/tayga -c /etc/tayga.conf
ip -6 route add 64:ff9b::/96 dev nat64 || true
iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o $IFACE -j MASQUERADE || true
echo "nameserver $DNS1" > /etc/resolv.conf
echo "nameserver $DNS2" >> /etc/resolv.conf
EOF

    chmod +x $BOOT_SCRIPT

    # 创建 openrc 服务
    SERVICE_FILE="/etc/init.d/nat64-dns"
    cat << EOF > $SERVICE_FILE
#!/sbin/openrc-run
description="Startup NAT64 + IPv4 forwarding + DNS"

start() {
    sh $BOOT_SCRIPT
}
stop() {
    pkill tayga || true
}
EOF
    chmod +x $SERVICE_FILE
    rc-update add nat64-dns default

    echo -e "${GREEN}开机自启配置完成${NC}"
}

# ---------- 网络测试 ----------
network_test() {
    echo -e "${BLUE}=== 网络测试 ===${NC}"

    echo -n "测试 IPv6 网络: "
    if ping6 -c 2 google.com &>/dev/null; then
        echo -e "${GREEN}正常${NC}"
    else
        echo -e "${RED}异常${NC}"
    fi

    echo -n "测试 IPv4 网络 (通过 NAT64): "
    if ping6 -c 2 $NAT64_TEST &>/dev/null; then
        echo -e "${GREEN}可达${NC}"
    else
        echo -e "${RED}不可达${NC}"
    fi

    echo -n "测试 DNS 解析: "
    DNS_TEST=$(dig +short google.com | head -n1)
    if [ -n "$DNS_TEST" ]; then
        echo -e "${GREEN}正常 (${DNS_TEST})${NC}"
    else
        echo -e "${RED}失败${NC}"
    fi

    echo -n "测试 NAT64 转换访问 IPv4 网站: "
    if curl -6 -s --max-time 10 http://ipv4.google.com &>/dev/null; then
        echo -e "${GREEN}正常${NC}"
    else
        echo -e "${RED}异常${NC}"
    fi

    echo -e "${BLUE}=== 当前公网 IP 信息 ===${NC}"
    echo -n "IPv6: "; curl -6 -s ifconfig.co || echo -e "${RED} 获取失败${NC}"; echo ""
    echo -n "IPv4 (NAT64): "; curl -4 -s ifconfig.co || echo -e "${RED} 获取失败${NC}"; echo ""
}

# ---------- 主程序 ----------
case $MODE in
    install)
        install_tayga
        configure_dns
        configure_nat64
        setup_autostart
        echo -e "${GREEN}=== 安装完成 ===${NC}"
        ;;
    test)
        network_test
        ;;
    all|*)
        install_tayga
        configure_dns
        configure_nat64
        setup_autostart
        network_test
        echo -e "${GREEN}=== 安装与测试完成 ===${NC}"
        ;;
esac
