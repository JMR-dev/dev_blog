# Runbook: blog.jasonmross.dev

Everything here assumes `gcloud` is logged in as an owner of `dev-blog-494815`.
The `make` targets that touch the VM use IAP; nothing needs a public SSH port.

## How a change gets deployed

Push to `main` (via a PR). `.gitea/workflows/pipeline.yml` then:

1. builds and unit-tests the site and runs `make check` (Pulumi program
   build/vet/invariant tests, shellcheck) and `make check-alloy` (the Alloy
   config's format, validity and scrub rules), on every push; runs
   Playwright when the site, the browser tests or the pipeline changed;
2. if the Pulumi source changed (`infra/`, `vm/`): `pulumi up`, then a config
   sync on the VM;
3. if the site or the Caddy pins changed: builds the images, smoke-tests the
   site image as the quadlet runs it, and pushes `:prod` and `:<short-sha>` to
   Artifact Registry;
4. kicks `podman-auto-update` on the VM over IAP, fails unless both units
   then run the registry's `:prod` (a rollback or a failed pull leaves the old
   image serving), and waits up to 20 minutes for
   `https://blog.jasonmross.dev/` to answer -- and, when it built the site, to
   serve that build's marker at `/version.txt`.

Deploys key off **source** only. Test code (`src/tests/`, `*.test.ts`,
`e2e/`, `infra/*_test.go`), the pipeline itself, docs and tooling are tested
on the way through and deploy nothing. To redeploy everything on purpose, run
the pipeline by hand (`workflow_dispatch`).

PRs stop after step 1 and add a `pulumi preview`. Read it before merging and
look for `replace` on `blog-vm` (see below). Pushing again to a PR cancels its
run in progress; on `main`, runs queue instead.

| You changed | What applies it | Watch for |
|---|---|---|
| `src/` (not `src/tests/`), `public/`, Astro config, deps, `image/app/` | the pipeline: new site image | the image smoke test and the health gate |
| `image/caddy/`, `image/*.version` | the pipeline: new images | the Dockerfile asserts both Caddy plugins |
| `vm/**` (templates, quadlets, units, `bootstrap.sh`) | the pipeline: `pulumi up` + config sync | services restart only if a rendered file changed |
| `infra/**` (not `*_test.go`) | the pipeline: `pulumi up` | any `replace` on the instance or the data disk |
| `vm/startup.sh`, boot disk, zone, subnet | `pulumi up` **replaces the VM** | ~15 min down and a new TLS certificate; see below |
| `blog:wafMode` | the pipeline | the fail2ban WAF jail follows the mode |
| `blog:watchtowerPeerSecret`, `vm/config/config.alloy.tmpl`, `vm/quadlets/alloy*` | the pipeline: `pulumi up` (metadata, in place) + config sync | restarts only the tunnel and Alloy, never the site; the sync's last lines say whether Alloy is ready and the tunnel has a handshake |
| tests, `.gitea/workflows/`, docs, `scripts/`, `Makefile` | nothing is deployed | — |
| a secret value | `gcloud secrets versions add …`, then `make sync` | — |

## Everyday commands

```bash
make status    # units, containers, timers
make logs      # follow site + Caddy logs
make ssh       # shell on the VM
make sync      # re-render config from the bucket, restart what changed
make rollout   # pull the current :prod images now
make preview   # pulumi preview from a workstation (needs the login below)
```

Pulumi from a workstation:

```bash
gcloud auth application-default login
export PULUMI_CONFIG_PASSPHRASE=$(gcloud secrets versions access latest \
    --secret=pulumi-config-passphrase --project=dev-blog-494815)
cd infra && pulumi login gs://dev-blog-494815-pulumi-state && pulumi stack select prod
```

## Rolling back

Every build is pushed with its commit tag. The pipeline log prints the digests.

```bash
AR=us-east1-docker.pkg.dev/dev-blog-494815/blog
gcloud artifacts docker images list $AR/blog --include-tags --limit 10
gcloud artifacts docker tags add $AR/blog:<good-short-sha> $AR/blog:prod
make rollout
```

A `podman tag` on the host doesn't stick; the next auto-update undoes it. For a
bad commit, a revert on `main` is the durable fix.

## Before anything that replaces the VM

Read `pulumi preview` for `gcp:compute:Instance … replace`. Before applying one:

```bash
gcloud compute snapshots create blog-data-pre-$(date +%Y%m%d) \
  --source-disk=blog-data --source-disk-zone=us-east1-b --storage-location=us-east1
curl -s 'https://api.certspotter.com/v1/issuances?domain=blog.jasonmross.dev'   # < 5 this week?
```

