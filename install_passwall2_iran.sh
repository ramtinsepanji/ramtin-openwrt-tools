#!/bin/sh
# install_passwall2_iran.sh
# Universal Passwall2 + Iran geosite installer for OpenWrt

set -e

echo "=== [Passwall2 Iran Installer] Starting ==="

# --- Detect OpenWrt release and arch ---
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
else
    echo "ERROR: This script is intended for OpenWrt only."
    exit 1
fi

REL="${DISTRIB_RELEASE%.*}"
[ -z "$REL" ] && REL="$DISTRIB_RELEASE"
ARCH="$DISTRIB_ARCH"
TARGET="$DISTRIB_TARGET"

echo "Detected OpenWrt: ${DISTRIB_DESCRIPTION}"
echo "Target: ${TARGET}, Arch: ${ARCH}"
echo "Using release tag: ${REL}"
echo

# --- Ensure customfeeds.conf exists ---
CUSTOMFEEDS="/etc/opkg/customfeeds.conf"
if [ ! -f "$CUSTOMFEEDS" ]; then
    echo "Creating $CUSTOMFEEDS ..."
    touch "$CUSTOMFEEDS"
fi

# --- Add Passwall feeds if missing ---
echo "=== Adding Passwall feeds if missing ==="
PASSWALL_PKG_LINE="src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL}/${ARCH}/passwall_packages"
PASSWALL2_LINE="src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL}/${ARCH}/passwall2"

if ! grep -q "passwall_packages" "$CUSTOMFEEDS" 2>/dev/null; then
    echo "$PASSWALL_PKG_LINE" >> "$CUSTOMFEEDS"
    echo "Added passwall_packages feed."
else
    echo "passwall_packages feed already present."
fi

if ! grep -q "passwall2" "$CUSTOMFEEDS" 2>/dev/null; then
    echo "$PASSWALL2_LINE" >> "$CUSTOMFEEDS"
    echo "Added passwall2 feed."
else
    echo "passwall2 feed already present."
fi

echo

# --- Ensure Passwall GPG key is installed ---
echo "=== Ensuring Passwall GPG key is installed ==="
KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub"
wget -q -O /tmp/passwall.pub "$KEY_URL" || echo "WARNING: Failed to download passwall.pub (will still try opkg)."
if [ -s /tmp/passwall.pub ]; then
    opkg-key add /tmp/passwall.pub 2>/dev/null || true
    echo "Passwall GPG key added (or already present)."
else
    echo "WARNING: passwall.pub is empty/missing, signature errors may appear."
fi

echo

# --- opkg update (do not fail on partial errors) ---
echo "=== Running opkg update (errors from some feeds are possible) ==="
set +e
opkg update
set -e
echo

# --- Ensure dnsmasq-full is installed ---
echo "=== Ensuring dnsmasq-full is installed ==="
if opkg list-installed dnsmasq-full >/dev/null 2>&1; then
    echo "dnsmasq-full already installed."
else
    if opkg list-installed dnsmasq >/dev/null 2>&1; then
        echo "Removing dnsmasq ..."
        opkg remove dnsmasq || true
    fi
    echo "Installing dnsmasq-full ..."
    opkg install dnsmasq-full
fi
echo

# --- Base dependencies ---
echo "=== Installing core packages (Passwall2, Xray, Geo, tools) ==="
BASE_PKGS="wget-ssl curl kmod-nft-tproxy kmod-nft-socket"
for p in $BASE_PKGS; do
    echo ">> Ensuring package: $p"
    if ! opkg list-installed "$p" >/dev/null 2>&1; then
        opkg install "$p" || echo "WARNING: Failed to install $p (optional or kernel-dependent)."
    else
        echo "   $p already installed."
    fi
done
echo

