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
