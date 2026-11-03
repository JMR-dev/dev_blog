#!/usr/bin/env bash
# Runs vm/bootstrap.sh's check_peer over made-up WireGuard configs: the shapes
# wg-easy publishes, and the ones wg and wg-quick would read differently from
# how they look. The config runs on the VM as root, so a shape that gets past
# check_peer can take the metadata server's route or run a command.
#
#   scripts/check-peer-config.sh [bootstrap.sh]
#
# The keys are dummies built here, so no key-shaped text sits in the repo.
# `make check-peer` runs it. Needs only awk and coreutils.

# Functions sourced from bootstrap.sh read many of the variables set below.
# shellcheck disable=SC2034

set -euo pipefail
# So `... | refuse` below runs in this shell, and its verdict counts.
shopt -s lastpipe

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${1:-${repo_root}/vm/bootstrap.sh}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Only the function: sourcing the file would run the bootstrap.
sed -n '/^check_peer() {$/,/^}$/p' "$script" >"${work}/check_peer.sh"
[[ -s "${work}/check_peer.sh" ]] || { echo "peer check: no check_peer in ${script}" >&2; exit 1; }
# shellcheck source=/dev/null
source "${work}/check_peer.sh"

# 32 bytes in base64, so wg would take them.
key() { printf "%032d" "$1" | base64; }
priv="$(key 1)" pub="$(key 2)" psk="$(key 3)"

# What wg-easy publishes for an agent peer, as `valid`; the others are this with
# something changed, through sed or printf.
valid() {
  printf '[Interface]\nPrivateKey = %s\nAddress = 10.8.0.134/32\nMTU = 1380\n\n' "$priv"
  printf '[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.8.0.0/24\n' "$pub" "$psk"
  printf 'PersistentKeepalive = 25\nEndpoint = wg.example.org:51820\n'
}
without() { valid | sed "/^$1 /d"; }
# awk, since sed's `a` would eat a blank at the start of the new line.
plus() { valid | KEY="$1" ADD="$2" awk '{ print } index($0, ENVIRON["KEY"]) == 1 { print ENVIRON["ADD"] }'; }
# Into [Interface], with bytes that won't go in an argument.
inside() { printf '[Interface]\n%b\n' "$1"; valid | sed 1d; }

bad=0
n=0
# A config comes in on stdin. Whatever the verdict, check_peer must print
# nothing, and a refusal must write nothing.
run() {
  cat >"${work}/in"
  : >"${work}/out"
  n=$((n + 1))
  if check_peer "${work}/in" "${work}/out" >"${work}/printed" 2>&1; then rc=0; else rc=1; fi
  if [[ -s "${work}/printed" ]]; then
    echo "printed something: $1"
    bad=1
  fi
}
accept() {
  run "$1"
  if ((rc)); then
    echo "refused: $1"
    bad=1
  fi
}
refuse() {
  run "$1"
  if ((!rc)); then
    echo "accepted: $1"
    bad=1
  elif [[ -s "${work}/out" ]]; then
    echo "refused but wrote: $1"
    bad=1
  fi
}
# Exactly this line in the output.
has() {
  if ! grep -qxF -- "$1" "${work}/out"; then
    echo "not in the output, after \"${2}\": ${1%% =*}"
    bad=1
  fi
}
hasnt() {
  if grep -qiE -- "$1" "${work}/out"; then
    echo "still in the output, after \"${2}\": $1"
    bad=1
  fi
}

valid | accept "wg-easy's config"
has "PrivateKey = ${priv}" "wg-easy's config"
has "PublicKey = ${pub}" "wg-easy's config"
has "PresharedKey = ${psk}" "wg-easy's config"
has "AllowedIPs = 10.8.0.0/24" "wg-easy's config"
cp "${work}/out" "${work}/normal"
accept "the normalised config, checked again" <"${work}/normal"
cmp -s "${work}/out" "${work}/normal" || { echo "the normalised config changed when checked again"; bad=1; }