# --- Optional helper packages ---
OPTIONAL_PKGS="tcping geoview"
for p in $OPTIONAL_PKGS; do
    echo ">> Ensuring optional package: $p"
    if ! opkg list-installed "$p" >/dev/null 2>&1; then
        opkg install "$p" || echo "WARNING: Optional package $p could not be installed."
    else
        echo "   $p already installed."
    fi
done
echo

# --- Install Passwall2 & geo databases ---
CORE_PKGS="luci-app-passwall2 xray-core v2ray-geoip v2ray-geosite v2ray-geosite-ir"
for p in $CORE_PKGS; do
    echo ">> Ensuring core package: $p"
    if ! opkg list-installed "$p" >/dev/null 2>&1; then
        if ! opkg install "$p"; then
            echo "ERROR: Failed to install $p. Check architecture/release compatibility."
            exit 1
        fi
    else
        echo "   $p already installed."
    fi
done
echo

# --- Ensure iran.dat is present ---
echo "=== Ensuring /usr/share/v2ray/iran.dat exists ==="
IRAN_DAT="/usr/share/v2ray/iran.dat"
if [ -f "$IRAN_DAT" ]; then
    echo "iran.dat already present at $IRAN_DAT"
else
    echo "WARNING: iran.dat not found at $IRAN_DAT."
    echo "         Make sure v2ray-geosite-ir package is properly installed."
fi
echo

# --- Patch default Passwall2 config template if present ---
DEFAULT_CFG="/usr/share/passwall2/0_default_config"
if [ -f "$DEFAULT_CFG" ]; then
    echo "=== Patching $DEFAULT_CFG for Iran rules ==="
    sed -i 's/China/Iran/g' "$DEFAULT_CFG"
    sed -i 's/geoip:cn/geoip:ir/g' "$DEFAULT_CFG"
    # Replace China geosite with Iran geosite + iran.dat extension
    sed -i 's/geosite:cn/geosite:category-ir\
ext:iran.dat:all/g' "$DEFAULT_CFG"
else
    echo "NOTE: $DEFAULT_CFG not found, skipping template patch."
fi
echo

# --- Ensure /etc/config/passwall2 exists ---
RUNTIME_CFG="/etc/config/passwall2"
if [ ! -f "$RUNTIME_CFG" ]; then
    echo "NOTE: $RUNTIME_CFG does not exist yet. It will be created by Passwall2 on first start."
    touch "$RUNTIME_CFG"
fi

echo "=== Patching /etc/config/passwall2 for Iran rules and DNS ==="

# Set global China label to Iran, and v2ray assets path
uci set passwall2.@global[0].china='Iran' 2>/dev/null || true
uci set passwall2.@global_rules[0].v2ray_location_asset='/usr/share/v2ray/' 2>/dev/null || true

# Ensure Iran shunt_rules section exists
if uci -q get passwall2.Iran >/dev/null 2>&1; then
    echo "Iran shunt_rules section already exists, updating values ..."
else
    echo "Creating Iran shunt_rules section ..."
    SEC="$(uci add passwall2 shunt_rules)"
    uci rename passwall2."$SEC"='Iran'
fi

# Standardized Iran rule (safe and consistent)
uci set passwall2.Iran.remarks='Iran'
uci set passwall2.Iran.network='tcp,udp'
uci set passwall2.Iran.ip_list='geoip:ir,ext:iran.dat:all'
uci set passwall2.Iran.domain_list='geosite:category-ir,ext:iran.dat:all'

uci commit passwall2 || true
echo

# --- Restart services ---
echo "=== Restarting dnsmasq and Passwall2 ==="
/etc/init.d/dnsmasq restart 2>/dev/null || echo "WARNING: dnsmasq restart failed (check service)."
/etc/init.d/passwall2 restart 2>/dev/null || echo "NOTE: passwall2 service restart may fail if not fully configured yet."
echo

echo "=== [Passwall2 Iran Installer] DONE ==="
echo "Open LuCI → Services → Passwall2 to configure your nodes and shunt."
