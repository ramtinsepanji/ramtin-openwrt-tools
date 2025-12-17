#!/bin/sh
set -eu

echo "=== [install_passwall2_iran] Starting ==="

need_cmd() { command -v "$1" >/dev/null 2>&1; }
say() { echo "$*"; }

# --- Detect OpenWrt release tag (e.g. 24.10) ---
REL_TAG="24.10"
if [ -r /etc/openwrt_release ]; then
  . /etc/openwrt_release 2>/dev/null || true
  # DISTRIB_RELEASE like 24.10.4 -> tag 24.10
  if [ -n "${DISTRIB_RELEASE:-}" ]; then
    REL_TAG="$(echo "$DISTRIB_RELEASE" | awk -F. '{print $1"."$2}')"
  fi
fi

# --- Detect best opkg arch for passwall feeds ---
OPKG_ARCH="unknown"
if need_cmd opkg; then
  # First non-"all" arch
  OPKG_ARCH="$(opkg print-architecture 2>/dev/null | awk '$1!="all"{print $1; exit}')"
fi

say "Detected release tag: ${REL_TAG}"
say "Detected opkg arch:   ${OPKG_ARCH}"

if [ "$OPKG_ARCH" = "unknown" ] || [ -z "$OPKG_ARCH" ]; then
  say "ERROR: Could not detect opkg architecture."
  exit 1
fi

# --- Ensure base tools ---
if ! need_cmd wget && ! need_cmd curl; then
  say "Installing wget-ssl ..."
  opkg update >/dev/null 2>&1 || true
  opkg install wget-ssl >/dev/null 2>&1 || true
fi

# --- Rebuild passwall feeds to match detected arch ---
say "=== Rewriting Passwall feeds (prevents wrong-arch downloads) ==="
PASSWALL_LIST="/etc/opkg/customfeeds.conf"
mkdir -p /etc/opkg

cat > "$PASSWALL_LIST" <<EOF
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL_TAG}/${OPKG_ARCH}/passwall2
src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL_TAG}/${OPKG_ARCH}/passwall_packages
EOF

# --- Passwall repo key (idempotent) ---
say "=== Ensuring Passwall GPG key ==="
KEY_DST="/etc/opkg/keys/02a4f3a0b1c0d7e9"  # name doesn't matter; content does
if [ ! -s "$KEY_DST" ]; then
  # Key published by passwall-build; using the canonical URL is important
  # If key already exists under another name, opkg will still work.
  TMPKEY="/tmp/passwall.key"
  if need_cmd wget; then
    wget -qO "$TMPKEY" "https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub" || true
  else
    curl -fsSL -o "$TMPKEY" "https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub" || true
  fi
  if [ -s "$TMPKEY" ]; then
    cp "$TMPKEY" "$KEY_DST" 2>/dev/null || true
    rm -f "$TMPKEY" || true
  fi
fi

# --- Update feeds ---
say "=== opkg update ==="
opkg update

# --- Core deps that are safe/needed for Passwall2 on fw4/nft ---
say "=== Core deps ==="
opkg install dnsmasq-full >/dev/null 2>&1 || true
opkg install kmod-nft-socket kmod-nft-tproxy >/dev/null 2>&1 || true

# --- Install Passwall2 + minimal dependencies (NO full system upgrade) ---
say "=== Passwall2 + required deps ==="
# These are required by luci-app-passwall2 in many builds
opkg install tcping geoview >/dev/null 2>&1 || true

# Main packages
opkg install luci-app-passwall2 xray-core >/dev/null 2>&1 || {
  say "ERROR: Failed to install luci-app-passwall2 and/or xray-core."
  exit 1
}

# Geo data packages (best effort; different feeds name them differently)
opkg install v2ray-geoip v2ray-geosite >/dev/null 2>&1 || true
opkg install xray-geoip xray-geosite >/dev/null 2>&1 || true

# --- Ensure iran.dat exists for ext:iran.dat:* usage ---
say "=== Ensuring /usr/share/v2ray/iran.dat ==="
mkdir -p /usr/share/v2ray
if [ ! -s /usr/share/v2ray/iran.dat ]; then
  # Use your existing known-good file source if you prefer.
  # This URL should point to a raw iran.dat you trust.
  IRAN_URL="https://raw.githubusercontent.com/bootmortis/iran-hosted-domains/main/iran.dat"
  if need_cmd wget; then
    wget -qO /usr/share/v2ray/iran.dat "$IRAN_URL" || true
  else
    curl -fsSL -o /usr/share/v2ray/iran.dat "$IRAN_URL" || true
  fi
fi
if [ ! -s /usr/share/v2ray/iran.dat ]; then
  say "WARNING: iran.dat not present; ext:iran.dat:* will not work until you provide it."
fi

# --- Build Passwall2 config sections if missing ---
say "=== Creating Passwall2 base sections if missing ==="
uci -q show passwall2 >/dev/null 2>&1 || touch /etc/config/passwall2

# Ensure @global[0]
if ! uci -q get passwall2.@global[0] >/dev/null 2>&1; then
  uci add passwall2 global >/dev/null
fi

# Ensure @global_forwarding[0] (not always present on fresh installs)
if ! uci -q get passwall2.@global_forwarding[0] >/dev/null 2>&1; then
  uci add passwall2 global_forwarding >/dev/null
fi

# Set "china" to Iran (Passwall naming quirk; keeps compatibility with UI)
uci set passwall2.@global[0].china='Iran' 2>/dev/null || true

# --- Create/overwrite IRAN shunt rule deterministically ---
say "=== Installing Iran shunt rules (domain/ip) ==="

# Find existing named section "IRAN" of type shunt_rules, else create it
IRAN_SEC=""
# if exists, uci get works:
if uci -q get passwall2.IRAN >/dev/null 2>&1; then
  IRAN_SEC="IRAN"
else
  # create named section
  uci add passwall2 shunt_rules >/dev/null
  # last added section is @shunt_rules[-1], rename to IRAN
  LAST="$(uci show passwall2 | awk -F= '/=shunt_rules/{sec=$1} END{print sec}')"
  [ -n "$LAST" ] || { say "ERROR: could not create shunt_rules section"; exit 1; }
  uci rename "${LAST}=IRAN"
  IRAN_SEC="IRAN"
fi

# Apply the known-good combo you confirmed works:
# Domain:
#   geosite:category-ir
#   ext:iran.dat:ir
#   ext:iran.dat:other
# IP:
#   geoip:ir
#   geoip:private
uci set "passwall2.${IRAN_SEC}.remarks=IRAN"
uci set "passwall2.${IRAN_SEC}.network=tcp,udp"
uci set "passwall2.${IRAN_SEC}.domain_list=geosite:category-ir ext:iran.dat:ir ext:iran.dat:other"
uci set "passwall2.${IRAN_SEC}.ip_list=geoip:ir geoip:private"

# Commit
uci commit passwall2

# Restart services best-effort
say "=== Restarting Passwall2 services (best effort) ==="
[ -x /etc/init.d/passwall2 ] && /etc/init.d/passwall2 restart >/dev/null 2>&1 || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

say "=== DONE: Passwall2 installed + IRAN shunt rule created automatically ==="
say "Rule written to: passwall2.IRAN (domain_list/ip_list)"
