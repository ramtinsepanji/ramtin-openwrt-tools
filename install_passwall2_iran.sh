#!/bin/sh
set -eu

log() { echo "=== [passwall2-iran] $*"; }
die() { echo ">>> [passwall2-iran] ERROR: $*" >&2; exit 1; }

need_root() {
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || die "Run as root"
}

# fetch URL to file (tries uclient-fetch then wget)
fetch_to() {
  URL="$1"
  OUT="$2"
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$OUT" "$URL" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$OUT" "$URL" && return 0
  fi
  die "No downloader found (need uclient-fetch or wget)"
}

is_installed() {
  opkg status "$1" 2>/dev/null | grep -q '^Status: install'
}

install_pkg() {
  PKG="$1"
  if is_installed "$PKG"; then
    log "OK: $PKG already installed"
    return 0
  fi
  log "Installing: $PKG"
  opkg install "$PKG" >/dev/null || die "Install failed: $PKG"
}

remove_pkg_if_installed() {
  PKG="$1"
  if is_installed "$PKG"; then
    log "Removing: $PKG"
    opkg remove "$PKG" >/dev/null || die "Remove failed: $PKG"
  fi
}

backup_if_exists() {
  F="$1"
  [ -f "$F" ] || return 0
  TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  BK="/root/$(basename "$F").bak-$TS"
  cp -f "$F" "$BK" 2>/dev/null || true
  log "Backup: $F -> $BK"
}

detect_release_arch() {
  # Use the same proven method you used:
  RELEASE="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE%.*}")"
  ARCH="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_ARCH:-}")"

  [ -n "$RELEASE" ] || die "Cannot detect OpenWrt release"
  [ -n "$ARCH" ] || die "Cannot detect OpenWrt arch"

  echo "$RELEASE $ARCH"
}

ensure_opkg_lists_dir() {
  mkdir -p /var/opkg-lists 2>/dev/null || true
}

# Remove any previous passwall-related src lines (to avoid duplicates/breakage), then append clean ones.
rewrite_passwall_feeds() {
  RELEASE="$1"
  ARCH="$2"
  FEED_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$RELEASE/$ARCH"

  mkdir -p /etc/opkg
  touch /etc/opkg/customfeeds.conf 2>/dev/null || true
  backup_if_exists /etc/opkg/customfeeds.conf

  # Delete older passwall lines (including *_all/_noarch variants) idempotently
  sed -i \
    -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall2\([[:space:]]\|$\)/d' \
    -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall_packages\([[:space:]]\|$\)/d' \
    -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall2_/d' \
    -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall_packages_/d' \
    /etc/opkg/customfeeds.conf 2>/dev/null || true

  {
    echo "src/gz passwall_packages $FEED_BASE/passwall_packages"
    echo "src/gz passwall2 $FEED_BASE/passwall2"
  } >> /etc/opkg/customfeeds.conf

  log "Passwall feeds set for: release=$RELEASE arch=$ARCH"
}

ensure_passwall_key() {
  KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub"
  TMP_KEY="/tmp/passwall.pub"

  # If key already present, skip (best-effort check)
  if opkg-key list 2>/dev/null | grep -qi passwall; then
    log "OK: Passwall key seems already present"
    return 0
  fi

  log "Fetching Passwall GPG key"
  fetch_to "$KEY_URL" "$TMP_KEY"
  opkg-key add "$TMP_KEY" >/dev/null || die "opkg-key add failed"
  log "OK: Passwall key added"
}

ensure_dnsmasq_full_mandatory() {
  log "Ensuring dnsmasq-full (mandatory)"
  if is_installed dnsmasq-full; then
    log "OK: dnsmasq-full already installed"
    return 0
  fi

  # Must switch from dnsmasq -> dnsmasq-full
  if is_installed dnsmasq; then
    log "Switch: dnsmasq -> dnsmasq-full"
    remove_pkg_if_installed dnsmasq
  fi

  install_pkg dnsmasq-full
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  log "OK: dnsmasq-full is installed"
}

ensure_passwall2_stack() {
  # Core kernel modules needed by Passwall2 TProxy mode
  install_pkg kmod-nft-tproxy
  install_pkg kmod-nft-socket

  # Basic tools (wget-ssl is useful for one-liners)
  install_pkg wget-ssl
  install_pkg curl

  # Passwall2 + common deps that Passwall2 repo expects
  install_pkg luci-app-passwall2
  install_pkg xray-core
  install_pkg geoview
  install_pkg tcping

  # Geo data used in your setup
  install_pkg v2ray-geoip
  install_pkg v2ray-geosite
  install_pkg v2ray-geosite-ir
}

