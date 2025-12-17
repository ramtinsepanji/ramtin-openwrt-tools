#!/bin/sh
set -u

log() { echo "=== [install_passwall2_iran] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --------- Detect OpenWrt release tag (major.minor) ----------
REL_TAG="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-}")"
[ -n "$REL_TAG" ] || REL_TAG="$(cat /etc/openwrt_version 2>/dev/null | head -n1)"
REL_TAG="$(echo "$REL_TAG" | awk -F. '{print $1"."$2}')"
[ -n "$REL_TAG" ] || REL_TAG="24.10"

# --------- Detect opkg primary arch (NOT "all") ----------
OPKG_ARCH="$(opkg print-architecture 2>/dev/null | awk '$2!="all"{print $2; exit}')"
[ -n "$OPKG_ARCH" ] || OPKG_ARCH="$(uname -m)"
log "Detected release tag: $REL_TAG"
log "Detected opkg arch:   $OPKG_ARCH"

# --------- Ensure network is up (basic sanity) ----------
command -v wget >/dev/null 2>&1 || die "wget not found (install base wget-ssl first)."
command -v opkg >/dev/null 2>&1 || die "opkg not found."

# --------- Add/Rewrite Passwall feeds (ARCH-CORRECT) ----------
PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$REL_TAG/$OPKG_ARCH"
PASSWALL_FEED1="src/gz passwall2 ${PASSWALL_BASE}/passwall2"
PASSWALL_FEED2="src/gz passwall_packages ${PASSWALL_BASE}/passwall_packages"

log "Rewriting Passwall feeds (prevents wrong-arch downloads)"
# remove older passwall lines (if any), then append cleanly
sed -i '/^[[:space:]]*src\/gz[[:space:]]\+passwall2[[:space:]]/d;/^[[:space:]]*src\/gz[[:space:]]\+passwall_packages[[:space:]]/d' /etc/opkg/customfeeds.conf 2>/dev/null || true
{
  echo "$PASSWALL_FEED1"
  echo "$PASSWALL_FEED2"
} >> /etc/opkg/customfeeds.conf

# --------- Ensure Passwall key (best-effort; script continues if key already exists) ----------
log "Ensuring Passwall GPG key"
if [ ! -f /etc/opkg/keys/*passwall* ] 2>/dev/null; then
  # Passwall build feeds usually ship signatures; in case key package exists, install it
  opkg update >/dev/null 2>&1 || true
fi

# --------- opkg update ----------
log "opkg update"
opkg update || die "opkg update failed (check DNS/Internet)."

# --------- Helpers ----------
is_installed() { opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed'; }
install_pkg() {
  PKG="$1"
  if is_installed "$PKG"; then
    log "OK: $PKG already installed"
    return 0
  fi
  log "Installing: $PKG"
  opkg install "$PKG" || return 1
  return 0
}

must_install() {
  PKG="$1"
  install_pkg "$PKG" || die "Cannot install required package: $PKG"
}

optional_install() {
  PKG="$1"
  install_pkg "$PKG" || log "WARNING: optional package failed to install: $PKG (skipped)"
}

# --------- Core deps (minimal, stable) ----------
log "Core deps"
# dnsmasq-full (recommended for Passwall DNS features; do not auto-remove other dnsmasq variants here)
must_install dnsmasq-full
must_install wget-ssl
must_install curl
# nft tproxy deps (safe even if you use redirect mode)
optional_install kmod-nft-socket
optional_install kmod-nft-tproxy

# --------- Passwall2 + minimal runtime ----------
log "Passwall2 + required deps"
# These two are dependencies for luci-app-passwall2 in your environment
must_install tcping
must_install geoview

# Xray + Passwall2 UI
must_install xray-core
must_install luci-app-passwall2

# --------- Configure Passwall2 defaults (safe / idempotent) ----------
log "Configuring Passwall2 defaults"
# ensure config file exists
[ -f /etc/config/passwall2 ] || touch /etc/config/passwall2

# Make sure global section exists; create if missing
if ! uci -q get passwall2.@global[0] >/dev/null 2>&1; then
  uci add passwall2 global >/dev/null
fi

# Your preferences: remote DNS = 8.8.8.8, TCP, IPv4
uci -q set passwall2.@global[0].remote_dns_protocol='tcp' || true
uci -q set passwall2.@global[0].remote_dns='8.8.8.8' || true
uci -q set passwall2.@global[0].remote_dns_query_strategy='UseIPv4' || true
uci -q set passwall2.@global[0].direct_dns_protocol='auto' || true
uci -q set passwall2.@global[0].direct_dns_query_strategy='UseIP' || true

# Keep IPv6 tproxy off (you wanted IPv6 disabled)
uci -q set passwall2.@global_forwarding[0].ipv6_tproxy='0' || true

# Set shunt selector label (Passwall uses "china" field historically)
uci -q set passwall2.@global[0].china='Iran' || true

# --------- Iran shunt rules (ALWAYS build from scratch, avoids "Entry not found") ----------
log "Iran shunt rules (domain/ip)"
uci -q delete passwall2.IRAN

uci set passwall2.IRAN='shunt_rules'
uci set passwall2.IRAN.remarks='IRAN'
uci set passwall2.IRAN.network='tcp,udp'

# Domain list (the combination that you confirmed works)
uci set passwall2.IRAN.domain_list='geosite:category-ir
ext:iran.dat:ir
ext:iran.dat:other'

# IP list
uci set passwall2.IRAN.ip_list='geoip:ir
geoip:private'

uci commit passwall2

# Enable service autostart (optional but usually desired after factory reset)
if [ -x /etc/init.d/passwall2 ]; then
  /etc/init.d/passwall2 enable >/dev/null 2>&1 || true
  /etc/init.d/passwall2 restart >/dev/null 2>&1 || true
fi

log "DONE."
log "Verify:"
echo "  uci show passwall2.IRAN"
echo "  uci -q get passwall2.@global[0].remote_dns"
echo "  opkg list-installed | grep -E 'luci-app-passwall2|xray-core|tcping|geoview|dnsmasq-full'"
exit 0
