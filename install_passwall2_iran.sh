#!/bin/sh
# ramtin-openwrt-tools / install_passwall2_iran.sh
# نصب خودکار Passwall2 + Xray + Geo و تنظیم شانت Iran با geosite/geoip ایران

set -e

log() {
    echo "$@"
}

HEADER() {
    echo
    echo "=== $@ ==="
}

log "=== [Passwall2 Iran Installer] Starting ==="

# --- 1) شناسایی سیستم --------------------------------------------------------
OWRT_RELEASE=""
OWRT_TARGET=""
OWRT_ARCH="$(uname -m)"

[ -f /etc/openwrt_release ] && . /etc/openwrt_release

[ -n "$DISTRIB_RELEASE" ] && OWRT_RELEASE="$DISTRIB_RELEASE"
[ -n "$DISTRIB_TARGET" ]  && OWRT_TARGET="$DISTRIB_TARGET"

log "Detected OpenWrt: ${OWRT_RELEASE:-unknown}"
log "Target: ${OWRT_TARGET:-unknown}, Arch: ${OWRT_ARCH:-unknown}"

# برای الان، Passwall فقط تگ 24.10 دارد
REL_TAG="24.10"
log "Using release tag: $REL_TAG"

# --- 2) اضافه کردن فیدهای Passwall -----------------------------------------
CUSTOM_FEEDS="/etc/opkg/customfeeds.conf"

HEADER "Adding Passwall feeds if missing"

grep -q "passwall_packages" "$CUSTOM_FEEDS" 2>/dev/null || {
    echo "Added passwall_packages feed."
    echo "src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL_TAG}/aarch64_cortex-a53/passwall_packages" >> "$CUSTOM_FEEDS"
}

grep -q "passwall2" "$CUSTOM_FEEDS" 2>/dev/null || {
    echo "Added passwall2 feed."
    echo "src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL_TAG}/aarch64_cortex-a53/passwall2" >> "$CUSTOM_FEEDS"
}

# --- 3) اضافه کردن GPG key برای فید Passwall --------------------------------
HEADER "Ensuring Passwall GPG key is installed"

PASSWALL_PUB_TMP="/tmp/passwall.pub"
# اگر opkg-key هست، سعی می‌کنیم key رو اضافه کنیم
if command -v opkg-key >/dev/null 2>&1; then
    wget -q -O "$PASSWALL_PUB_TMP" \
        "https://downloads.sourceforge.net/project/openwrt-passwall-build/passwall.pub" && \
        opkg-key add "$PASSWALL_PUB_TMP" >/dev/null 2>&1 || true
    echo "Passwall GPG key added (or already present)."
else
    echo "WARNING: opkg-key not found; skipping adding Passwall GPG key."
fi

# --- 4) opkg update ----------------------------------------------------------
HEADER "Running opkg update (errors from some feeds are possible)"
opkg update

# --- 5) جایگزینی dnsmasq با dnsmasq-full ------------------------------------
HEADER "Ensuring dnsmasq-full is installed"

if ! opkg list-installed | grep -q "^dnsmasq-full "; then
    # اگر dnsmasq ساده نصب است، ابتدا پاکش می‌کنیم
    if opkg list-installed | grep -q "^dnsmasq "; then
        echo "Removing dnsmasq ..."
        opkg remove dnsmasq || true
    fi

    echo "Installing dnsmasq-full ..."
    opkg install dnsmasq-full
else
    echo "dnsmasq-full already installed."
fi

# --- 6) تابع نصب پکیج‌ها -----------------------------------------------------
ensure_pkg() {
    local pkg="$1"
    echo ">> Ensuring package: $pkg"
    if opkg list-installed | grep -q "^${pkg} "; then
        echo "   $pkg already installed."
    else
        echo "   Installing $pkg ..."
        opkg install "$pkg"
    fi
}

ensure_optional_pkg() {
    local pkg="$1"
    echo ">> Ensuring package: $pkg (optional)"
    if opkg list-installed | grep -q "^${pkg} "; then
        echo "   $pkg already installed."
    else
        echo "   Installing $pkg ..."
        if ! opkg install "$pkg"; then
            echo "   WARNING: optional package $pkg failed to install, skipping."
        fi
    fi
}

# --- 7) نصب پکیج‌های اصلی و ضروری -------------------------------------------
HEADER "Installing core packages (Passwall2, Xray, Geo, tools)"

# ابزارهای پایه
ensure_pkg wget-ssl
ensure_pkg curl

# nftables tproxy/socket
ensure_pkg kmod-nft-tproxy
ensure_pkg kmod-nft-socket

# ابزارهای کمکی (اختیاری)
ensure_optional_pkg tcping
ensure_optional_pkg geoview

# خود Passwall2 و Xray و Geo
ensure_pkg luci-app-passwall2
ensure_pkg xray-core
ensure_pkg v2ray-geoip
ensure_pkg v2ray-geosite
ensure_pkg v2ray-geosite-ir

# --- 8) بررسی وجود iran.dat --------------------------------------------------
HEADER "Checking for Iran geosite data (iran.dat)"

IRAN_DAT="/usr/share/v2ray/iran.dat"
if [ -f "$IRAN_DAT" ]; then
    echo "Found $IRAN_DAT"
    HAS_IRAN_DAT=1
else
    echo "NOTE: iran.dat not found. Script will use only builtin geosite:category-ir."
    HAS_IRAN_DAT=0
fi

# --- 9) تنظیم شانت Iran در Passwall2 -----------------------------------------
patch_passwall2_config() {
    HEADER "Patching /etc/config/passwall2 for Iran rules and DNS"

    # حداقل سکشن شانت Iran
    uci -q batch << 'EOF'
set passwall2.Iran=shunt_rules
set passwall2.Iran.remarks='Iran'
set passwall2.Iran.network='tcp,udp'
EOF

    # IP list: ایران + private
    uci set passwall2.Iran.ip_list='geoip:ir
geoip:private'

    # Domain list: geosite ایران + iran.dat اگر وجود داشته باشد
    if [ "$HAS_IRAN_DAT" -eq 1 ]; then
        uci set passwall2.Iran.domain_list='geosite:category-ir
ext:iran.dat:ir
ext:iran.dat:other'
    else
        # فقط دسته ایرانی از geosite اصلی
        uci set passwall2.Iran.domain_list='geosite:category-ir'
    fi

    uci commit passwall2

    echo
    echo "Passwall2 Iran shunt configured as:"
    uci show passwall2.Iran || true
}

patch_passwall2_config

# --- 10) ریستارت dnsmasq و Passwall2 ----------------------------------------
HEADER "Restarting dnsmasq and Passwall2"

#/etc/init.d/network reload 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || /etc/init.d/dnsmasq start 2>/dev/null || true
/etc/init.d/passwall2 restart 2>/dev/null || true

log ""
log "=== [Passwall2 Iran Installer] DONE ==="
log "Open LuCI → Services → Passwall2:"
log "  • Nodes را تنظیم کن"
log "  • در Shunt Rules از سکشن 'Iran' برای ترافیک ایران استفاده کن."