# Normalised.
without MTU | accept "no MTU"
has "MTU = 1380" "no MTU"
without PersistentKeepalive | accept "no keepalive"
has "PersistentKeepalive = 25" "no keepalive"
without PresharedKey | accept "no preshared key"
hasnt '^PresharedKey' "no preshared key"
plus MTU 'DNS = 1.1.1.1, 8.8.8.8' | accept "a DNS line"
hasnt '^DNS' "a DNS line"
valid | sed 's/^MTU = 1380/MTU = 1280/' | accept "another MTU"
has "MTU = 1280" "another MTU"
valid | sed 's/^\[Interface\]/[INTERFACE]/; s/^\[Peer\]/[peer]/; s/^PrivateKey/PRIVATEKEY/; s/^AllowedIPs/allowedips/' | accept "keys in any case"
has "AllowedIPs = 10.8.0.0/24" "keys in any case"
has "[Peer]" "keys in any case"
has "PrivateKey = ${priv}" "keys in any case"
valid | sed 's/^Address = /# a comment\nAddress=/; s/^AllowedIPs = 10.8.0.0\/24/  Allowed IPs = 10.8.0.0\/24 # 0.0.0.0\/0/' | accept "blanks and comments"
has "AllowedIPs = 10.8.0.0/24" "blanks and comments"
hasnt '#' "blanks and comments"

# Too wide, by each way of writing it.
valid | sed 's#^AllowedIPs = .*#AllowedIPs = 0.0.0.0/0#' | refuse "a full tunnel"
valid | sed 's#^AllowedIPs = .*#AllowedIPs = 10.8.0.0/24, 0.0.0.0/0#' | refuse "a second route on the line"
plus AllowedIPs 'AllowedIPs = 0.0.0.0/0' | refuse "a second AllowedIPs"
plus AllowedIPs 'Allowed IPs = 0.0.0.0/0' | refuse "a second AllowedIPs, with a blank in the name"
plus AllowedIPs 'allowed	ips=169.254.169.254/32' | refuse "a second AllowedIPs, with a tab in the name"
plus Endpoint '[Peer]' | refuse "a second [Peer]"
plus Endpoint '[ Peer ]' | refuse "a second [Peer], with blanks in it"
plus Endpoint '[ pe er ]' | refuse "a second [Peer], split and in lower case"
plus MTU '[Interface]' | refuse "a second [Interface]"
without AllowedIPs | refuse "no AllowedIPs"
without Endpoint | refuse "no Endpoint"
valid | sed 's/^\[Peer\]//' | refuse "no [Peer]"
valid | sed 's/^\[Interface\]//' | refuse "no [Interface]"
{ valid | sed -n '/^\[Peer\]/,$p'; echo; valid | sed -n '1,/^MTU/p'; } | refuse "[Peer] before [Interface]"

# Hooks and settings, by each way of writing them.
for k in PreUp PostUp PreDown PostDown; do
  plus MTU "${k} = touch /tmp/owned" | refuse "${k}"
done
plus MTU 'Post Up = touch /tmp/owned' | refuse "PostUp with a blank in the name"
plus MTU 'POSTUP = touch /tmp/owned' | refuse "PostUp in capitals"
plus MTU 'Table = off' | refuse "Table"
plus MTU 'Fw Mark = 51820' | refuse "FwMark with a blank in the name"
plus MTU 'FwMark = 51820' | refuse "FwMark"
plus MTU 'SaveConfig = true' | refuse "SaveConfig"
plus MTU 'ListenPort = 51820' | refuse "a key on no list"
plus Endpoint 'PostUp = touch /tmp/owned' | refuse "a hook in [Peer]"
plus Endpoint 'DNS = 1.1.1.1' | refuse "DNS in [Peer]"
{ echo 'PostUp = touch /tmp/owned'; valid; } | refuse "a key before any section"
plus MTU 'not a setting' | refuse "a line with no ="

# Bytes that wg or bash's read would strip or read as a blank.
inside 'Post\0000Up = touch /tmp/owned' | refuse "NUL inside PostUp"
inside 'Tab\0000le = off' | refuse "NUL inside Table"
inside 'D\0000NS = 1.1.1.1' | refuse "NUL inside DNS"
inside '\fDNS = 1.1.1.1' | refuse "a form feed before DNS"
inside 'Post\vUp = touch /tmp/owned' | refuse "a vertical tab in PostUp"
inside 'Post\rUp = touch /tmp/owned' | refuse "a carriage return in PostUp"
valid | sed 's/$/\r/' | refuse "CRLF line ends"
inside 'Comment = caf\0303\0251' | refuse "a byte over 0x7e"

