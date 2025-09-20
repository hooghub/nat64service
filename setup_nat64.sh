#!/bin/bash
# 一键 NAT64 + IPv6 DNS 配置 + 开机自启 + 网络测试（可选模式）
# 用法:
#   ./nat64_onekey.sh install    # 只安装 NAT64 + DNS
#   ./nat64_onekey.sh test       # 只测试网络
#   ./nat64_onekey.sh all        # 安装 + 测试（默认）
# 作者: ChatGPT

set -e

MODE=${1:-all}  # 默认模式 all

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

DNS1="2001:67c:2b0::4"
DNS2="2001:67c:2b0::6"

NAT64_TEST="64:ff9b::c000:0201"  # 测试 IPv4 NAT64 地址

# ---------- 安装 NAT64 + DNS ----------
install_nat64_dns() {
    echo -e "${BLUE}=== 更新系统并安装必要软件 ===${NC}"
    apt update -y
    apt install -y tayga iptables resolvconf net-tools iproute2 iptables-persistent dnsutils curl

    echo -e "${BLUE}=== 配置固定 IPv6 DNS ===${NC}"
    RESOLV_FILE="/etc/resolvconf/resolv.conf.d/base"
    grep -q "$DNS1" $RESOLV_FILE || cat << EOF >> $RESOLV_FILE
nameserver $DNS1
nameserver $DNS2
EOF
    resolvconf -u

    if systemctl is-active --quiet systemd-resolved; then
        echo -e "${YELLOW}禁用 systemd-resolved 对 /etc/resolv.conf 覆盖${NC}"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        rm -f /etc/resolv.conf
        touch /etc/resolv.conf
        echo "nameserver $DNS1" >> /etc/resolv.conf
        echo "nameserver $DNS2" >> /etc/resolv.conf
    fi
    echo -e "${GREEN}DNS 配置完成:${NC}"
    cat /etc/resolv.conf

    echo -e "${BLUE}=== 配置 Tayga NAT64 ===${NC}"
    cat << EOF > /etc/tayga.conf
ipv4-addr 192.168.255.1
prefix 64:ff9b::/96
dynamic-pool 192.168.255.0/24
data-dir /var/lib/tayga
EOF
    systemctl enable tayga
    systemctl restart tayga

    echo -e "${BLUE}=== 自动检测默认出口接口 ===${NC}"
    IFACE=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1)}}}')
    if [ -z "$IFACE" ]; then
        echo -e "${RED}无法检测默认 IPv6 接口，请手动设置${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到默认出口接口: $IFACE${NC}"

    echo -e "${BLUE}=== 配置 NAT64 路由和 IPv4 转发 ===${NC}"
    sysctl -w net.ipv4.ip_forward=1
    ip -6 route add 64:ff9b::/96 dev nat64
    iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o $IFACE -j MASQUERADE
    netfilter-persistent save

    echo -e "${BLUE}=== 创建开机自启脚本 ===${NC}"
    BOOT_SCRIPT="/usr/local/bin/nat64-dns-start.sh"
    cat << EOF > $BOOT_SCRIPT
#!/bin/bash
sysctl -w net.ipv4.ip_forward=1
ip -6 route add 64:ff9b::/96 dev nat64 || true
iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o $IFACE -j MASQUERADE || true
echo "nameserver $DNS1" > /etc/resolv.conf
echo "nameserver $DNS2" >> /etc/resolv.conf
EOF
    chmod +x $BOOT_SCRIPT

    cat << EOF > /etc/systemd/system/nat64-dns.service
[Unit]
Description=Startup NAT64 + IPv4 forwarding + DNS
After=network.target

[Service]
Type=oneshot
ExecStart=$BOOT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nat64-dns.service
    systemctl start nat64-dns.service
}

# ---------- 网络测试 ----------
network_test() {
    echo -e "${BLUE}=== 开始网络测试 ===${NC}"

    echo -n "测试 IPv6 网络: "
    if ping6 -c 3 google.com &>/dev/null; then
        echo -e "${GREEN}正常${NC}"
    else
        echo -e "${RED}异常${NC}"
    fi

    echo -n "测试 IPv4 网络 (通过 NAT64): "
    if ping6 -c 3 $NAT64_TEST &>/dev/null; then
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
    echo -n "IPv6: "
    curl -6 -s ifconfig.co || echo -e "${RED} 获取失败${NC}"
    echo ""
    echo -n "IPv4 (NAT64): "
    curl -4 -s ifconfig.co || echo -e "${RED} 获取失败${NC}"
    echo ""
    echo -e "${GREEN}=== 网络测试完成 ===${NC}"
}

# ---------- 主程序 ----------
case $MODE in
    install)
        install_nat64_dns
        echo -e "${GREEN}=== 安装完成 ===${NC}"
        ;;
    test)
        network_test
        ;;
    all|*)
        install_nat64_dns
        network_test
        echo -e "${GREEN}=== 安装与测试完成 ===${NC}"
        ;;
esac
