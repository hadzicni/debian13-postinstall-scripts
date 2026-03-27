#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Root check (shared)
# ============================================================
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# ============================================================
# Colors (TTY safe)
# ============================================================
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_MAGENTA="\033[35m"
  C_CYAN="\033[36m"
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# pretty printers
info()    { printf "${C_BLUE}==>${C_RESET} %s\n" "$*"; }
ok()      { printf "${C_GREEN}✔${C_RESET} %s\n" "$*"; }
warn()    { printf "${C_YELLOW}!${C_RESET} %s\n" "$*"; }
error()   { printf "${C_RED}✖ %s${C_RESET}\n" "$*"; }
section() { printf "\n${C_BOLD}${C_MAGENTA}=== %s ===${C_RESET}\n\n" "$*"; }

trap 'error "Script failed on line $LINENO"' ERR

# ============================================================
# Banner
# ============================================================
print_banner() {
  local host="$(hostname)"
  local date="$(date)"

  printf "${C_BOLD}${C_CYAN}"

  cat <<'EOF'
 _____     ______     ______     __     ______     __   __        ______   ______     ______     ______   __     __   __     ______     ______
/\  __-.  /\  ___\   /\  == \   /\ \   /\  __ \   /\ "-.\ \      /\  == \ /\  __ \   /\  ___\   /\__  _\ /\ \   /\ "-.\ \   /\  ___\   /\__  _\
\ \ \/\ \ \ \  __\   \ \  __<   \ \ \  \ \  __ \  \ \ \-.  \     \ \  _-/ \ \ \/\ \  \ \___  \  \/_/\ \/ \ \ \  \ \ \-.  \  \ \___  \  \/_/\ \/
 \ \____-  \ \_____\  \ \_____\  \ \_\  \ \_\ \_\  \ \_\\"\_\     \ \_\    \ \_____\  \/\_____\    \ \_\  \ \_\  \ \_\\"\_\  \/\_____\    \ \_\
  \/____/   \/_____/   \/_____/   \/_/   \/_/\/_/   \/_/ \/_/      \/_/     \/_____/   \/_____/     \/_/   \/_/   \/_/ \/_/   \/_____/     \/_/

        Debian 13 Server Setup
EOF

  printf "\n  Host: %s\n" "$host"
  printf "  Date: %s\n" "$date"
  printf "${C_RESET}\n\n"
}

# ============================================================
# HEADER
# ============================================================
[ -t 1 ] && printf "\033c"
print_banner

# ============================================================
# SECTION 1 — Debian 13 Post Install Network Setup
# ============================================================
section "Debian 13 Post Install Network Setup"
echo