ensure_iran_shunt_rule() {
  # Passwall2 uses "china" label internally; set it to Iran
  uci -q set passwall2.@global[0].china='Iran' 2>/dev/null || true

  # Ensure a shunt_rules section exists and is named IRAN
  if uci -q show passwall2.IRAN >/dev/null 2>&1; then
    IRAN_SEC="IRAN"
  else
    # Try to find an existing shunt_rules with remarks=IRAN
    SEC="$(uci show passwall2 2>/dev/null | awk -F'[.=]' '
      $0 ~ /=shunt_rules$/ {s=$2}
      $0 ~ "remarks=.IRAN." {print s; exit}
    ')"
    if [ -n "${SEC:-}" ]; then
      IRAN_SEC="$SEC"
      uci -q rename "passwall2.$IRAN_SEC=IRAN" 2>/dev/null || true
      IRAN_SEC="IRAN"
    else
      # Create one
      NEW="$(uci add passwall2 shunt_rules 2>/dev/null || true)"
      [ -n "${NEW:-}" ] || die "Failed to add shunt_rules section"
      uci -q rename "passwall2.$NEW=IRAN" || die "Failed to rename shunt_rules to IRAN"
      IRAN_SEC="IRAN"
    fi
  fi

  # Set rule (newline-based lists, so LuCI shows them زیر هم)
  uci -q batch <<'UCI'
set passwall2.IRAN.remarks='IRAN'
set passwall2.IRAN.network='tcp,udp'
UCI

  uci -q set passwall2.IRAN.domain_list="$(printf '%s\n' \
'geosite:category-ir' \
'ext:iran.dat:ir' \
'ext:iran.dat:other')"

  uci -q set passwall2.IRAN.ip_list="$(printf '%s\n' \
'geoip:ir' \
'geoip:private')"

  uci -q commit passwall2

  # Warn (non-fatal) if iran.dat missing
  if [ ! -s /usr/share/v2ray/iran.dat ]; then
    log "NOTE: /usr/share/v2ray/iran.dat not found. ext:iran.dat:* rules need this file."
  fi

  /etc/init.d/passwall2 restart >/dev/null 2>&1 || true
  log "OK: IRAN shunt rule applied"
}

patch_default_config_optional() {
  # Optional: update default template so future resets use Iran too.
  # Do it safely and idempotently.
  F="/usr/share/passwall2/0_default_config"
  [ -f "$F" ] || return 0

  # If already contains category-ir, skip patching
  if grep -q 'geosite:category-ir' "$F" 2>/dev/null; then
    log "OK: default_config already patched"
    return 0
  fi

  backup_if_exists "$F"

  # Replace China -> Iran, geoip:cn -> geoip:ir, and geosite:cn -> our multiline
  sed -i \
    -e 's/\bChina\b/Iran/g' \
    -e 's/geoip:cn/geoip:ir/g' \
    "$F" 2>/dev/null || true

  # Replace geosite:cn line wherever it appears
  # BusyBox sed supports \n in replacement in many builds; safer: do a small awk rewrite.
  TMP="/tmp/pw2_default_config.$$"
  awk '
    {
      if ($0 ~ /geosite:cn/) {
        print "geosite:category-ir"
        print "ext:iran.dat:ir"
        print "ext:iran.dat:other"
        next
      }
      print
    }
  ' "$F" > "$TMP" 2>/dev/null && mv "$TMP" "$F" 2>/dev/null || true

  log "OK: default_config patched"
}

main() {
  need_root
  ensure_opkg_lists_dir

  read RELEASE ARCH <<EOF
$(detect_release_arch)
EOF

  log "Detected OpenWrt: release=$RELEASE arch=$ARCH"

  # 1) Update official feeds first (helps on fresh routers)
  log "opkg update (official + existing feeds)"
  opkg update >/dev/null || die "opkg update failed (check DNS/Internet)"

  # 2) dnsmasq-full is mandatory (do it before messing with passwall feeds)
  ensure_dnsmasq_full_mandatory

  # 3) Passwall key + feeds
  ensure_passwall_key
  rewrite_passwall_feeds "$RELEASE" "$ARCH"

  # 4) Update feeds again (now includes passwall repos)
  log "opkg update (with passwall feeds)"
  opkg update >/dev/null || die "opkg update failed after adding passwall feeds"

  # 5) Install stack
  ensure_passwall2_stack

  # 6) Configure IRAN rule
  ensure_iran_shunt_rule

  # 7) Optional template patch
  patch_default_config_optional

  log "DONE"
  log "LuCI: Services -> Passwall2 (Shunt) | Use China list = Iran"
}

main "$@"