# Keys wg would print whole in its error.
valid | sed "s#^PrivateKey = .*#PrivateKey = ${priv}X#" | refuse "a private key one too long"
valid | sed "s#^PrivateKey = .*#PrivateKey = ${priv%=}#" | refuse "a private key with no ="
valid | sed "s#^PrivateKey = .*#PrivateKey = ${priv%??}!=#" | refuse "a private key with a bad character"
valid | sed "s#^PrivateKey = .*#PrivateKey = ${priv%??}B=#" | refuse "a private key whose last character decodes to too many bits"
valid | sed 's/^PublicKey = .*/PublicKey = x/' | refuse "a short public key"
valid | sed 's/^PresharedKey = .*/PresharedKey = x/' | refuse "a short preshared key"
without PrivateKey | refuse "no private key"
without PublicKey | refuse "no public key"
plus PrivateKey "PrivateKey = ${priv}" | refuse "a second private key"

# Addresses and the rest.
valid | sed 's#^Address = .*#Address = 10.8.0.5/32#' | refuse "an address under the agent half"
valid | sed 's#^Address = .*#Address = 169.254.169.254/32#' | refuse "the metadata server's address"
valid | sed 's#^Address = .*#Address = 10.8.0.134/24#' | refuse "an address with a wider mask"
valid | sed 's#^Address = .*#Address = 10.8.0.255/32#' | refuse "the tunnel's broadcast address"
valid | sed 's#^Address = .*#Address = 10.8.0.134/32, fd00::1/128#' | refuse "a second address"
plus Address 'Address = 10.8.0.135/32' | refuse "a second Address line"
without Address | refuse "no Address"
valid | sed 's/^MTU = .*/MTU = big/' | refuse "an MTU that is no number"
valid | sed 's/^PersistentKeepalive = .*/PersistentKeepalive = often/' | refuse "a keepalive that is no number"
valid | sed 's/^Endpoint = .*/Endpoint = $(id)/' | refuse "an endpoint that is no host and port"
valid | sed 's/^Endpoint = .*/Endpoint = [2001:db8::1]:51820/' | accept "an IPv6 endpoint"
has "Endpoint = [2001:db8::1]:51820" "an IPv6 endpoint"
: | refuse "an empty file"

((bad == 0)) || { echo "peer check: check_peer gets these wrong (above)" >&2; exit 1; }
echo "peer check: ${n} configs, all judged right"

# ---------------------------------------------------------------------------
# When telemetry stops: render_telemetry and its helpers, run against stubs. Only
# a missing or empty secret, or no metadata value, takes it down. Anything else
# warns and leaves it running.
# ---------------------------------------------------------------------------
for fn in meta_or_fail telemetry_off telemetry_leave fetch_peer render_telemetry; do
  sed -n "/^${fn}() {\$/,/^}\$/p" "$script" >"${work}/${fn}.sh"
  [[ -s "${work}/${fn}.sh" ]] || { echo "peer check: no ${fn} in ${script}" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "${work}/${fn}.sh"
done

# What those functions read, pointed into the scratch directory.
WG_IFACE=wg-watchtower
WG_DIR="${work}/wireguard"
WG_CONF="${WG_DIR}/wg-watchtower.conf"
ALLOY_CONF="${work}/alloy/config.alloy"
RENDER_DIR="${work}/quadlets"
STATE_DIR="${work}/state"
WATCHTOWER_PROJECT=watchtower-observe
WATCHTOWER_PEER_SECRET=wireguard-blog-vm-peer
PEER_META_READ=1
PEER_FETCH_ERROR=""
TELEMETRY_ON=0
JOURNAL_ACCESS_CHANGED=0

log() { echo "log: $*" >&2; }
warn() { echo "warn: $*" >&2; }
# Every action on a unit, to read back.
systemctl() { echo "systemctl $*" >>"${work}/calls"; }
restorecon() { :; }
rpm() { [[ "${WG_TOOLS:-yes}" == yes ]]; }
dnf() { return 1; }
getent() { [[ "${JOURNAL_GROUP:-yes}" == yes ]] && echo 'systemd-journal:x:190:'; }
render() { return 1; }
# Only render_telemetry's -d comes here, and -o root wouldn't work unprivileged.
install() { mkdir -p "${!#}"; }

# The server's answer: the value then the status, as curl's -w writes it.
curl() {
  case "$META" in
    set) printf 'wireguard-blog-vm-peer\n200' ;;
    empty) printf '\n200' ;;
    404) printf '<html>not found</html>\n404' ;;
    500) printf '<html>error</html>\n500' ;;
    503) printf '\n503' ;;
    down) return 7 ;;
  esac
}