# ---- Default auto-detection ----
DEFAULT_USER=$(logname 2>/dev/null || ls /home 2>/dev/null | head -n1 || echo "user")
DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
DEFAULT_IFACE=${DEFAULT_IFACE:-$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' | head -n1)}
DEFAULT_IFACE=${DEFAULT_IFACE:-eth0}
DEFAULT_IP="192.168.88.20/24"
DEFAULT_GW="192.168.88.1"
DEFAULT_DNS="192.168.88.1"
DEFAULT_FALLBACK="8.8.8.8"

[ "$DEFAULT_USER" = "user" ] && warn "No regular user detected"
[ -t 0 ] || { error "Script must be run interactively"; exit 1; }

# ---- Prompts with prefilled values ----
read -e -p "Enter username to add to sudo group: " -i "$DEFAULT_USER" USERNAME
ip -br link
read -e -p "Enter network interface name: " -i "$DEFAULT_IFACE" INTERFACE

ip link show "$INTERFACE" >/dev/null 2>&1 || { error "Interface not found"; exit 1; }

read -e -p "Enter static IP with CIDR: " -i "$DEFAULT_IP" IP
read -e -p "Enter gateway IP: " -i "$DEFAULT_GW" GATEWAY
read -e -p "Enter primary DNS server IP: " -i "$DEFAULT_DNS" DNS_SERVER
read -e -p "Enter fallback DNS server IP: " -i "$DEFAULT_FALLBACK" FALLBACK_DNS

echo
echo "Configuration summary:"
echo "User: $USERNAME"
echo "Interface: $INTERFACE"
echo "IP: $IP"
echo "Gateway: $GATEWAY"
echo "Primary DNS: $DNS_SERVER"
echo "Fallback DNS: $FALLBACK_DNS"
echo

read -e -p "Proceed? (yes/no): " -i "yes" CONFIRM
[ "$CONFIRM" != "yes" ] && { warn "Aborted."; exit 1; }

echo
section "Updating system"
apt update >/dev/null 2>&1 || { error "APT update failed"; exit 1; }
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y >/dev/null || { error "Upgrade failed"; exit 1; }
ok "System upgraded"

section "Installing required packages"
DEBIAN_FRONTEND=noninteractive apt install -y qemu-guest-agent sudo systemd-resolved systemd-timesyncd \
  >/dev/null 2>&1 || { error "Package installation failed"; exit 1; }
ok "Base packages installed"
section "Limiting journal size"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=2week
EOF

mkdir -p /var/log/journal
systemctl restart systemd-journald
journalctl --vacuum-size=200M >/dev/null 2>&1 || true
ok "journald limited"

systemctl enable --now qemu-guest-agent
ok "QEMU Guest Agent enabled"

section "Adding user to sudo group"
id "$USERNAME" >/dev/null 2>&1 || { error "User does not exist"; exit 1; }
usermod -aG sudo "$USERNAME"

section "Removing old network stacks"
DEBIAN_FRONTEND=noninteractive apt purge -y network-manager netplan.io ifupdown >/dev/null 2>&1 || true
rm -rf /etc/network 2>/dev/null || true
rm -rf /etc/netplan 2>/dev/null || true

section "Enabling systemd services"
systemctl enable --now systemd-networkd
systemctl enable --now systemd-resolved
systemctl enable --now systemd-timesyncd
section "Configuring locale and timezone"

# ensure locales package
DEBIAN_FRONTEND=noninteractive apt install -y locales >/dev/null 2>&1

# create locale.gen if missing
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || {
  echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
}

DEBIAN_FRONTEND=noninteractive locale-gen >/dev/null
update-locale LANG=en_US.UTF-8
ok "Locale set to en_US.UTF-8"

# timezone
timedatectl set-timezone Europe/Zurich
ok "Timezone set to Europe/Zurich"

systemctl disable networking --now 2>/dev/null || true
systemctl disable NetworkManager --now 2>/dev/null || true

section "Creating network configuration"
mkdir -p /etc/systemd/network

[ -f /etc/systemd/network/10-${INTERFACE}.network ] \
  && warn "Existing network configuration will be replaced"

cat > /etc/systemd/network/10-${INTERFACE}.network <<EOF
[Match]
Name=${INTERFACE}

[Network]
Address=${IP}
DNS=${DNS_SERVER}
DHCP=no
IPv6AcceptRA=no

[Route]
Destination=0.0.0.0/0
Gateway=${GATEWAY}
EOF

section "Configuring systemd-resolved (Fallback DNS)"
cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=${DNS_SERVER}
FallbackDNS=${FALLBACK_DNS}
DNSSEC=no
DNSOverTLS=no
Cache=yes
EOF

section "Applying network"

networkctl reload
systemctl restart systemd-networkd

systemctl restart systemd-resolved
resolvectl flush-caches || true

for i in {1..50}; do
  [ -e /run/systemd/resolve/stub-resolv.conf ] && break
  sleep 0.2
done

[ -e /run/systemd/resolve/stub-resolv.conf ] \
  || { error "systemd-resolved stub not created"; exit 1; }

rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

ok "network applied"

echo
section "Network Setup Complete"
echo

# ============================================================
# SECTION 2 — Fastfetch Installation
# ============================================================

FF_VERSION="2.58.0"
BASE_URL="https://github.com/fastfetch-cli/fastfetch/releases/download/${FF_VERSION}"

section "Installing fastfetch ${FF_VERSION}"

# Dependencies
apt update >/dev/null 2>&1 || { error "APT update failed"; exit 1; }
DEBIAN_FRONTEND=noninteractive apt install -y curl ca-certificates >/dev/null 2>&1 || { error "Dependency install failed"; exit 1; }
ok "APT repositories updated"

# Architecture mapping
arch=$(dpkg --print-architecture)

case "$arch" in
  amd64) pkg="fastfetch-linux-amd64.deb" ;;
  arm64) pkg="fastfetch-linux-aarch64.deb" ;;
  *)
    echo "Unsupported architecture: $arch"
    exit 1
  ;;
esac

url="${BASE_URL}/${pkg}"
tmpdeb="/tmp/${pkg}"

echo "Downloading: $url"
curl -L --fail --retry 3 --connect-timeout 10 "$url" -o "$tmpdeb" \
  || { error "Download failed"; exit 1; }

# Install
DEBIAN_FRONTEND=noninteractive apt install -y "$tmpdeb" >/dev/null 2>&1 || { error "Fastfetch install failed"; exit 1; }
ok "Fastfetch installed"
rm -f "$tmpdeb"

# Show on login
cat > /etc/profile.d/fastfetch.sh <<'EOF'
case $- in
  *i*) ;;
  *) return;;
esac

[ -t 1 ] || return
[ "$EUID" -ge 1000 ] || return

command -v fastfetch >/dev/null && fastfetch 2>/dev/null || true
EOF

chmod +x /etc/profile.d/fastfetch.sh

echo
ok "Fastfetch ${FF_VERSION} installed"
info "Reconnect SSH to see it"

echo
section "All Tasks Completed"
warn "Reboot recommended"
