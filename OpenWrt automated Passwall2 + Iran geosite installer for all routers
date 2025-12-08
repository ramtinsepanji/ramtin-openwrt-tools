#!/bin/sh
# ramtinsepanji / ramtin-openwrt-tools
# Universal Passwall2 + Iran Geo installer for OpenWrt

set -e

echo "=== [Passwall2 Iran Installer] Starting ==="

# --- Basic sanity checks ---
if [ "$(id -u)" != "0" ]; then
  echo "ERROR: This script must be run as root (uid=0)." >&2
  exit 1
fi

if [ ! -f /etc/openwrt_release ]; then
  echo "ERROR: This system does not look like OpenWrt." >&2
  exit 1
fi

. /etc/openwrt_release

release_short="${DISTRIB_RELEASE%.*}"
[ -z "$release_short" ] && release_short="$DISTRIB_RELEASE"
arch="$DISTRIB_ARCH"

echo "Detected OpenWrt: $DISTRIB_ID $DISTRIB_RELEASE ($DISTRIB_DESCRIPTION)"
echo "Target: ${DISTRIB_TARGET:-unknown}, Arch: $arch"
echo "Using release tag: $release_short"
echo

# --- Ensure customfeeds exists ---
FEEDS="/etc/opkg/customfeeds.conf"
if [ ! -f "$FEEDS" ]; then
  touch "$FEEDS"
fi

# --- Add Passwall feeds if missing ---
echo "=== Adding Passwall feeds if missing ==="
if ! grep -q "passwall2" "$FEEDS"; then
  cat >> "$FEEDS" << EOT
src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$release_short/$arch/passwall_packages
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$release_short/$arch/passwall2
EOT
  echo "Passwall feeds added to $FEEDS"
else
  echo "Passwall feeds already present in $FEEDS"
fi

echo
echo "=== Running opkg update (errors from some feeds are possible) ==="
set +e
opkg update
OPKG_RC=$?
set -e
if [ "$OPKG_RC" -ne 0 ]; then
  echo "WARNING: opkg update reported errors. Continuing, but some packages may be missing." >&2
fi

# --- Helper to install packages with a nicer log ---
install_pkg() {
  for p in "$@"; do
    echo
    echo "=== Installing package: $p ==="
    if ! opkg install "$p"; then
      echo "WARNING: Failed to install package: $p" >&2
    fi
  done
}

# --- Replace dnsmasq with dnsmasq-full ---
echo
echo "=== Replacing dnsmasq with dnsmasq-full ==="
if opkg list-installed | grep -q '^dnsmasq '; then
  opkg remove dnsmasq --force-depends || true
fi
install_pkg dnsmasq-full

# --- Core packages for Passwall2 ---
echo
echo "=== Installing core packages (Passwall2, Xray, Geo, tools) ==="

# Optional tools first
install_pkg wget-ssl curl tcping geoview

# Kernel NF-T Proxy modules (may fail on some targets; not fatal)
install_pkg kmod-nft-tproxy kmod-nft-socket

# Passwall2 + Xray + Iran GeoSite
echo
echo "=== Installing luci-app-passwall2, xray-core, v2ray-geosite-ir ==="
if ! opkg install luci-app-passwall2; then
  echo "ERROR: luci-app-passwall2 is not available for this arch/release." >&2
  echo "       Arch: $arch, Release: $DISTRIB_RELEASE" >&2
  exit 1
fi

install_pkg xray-core v2ray-geosite-ir

# --- Ensure iran.dat exists in /usr/share/v2ray ---
echo
echo "=== Ensuring /usr/share/v2ray/iran.dat exists ==="
mkdir -p /usr/share/v2ray

if [ -f /usr/share/v2ray/iran.dat ]; then
  echo "iran.dat already exists in /usr/share/v2ray"
else
  echo "iran.dat not found, downloading from GitHub (bootmortis/iran-hosted-domains)..."
  if ! wget -O /usr/share/v2ray/iran.dat \
    https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat; then
    echo "ERROR: Failed to download iran.dat" >&2
    exit 1
  fi
fi

# --- Make sure Passwall2 config/template exists ---
echo
echo "=== Ensuring Passwall2 configuration exists ==="
/etc/init.d/passwall2 restart >/dev/null 2>&1 || true

# --- Patch default template ---
if [ -f /usr/share/passwall2/0_default_config ]; then
  echo "Patching /usr/share/passwall2/0_default_config for Iran rules..."
  sed -i "s/China/Iran/g" /usr/share/passwall2/0_default_config
  sed -i "s/geoip:cn/geoip:ir/g" /usr/share/passwall2/0_default_config
  sed -i "s/geosite:cn/geosite:category-ir\next:iran.dat:all/g" /usr/share/passwall2/0_default_config
else
  echo "WARNING: /usr/share/passwall2/0_default_config not found. Skipping template patch." >&2
fi

# --- Patch live /etc/config/passwall2 if present ---
if [ -f /etc/config/passwall2 ]; then
  echo
  echo "=== Patching /etc/config/passwall2 for Iran rules and DNS ==="
  sed -i "s/China/Iran/g" /etc/config/passwall2
  sed -i "s/geoip:cn/geoip:ir/g" /etc/config/passwall2
  sed -i "s/geosite:cn/geosite:category-ir\next:iran.dat:all/g" /etc/config/passwall2

  uci set passwall2.@global[0].china='Iran' 2>/dev/null || true
  uci set passwall2.@global[0].remote_dns_protocol='tcp' 2>/dev/null || true
  uci set passwall2.@global[0].remote_dns='8.8.8.8' 2>/dev/null || true
  uci set passwall2.@global[0].remote_dns_query_strategy='UseIPv4' 2>/dev/null || true
  uci set passwall2.@global_rules[0].v2ray_location_asset='/usr/share/v2ray/' 2>/dev/null || true

  uci commit passwall2 || true
else
  echo "WARNING: /etc/config/passwall2 not found (Passwall2 may not have started yet)." >&2
fi

echo
echo "=== Restarting dnsmasq and Passwall2 ==="
/etc/init.d/dnsmasq restart || true
/etc/init.d/passwall2 restart || true

echo
echo "=== [Passwall2 Iran Installer] DONE ==="
echo "Open LuCI → Services → Passwall2 to configure your nodes and shunt."
