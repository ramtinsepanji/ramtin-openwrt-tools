#!/bin/sh
set -eu

log() { echo "=== [passwall2-iran] $*"; }
die() { echo ">>> [passwall2-iran] ERROR: $*" >&2; exit 1; }

### 1. Detect OpenWrt release
REL="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-24.10}")"
REL="${REL%.*}"
log "OpenWrt release: $REL"

### 2. Detect best architecture
ARCH="$(opkg print-architecture | awk '
  $1=="arch" && $2!="all" && $2!="noarch" { if ($3>p) {p=$3; a=$2} }
  END{print a}'
)"
[ -n "$ARCH" ] || die "Cannot detect opkg architecture"
log "Architecture: $ARCH"

### 3. Base URLs (official passwall build repo)
BASE="https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL}/${ARCH}"
PW2_IPK_URL="$(wget -qO- "$BASE/passwall2/Packages.gz" | gunzip 2>/dev/null | awk '/^Package: luci-app-passwall2/{f=1} f&&/^Filename:/{print $2;exit}')"
XRAY_IPK_URL="$(wget -qO- "$BASE/passwall_packages/Packages.gz" | gunzip 2>/dev/null | awk '/^Package: xray-core/{f=1} f&&/^Filename:/{print $2;exit}')"

[ -n "$PW2_IPK_URL" ] || die "luci-app-passwall2 not found in official repo"
[ -n "$XRAY_IPK_URL" ] || die "xray-core not found in official repo"

### 4. Ensure dnsmasq-full (mandatory)
log "Ensuring dnsmasq-full"
if opkg status dnsmasq-full >/dev/null 2>&1; then
  log "dnsmasq-full already installed"
else
  if opkg status dnsmasq >/dev/null 2>&1; then
    log "Removing dnsmasq"
    opkg remove dnsmasq || die "Failed to remove dnsmasq"
  fi
  opkg update
  opkg install dnsmasq-full || die "Failed to install dnsmasq-full"
  /etc/init.d/dnsmasq restart || true
fi

### 5. Core tools
for p in wget-ssl curl ca-bundle; do
  opkg status "$p" >/dev/null 2>&1 || opkg install "$p" || die "Failed to install $p"
done

### 6. Download & install Passwall2 + Xray (direct IPK)
TMP="/tmp/passwall2-install"
mkdir -p "$TMP"
cd "$TMP"

log "Downloading luci-app-passwall2"
wget -O pw2.ipk "$BASE/$PW2_IPK_URL" || die "Download failed (passwall2)"

log "Downloading xray-core"
wget -O xray.ipk "$BASE/$XRAY_IPK_URL" || die "Download failed (xray-core)"

log "Installing IPKs"
opkg install pw2.ipk xray.ipk || die "IPK installation failed"

### 7. Iran Shunt Rules (tested & working)
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

### 8. Finish
log "Installation completed successfully"
log "Go to Passwall2 → Shunt → select profile: IRAN"
