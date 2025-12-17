#!/bin/sh
set -eu

log(){ echo "=== [passwall2-iran] $*"; }
die(){ echo ">>> [passwall2-iran] ERROR: $*" >&2; exit 1; }

REL="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-24.10}")"
REL="${REL%.*}"
log "OpenWrt release: $REL"

ARCH="$(opkg print-architecture 2>/dev/null | awk '
  $1=="arch" && $2!="all" && $2!="noarch" { if ($3>p) {p=$3; a=$2} }
  END{print a}'
)"
[ -n "$ARCH" ] || die "Cannot detect opkg architecture"
log "Architecture: $ARCH"

# Tools needed for reading Packages.gz
opkg status wget-ssl >/dev/null 2>&1 || opkg update && opkg install wget-ssl >/dev/null 2>&1 || true
opkg status ca-bundle >/dev/null 2>&1 || opkg install ca-bundle >/dev/null 2>&1 || true

# Ensure we can decompress .gz (prefer busybox gunzip, otherwise install gzip)
if ! (command -v gunzip >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1); then
  opkg update >/dev/null 2>&1 || true
  opkg install gzip >/dev/null 2>&1 || die "Need gzip/gunzip to read Packages.gz"
fi

zcat_compat() {
  if command -v gunzip >/dev/null 2>&1; then gunzip -c
  else gzip -dc
  fi
}

REPO_ROOT="https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL}/${ARCH}"

get_filename() {
  FEED="$1"   # passwall2 OR passwall_packages
  PKG="$2"    # package name
  URL="$REPO_ROOT/$FEED/Packages.gz"

  RAW="$(wget -qO- "$URL" || true)"
  [ -n "$RAW" ] || die "Cannot download $URL (repo/mirror issue)"
  printf "%s" "$RAW" | zcat_compat 2>/dev/null | awk -v P="$PKG" '
    $1=="Package:" && $2==P {f=1; next}
    f && $1=="Filename:" {print $2; exit}
  '
}

fix_path() {
  FEED="$1"
  FN="$2"
  case "$FN" in
    */*) echo "$FN" ;;                 # already has path
    *)  echo "$FEED/$FN" ;;            # add feed folder
  esac
}

log "Ensuring dnsmasq-full (mandatory)"
if opkg status dnsmasq-full >/dev/null 2>&1; then
  log "dnsmasq-full already installed"
else
  if opkg status dnsmasq >/dev/null 2>&1; then
    log "Removing dnsmasq -> installing dnsmasq-full"
    opkg remove dnsmasq || die "Failed to remove dnsmasq"
  fi
  opkg update
  opkg install dnsmasq-full || die "Failed to install dnsmasq-full"
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

log "Resolving package filenames from Packages.gz"
PW2_FN="$(get_filename passwall2 luci-app-passwall2)"
XRAY_FN="$(get_filename passwall_packages xray-core)"

[ -n "$PW2_FN" ] || die "luci-app-passwall2 not found for arch=$ARCH"
[ -n "$XRAY_FN" ] || die "xray-core not found for arch=$ARCH"

PW2_PATH="$(fix_path passwall2 "$PW2_FN")"
XRAY_PATH="$(fix_path passwall_packages "$XRAY_FN")"

PW2_URL="$REPO_ROOT/$PW2_PATH"
XRAY_URL="$REPO_ROOT/$XRAY_PATH"

TMP="/tmp/pw2-iran.$$"
mkdir -p "$TMP"
cd "$TMP"

log "Downloading luci-app-passwall2: $PW2_URL"
wget -O pw2.ipk "$PW2_URL" || die "Download failed (passwall2)"

log "Downloading xray-core: $XRAY_URL"
wget -O xray.ipk "$XRAY_URL" || die "Download failed (xray-core)"

log "Installing IPKs"
opkg install pw2.ipk xray.ipk || die "IPK installation failed"

log "Configuring Iran shunt rules"
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

log "Done"
