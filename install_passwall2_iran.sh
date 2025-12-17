cat << 'EOF' > /tmp/install_passwall2_iran.sh
#!/bin/sh
set -eu

SCRIPT_NAME="install_passwall2_iran"
PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases"
PW_KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

detect_release_tag() {
  if [ -r /etc/openwrt_release ]; then
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    if [ -n "${DISTRIB_RELEASE:-}" ]; then
      echo "${DISTRIB_RELEASE%.*}"
      return 0
    fi
  fi
  die "Cannot detect OpenWrt release tag from /etc/openwrt_release"
}

detect_best_arch() {
  need_cmd opkg
  # Prefer highest-priority non-all/non-noarch arch
  # opkg print-architecture lines: "arch <name> <priority>"
  opkg print-architecture 2>/dev/null | awk '
    $1=="arch" {
      name=$2; pr=$3;
      if (name!="all" && name!="noarch") {
        if (pr>best_pr) { best_pr=pr; best_name=name; }
      }
    }
    END {
      if (best_name=="") exit 1;
      print best_name;
    }' || die "Cannot detect opkg architecture (opkg print-architecture failed)"
}

ensure_passwall_key() {
  [ -d /etc/opkg/keys ] || mkdir -p /etc/opkg/keys

  if command -v wget >/dev/null 2>&1; then
    wget -qO /tmp/passwall.pub "$PW_KEY_URL" || die "Failed to download Passwall public key"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O /tmp/passwall.pub "$PW_KEY_URL" || die "Failed to download Passwall public key"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$PW_KEY_URL" -o /tmp/passwall.pub || die "Failed to download Passwall public key"
  else
    die "No downloader found (need wget-ssl or curl or uclient-fetch)"
  fi

  fp="$(opkg-key add /tmp/passwall.pub 2>/dev/null || true)"
  rm -f /tmp/passwall.pub
  [ -n "$fp" ] || true
}

rewrite_passwall_feeds() {
  rel_tag="$1"
  arch="$2"

  [ -d /etc/opkg ] || mkdir -p /etc/opkg
  conf="/etc/opkg/customfeeds.conf"
  [ -f "$conf" ] || : > "$conf"

  # Remove any previous passwall-build entries to avoid arch mismatches
  tmp="/tmp/customfeeds.conf.$$"
  awk '
    BEGIN{IGNORECASE=1}
    $0 ~ /openwrt-passwall-build/ {next}
    $1=="src/gz" && ($2 ~ /^passwall2$/ || $2 ~ /^passwall_packages$/) {next}
    {print}
  ' "$conf" > "$tmp" || true
  mv "$tmp" "$conf"

  cat >> "$conf" <<EOM

src/gz passwall2 ${PASSWALL_BASE}/packages-${rel_tag}/${arch}/passwall2
src/gz passwall_packages ${PASSWALL_BASE}/packages-${rel_tag}/${arch}/passwall_packages
EOM
}

opkg_update_safe() {
  opkg update || die "opkg update failed"
}

ensure_pkg() {
  pkg="$1"
  if opkg status "$pkg" >/dev/null 2>&1; then
    log "OK: $pkg already installed"
    return 0
  fi
  log "Installing: $pkg"
  opkg install "$pkg" || die "Failed to install: $pkg"
}

ensure_dnsmasq_full() {
  if opkg status dnsmasq-full >/dev/null 2>&1; then
    log "OK: dnsmasq-full already installed"
    return 0
  fi
  if opkg status dnsmasq >/dev/null 2>&1; then
    log "Switching dnsmasq -> dnsmasq-full"
    opkg remove dnsmasq || true
  fi
  ensure_pkg dnsmasq-full
}

ensure_passwall2_iran_shunt() {
  # Ensure base config exists
  if [ ! -f /etc/config/passwall2 ]; then
    /etc/init.d/passwall2 stop >/dev/null 2>&1 || true
    /etc/init.d/passwall2 start >/dev/null 2>&1 || true
  fi

  # Create/overwrite IRAN shunt rule section
  uci -q delete passwall2.IRAN || true
  uci set passwall2.IRAN='shunt_rules'
  uci set passwall2.IRAN.remarks='IRAN'
  uci set passwall2.IRAN.network='tcp,udp'

  # Domain list (tested safer baseline for Iran shunt)
  # - geosite:category-ir is the primary maintained bucket
  # - ext:iran.dat:ir and ext:iran.dat:other rely on /usr/share/v2ray/iran.dat if present
  uci set passwall2.IRAN.domain_list="geosite:category-ir
ext:iran.dat:ir
ext:iran.dat:other"

  # IP list
  uci set passwall2.IRAN.ip_list="geoip:ir
geoip:private"

  # Make Passwall2 use IRAN list as "china" selector (Passwall2 naming quirk)
  uci set passwall2.@global[0].china='IRAN'

  uci commit passwall2
}

main() {
  need_cmd opkg
  need_cmd uci

  rel_tag="$(detect_release_tag)"
  arch="$(detect_best_arch)"

  log "=== [$SCRIPT_NAME] Starting ==="
  log "Detected release tag: $rel_tag"
  log "Detected opkg arch:   $arch"

  log "=== Rewriting Passwall feeds (prevents wrong-arch downloads) ==="
  rewrite_passwall_feeds "$rel_tag" "$arch"

  log "=== Ensuring Passwall GPG key ==="
  ensure_passwall_key

  log "=== opkg update ==="
  opkg_update_safe

  log "=== Core deps ==="
  ensure_dnsmasq_full
  ensure_pkg kmod-nft-socket
  ensure_pkg kmod-nft-tproxy

  log "=== Passwall2 + required deps ==="
  # luci-app-passwall2 requires tcping and geoview on your build
  ensure_pkg tcping
  ensure_pkg geoview
  ensure_pkg xray-core
  ensure_pkg luci-app-passwall2

  log "=== Iran shunt rules (domain/ip) ==="
  ensure_passwall2_iran_shunt

  log "=== Enable service (do not force start) ==="
  /etc/init.d/passwall2 enable >/dev/null 2>&1 || true

  log "=== Verification ==="
  opkg status luci-app-passwall2 >/dev/null 2>&1 && log "OK: luci-app-passwall2 installed"
  opkg status xray-core >/dev/null 2>&1 && log "OK: xray-core installed"
  opkg status geoview >/dev/null 2>&1 && log "OK: geoview installed"
  opkg status tcping >/dev/null 2>&1 && log "OK: tcping installed"
  uci -q get passwall2.@global[0].china | grep -q '^IRAN$' && log "OK: passwall2 global china=IRAN"
  uci -q show passwall2.IRAN >/dev/null 2>&1 && log "OK: passwall2.IRAN shunt section exists"

  log "=== Done ==="
  log "Next: Configure your nodes in LuCI -> Services -> Passwall2, then enable Passwall2 global switch."
}

main "$@"
EOF
chmod +x /tmp/install_passwall2_iran.sh
sh /tmp/install_passwall2_iran.sh
