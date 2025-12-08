#!/bin/sh
# ramtin-openwrt-tools - Passwall2 + Iran geosite installer (v4)
# Safe on fresh factory reset & re-runs (idempotent, no duplicates).

set -e

echo "=== [Passwall2 Iran Installer] Starting ==="

# --- Detect OpenWrt release / arch ------------------------------------------------
DISTRIB_RELEASE=""
DISTRIB_TARGET=""
DISTRIB_ARCH=""

if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
fi

# RELEASE_TAG: e.g. 24.10 from 24.10.4
REL_MAJOR="${DISTRIB_RELEASE%%.*}"
REL_REST="${DISTRIB_RELEASE#*.}"
REL_MINOR="${REL_REST%%.*}"
RELEASE_TAG="${REL_MAJOR}.${REL_MINOR}"

[ -z "$RELEASE_TAG" ] && RELEASE_TAG="24.10"
[ -z "$DISTRIB_ARCH" ] && DISTRIB_ARCH="$(uname -m)"

echo "Detected OpenWrt: ${DISTRIB_ID:-OpenWrt} ${DISTRIB_RELEASE:-unknown}"
echo "Target: ${DISTRIB_TARGET:-unknown}, Arch: ${DISTRIB_ARCH}"
echo "Using release tag: ${RELEASE_TAG}"
echo

PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases"
PASSWALL_PKG_URL="${PASSWALL_BASE}/packages-${RELEASE_TAG}/${DISTRIB_ARCH}/passwall_packages"
PASSWALL2_PKG_URL="${PASSWALL_BASE}/packages-${RELEASE_TAG}/${DISTRIB_ARCH}/passwall2"

CUSTOMFEEDS="/etc/opkg/customfeeds.conf"

# --- Add Passwall feeds if missing -----------------------------------------------
echo "=== Adding Passwall feeds if missing ==="

grep -q "passwall_packages" "$CUSTOMFEEDS" 2>/dev/null || {
    echo "src/gz passwall_packages ${PASSWALL_PKG_URL}" >> "$CUSTOMFEEDS"
    echo "Added passwall_packages feed."
}

grep -q "passwall2 " "$CUSTOMFEEDS" 2>/dev/null || {
    echo "src/gz passwall2 ${PASSWALL2_PKG_URL}" >> "$CUSTOMFEEDS"
    echo "Added passwall2 feed."
}

echo

# --- Ensure Passwall GPG key is installed ----------------------------------------
echo "=== Ensuring Passwall GPG key is installed ==="
if ! opkg-key list 2>/dev/null | grep -q "openwrt-passwall-build"; then
    TMP_KEY="/tmp/passwall.pub"
    wget -q -O "$TMP_KEY" \
        "https://downloads.sourceforge.net/project/openwrt-passwall-build/passwall.pub" \
        || wget -q -O "$TMP_KEY" \
        "https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub" \
        || echo "WARNING: Could not download Passwall public key."
    [ -f "$TMP_KEY" ] && opkg-key add "$TMP_KEY" 2>/dev/null || true
    echo "Passwall GPG key added (or already present)."
else
    echo "Passwall GPG key already present."
fi

echo

# --- opkg update ------------------------------------------------------------------
echo "=== Running opkg update (errors from some feeds are possible) ==="
opkg update || true
echo

# --- Helper: ensure package is installed (robust check) --------------------------
ensure_pkg() {
    PKG="$1"
    LABEL="$2"
    [ -z "$LABEL" ] && LABEL="$PKG"

    echo ">> Ensuring package: $LABEL"

    # Robust: واقعی از خروجی list-installed چک می‌کنیم
    if opkg list-installed 2>/dev/null | grep -q "^${PKG} - "; then
        echo "   ${PKG} already installed."
    else
        echo "   Installing ${PKG} ..."
        opkg install "$PKG"
    fi
}

# --- Ensure dnsmasq-full ---------------------------------------------------------
echo "=== Ensuring dnsmasq-full is installed ==="
if opkg list-installed 2>/dev/null | grep -q "^dnsmasq-full - "; then
    echo "dnsmasq-full already installed."
else
    opkg remove dnsmasq 2>/dev/null || true
    opkg install dnsmasq-full
fi

echo

# --- Core packages (no Iran logic yet) -------------------------------------------
echo "=== Installing core packages (Passwall2, Xray, Geo, tools) ==="

ensure_pkg wget-ssl "wget-ssl"
ensure_pkg curl "curl"
ensure_pkg kmod-nft-tproxy "kmod-nft-tproxy"
ensure_pkg kmod-nft-socket "kmod-nft-socket"

# Optional but useful helper tools
ensure_pkg tcping "tcping (optional)"
ensure_pkg geoview "geoview (optional)"

# Passwall2 stack
ensure_pkg luci-app-passwall2 "luci-app-passwall2"
ensure_pkg xray-core "xray-core"
ensure_pkg v2ray-geoip "v2ray-geoip"
ensure_pkg v2ray-geosite "v2ray-geosite (global geosite)"
ensure_pkg v2ray-geosite-ir "v2ray-geosite-ir (Iran geosite)"

echo

# --- Iran geosite: iran.dat is OPTIONAL ------------------------------------------
echo "=== Checking for Iran geosite data (iran.dat) ==="
IR_EXTRA=""

if [ -f /usr/share/v2ray/iran.dat ]; then
    echo "Found /usr/share/v2ray/iran.dat"
    IR_EXTRA=",ext:iran.dat:all"
else
    CANDIDATE="$(find /usr/share -maxdepth 4 -type f -name 'iran.dat' 2>/dev/null | head -n 1)"
    if [ -n "$CANDIDATE" ]; then
        echo "Found iran.dat at: $CANDIDATE (creating symlink /usr/share/v2ray/iran.dat)"
        mkdir -p /usr/share/v2ray
        ln -sf "$CANDIDATE" /usr/share/v2ray/iran.dat
        IR_EXTRA=",ext:iran.dat:all"
    else
        echo "NOTE: iran.dat not found. Script will use only builtin geosite:category-ir."
        echo "      This is safe; extra iran.dat data is just an improvement if present."
    fi
fi

echo

# --- Patch Passwall2 config: Iran rules & china label ----------------------------
echo "=== Patching /etc/config/passwall2 for Iran rules and DNS ==="

[ -f /etc/config/passwall2 ] || touch /etc/config/passwall2

# Global section: set china label to 'Iran' (for UI)
if uci -q show passwall2.@global[0] >/dev/null 2>&1; then
    uci set passwall2.@global[0].china='Iran'
else
    SEC="$(uci add passwall2 global)"
    uci set passwall2."$SEC".enabled='0'
    uci set passwall2."$SEC".china='Iran'
fi

# Iran shunt_rules section (idempotent)
if ! uci -q show passwall2.Iran >/dev/null 2>&1; then
    uci set passwall2.Iran=shunt_rules
fi

uci set passwall2.Iran.remarks='Iran'
uci set passwall2.Iran.network='tcp,udp'
uci set passwall2.Iran.ip_list="geoip:ir${IR_EXTRA}"
uci set passwall2.Iran.domain_list="geosite:category-ir${IR_EXTRA}"

uci commit passwall2

echo "Passwall2 config patched:"
uci show passwall2.Iran 2>/dev/null || true
echo

# --- Restart services ------------------------------------------------------------
echo "=== Restarting dnsmasq and Passwall2 ==="
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/passwall2 restart 2>/dev/null || true

echo
echo "=== [Passwall2 Iran Installer] DONE ==="
echo "Open LuCI → Services → Passwall2 to add your nodes and assign 'Iran' shunt."
