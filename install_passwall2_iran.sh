#!/bin/sh
set -eu

echo "=== [Passwall2 Iran Installer] Starting ==="

need_cmd() { command -v "$1" >/dev/null 2>&1; }

FETCH=""
if need_cmd wget; then
  FETCH="wget -qO-"
elif need_cmd uclient-fetch; then
  FETCH="uclient-fetch -qO-"
elif need_cmd curl; then
  FETCH="curl -fsSL"
else
  echo "ERROR: need wget/uclient-fetch/curl"
  exit 1
fi

# --- Detect OpenWrt release (major.minor) ---
REL_FULL="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-}")"
if [ -z "${REL_FULL}" ]; then
  echo "ERROR: cannot detect OpenWrt version"
  exit 1
fi
REL_MM="$(echo "$REL_FULL" | awk -F. '{print $1"."$2}')"

# --- Detect best opkg architecture (highest priority, excluding all/noarch) ---
ARCH="$(opkg print-architecture 2>/dev/null | awk '
  $1=="arch" && $2!="all" && $2!="noarch" {
    pr=$3+0;
    if (pr>max) { max=pr; arch=$2 }
  }
  END { print arch }
')"
if [ -z "${ARCH}" ]; then
  echo "ERROR: cannot detect opkg architecture"
  exit 1
fi

TARGET="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_TARGET:-unknown}")"
echo "Detected OpenWrt: ${REL_FULL} (tag ${REL_MM})"
echo "Target: ${TARGET}"
echo "OPKG Arch: ${ARCH}"

PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL_MM}/${ARCH}"
FEED1="src/gz passwall_packages ${PASSWALL_BASE}/passwall_packages"
FEED2="src/gz passwall2 ${PASSWALL_BASE}/passwall2"

echo
echo "=== Ensuring Passwall feeds exist (arch-correct) ==="
mkdir -p /etc/opkg
touch /etc/opkg/customfeeds.conf

# Replace existing passwall lines to avoid mixed-arch feed pollution
grep -vE '^(src/gz[[:space:]]+passwall_packages[[:space:]]|src/gz[[:space:]]+passwall2[[:space:]])' \
  /etc/opkg/customfeeds.conf > /tmp/customfeeds.conf.new || true
{
  echo "$FEED1"
  echo "$FEED2"
} >> /tmp/customfeeds.conf.new
mv /tmp/customfeeds.conf.new /etc/opkg/customfeeds.conf

echo "Feeds set to:"
echo "  $FEED1"
echo "  $FEED2"

echo
echo "=== Installing Passwall opkg key (passwall.pub) ==="
# SourceForge root contains passwall.pub
# https://sourceforge.net/projects/openwrt-passwall-build/files/  (file: passwall.pub)
KEY_TMP="/tmp/passwall.pub"
$FETCH "https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub" > "$KEY_TMP" || {
  echo "ERROR: failed to download passwall.pub"
  exit 1
}
opkg-key add "$KEY_TMP" >/dev/null 2>&1 || true
rm -f "$KEY_TMP" || true
echo "Key added (or already present)."

echo
echo "=== opkg update ==="
opkg update

echo
echo "=== Installing required packages (no system-wide upgrade) ==="
# Minimal set for Passwall2 + Xray + rule engine deps
# dnsmasq-full recommended for DNS redirect setups
opkg install \
  dnsmasq-full \
  luci-app-passwall2 \
  xray-core \
  geoview \
  tcping \
  ca-bundle ca-certificates

echo
echo "=== Basic Passwall2 defaults (safe) ==="
# Ensure global section exists
if ! uci -q get passwall2.@global[0] >/dev/null 2>&1; then
  uci add passwall2 global >/dev/null
fi

uci -q batch <<'UCI'
set passwall2.@global[0].enabled='0'
set passwall2.@global[0].localhost_proxy='1'
set passwall2.@global[0].client_proxy='1'
set passwall2.@global[0].node_socks_port='1070'

# DNS: use 8.8.8.8 over TCP (per your preference)
set passwall2.@global[0].remote_dns_protocol='tcp'
set passwall2.@global[0].remote_dns='8.8.8.8'
set passwall2.@global[0].remote_dns_query_strategy='UseIPv4'
set passwall2.@global[0].direct_dns_protocol='auto'
set passwall2.@global[0].direct_dns_query_strategy='UseIP'

# Redirect DNS
set passwall2.@global[0].dns_redirect='1'

# Use nft
set passwall2.@global_forwarding[0].use_nft='1'
set passwall2.@global_forwarding[0].tcp_proxy_way='redirect'
set passwall2.@global_forwarding[0].ipv6_tproxy='0'

# Assets
set passwall2.@global_rules[0].geosite_update='1'
set passwall2.@global_rules[0].geoip_update='1'
set passwall2.@global_rules[0].v2ray_location_asset='/usr/share/v2ray/'
set passwall2.@global_rules[0].enable_geoview='1'
commit passwall2
UCI

echo
echo "=== Configuring IRAN shunt rule (tested combination) ==="
# Create/update the IRAN shunt_rules section
uci -q batch <<'UCI'
set passwall2.IRAN=shunt_rules
set passwall2.IRAN.remarks='IRAN'
set passwall2.IRAN.network='tcp,udp'
set passwall2.IRAN.domain_list='geosite:category-ir
ext:iran.dat:ir
ext:iran.dat:other'
set passwall2.IRAN.ip_list='geoip:ir
geoip:private'

# Tell Passwall2 which "country group" is treated as local
set passwall2.@global[0].china='IRAN'
commit passwall2
UCI

echo
echo "=== Restarting Passwall2 (still disabled globally) ==="
/etc/init.d/passwall2 restart >/dev/null 2>&1 || true

echo
echo "=== Verification ==="
opkg list-installed | grep -E 'luci-app-passwall2|xray-core|geoview|tcping|dnsmasq-full' || true
echo "UCI IRAN rule:"
uci show passwall2.IRAN || true

echo
echo "DONE. Now go to LuCI > Services > Passwall2 and set your nodes/ACL, then enable."
