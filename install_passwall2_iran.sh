#!/bin/sh
set -e

log(){ echo "=== [passwall2-iran] $*"; }
die(){ echo ">>> ERROR: $*" >&2; exit 1; }

REL="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-24.10}")"
REL="${REL%.*}"
ARCH="$(opkg print-architecture | awk '$1=="arch" && $2!="all" && $2!="noarch"{print $2}' | head -n1)"

[ -n "$ARCH" ] || die "Cannot detect architecture"

BASE="https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL}/${ARCH}"

ensure_pkg() {
  PKG="$1"
  opkg status "$PKG" 2>/dev/null | grep -q installed || opkg install "$PKG"
}

ensure_pkg wget-ssl
ensure_pkg ca-bundle
ensure_pkg gzip

zcat_() {
  gunzip -c 2>/dev/null || gzip -dc
}

get_ipk() {
  FEED="$1"
  NAME="$2"
  URL="$BASE/$FEED/Packages.gz"

  wget -qO- "$URL" | zcat_ | awk -v P="$NAME" '
    $1=="Package:" && $2==P {f=1}
    f && $1=="Filename:" {print $2; exit}
  '
}

fix_path() {
  case "$1" in
    */*) echo "$1" ;;
    *)   echo "$2/$1" ;;
  esac
}

log "Ensuring dnsmasq-full"
if ! opkg status dnsmasq-full >/dev/null 2>&1; then
  opkg status dnsmasq >/dev/null 2>&1 && opkg remove dnsmasq
  opkg install dnsmasq-full
fi

PW_FN="$(get_ipk passwall2 luci-app-passwall2)"
XR_FN="$(get_ipk passwall_packages xray-core)"

[ -n "$PW_FN" ] || die "Passwall2 not found in repo"
[ -n "$XR_FN" ] || die "xray-core not found in repo"

PW_PATH="$(fix_path "$PW_FN" passwall2)"
XR_PATH="$(fix_path "$XR_FN" passwall_packages)"

TMP="/tmp/passwall.$$"
mkdir -p "$TMP"
cd "$TMP"

log "Downloading Passwall2"
wget -O pw.ipk "$BASE/$PW_PATH" || die "Download failed (passwall2)"

log "Downloading xray-core"
wget -O xr.ipk "$BASE/$XR_PATH" || die "Download failed (xray-core)"

log "Installing packages"
opkg install pw.ipk xr.ipk || die "Install failed"

log "Configuring IRAN shunt"
uci -q batch <<'EOF'
set passwall2.@global[0].china='Iran'
delete passwall2.IRAN
add passwall2 shunt_rules
rename passwall2.@shunt_rules[-1]='IRAN'
set passwall2.IRAN.remarks='IRAN'
set passwall2.IRAN.network='tcp,udp'
set passwall2.IRAN.domain_list='geosite:category-ir,ext:iran.dat:ir,ext:iran.dat:other'
set passwall2.IRAN.ip_list='geoip:ir,geoip:private'
commit passwall2
EOF

log "DONE"
