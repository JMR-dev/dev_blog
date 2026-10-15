# Network path

How a request reaches the site, and what filters it on the way. This file is
not part of the Astro site; it lives under `docs/`, not `src/`.

```
Internet
   │
   ▼  VPC firewall (infra/pkg/network): tcp 80/443 + udp 443 from anywhere,
   │  tcp 22 from the IAP range (35.235.240.0/20) only
   ▼
blog-vm  (static IP, A record in the `blog` zone)
   │
   ▼  nftables, one `inet` table (vm/nftables/host.nft); fail2ban bans are
   │  dropped at PREROUTING, before netavark's DNAT
   ▼
Caddy  :80/:443   TLS (DNS-01), Coraza WAF + CRS, security headers
   │   reverse_proxy blog:8080 (bridge) or 127.0.0.1:8080 (host network)
   ▼
site container :8080  static files, read-only, uid 1000
```

## Bridge or host network for Caddy

Caddy normally runs on the pinned `blog` bridge (`10.89.10.0/24`) and
publishes 80/443. Rootful netavark forwards with DNAT, which rewrites only the
destination, so Caddy still sees the real client address.

The DNS-01 plugin needs the GCE metadata server for credentials. On first
sync, `vm/bootstrap.sh` (`probe_caddy_network`) checks whether a container on
the bridge can reach it. If it cannot, Caddy is rendered with `Network=host`
and proxies to the site's loopback publish instead. The result is cached in
`/etc/blog/caddy-network`.

## Why bans happen at PREROUTING

Traffic to a published container port is DNAT'd in PREROUTING and then
forwarded; it never traverses the INPUT hook. A fail2ban action that adds
INPUT rules reports a ban while the traffic keeps flowing. The
`nft-prerouting` action (`vm/fail2ban/action.d/`) drops by source address
before the DNAT, which covers both Caddy modes.

## Never flush the ruleset

Load changes with `nft -f`. `systemctl reload|restart nftables` flushes every
table on EL, including netavark's, which silently drops the container port
forwards until the containers restart. `vm/bootstrap.sh` already does it the
safe way on each sync.

## Admin access

There is no public SSH. `make ssh` runs
`gcloud compute ssh blog-vm --tunnel-through-iap`, which needs
`roles/iap.tunnelResourceAccessor` and an OS Login role. fail2ban never bans
loopback, the podman bridge or the IAP range, so a lock-out can't cut off the
way back in.
