#!/usr/bin/env bash
# Loads the real vm/nftables/host.nft in a throwaway network namespace and checks
# who can reach the metadata server's address: Alloy's uid only for DNS, every
# other uid for anything. Nothing on the host is touched: the ruleset, the
# address and the listeners all go with the namespace.
#
#   scripts/check-metadata-guard.sh [host.nft] [alloy.container]
#
# Where this user has subordinate uids (unshare --map-auto), the probes really
# run as uid 473, 1000 and root. Without them, as on a CI job pod, the namespace
# has root alone: the ruleset is checked as written (root gets through), then
# with the rule's uid changed to root's, so the rule is still seen to fire, and
# this says so.
#
# It can't show what a namespace doesn't have: the real metadata server, and a
# rootful podman container with Network=host. `make check-metadata-guard` runs
# it. Needs unshare, setpriv, nft, ip, python3 and envsubst.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ruleset="${1:-${repo_root}/vm/nftables/host.nft}"
quadlet="${2:-${repo_root}/vm/quadlets/alloy.container}"
metadata=169.254.169.254

fail() { echo "metadata guard: $*" >&2; exit 1; }

# A listener on each port, or a probe of one. The probe exits 0 only on a reply,
# so a UDP packet that goes nowhere isn't taken for one that got through.
probe_py='
import socket, sys, threading

