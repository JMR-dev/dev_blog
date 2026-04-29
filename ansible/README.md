# Ansible — dev_blog production host

Provisions the AlmaLinux 10 instance created by `infra/` (Vultr) so it can
run the Podman-managed `dev-blog-app` + `dev-blog-caddy` stack with:

- **Automatic security updates** via `dnf-automatic` (`upgrade_type=security`,
  `apply_updates=yes`, `reboot=never`) plus a separate `auto-reboot.timer`
  that fires daily at **02:00 America/Chicago** and reboots only when
  `dnf needs-restarting -r` says one is pending.
- **nftables** as the host firewall (allow `22/80/443/tcp` + `443/udp`,
  rate-limited new SSH, `policy drop` everywhere else; firewalld masked).
- **fail2ban** with the `nftables-multiport` banaction, watching the SSH
  journal and the Caddy / Coraza logs.
- **Podman + runtime deps** (`crun`, `netavark`, `aardvark-dns`,
  `slirp4netns`, `fuse-overlayfs`, `passt`, `container-selinux`, `skopeo`,
  `buildah`) and the Quadlet units from `../quadlet/` (with the `Image=`
  lines rewritten to point at GHCR).
- **GHCR auth** via the `gh` CLI: a PAT (`ghcr_pat`) is used to authenticate
  both `gh` and `podman` against `ghcr.io`, and the app/caddy images are
  pulled before the Quadlet units start.

## Coraza → fail2ban → nftables wiring

```
[ Caddy + Coraza container ]
        │  writes to /var/log/caddy (bind-mounted from host)
        ▼
   /var/log/caddy/access.log         (Caddy JSON access log – status=403 lines)
   /var/log/caddy/coraza-audit.log   (Coraza serial audit log – any --A-- entry)
        │  tailed by
        ▼
[ fail2ban  jail: caddy-coraza ]
        │  banaction = nftables-multiport
        ▼
[ nftables  table f2b-table / set addr-set-caddy-coraza ]   →   packets dropped
```

Three repo files were updated to enable that wiring:

- `quadlet/dev-blog-caddy.container` — adds `Volume=/var/log/caddy:/var/log/caddy:Z`.
- `caddy/Caddyfile` — sends access logs to `/var/log/caddy/access.log` (JSON).
- `caddy/coraza.conf` — enables `SecAuditLog` (serial) at
  `/var/log/caddy/coraza-audit.log`, only on relevant 4xx/5xx.

The fail2ban filter (`roles/fail2ban/files/caddy-coraza.filter`) matches
either `"remote_ip":"…","status":403` lines from the access log or
`--xxxx-A--` headers in the audit log. Either pattern produces a hit on
`<HOST>`, so once a client crosses `maxretry` within `findtime`, fail2ban
drops it into the `f2b-table` nft set for `bantime`.

## Usage

```sh
cd ansible
cp inventory.yml.example inventory.yml   # set ansible_host = your Vultr IP

# Quick connectivity / fact gathering:
ansible -m ping blog

# Full provision:
ansible-playbook site.yml

# Just one role:
ansible-playbook site.yml --tags fail2ban   # (add `tags:` to roles if needed)
```

## Tunables (group_vars/all.yml)

| Var                            | Default        | Notes                           |
| ------------------------------ | -------------- | ------------------------------- |
| `ssh_port`                     | `22`           |                                 |
| `http_port` / `https_port`     | `80` / `443`   |                                 |
| `caddy_log_dir`                | `/var/log/caddy` | host path bind-mounted into Caddy |
| `dnf_automatic_apply_updates`  | `true`         |                                 |
| `dnf_automatic_upgrade_type`   | `security`     | `default` for full updates      |
| `f2b_findtime` / `f2b_bantime` / `f2b_maxretry` | `10m / 1h / 5` | Caddy/Coraza jail thresholds |
| `ghcr_owner` / `ghcr_repo`     | `OWNER / dev_blog` | GHCR namespace               |
| `image_tag`                    | `latest`       | Tag to pull (CI sets to commit SHA) |

## Notes

- Don't enable both `firewalld` and the `nftables` service — this playbook
  masks `firewalld`. Podman's `netavark` writes to its own nft tables and
  doesn't conflict.
- The `synchronize` task uses `ansible.posix.synchronize`. Install
  `ansible-galaxy collection install ansible.posix` once on the controller.
- After first run, verify with:
  - `systemctl status dnf-automatic.timer nftables fail2ban`
  - `nft list ruleset`
  - `fail2ban-client status caddy-coraza`
