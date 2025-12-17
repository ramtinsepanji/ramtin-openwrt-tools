#!/bin/sh
set -eu

log() { echo "=== [install_passwall2_iran] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --------- Detect OpenWrt release tag (major.minor) ----------
REL_TAG="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-}")"
[ -n "${REL_TAG:-}" ] || REL_TAG="$(cat /etc/openwrt_version 2>/dev/null | head -n1 || true)"
REL_TAG="$(echo "${REL_TAG:-}" | awk -F. 'NF>=2{print $1"."$2}')"
[ -n "${REL_TAG:-}" ] || REL_TAG="24.10"

# --------- Detect correct arch for Passwall feed ----------
detect_arch_from_opkg() {
  # Pick highest-priority arch excluding all/noarch
  opkg print-architecture 2>/dev/null \
  | awk '$2!="all" && $2!="noarch"{print $2, $3}' \
  | sort -k2,2nr 2>/dev/null \
  | head -n1 \
  | awk '{print $1}'
}

detect_arch_from_distfeeds() {
  # Extract arch from official feed URLs: .../packages/<ARCH>/base
  for f in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf; do
    [ -f "$f" ] || continue
    awk '
      match($0, /\/packages\/([^\/]+)\/(base|luci|packages|routing|telephony)\//, a) {
        print a[1]; exit
      }
    ' "$f" 2>/dev/null && return 0
  done
  return 1
}

OPKG_ARCH="$(detect_arch_from_opkg || true)"
if [ -z "${OPKG_ARCH:-}" ]; then
  OPKG_ARCH="$(detect_arch_from_distfeeds || true)"
fi
# last resort (not great, but better than empty)
[ -n "${OPKG_ARCH:-}" ] || OPKG_ARCH="$(uname -m)"

log "Detected release tag: $REL_TAG"
log "Detected opkg arch:   $OPKG_ARCH"

# Hard guard: never allow all/noarch
case "$OPKG_ARCH" in
  all|noarch) die "Arch detection returned '$OPKG_ARCH' (invalid for Passwall feed). Run: opkg print-architecture" ;;
esac

# --------- Ensure basic commands ----------
command -v opkg >/dev/null 2>&1 || die "opkg not found."
command -v wget >/dev/null 2>&1 || die "wget not found."
command -v uci  >/dev/null 2>&1 || die "uci not found."

# --------- Rewrite Passwall feeds (ARCH-CORRECT) ----------
PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL_TAG}/${OPKG_ARCH}"
PASSWALL_FEED1="src/gz passwall2 ${PASSWALL_BASE}/passwall2"
PASSWALL_FEED2="src/gz passwall_packages ${PASSWALL_BASE}/passwall_packages"

log "Rewriting Passwall feeds (arch-correct)"
mkdir -p /etc/opkg
touch /etc/opkg/customfeeds.conf
sed -i \
  '/^[[:space:]]*src\/gz[[:space:]]\+passwall2[[:space:]]/d;
   /^[[:space:]]*src\/gz[[:space:]]\+passwall_packages[[:space:]]/d' \
  /etc/opkg/customfeeds.conf 2>/dev/null || true
{
  echo "$PASSWALL_FEED1"
  echo "$PASSWALL_FEED2"
} >> /etc/opkg/customfeeds.conf

# --------- opkg update (do NOT fail the whole run if one feed transiently fails) ----------
log "opkg update"
opkg update || true

# Verify passwall lists actually downloaded (otherwise stop with a clear error)
if ! ls /var/opkg-lists/passwall2 >/dev/null 2>&1; then
  die "Passwall2 feed list not present. Likely wrong arch or blocked SourceForge. Arch=$OPKG_ARCH"
fi

# --------- Helpers ----------
is_installed() { opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed'; }
must_install() {
  PKG="$1"
  if is_installed "$PKG"; then
    log "OK: $PKG already installed"
    return 0
  fi
  log "Installing: $PKG"
  opkg install "$PKG" >/dev/null || die "Cannot install required package: $PKG"
}

optional_install() {
  PKG="$1"
  if is_installed "$PKG"; then
    log "OK: $PKG already installed"
    return 0
  fi
  log "Installing (optional): $PKG"
  opkg install "$PKG" >/dev/null || log "WARNING: optional package failed: $PKG (skipped)"
}

# --------- Core deps (minimal) ----------
log "Core deps"
must_install wget-ssl
must_install curl
must_install dnsmasq-full
optional_install kmod-nft-socket
optional_install kmod-nft-tproxy

# --------- Passwall2 + required deps ----------
log "Passwall2 + required deps"
must_install tcping
must_install geoview
must_install xray-core
must_install luci-app-passwall2

# --------- Passwall2 defaults + Iran shunt (create section from scratch) ----------
log "Configuring Passwall2 + IRAN shunt"
[ -f /etc/config/passwall2 ] || touch /etc/config/passwall2

# ensure global exists
uci -q get passwall2.@global[0] >/dev/null 2>&1 || uci add passwall2 global >/dev/null

# user preference: 8.8.8.8 remote dns
uci -q set passwall2.@global[0].remote_dns_protocol='tcp' || true
uci -q set passwall2.@global[0].remote_dns='8.8.8.8' || true
uci -q set passwall2.@global[0].remote_dns_query_strategy='UseIPv4' || true
uci -q set passwall2.@global[0].china='IRAN' || true

# disable ipv6 tproxy if section exists
uci -q set passwall2.@global_forwarding[0].ipv6_tproxy='0' || true

# Rebuild IRAN section every time (prevents "Entry not found" and old garbage)
uci -q delete passwall2.IRAN

uci set passwall2.IRAN='shunt_rules'
uci set passwall2.IRAN.remarks='IRAN'
uci set passwall2.IRAN.network='tcp,udp'

# This is the combo you said works reliably
uci set passwall2.IRAN.domain_list='geosite:category-ir
ext:iran.dat:ir
ext:iran.dat:other'

uci set passwall2.IRAN.ip_list='geoip:ir
geoip:private'

uci commit passwall2

# enable/restart service
[ -x /etc/init.d/passwall2 ] && /etc/init.d/passwall2 enable >/dev/null 2>&1 || true
[ -x /etc/init.d/passwall2 ] && /etc/init.d/passwall2 restart >/dev/null 2>&1 || true

log "DONE."
log "Sanity checks:"
echo "  opkg print-architecture"
echo "  uci show passwall2.IRAN"
echo "  ls -l /var/opkg-lists | grep passwall"
exit 0