Let's Encrypt allows five duplicate certificates a week, and the ACME state
lives on the boot disk.

## First-time setup (already done; for rebuilding from scratch)

1. `scripts/bootstrap.sh dev-blog-494815 us-east1`. It enables the APIs and
   creates:
   - the state bucket
   - the state passphrase
   - `gitea-deploy@`
   - the `blog` zone and its NS delegation from `public`
   - `blog-acme-email`
2. Set the ACME contact:
   `printf %s '<email>' | gcloud secrets versions add blog-acme-email --data-file=- --project=dev-blog-494815`.
3. `pulumi stack init prod` with the passphrase exported (see above), and
   commit the `encryptionsalt:` line it adds.
4. Create a key for `gitea-deploy@` and store it as the repository's Actions
   secret `GCP_SA_KEY` in Gitea. Then delete the local file.
5. Merge to `main`. The first run creates everything. The services crash-loop
   every 30s until the first images land; that is expected.

## Rotating the CI key

```bash
SA=gitea-deploy@dev-blog-494815.iam.gserviceaccount.com
gcloud iam service-accounts keys create key.json --iam-account=$SA
# replace GCP_SA_KEY in Gitea (repo Settings → Actions → Secrets), run the pipeline, then:
gcloud iam service-accounts keys list --iam-account=$SA
gcloud iam service-accounts keys delete <old-key-id> --iam-account=$SA
rm key.json
```

