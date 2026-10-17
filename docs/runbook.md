# Runbook: blog.jasonmross.dev

Everything here assumes `gcloud` is logged in as an owner of `dev-blog-494815`.
The `make` targets that touch the VM use IAP; nothing needs a public SSH port.

## How a change gets deployed

Push to `main` (via a PR). `.gitea/workflows/pipeline.yml` then:

1. builds and unit-tests the site and runs `make check` (Pulumi program
   build/vet/invariant tests, shellcheck), on every push; runs Playwright when
   the site, the browser tests or the pipeline changed;
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
sudo journalctl CONTAINER_NAME=caddy --since '7 days ago' | grep '"transaction"' | less
```

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
sudo journalctl -u caddy | grep -i challenge                           # dns-01, not http-01
cat /etc/blog/caddy-network                                            # bridge (or host)
sudo nft -f /etc/sysconfig/nftables.conf && curl -fsS -o /dev/null https://blog.jasonmross.dev/   # a reload must not break forwarding
sudo podman auto-update --dry-run                                      # both units, no auth error
sudo fail2ban-client set sshd banip 192.0.2.1 && sudo nft list ruleset | grep -A3 f2b && sudo fail2ban-client set sshd unbanip 192.0.2.1
free -m; swapon --show
```

From outside, `nc -zv -w5 <static-ip> 22` should time out.
