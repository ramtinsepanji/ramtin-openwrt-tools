#!/bin/sh
set -eu

log() { echo "=== [passwall2-iran] $*"; }
die() { echo ">>> [passwall2-iran] ERROR: $*" >&2; exit 1; }

# --------------------------------------------------
# Sanity check
# --------------------------------------------------
[ -f /etc/openwrt_release ] || die "This script is for OpenWrt only"

# --------------------------------------------------
# Detect OpenWrt release (24.10 / 23.05 / ...)
# --------------------------------------------------
. /etc/openwrt_release
RELEASE="${DISTRIB_RELEASE%.*}"
[ -n "$RELEASE" ] || die "Cannot detect OpenWrt release"

# --------------------------------------------------
# Detect best opkg architecture (real, not guessed)
# --------------------------------------------------
ARCH="$(opkg print-architecture | awk '
  $1=="arch" && $2!="all" && $2!="noarch" {
    if ($3>p) {p=$3; a=$2}
  }
  END{print a}
')"
[ -n "$ARCH" ] || die "Cannot detect opkg architecture"

log "Detected OpenWrt release: $RELEASE"
log "Detected architecture:    $ARCH"

# --------------------------------------------------
# Base tools
# --------------------------------------------------
opkg install wget-ssl ca-bundle >/dev/null 2>&1 || true

# --------------------------------------------------
# dnsmasq-full (mandatory)
# --------------------------------------------------
if ! opkg status dnsmasq-full 2>/dev/null | grep -q installed; then
  if opkg status dnsmasq 2>/dev/null | grep -q installed; then
    log "Removing dnsmasq"
    opkg remove dnsmasq || die "Failed to remove dnsmasq"
  fi
  log "Installing dnsmasq-full"
  opkg install dnsmasq-full || die "Failed to install dnsmasq-full"
else
  log "dnsmasq-full already installed"
fi

# --------------------------------------------------
# Kernel deps for Passwall
# --------------------------------------------------
log "Ensuring kernel dependencies"
opkg install kmod-nft-tproxy kmod-nft-socket >/dev/null 2>&1 || \
  die "Failed to install kernel dependencies"

# --------------------------------------------------
# Add official Passwall GPG key (once)
# --------------------------------------------------
if ! opkg-key list | grep -qi passwall; then
  log "Adding Passwall GPG key"
  wget -O /tmp/passwall.pub \
    https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub || \
    wget -O /tmp/passwall.pub \
    https://downloads.sourceforge.net/project/openwrt-passwall-build/passwall.pub || \
    die "Cannot download passwall.pub"
  opkg-key add /tmp/passwall.pub || die "Failed to add passwall key"
else
  log "Passwall GPG key already present"
fi

# --------------------------------------------------
# Configure Passwall feeds (clean & idempotent)
# --------------------------------------------------
FEED_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$RELEASE/$ARCH"
CUSTOM="/etc/opkg/customfeeds.conf"
touch "$CUSTOM"

ensure_feed() {
  name="$1"
  url="$2"
  if grep -qE "^src/gz $name " "$CUSTOM"; then
    sed -i -E "s|^src/gz $name .*|src/gz $name $url|" "$CUSTOM"
  else
    echo "src/gz $name $url" >> "$CUSTOM"
  fi
}

log "Configuring Passwall feeds"
ensure_feed passwall_packages "$FEED_BASE/passwall_packages"
ensure_feed passwall2         "$FEED_BASE/passwall2"

# --------------------------------------------------
# Update once
# --------------------------------------------------
log "opkg update"
opkg update || die "opkg update failed"

# --------------------------------------------------
# Install Passwall2 stack
# --------------------------------------------------
log "Installing Passwall2"
opkg install luci-app-passwall2 xray-core v2ray-geosite-ir tcping geoview || \
  die "Failed to install Passwall2 packages"

# --------------------------------------------------
# Configure IRAN shunt rule (SAFE, via UCI)
# --------------------------------------------------
log "Configuring IRAN shunt rule"

# Ensure global exists
uci -q show passwall2.@global[0] >/dev/null 2>&1 || \
  uci add passwall2 global >/dev/null

uci -q set passwall2.@global[0].china='IRAN'

# Find or create IRAN rule
IRAN_SEC="$(uci show passwall2 | awk -F'[.=]' '
  /=shunt_rules/ {sec=$2}
  /remarks=.IRAN./ {print $2; found=1; exit}
  END{if(!found)print ""}
')"

if [ -z "$IRAN_SEC" ]; then
  uci add passwall2 shunt_rules >/dev/null
  IRAN_SEC="$(uci show passwall2 | awk -F'[.=]' '/=shunt_rules$/ {s=$2} END{print s}')"
fi

# EXACT rules you requested
uci -q set passwall2.$IRAN_SEC.remarks='IRAN'
uci -q set passwall2.$IRAN_SEC.network='tcp,udp'
uci -q set passwall2.$IRAN_SEC.domain_list='geosite:category-ir,ext:iran.dat:ir,ext:iran.dat:other'
uci -q set passwall2.$IRAN_SEC.ip_list='geoip:ir,geoip:private'

uci commit passwall2

log "DONE"
log "LuCI → Passwall2 → Shunt / China list → select IRAN"
