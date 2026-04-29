# Caddy on host networking + loopback-published app

This doc captures *why* the production deployment puts Caddy in the host
network namespace and reaches the app over loopback, and *exactly what*
that requires in the Quadlet units and the Caddyfile.

> Note: this file lives under `docs/` at the repo root. It is **not**
> part of the Astro site (`src/pages/` + the `blog` content collection
> are what get built and served). Do not move it under `src/`.

## Why

With Podman's default port-publish path (`PublishPort=80:80` on a
user-defined bridge), inbound packets are NAT'd by netavark before they
hit the container. Caddy then sees the bridge gateway as the source
address instead of the real client. That breaks two things we care about:

- **fail2ban / nftables bans** — the `nftables-multiport` action would
  populate the f2b set with the gateway's address, banning nothing
  useful.
- **Coraza's audit log** — every "blocked" entry would record the same
  internal address, so manual triage is impossible.

Switching Caddy to the host network namespace removes that NAT hop:
Caddy binds 80/443 directly on the host's interfaces and sees the real
client IP for both v4 and v6.

## What changed

### 1. `quadlet/dev-blog-caddy.container`

Caddy now lives in the host network namespace.

```diff
-Network=dev-blog.network
-NetworkAlias=caddy
-
-PublishPort=80:80
-PublishPort=443:443
-PublishPort=443:443/udp
-PublishPort=[::]:80:80
-PublishPort=[::]:443:443
-PublishPort=[::]:443:443/udp
+Network=host
```

`Network=host` is mutually exclusive with both `Network=dev-blog.network`
and any `PublishPort=` directives — Caddy binds 80/443 directly on the
host's interfaces, so the user-defined network and port-forwarding are
gone for this container. `CAP_NET_BIND_SERVICE` is still kept because
the container's non-root user still has to bind privileged ports.

### 2. `quadlet/dev-blog-app.container`

App stays on the user-defined network *and* publishes on host loopback
only.

```diff
-# Not exposed publicly – Caddy reverse-proxies in over the internal network.
-# PublishPort=4321:4321
+# Caddy now runs on the host network namespace, so it cannot reach the app
+# via podman DNS (`app:4321`). Publish the app port on the host's *loopback*
+# only -- it is reachable to Caddy on the host but not from outside.
+PublishPort=127.0.0.1:4321:4321
+PublishPort=[::1]:4321:4321
```

The app keeps `Network=dev-blog.network` (so it could still talk to
future sidecars on that bridge), but now also surfaces on
`127.0.0.1:4321` and `[::1]:4321`. nftables already accepts
`iif "lo" accept`, so loopback traffic is unfiltered.

### 3. `caddy/Caddyfile`

Reverse-proxy target updated.

```diff
-reverse_proxy app:4321 {
+reverse_proxy 127.0.0.1:4321 {
   header_up X-Real-IP        {remote_host}
   header_up X-Forwarded-Proto {scheme}
 }
```

`{remote_host}` is now the **real** client IP (v4 or v6) because Caddy
sees the connection unmodified, instead of the bridge gateway. That
value flows into the JSON access log (`"remote_ip"`) and Coraza's serial
audit log, which is exactly what the fail2ban filter keys on — so the
`nftables-multiport` action populates the right addresses in
`f2b-table` and bans actually work.

## Topology, before vs. after

**Before**

```
Internet ─┐
         (host nft) ─► podman PublishPort NAT ─► dev-blog (bridge, dual-stack)
                                                  ├─ caddy   (real IP lost)
                                                  └─ app     (Caddy → app:4321 via podman DNS)
```

**After**

```
Internet ─┐
         (host nft) ─► caddy in host netns (real client v4/v6 preserved)
                          │  reverse_proxy
                          ▼
                       127.0.0.1:4321 / [::1]:4321 (loopback publish)
                          │
                       dev-blog (bridge, dual-stack)
                          └─ app
```

## Things that did *not* need to change

- `dev-blog.network` — still a dual-stack bridge; the app still uses it
  (and any future sidecar can join it).
- `nftables.conf.j2` — already accepted `tcp dport { 22, 80, 443 }` and
  `udp dport { 443 }` in the `inet filter` table, plus
  `iif "lo" accept`, so both Caddy's public listeners and the loopback
  hop to the app are covered.
- fail2ban filter regexes, Coraza config, Ansible roles, Quadlet
  `[Install]` lines.

## Operational heads-up

- `compose.yaml` (local-dev convenience) was deliberately left alone —
  it still wires Caddy through the bridge with `PublishPort`, which is
  fine for local iteration where preserving real client IPs doesn't
  matter.
- If you ever add another container that Caddy needs to reach, follow
  the same pattern: have *that* container publish to `127.0.0.1:<port>`
  (and `[::1]:<port>` for v6) and reference it from the Caddyfile via
  loopback.
- Because the app's loopback publish is bound to `127.0.0.1` / `[::1]`
  only, it is **not** reachable from any other host on the network even
  if nftables were ever flushed — the kernel itself drops non-loopback
  traffic destined to those addresses.