The key can do anything Pulumi can in this project, and every job on the
shared GKE runner could read it. Keep it to this one project and rotate it.
If Gitea gains Actions OIDC tokens
([go-gitea/gitea#33681](https://github.com/go-gitea/gitea/issues/33681)),
replace the key with Workload Identity Federation.

## WAF: DetectionOnly → On

The WAF starts by logging what it would block. After a week or two of
traffic:

```bash
make ssh
sudo journalctl CONTAINER_NAME=caddy --since '7 days ago' | grep 'Coraza: Warning' | less   # one line per rule match
sudo less /var/log/caddy/coraza-audit.log                                                 # whole requests; older days in .1, .2.gz, ...
```

The audit records stay on the VM, in a file rotated daily and kept for 14
days, never in the journal: they hold whole requests, cookies and bodies,
and the journal is shipped to watchtower.

Add exclusions (ids 1,000,000+) to `vm/config/Caddyfile.tmpl` for anything
legitimate. Then set `blog:wafMode: On` in `infra/Pulumi.prod.yaml` and merge.
That also enables the `caddy-coraza` fail2ban jail.

## Drills

Several controls fail silently and still show as healthy in `make status`.
Run these after the first deploy, and re-run the matching one after changing
its layer.

```bash
dig +short NS blog.jasonmross.dev           # the `blog` zone's name servers
dig +short A blog.jasonmross.dev            # the static IP (pulumi stack output address)
curl -sI https://blog.jasonmross.dev/       # 200, HSTS/nosniff/SAMEORIGIN/Referrer-Policy, no Server
curl -vI https://blog.jasonmross.dev 2>&1 | grep -i issuer     # Let's Encrypt

# WAF: 200 in DetectionOnly (403 in On), and a record either way
curl -s -o /dev/null -w '%{http_code}\n' 'https://blog.jasonmross.dev/?file=../../../../etc/passwd'

make ssh
sudo journalctl CONTAINER_NAME=caddy --since '5 min ago' | grep 930   # the LFI probe above
sudo tail -c 300 /var/log/caddy/coraza-audit.log                       # its audit record, in the file
sudo journalctl CONTAINER_NAME=caddy --since '5 min ago' | grep -c '"transaction"'   # 0: never in the journal
sudo journalctl -u caddy | grep -i challenge                           # dns-01, not http-01
cat /etc/blog/caddy-network                                            # bridge (or host)
sudo nft -f /etc/sysconfig/nftables.conf && curl -fsS -o /dev/null https://blog.jasonmross.dev/   # a reload must not break forwarding
sudo podman auto-update --dry-run                                      # both units, no auth error
sudo fail2ban-client set sshd banip 192.0.2.1 && sudo nft list ruleset | grep -A3 f2b && sudo fail2ban-client set sshd unbanip 192.0.2.1
free -m; swapon --show
curl -fsS http://127.0.0.1:2020/metrics | grep -c '^caddy_'             # Caddy's metrics, loopback only
curl -fsS http://127.0.0.1:12345/-/ready                               # Alloy
sudo wg show wg-watchtower latest-handshakes | awk '{print $2}'         # seconds since the epoch, not 0
```

From outside, `nc -zv -w5 <static-ip> 22` should time out, and so should
`nc -zv -w5 <static-ip> 2020` and `12345`.

## Telemetry (watchtower)

The VM ships its logs and metrics to watchtower, the owner's
Loki/Mimir/Tempo/Grafana on Hetzner. watchtower's
`docs/client-telemetry.md` (in `watchtower-observability-stack`) is the
contract; this deployment implements it:

- **The tunnel.** `blog-vm` is watchtower's agent peer `blog-vm`
  (10.8.0.134): a WireGuard interface `wg-watchtower`
  (`wg-quick@wg-watchtower`) that routes 10.8.0.0/24 and nothing else.
  `watchtower.jasonmross.dev` resolves to 10.8.0.1, inside it. The peer
  config is the secret `wireguard-blog-vm-peer` in project
  `watchtower-observe`, named by `blog:watchtowerPeerSecret` and read on the
  VM by `blog-vm@` only. `vm/bootstrap.sh` (`render_telemetry`) refuses it
  unless it is a split tunnel with no hooks, drops its DNS, and installs it
  at `/etc/wireguard/wg-watchtower.conf` (root, 0600). Nothing prints it.
- **Alloy** (`vm/quadlets/alloy.container`): v1.21.2, pinned by digest and
  never auto-updated; 192 MiB at most; its UI on `127.0.0.1:12345` only. It
  reads the persistent journal (every unit, the site and Caddy included)
  and scrubs it before anything leaves the host (`vm/config/config.alloy.tmpl`:
  IPs, Referer, the WAF's matched data, emails, credentials, OS Login
  names...), and scrapes the host, itself, Caddy's `127.0.0.1:2020` and a
  probe of the public site every 60 s. Everything is labelled
  `service=blog`, `host=blog-vm`, `env=production`.
- **Not the site.** The tunnel and Alloy restart only when their own
  config changed, never with the blog or Caddy, and an OOM kills Alloy, not
  the site.

### Changing it

- **Scrub rules:** edit `vm/config/config.alloy.tmpl` between the
  `// scrub:` markers, add made-up lines to `scripts/testdata/scrub.log`
  (`keep:`, `same:` or `drop:`) and what must never come out to
  `scrub.forbidden`, then `make check-alloy` (needs `alloy` v1.21.2 and
  `jq`). `SCRUB_SHOW=1 scripts/check-alloy-scrub.sh` prints what would ship.
- **Off:** remove `blog:watchtowerPeerSecret` from `infra/Pulumi.prod.yaml`
  and merge. The sync stops the tunnel and Alloy and removes their config.
  A missing, empty or refused secret does the same, with a warning in
  `journalctl -u blog-config-sync`; the site is never affected.
- **Rekeying:** delete the `blog-vm` client in wg-easy; watchtower's next
  deploy publishes a new config, and this VM picks it up on its next sync
  (`make sync`) or boot.
- **Alloy upgrades:** watchtower's contract pins the version. Change the
  tag and digest in `vm/quadlets/alloy.container` and the version and
  sha256 in the pipeline's infra-check job together.

### Checking it

In Grafana Explore, `Loki (jasonmross)` and `Mimir (jasonmross)`:

```
count by (job) (up{host="blog-vm"})                                    # integrations/unix, alloy, caddy, blackbox: all 1
sum by (unit, container) (count_over_time({host="blog-vm"}[15m]))     # logs flow
rate(prometheus_remote_storage_samples_failed_total{host="blog-vm"}[10m])   # 0
node_memory_MemAvailable_bytes{host="blog-vm"} / node_memory_MemTotal_bytes{host="blog-vm"}   # above 0.15 for 48 h
```

Over the first hour of real traffic, each of these must find nothing:

```
{host="blog-vm"} |~ "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"
{host="blog-vm"} |~ "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[a-z]{2,}"
{host="blog-vm"} |= "eyJ"
{host="blog-vm"} |= "\"transaction\""
{host="blog-vm"} |~ "(?i)\"(cookie|authorization)\""
{host="blog-vm"} |~ "_(gmail|googlemail)_com"
{host="blog-vm"} |~ "(?i)\"referr?er\":\\[\""
```

A hit means a rule is missing: add the line's shape to the fixture, fix the
rule, and merge before anything else.

**Memory.** An e2-micro has 1 GB. If `MemAvailable` dips under about 300 MB
with Alloy running, set `blog:machineType: e2-small` (in place: one stop
and start, about a minute down).

On the VM:

```bash
systemctl status alloy wg-quick@wg-watchtower --no-pager
journalctl -u alloy -n 50 --no-pager
sudo journalctl -u blog-config-sync -n 40 --no-pager | grep -i -e watchtower -e alloy
```
