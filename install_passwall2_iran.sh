#!/bin/sh
set -eu

TAG="install_passwall2_iran"

log(){ echo "=== [$TAG] $*"; }
warn(){ echo ">>> [$TAG] WARNING: $*" >&2; }
die(){ echo ">>> [$TAG] ERROR: $*" >&2; exit 1; }

have(){ command -v "$1" >/dev/null 2>&1; }

rel_tag() {
  if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release 2>/dev/null || true
    echo "${DISTRIB_RELEASE:-24.10.0}" | awk -F. '{print $1"."$2}'
  else
    echo "24.10"
  fi
}

opkg_primary_arch() {
  opkg print-architecture 2>/dev/null | awk '
    $2!="all" && $2!="noarch" {print $2; exit}
  '
}

pkg_installed() {
  opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed'
}

pkg_upgradable() {
  opkg list-upgradable 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

ensure_pkg() {
  PKG="$1"
  OPTIONAL="${2:-0}"

  if pkg_installed "$PKG"; then
    if pkg_upgradable "$PKG"; then
      log "Upgrading: $PKG"
      opkg upgrade "$PKG" >/dev/null 2>&1 || {
        [ "$OPTIONAL" = "1" ] && warn "Upgrade failed for optional $PKG (skip)" && return 0
        die "Upgrade failed for required $PKG"
      }
    else
      log "OK: $PKG already installed"
    fi
  else
    log "Installing: $PKG"
    opkg install "$PKG" >/dev/null 2>&1 || {
      [ "$OPTIONAL" = "1" ] && warn "Install failed for optional $PKG (skip)" && return 0
      die "Install failed for required $PKG"
    }
  fi
}

rewrite_passwall_feeds() {
  REL="$(rel_tag)"
  ARCH="$(opkg_primary_arch)"
  [ -n "$ARCH" ] || die "Cannot detect opkg arch (only all/noarch?)"

  log "Detected release tag: $REL"
  log "Detected opkg arch:   $ARCH"

  FEED="/etc/opkg/customfeeds.conf"
  BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${REL}/${ARCH}"

  log "Writing Passwall feeds (arch-correct) => $FEED"
  cat > "$FEED" <<EOF
src/gz passwall2 ${BASE}/passwall2
src/gz passwall_packages ${BASE}/passwall_packages
EOF
}

backup_configs() {
  TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  BK="/root/passwall2-backup-${TS}"
  mkdir -p "$BK" >/dev/null 2>&1 || true

  [ -f /etc/config/passwall2 ] && cp -f /etc/config/passwall2 "$BK/" || true
  [ -f /etc/config/passwall2_server ] && cp -f /etc/config/passwall2_server "$BK/" || true
  [ -f /etc/config/dhcp ] && cp -f /etc/config/dhcp "$BK/" || true

  log "Backup (if existed): $BK"
}

dnsmasq_full_mandatory() {
  # This function forces dnsmasq-full safely:
  # - If dnsmasq-full already installed: upgrade if needed
  # - Else if dnsmasq installed: remove dnsmasq then install dnsmasq-full
  # - If anything fails: try to rollback to dnsmasq to avoid breaking LAN DNS
  log "Ensuring dnsmasq-full (mandatory)"

  if pkg_installed dnsmasq-full; then
    if pkg_upgradable dnsmasq-full; then
      log "Upgrading: dnsmasq-full"
      opkg upgrade dnsmasq-full >/dev/null 2>&1 || die "Upgrade failed: dnsmasq-full"
    else
      log "OK: dnsmasq-full already installed"
    fi
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    return 0
  fi

  # dnsmasq-full not installed
  if pkg_installed dnsmasq; then
    log "dnsmasq is installed; switching to dnsmasq-full (remove dnsmasq -> install dnsmasq-full)"

    # Stop first to reduce chance of transient issues
    /etc/init.d/dnsmasq stop >/dev/null 2>&1 || true

    # Remove dnsmasq (keep configs under /etc/config/dhcp)
    opkg remove dnsmasq >/dev/null 2>&1 || {
      /etc/init.d/dnsmasq start >/dev/null 2>&1 || true
      die "Cannot remove dnsmasq (required to install dnsmasq-full without file clashes)"
    }

    # Now install dnsmasq-full
    if ! opkg install dnsmasq-full >/dev/null 2>&1; then
      warn "Failed to install dnsmasq-full; attempting rollback to dnsmasq"
      opkg install dnsmasq >/dev/null 2>&1 || true
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
      die "dnsmasq-full install failed (rollback attempted)"
    fi

    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "dnsmasq service restart failed after dnsmasq-full install"
    log "Switched OK: dnsmasq-full is now installed"
    return 0
  fi

  # Neither dnsmasq nor dnsmasq-full installed (rare, but handle)
  log "Neither dnsmasq nor dnsmasq-full found; installing dnsmasq-full"
  opkg install dnsmasq-full >/dev/null 2>&1 || die "Cannot install dnsmasq-full"
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

uci_ensure_anon_section() {
  CONF="$1"; TYPE="$2"
  if ! uci -q show "$CONF" 2>/dev/null | grep -q "^${CONF}\.@${TYPE}\[0\]="; then
    uci add "$CONF" "$TYPE" >/dev/null 2>&1 || true
  fi
}

apply_iran_shunt() {
  have uci || die "uci not found"

  if ! uci -q show passwall2 >/dev/null 2>&1; then
    touch /etc/config/passwall2
  fi

  uci_ensure_anon_section passwall2 global

  uci -q set passwall2.IRAN='shunt_rules'
  uci -q set passwall2.IRAN.remarks='IRAN'
  uci -q set passwall2.IRAN.network='tcp,udp'

  # Known-good combo from your tests
  uci -q set passwall2.IRAN.domain_list='geosite:category-ir
ext:iran.dat:ir
ext:iran.dat:other'
  uci -q set passwall2.IRAN.ip_list='geoip:ir
geoip:private'

  uci -q set passwall2.@global[0].china='IRAN'

  uci commit passwall2 >/dev/null 2>&1 || die "uci commit passwall2 failed"
  [ -x /etc/init.d/passwall2 ] && /etc/init.d/passwall2 restart >/dev/null 2>&1 || true

  log "IRAN shunt applied (copy-check):"
  echo "---- Domain ----"
  echo "geosite:category-ir"
  echo "ext:iran.dat:ir"
  echo "ext:iran.dat:other"
  echo "---- IP ----"
  echo "geoip:ir"
  echo "geoip:private"
}

main() {
  have opkg || die "opkg not found"

  log "Start"
  backup_configs
  rewrite_passwall_feeds

  log "opkg update"
  opkg update || die "opkg update failed (check Internet/DNS)"

  # Mandatory: dnsmasq-full (smart swap)
  dnsmasq_full_mandatory

  # Passwall2 stack (minimal, stable)
  ensure_pkg wget-ssl 1
  ensure_pkg curl 1

  ensure_pkg luci-app-passwall2 0
  ensure_pkg xray-core 0
  ensure_pkg tcping 0
  ensure_pkg geoview 0

  # Optional geo packages (many builds already ship dat files)
  ensure_pkg v2ray-geoip 1
  ensure_pkg v2ray-geosite 1

  apply_iran_shunt

  log "Done"
}

main "$@"