# gcloud as it answers each case. fakeGCLOUD marks what may never be printed.
gcloud() {
  case "$SECRET" in
    good) valid ;;
    changed) valid | sed 's/^MTU = 1380/MTU = 1280/' ;;
    empty) ;;
    refused) valid | sed 's#^AllowedIPs = .*#AllowedIPs = 0.0.0.0/0#' ;;
    no-secret)
      echo 'ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret [projects/1/secrets/x] not found. fakeGCLOUD' >&2
      return 1
      ;;
    no-version)
      echo 'ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret Version [projects/1/secrets/x/versions/latest] not found. fakeGCLOUD' >&2
      return 1
      ;;
    denied)
      echo "ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: Permission 'secretmanager.versions.access' denied (or it may not exist). fakeGCLOUD" >&2
      return 1
      ;;
    5xx)
      echo 'ERROR: (gcloud.secrets.versions.access) UNAVAILABLE: The service is currently unavailable. fakeGCLOUD' >&2
      return 1
      ;;
    network)
      echo 'ERROR: gcloud crashed (ConnectionError): HTTPSConnectionPool: Max retries exceeded. fakeGCLOUD' >&2
      return 1
      ;;
    token)
      echo 'ERROR: (gcloud.secrets.versions.access) There was a problem refreshing your current auth tokens. fakeGCLOUD' >&2
      return 1
      ;;
  esac
}

# A host with telemetry running on the old config, or with none at all.
running() {
  rm -rf "$WG_DIR" "$RENDER_DIR" "$STATE_DIR" "${work}/alloy"
  mkdir -p "$WG_DIR" "$RENDER_DIR" "$STATE_DIR/config" "$STATE_DIR/quadlets" "${work}/alloy"
  echo old >"$WG_CONF"
  echo old >"$ALLOY_CONF"
  echo old >"${RENDER_DIR}/alloy.container"
  echo old >"${RENDER_DIR}/alloy-data.volume"
  : >"${work}/calls"
}
fresh() {
  running
  rm -f "$WG_CONF" "$ALLOY_CONF" "${RENDER_DIR}"/alloy*
}
# As bootstrap.sh runs it: under set -e, and not in a condition, which would
# switch that off.
go() {
  n=$((n + 1))
  set +e
  (
    set -e
    render_telemetry
    echo "$TELEMETRY_ON" >"${work}/telemetry_on"
  ) >"${work}/printed" 2>&1
  rc=$?
  set -e
  if ((rc)); then
    echo "render_telemetry failed the bootstrap: $1"
    bad=1
  fi
  if grep -q -e fakeGCLOUD -e "$priv" -e "$pub" -e "$psk" "${work}/printed"; then
    echo "printed gcloud's error or a key: $1"
    bad=1
  fi
  if compgen -G "${WG_DIR}/.peer-*" >/dev/null; then
    echo "left a temporary file behind: $1"
    bad=1
  fi
}
says() {
  if ! grep -qF -- "$1" "${work}/printed"; then
    echo "didn't say \"${1}\": $2"
    bad=1
  fi
}
torn_down() {
  go "$1"
  if [[ -e "$WG_CONF" || -e "$ALLOY_CONF" || -e "${RENDER_DIR}/alloy.container" ]]; then
    echo "left config behind: $1"
    bad=1
  fi
  if ! grep -q "disable --now wg-quick@${WG_IFACE}" "${work}/calls" || ! grep -q 'stop alloy.service' "${work}/calls"; then
    echo "didn't stop them: $1"
    bad=1
  fi
  if [[ "$(cat "${work}/telemetry_on")" != 0 ]]; then
    echo "the deploy check would run: $1"
    bad=1
  fi
}
# Nothing touched: the old config in place, and no unit stopped or restarted.
left_alone() {
  go "$1"
  if [[ "$(cat "$WG_CONF")" != old || "$(cat "$ALLOY_CONF")" != old || "$(cat "${RENDER_DIR}/alloy.container")" != old ]]; then
    echo "changed the config: $1"
    bad=1
  fi
  if [[ -s "${work}/calls" ]]; then
    echo "touched a unit: $1: $(cat "${work}/calls")"
    bad=1
  fi
  if [[ "$(cat "${work}/telemetry_on")" != 1 ]]; then
    echo "the deploy check wouldn't run: $1"
    bad=1
  fi
  says "left as it is" "$1"
}