def serve_tcp(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((sys.argv[2], port))
    s.listen()
    while True:
        c, _ = s.accept()
        c.sendall(b"ok")
        c.close()

def serve_udp(port):
    s = socket.socket(type=socket.SOCK_DGRAM)
    s.bind((sys.argv[2], port))
    while True:
        _, peer = s.recvfrom(16)
        s.sendto(b"ok", peer)

if sys.argv[1] == "serve":
    for port in (53, 80, 443):
        threading.Thread(target=serve_tcp, args=(port,), daemon=True).start()
    for port in (53, 123):
        threading.Thread(target=serve_udp, args=(port,), daemon=True).start()
    threading.Event().wait()

proto, port = sys.argv[3], int(sys.argv[4])
s = socket.socket(type=socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM)
s.settimeout(2)
try:
    # Not from the address itself: the reply, under root when that is the only
    # uid there is, would be going to the metadata address too.
    s.bind(("127.0.0.1", 0))
    s.connect((sys.argv[2], port))
    if proto == "udp":
        s.send(b"x")
    sys.exit(0 if s.recv(16) == b"ok" else 1)
except OSError:
    sys.exit(1)
'

bad=0
n=0
# probe <uid> <proto> <port> <reaches|refused>
probe() {
  local uid="$1" proto="$2" port="$3" want="$4" got=refused
  # Already that uid, nothing to change. With root alone mapped, setgroups is
  # denied, so setpriv would fail and read as a refusal.
  local become=(setpriv --reuid "$uid" --regid "$uid" --clear-groups)
  [[ "$uid" != "$(id -u)" ]] || become=()
  n=$((n + 1))
  if "${become[@]}" python3 -c "$probe_py" try "$metadata" "$proto" "$port" >/dev/null 2>&1; then
    got=reaches
  fi
  if [[ "$got" != "$want" ]]; then
    echo "uid ${uid} ${proto}/${port}: ${got}, wanted ${want}" >&2
    bad=1
  fi
}

# Inside the namespace, as its root. A separate run of this file, so the outside
# stays clean whatever goes wrong in here.
inside() {
  local rendered="$1" single_uid="$2"
  # Other uids may not be able to read where this was started.
  cd /
  ip link set lo up
  ip addr add "${metadata}/32" dev lo
  nft -f "$rendered"
  nft list chain inet blog_filter output >/dev/null || fail "no output chain after the load"

  # Alone in this namespace, so no one else's listener or port.
  python3 -c "$probe_py" serve "$metadata" &
  local server=$!
  # shellcheck disable=SC2064
  trap "kill ${server} 2>/dev/null" EXIT
  local _
  for _ in $(seq 40); do
    python3 -c "$probe_py" try "$metadata" tcp 80 && break
    sleep 0.1
  done

  # Whoever isn't Alloy goes anywhere.
  probe 0 tcp 80 reaches
  probe 0 tcp 443 reaches
  probe 0 tcp 53 reaches
  probe 0 udp 53 reaches
  probe 0 udp 123 reaches

  local alloy=473
  if ((single_uid)); then
    # Only root exists in here. The same file, with the rule aimed at root.
    sed 's/meta skuid 473 /meta skuid 0 /' "$rendered" >"${rendered}.root"
    grep -q 'meta skuid 0 ' "${rendered}.root" || fail "no skuid rule to aim at root"
    nft -f "${rendered}.root"
    alloy=0
  else
    # Caddy's uid on the host network, which needs the server for DNS-01.
    probe 1000 tcp 80 reaches
    probe 1000 tcp 443 reaches
  fi

  # Alloy: DNS through, and nothing else.
  probe "$alloy" tcp 53 reaches
  probe "$alloy" udp 53 reaches
  probe "$alloy" tcp 80 refused
  probe "$alloy" tcp 443 refused
  probe "$alloy" udp 123 refused

  ((bad == 0)) || exit 1
  # The refusals were the rule's, not a dead listener.
  nft list chain inet blog_filter output | grep -qE 'counter packets [1-9]' \
    || fail "the rule's counter never moved"
  echo "$n"
}

if [[ "${1:-}" == --inside ]]; then
  shift
  inside "$@"
  exit
fi

[[ -f "$ruleset" && -f "$quadlet" ]] || fail "need ${ruleset} and ${quadlet}"

# The rule is worth nothing if the uid moves and it doesn't.
quadlet_uid="$(sed -n 's/^User=//p' "$quadlet")"
[[ "$quadlet_uid" == 473 ]] || fail "alloy.container runs as ${quadlet_uid:-nobody}, the ruleset and this check as 473"
if grep -q '^UserNS=' "$quadlet"; then
  fail "alloy.container has a UserNS=, so its uid on the host isn't 473"
fi
grep -q '^Network=host$' "$quadlet" || fail "alloy.container isn't on the host network, so its packets never reach the output chain"
[[ "$(grep -c "meta skuid ${quadlet_uid} ip daddr ${metadata} " "$ruleset")" -eq 2 ]] \
  || fail "the ruleset should have two rules for uid ${quadlet_uid}"
if grep -E '^\s*[^#[:space:]].*\bip daddr 169\.254\.169\.254\b' "$ruleset" | grep -qv 'meta skuid 473'; then
  fail "a rule on the metadata server for everyone: Caddy needs it for DNS-01"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rendered="${work}/host.nft"
PODMAN_SUBNET=10.89.10.0/24 PODMAN_GATEWAY=10.89.10.1 \
  envsubst '${PODMAN_SUBNET} ${PODMAN_GATEWAY}' <"$ruleset" >"$rendered"

self="${BASH_SOURCE[0]}"
if unshare --user --map-auto --map-root-user --net true 2>/dev/null \
    && unshare --user --map-auto --map-root-user --net setpriv --reuid 473 --regid 473 --clear-groups true 2>/dev/null; then
  count="$(unshare --user --map-auto --map-root-user --net "$self" --inside "$rendered" 0)"
  echo "metadata guard: ${count} probes in a namespace as uids 473, 1000 and 0: all as they should be"
elif unshare --user --map-root-user --net true 2>/dev/null; then
  count="$(unshare --user --map-root-user --net "$self" --inside "$rendered" 1)"
  echo "metadata guard: ${count} probes in a namespace as root only (no subordinate uids here), the rule aimed at root: all as they should be"
else
  fail "can't make a user and network namespace here"
fi