# The metadata read, on its own: a value, not set, or could not ask.
meta_case() {
  local want_rc="$1" want_value="$2" got got_rc=0
  META="$3"
  got="$(meta_or_fail watchtower-peer-secret)" || got_rc=$?
  n=$((n + 1))
  if [[ "$got_rc" != "$want_rc" || "$got" != "$want_value" ]]; then
    echo "metadata answering ${META}: rc ${got_rc}, value \"${got}\""
    bad=1
  fi
}
meta_case 0 wireguard-blog-vm-peer set
meta_case 0 "" empty
meta_case 0 "" 404
meta_case 1 "" 500
meta_case 1 "" 503
meta_case 1 "" down

# No peer: down it comes.
SECRET=good
WATCHTOWER_PEER_SECRET=""
running
torn_down "no metadata value"
says "no watchtower-peer-secret metadata" "no metadata value"
fresh
go "no metadata value, nothing running"
says "log: watchtower telemetry off" "no metadata value, nothing running"
[[ ! -s "${work}/calls" ]] || { echo "touched a unit with nothing running"; bad=1; }
WATCHTOWER_PEER_SECRET=wireguard-blog-vm-peer
for SECRET in no-secret no-version empty; do
  running
  torn_down "secret: ${SECRET}"
  says "is missing or empty" "secret: ${SECRET}"
done

# Anything else: left running, with a warning.
for SECRET in denied 5xx network token; do
  running
  left_alone "secret: ${SECRET}"
done
says "a network, API or credentials error" "secret: token"
SECRET=denied
running
left_alone "secret: denied, again"
says "permission denied" "secret: denied"
SECRET=refused
running
left_alone "a refused config"
says "refused" "a refused config"

# A failed metadata read isn't no peer, even though the name is empty.
SECRET=no-secret
WATCHTOWER_PEER_SECRET=""
PEER_META_READ=0
running
left_alone "the metadata server not answering"
PEER_META_READ=1
WATCHTOWER_PEER_SECRET=wireguard-blog-vm-peer

SECRET=good
WG_TOOLS=no
running
left_alone "wireguard-tools not installable"
WG_TOOLS=yes
JOURNAL_GROUP=no
running
left_alone "no systemd-journal group"
JOURNAL_GROUP=yes

# Nothing there yet, and a failure: nothing to start, no deploy check to wait on.
SECRET=denied
fresh
go "a failure with no config yet"
says "left as it is" "a failure with no config yet"
if [[ -s "${work}/calls" || -e "$WG_CONF" || "$(cat "${work}/telemetry_on")" != 0 ]]; then
  echo "acted on a failure with no config yet"
  bad=1
fi

# And when it works: a new config restarts the tunnel, an unchanged one doesn't.
SECRET=good
fresh
go "a first config"
grep -qxF "PrivateKey = ${priv}" "$WG_CONF" || { echo "a first config wasn't installed"; bad=1; }
grep -q "restart wg-quick@${WG_IFACE}" "${work}/calls" || { echo "a first config didn't restart the tunnel"; bad=1; }
grep -q 'restart alloy.service' "${work}/calls" || { echo "a first config didn't restart Alloy"; bad=1; }
[[ "$(cat "${work}/telemetry_on")" == 1 ]] || { echo "a first config: the deploy check wouldn't run"; bad=1; }
: >"${work}/calls"
go "the same config again"
grep -q "restart" "${work}/calls" && { echo "the same config restarted something"; bad=1; }
grep -q "start wg-quick@${WG_IFACE}" "${work}/calls" || { echo "the same config didn't start the tunnel"; bad=1; }
# A repaired journal: Alloy has to reopen it, and the tunnel has no reason to drop.
JOURNAL_ACCESS_CHANGED=1
: >"${work}/calls"
go "the same config, with the journal's access just repaired"
grep -q "restart alloy.service" "${work}/calls" || { echo "repaired journal access didn't restart Alloy"; bad=1; }
grep -q "restart wg-quick@${WG_IFACE}" "${work}/calls" && { echo "repaired journal access restarted the tunnel"; bad=1; }
JOURNAL_ACCESS_CHANGED=0
SECRET=changed
: >"${work}/calls"
go "a changed config"
grep -qxF "MTU = 1280" "$WG_CONF" || { echo "a changed config wasn't installed"; bad=1; }
grep -q "restart wg-quick@${WG_IFACE}" "${work}/calls" || { echo "a changed config didn't restart the tunnel"; bad=1; }

((bad == 0)) || { echo "peer check: render_telemetry gets these wrong (above)" >&2; exit 1; }
echo "peer check: ${n} checks in all, telemetry stops only when it should"
