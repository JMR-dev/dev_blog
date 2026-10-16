#!/usr/bin/env bash
#
# blog VM bootstrap. Installed as /usr/local/sbin/blog-bootstrap: exec'd by
# vm/startup.sh on every boot, and re-run by blog-config-sync.service with
# --sync-only after a config push.
#
# MUST be idempotent: it runs on every boot, and on every sync.
#
#   (no args)     full run -- packages, disk, SELinux, firewall, units, config
#   --sync-only   re-pull vm/ from GCS, re-render templates, restart what changed
#
set -euo pipefail

readonly STATE_DIR=/opt/blog-config
readonly RENDER_DIR=/etc/containers/systemd
readonly INSTALLED=/usr/local/sbin/blog-bootstrap
readonly DATA_DIR=/var/lib/blog
readonly LOG_TAG=blog-bootstrap

log()  { echo "[${LOG_TAG}] $*" >&2; }
die()  { echo "[${LOG_TAG}] FATAL: $*" >&2; exit 1; }
warn() { echo "[${LOG_TAG}] WARN: $*" >&2; }

MODE=full
[[ "${1:-}" == "--sync-only" ]] && MODE=sync

# ---------------------------------------------------------------------------
# Instance metadata (populated by Pulumi, infra/pkg/compute)
# ---------------------------------------------------------------------------
meta() {
    curl -fsS -H 'Metadata-Flavor: Google' \
        "http://169.254.169.254/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || true
}

CONFIG_BUCKET=$(meta config-bucket)
BACKUP_BUCKET=$(meta backup-bucket)
GCP_PROJECT=$(meta gcp-project)
AR_HOST=$(meta ar-host)
IMAGE_APP=$(meta image-app)
IMAGE_CADDY=$(meta image-caddy)
DOMAIN=$(meta domain)
APP_PORT=$(meta app-port)
HEALTH_PATH=$(meta health-path)
APP_DATA_PATH=$(meta app-data-path)
PODMAN_SUBNET=$(meta podman-subnet)
PODMAN_GATEWAY=$(meta podman-gateway)
WAF_MODE=$(meta waf-mode)
DATA_DISK_DEVICE=$(meta data-disk-device)
SECRET_NAMES=$(meta secret-names)

[[ -n "${CONFIG_BUCKET}" ]] || die "config-bucket metadata is missing; nothing to sync from"
[[ -n "${DOMAIN}"        ]] || die "domain metadata is missing"
: "${APP_PORT:=8080}"
: "${HEALTH_PATH:=/healthz}"
: "${APP_DATA_PATH:=/data}"
# DetectionOnly is the safe default: run it, read what it flags, add
# exclusions, then switch to On.
: "${WAF_MODE:=DetectionOnly}"
case "${WAF_MODE}" in
    On|DetectionOnly|Off) ;;
    *) die "waf-mode must be On, DetectionOnly, or Off (got: ${WAF_MODE})" ;;
esac
: "${DATA_DISK_DEVICE:=/dev/disk/by-id/google-blog-data}"

export GCP_PROJECT AR_HOST IMAGE_APP IMAGE_CADDY DOMAIN APP_PORT HEALTH_PATH APP_DATA_PATH
export PODMAN_SUBNET PODMAN_GATEWAY WAF_MODE

# ---------------------------------------------------------------------------
# Self-update
# ---------------------------------------------------------------------------
# Pulls vm/ from the bucket, and if this script itself changed, installs the new
# copy and re-executes it -- so a sync always runs the logic that matches the
# templates it just pulled. Without the exec, bash keeps running the functions
# it already parsed, and the first sync after a bootstrap.sh change renders the
# NEW templates with the OLD logic (unsubstituted ${VARS} in a quadlet, a
# missing envsubst variable in a jail file).
#
# The replace is an atomic rename onto a fresh inode, never an in-place copy:
# bash reads scripts incrementally, and truncating the file it is executing can
# rewrite its input mid-run.
sync_config() {
    log "syncing configuration from gs://${CONFIG_BUCKET}/vm/"
    mkdir -p "${STATE_DIR}"
    gcloud storage rsync --recursive --delete-unmatched-destination-objects \
        "gs://${CONFIG_BUCKET}/vm" "${STATE_DIR}" \
        || die "config sync failed"
}

self_update() {
    if cmp -s "${STATE_DIR}/bootstrap.sh" "${INSTALLED}"; then
        return 0
    fi
    install -m 0755 "${STATE_DIR}/bootstrap.sh" "${INSTALLED}.new"
    mv -f "${INSTALLED}.new" "${INSTALLED}"
    log "updated ${INSTALLED}"
    # The guard stops a loop if the bucket copy changes again mid-run.
    if [[ -z "${BLOG_BOOTSTRAP_REEXEC:-}" ]]; then
        log "re-executing the updated script"
        BLOG_BOOTSTRAP_REEXEC=1 exec "${INSTALLED}" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
install_packages() {
    log "installing packages"
    dnf -y install \
        podman container-selinux \
        nftables \
        jq gettext \
        policycoreutils-python-utils \
        xfsprogs

    # fail2ban lives in EPEL on RHEL-family distros. The exact package set has
    # shifted between EPEL releases, so probe rather than assume.
    if ! rpm -q epel-release >/dev/null 2>&1; then
        dnf -y install epel-release || warn "epel-release unavailable; fail2ban will be skipped"
    fi
    if dnf -y install fail2ban fail2ban-server 2>/dev/null; then
        # The systemd journal backend needs the Python bindings; without them
        # fail2ban silently falls back and matches nothing.
        dnf -y install python3-systemd || warn "python3-systemd missing; the systemd backend may not work"
    else
        warn "fail2ban not installable from configured repos -- skipping fail2ban setup"
    fi
}

# ---------------------------------------------------------------------------
# Data disk
# ---------------------------------------------------------------------------
setup_data_disk() {
    log "configuring data disk ${DATA_DISK_DEVICE}"
    [[ -e "${DATA_DISK_DEVICE}" ]] || die "data disk ${DATA_DISK_DEVICE} not present"

    if ! blkid "${DATA_DISK_DEVICE}" >/dev/null 2>&1; then
        log "disk is unformatted -- creating XFS filesystem"
        mkfs.xfs -q "${DATA_DISK_DEVICE}"
    fi

    local uuid
    uuid=$(blkid -s UUID -o value "${DATA_DISK_DEVICE}")
    [[ -n "${uuid}" ]] || die "could not read UUID from ${DATA_DISK_DEVICE}"

    mkdir -p "${DATA_DIR}"

    # By UUID, never by device path: GCE can reorder /dev/sdX across reboots.
    if ! grep -q "UUID=${uuid}" /etc/fstab; then
        log "adding fstab entry for ${uuid}"
        printf 'UUID=%s %s xfs defaults,nofail,x-systemd.device-timeout=30 0 2\n' \
            "${uuid}" "${DATA_DIR}" >> /etc/fstab
    fi

    systemctl daemon-reload
    mountpoint -q "${DATA_DIR}" || mount "${DATA_DIR}"
    mountpoint -q "${DATA_DIR}" || die "${DATA_DIR} failed to mount"

    # Set the SELinux label persistently ONCE, rather than putting :Z on the
    # quadlet's volume line. :Z would force a recursive relabel of the entire
    # data tree on every container start.
    if ! semanage fcontext -l 2>/dev/null | grep -q "^${DATA_DIR}(/\\.\\*)?"; then
        log "setting persistent SELinux fcontext on ${DATA_DIR}"
        semanage fcontext -a -t container_file_t "${DATA_DIR}(/.*)?" || \
            warn "semanage fcontext failed; check SELinux state"
    fi
    restorecon -RF "${DATA_DIR}" || warn "restorecon failed"

    # The mount point itself must belong to the container's uid (1000 -- the
    # image contract), not just its subdirectories. A root-owned 0755 mount
    # point makes the app's first mkdir fail with a bare "permission denied"
    # that reads like an SELinux problem.
    chown 1000:1000 "${DATA_DIR}"
    chmod 0750 "${DATA_DIR}"
}

# ---------------------------------------------------------------------------
# Swap
# ---------------------------------------------------------------------------
# GCE instances ship with no swap. On a 2 GB machine a burst (a large upload, a
# compaction, a migration) can push the app past physical memory, and the OOM
# killer picks a victim mid-request.
#
# This is ballast, not working memory -- hence the low swappiness. If the box is
# swapping steadily, the answer is a bigger machine type, not more swap.
setup_swap() {
    local swapfile=/swapfile size_mb=2048

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${swapfile}"; then
        log "swap already active"
    else
        if [[ ! -f "${swapfile}" ]]; then
            log "creating ${size_mb}MB swap file"
            # dd, not fallocate: a fallocated file can carry unwritten extents
            # that mkswap accepts and the kernel then refuses to swap to.
            dd if=/dev/zero of="${swapfile}" bs=1M count="${size_mb}" status=none
            chmod 0600 "${swapfile}"
            mkswap "${swapfile}" >/dev/null
        fi
        swapon "${swapfile}" || warn "swapon failed"
    fi

    grep -q "^${swapfile} " /etc/fstab \
        || printf '%s none swap sw 0 0\n' "${swapfile}" >> /etc/fstab

    echo 'vm.swappiness = 10' > /etc/sysctl.d/90-blog-swappiness.conf
    sysctl -q -p /etc/sysctl.d/90-blog-swappiness.conf || warn "could not apply swappiness"
}

# ---------------------------------------------------------------------------
# Podman / netavark
# ---------------------------------------------------------------------------
configure_podman() {
    log "configuring podman firewall driver"
    mkdir -p /etc/containers/containers.conf.d
    # Netavark keeps its rules in a dedicated `netavark` nftables table, which is
    # what makes coexistence with our own table workable. Changing this with
    # containers running leaves conflicting rules behind -- it is set here,
    # before anything starts, and a reboot is the fix if it is ever changed on a
    # live host.
    cat > /etc/containers/containers.conf.d/10-blog.conf <<'EOF'
[network]
firewall_driver = "nftables"
EOF
}

# ---------------------------------------------------------------------------
# Host firewall
# ---------------------------------------------------------------------------
# Runs on every invocation so a pushed vm/nftables/host.nft change applies
# without waiting for a reboot.
setup_nftables() {
    log "installing nftables ruleset"
    # firewalld and a hand-managed ruleset will fight. Pick one.
    systemctl disable --now firewalld >/dev/null 2>&1 || true
    systemctl mask firewalld >/dev/null 2>&1 || true

    [[ -n "${PODMAN_SUBNET}" && -n "${PODMAN_GATEWAY}" ]] \
        || die "podman-subnet/podman-gateway metadata missing; cannot render the ruleset"

    # Validate BEFORE installing. A ruleset that fails to parse must never land
    # in /etc/sysconfig: nftables.service would fail to load it on the next boot
    # and the host would come up with no blog_filter table at all.
    local tmp
    tmp=$(mktemp)
    envsubst '${PODMAN_SUBNET} ${PODMAN_GATEWAY}' < "${STATE_DIR}/nftables/host.nft" > "${tmp}"
    if ! nft -c -f "${tmp}"; then
        rm -f "${tmp}"
        die "nftables ruleset failed validation"
    fi
    install -m 0600 "${tmp}" /etc/sysconfig/nftables.conf
    rm -f "${tmp}"
    systemctl enable --now nftables
    # NOT `systemctl reload nftables`: on EL the unit's ExecReload is
    # `nft 'flush ruleset; include ...'`, which wipes netavark's DNAT rules and
    # fail2ban's ban table along with ours. Every container not restarted
    # afterwards silently loses its published ports -- TCP still connects (into
    # the port reservation conmon holds) and then nothing ever answers. The
    # file replaces exactly one table (create-then-delete), so loading it
    # directly IS the reload. For the same reason, never `restart` or `stop` the
    # unit either: its ExecStop is a bare `flush ruleset`.
    nft -f /etc/sysconfig/nftables.conf

    # If this fails, the ruleset flushed something it should not have.
    nft list table inet blog_filter >/dev/null || die "blog_filter table missing after load"
}

# ---------------------------------------------------------------------------
# Artifact Registry credentials for root podman
# ---------------------------------------------------------------------------
install_ar_auth() {
    log "installing Artifact Registry auth refresher"
    cat > /usr/local/bin/blog-ar-auth <<'EOF'
#!/usr/bin/env bash
# Writes a docker-format auth file for Artifact Registry using the VM service
# account's metadata token.
#
# podman-auto-update.service runs as root with no interactive gcloud session, so
# it needs a credential sitting on disk. A stale or missing one is the most
# common reason auto-update quietly stops working on GCE.
set -euo pipefail

AR_HOST=$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://169.254.169.254/computeMetadata/v1/instance/attributes/ar-host)
TOKEN=$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token \
    | jq -r .access_token)

[[ -n "${TOKEN}" && "${TOKEN}" != "null" ]] || { echo "no access token from metadata server" >&2; exit 1; }

AUTH=$(printf 'oauth2accesstoken:%s' "${TOKEN}" | base64 -w0)
umask 077
tmp=$(mktemp /etc/containers/.ar-auth.XXXXXX)
jq -n --arg host "${AR_HOST}" --arg auth "${AUTH}" \
    '{auths: {($host): {auth: $auth}}}' > "${tmp}"
chmod 0600 "${tmp}"
mv "${tmp}" /etc/containers/ar-auth.json
EOF
    chmod 0755 /usr/local/bin/blog-ar-auth
    /usr/local/bin/blog-ar-auth || warn "initial AR auth refresh failed"
}

# ---------------------------------------------------------------------------
# Helper scripts
# ---------------------------------------------------------------------------
install_helpers() {
    log "installing helper scripts"

    cat > /usr/local/bin/blog-backup <<EOF
#!/usr/bin/env bash
# Streams the app's own dump (vm/hooks/backup.sh) to Cloud Storage.
#
# Complements the PD snapshot schedule rather than replacing it: a snapshot only
# restores this disk, and is crash-consistent at best; an application dump
# restores onto any host.
#
# The VM may only CREATE objects in the backup bucket (no read, no delete), so a
# failed stream cannot be cleaned up. Instead, a dump counts only once its .ok
# marker exists -- restore from dumps that have one.
set -euo pipefail
BUCKET="${BACKUP_BUCKET}"
HOOK="${STATE_DIR}/hooks/backup.sh"
[[ -n "\${BUCKET}" ]] || { echo "no backup bucket configured" >&2; exit 0; }
if [[ ! -f "\${HOOK}" ]]; then
    echo "no vm/hooks/backup.sh -- relying on PD snapshots alone" >&2
    exit 0
fi
stamp=\$(date -u +%Y%m%dT%H%M%SZ)
obj="gs://\${BUCKET}/dumps/blog-\${stamp}.dump"
bash "\${HOOK}" | gcloud storage cp - "\${obj}"
printf '%s\n' "\${stamp}" | gcloud storage cp - "\${obj}.ok"
echo "backup complete: \${obj}"
EOF
    chmod 0755 /usr/local/bin/blog-backup

    cat > /usr/local/bin/blog-reboot-if-needed <<'EOF'
#!/usr/bin/env bash
# Reboots only when the package layer says a reboot is genuinely required.
#
# `needs-restarting -r` exits 0 for "no reboot needed" and 1 for "reboot
# needed". Anything else -- most likely 127 because the dnf5 plugin is packaged
# differently on this release -- means we do not KNOW, and "do not know" must
# never mean "reboot the production host every week".
set -uo pipefail

dnf needs-restarting -r >/dev/null 2>&1
rc=$?

case "${rc}" in
    0) echo "no reboot required" ; exit 0 ;;
    1) echo "reboot required by pending updates -- rebooting" ; systemctl reboot ;;
    *) echo "needs-restarting returned ${rc} (plugin missing?) -- NOT rebooting" >&2
       echo "install the dnf needs-restarting plugin, or this check is inert" >&2
       exit 0 ;;
esac
EOF
    chmod 0755 /usr/local/bin/blog-reboot-if-needed
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
# Renders src -> dst through envsubst, only if the content actually differs,
# and reports whether it changed. Keeps config-sync from restarting healthy
# services for no reason.
#
# `vars` is an explicit list, never bare envsubst: templates are full of
# literal $ (shell, regexes, Caddy placeholders), and only the named variables
# may be substituted.
render() {
    local src="$1" dst="$2" owner="$3" mode="$4" vars="$5"
    local tmp
    tmp=$(mktemp)
    envsubst "${vars}" < "${src}" > "${tmp}"
    if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
        rm -f "${tmp}"
        return 1
    fi
    install -o "${owner%:*}" -g "${owner#*:}" -m "${mode}" "${tmp}" "${dst}"
    rm -f "${tmp}"
    log "rendered ${dst}"
    return 0
}

# Exports SECRET_<NAME> for every secret in the secret-names metadata
# (infra/secret-names.txt), e.g. blog-acme-email -> SECRET_ACME_EMAIL, and
# appends each to SECRET_VARS for envsubst. Returns 1 if any `generate` secret
# is unreadable; the caller then skips rendering entirely, because an app
# started with an empty signing key is far worse than one not restarted.
# `operator` secrets are optional and render empty, with a warning.
SECRET_VARS=""
SECRET_ENV_NAMES=()
load_secrets() {
    local entries entry id src var value missing=0
    IFS=',' read -r -a entries <<< "${SECRET_NAMES}"
    for entry in "${entries[@]}"; do
        [[ -n "${entry}" ]] || continue
        id=${entry%%:*}
        src=${entry#*:}
        var=SECRET_$(printf '%s' "${id#blog-}" | tr 'a-z-' 'A-Z_')
        if value=$(gcloud secrets versions access latest --secret="${id}" \
                       --project="${GCP_PROJECT}" 2>/dev/null) && [[ -n "${value}" ]]; then
            :
        elif [[ "${src}" == generate ]]; then
            warn "required secret ${id} is unreadable (no version yet, or the IAM grant has not propagated)"
            value=""
            missing=1
        else
            warn "optional secret ${id} has no readable value -- rendering it empty"
            value=""
        fi
        export "${var}=${value}"
        SECRET_VARS+=" \${${var}}"
        SECRET_ENV_NAMES+=("${var}")
    done
    return "${missing}"
}

# Decides whether Caddy can live on the podman bridge or needs the host network.
#
# The googleclouddns ACME plugin authenticates via Application Default
# Credentials, which on GCE means reaching the metadata server at
# 169.254.169.254. If a container on our bridge cannot reach it, DNS-01 issuance
# fails at certificate time -- long after this script has reported success -- so
# the check happens here, up front, and the answer is cached. Delete
# /etc/blog/caddy-network to re-probe.
probe_caddy_network() {
    local cache=/etc/blog/caddy-network
    if [[ -f "${cache}" ]]; then
        cat "${cache}"
        return 0
    fi
    if ! podman image exists "${IMAGE_CADDY}" 2>/dev/null; then
        # Cannot probe yet (first boot, before the first image build). Assume the
        # bridge and re-probe on the next config-sync.
        echo bridge
        return 0
    fi

    # The network normally does not exist yet: on a full boot this runs before
    # the quadlet units start. Creating it here with the same arguments quadlet
    # uses keeps the probe honest -- otherwise `podman run --network blog`
    # fails and the probe wrongly concludes the metadata server is unreachable.
    # stdout is discarded because this function's stdout IS the return value.
    podman network create --ignore \
        --subnet "${PODMAN_SUBNET}" --gateway "${PODMAN_GATEWAY}" blog >/dev/null 2>&1 || true

    local mode=host
    if podman run --rm --network blog --entrypoint curl "${IMAGE_CADDY}" \
        -fsS -m 10 -H 'Metadata-Flavor: Google' \
        http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token \
        >/dev/null 2>&1; then
        mode=bridge
    else
        warn "metadata server unreachable from the podman bridge -- Caddy will use the host network"
    fi
    mkdir -p /etc/blog
    echo "${mode}" > "${cache}"
    echo "${mode}"
}

render_all() {
    log "rendering configuration"
    mkdir -p /etc/blog /etc/caddy "${RENDER_DIR}"

    if ! load_secrets; then
        # Deliberately NOT a failure: on first boot the secrets may not be
        # readable yet (IAM propagation). Rendering an app config with empty
        # secrets would be far worse than doing nothing; the next sync retries.
        warn "required secrets unavailable -- skipping config render (will retry on the next sync)"
        unset "${SECRET_ENV_NAMES[@]}"
        return 0
    fi

    local caddy_mode caddy_network caddy_publish caddy_sysctl app_upstream
    caddy_mode=$(probe_caddy_network)
    if [[ "${caddy_mode}" == "host" ]]; then
        caddy_network="host"
        caddy_publish="# Network=host: ports are bound directly, publishing would be invalid."
        caddy_sysctl="# Network=host: podman rejects net.* sysctls; set on the host instead."
        app_upstream="127.0.0.1:${APP_PORT}"
        # Container-local sysctls are unavailable on the host network, so allow
        # unprivileged binds to 80/443 host-wide. Narrower than granting the
        # container CAP_NET_BIND_SERVICE.
        echo 'net.ipv4.ip_unprivileged_port_start = 80' > /etc/sysctl.d/90-blog-caddy.conf
        sysctl -q -p /etc/sysctl.d/90-blog-caddy.conf || warn "could not apply unprivileged port sysctl"
    else
        caddy_network="blog.network"
        caddy_publish=$'PublishPort=80:80\nPublishPort=443:443\nPublishPort=443:443/udp'
        caddy_sysctl="Sysctl=net.ipv4.ip_unprivileged_port_start=0"
        app_upstream="blog:${APP_PORT}"
        rm -f /etc/sysctl.d/90-blog-caddy.conf
    fi

    # Without a contact address Caddy still issues certificates, just under an
    # account with no email -- far better than an empty `email` directive, which
    # fails to parse and leaves nothing serving TLS.
    local caddy_email
    if [[ -n "${SECRET_ACME_EMAIL:-}" ]]; then
        caddy_email="email ${SECRET_ACME_EMAIL}"
    else
        caddy_email="# no ACME contact address: secret blog-acme-email has no value"
    fi

    # What the app must treat as its reverse proxy, so it logs (and rate
    # limits, and fail2ban bans) the real client instead of Caddy. Both the
    # bridge CIDR and loopback, so the value is right in either Caddy mode:
    # rootful podman SNATs host-loopback traffic to the bridge gateway.
    local trusted_proxies="${PODMAN_SUBNET},127.0.0.1/32"

    export TRUSTED_PROXIES="${trusted_proxies}" \
           APP_UPSTREAM="${app_upstream}" \
           CADDY_NETWORK="${caddy_network}" \
           CADDY_PUBLISH_PORTS="${caddy_publish}" \
           CADDY_SYSCTL="${caddy_sysctl}" \
           CADDY_EMAIL="${caddy_email}"

    local changed=0

    # The app's environment. root:root 0400: podman reads it on the host when it
    # creates the container (EnvironmentFile=), and nothing inside the container
    # ever sees the file itself.
    #
    # For an app configured by a FILE instead (an .ini, .toml, .yaml), render it
    # the same way, owned by the container uid since the app reads it, and
    # bind-mount it read-only in vm/quadlets/blog.container:
    #   render "${STATE_DIR}/config/app.toml.tmpl" /etc/blog/app.toml 1000:1000 0400 \
    #       "\${DOMAIN} \${TRUSTED_PROXIES}${SECRET_VARS}" && changed=1
    render "${STATE_DIR}/config/app.env.tmpl" /etc/blog/app.env root:root 0400 \
        "\${DOMAIN} \${APP_PORT} \${APP_DATA_PATH} \${TRUSTED_PROXIES}${SECRET_VARS}" \
        && changed=1

    render "${STATE_DIR}/config/Caddyfile.tmpl" /etc/caddy/Caddyfile root:root 0644 \
        '${DOMAIN} ${CADDY_EMAIL} ${APP_UPSTREAM} ${WAF_MODE}' \
        && changed=1

    local unit
    for unit in blog.network blog.container caddy.container caddy-data.volume caddy-config.volume; do
        render "${STATE_DIR}/quadlets/${unit}" "${RENDER_DIR}/${unit}" root:root 0644 \
            '${IMAGE_APP} ${IMAGE_CADDY} ${PODMAN_SUBNET} ${PODMAN_GATEWAY} ${GCP_PROJECT} ${APP_PORT} ${HEALTH_PATH} ${APP_DATA_PATH} ${CADDY_NETWORK} ${CADDY_PUBLISH_PORTS} ${CADDY_SYSCTL}' \
            && changed=1
    done

    for unit in "${STATE_DIR}"/systemd/*; do
        [[ -f "${unit}" ]] || continue
        local base; base=$(basename "${unit}")
        if ! cmp -s "${unit}" "/etc/systemd/system/${base}"; then
            install -m 0644 "${unit}" "/etc/systemd/system/${base}"
            log "installed unit ${base}"
            changed=1
        fi
    done

    unset "${SECRET_ENV_NAMES[@]}"

    systemctl daemon-reload
    if (( changed )); then
        log "configuration changed -- restarting services"
        systemctl restart blog.service || warn "blog did not restart cleanly"
        systemctl restart caddy.service || warn "caddy did not restart cleanly"
    else
        log "configuration unchanged"
    fi
}

# ---------------------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------------------
# Runs on every invocation, not just full boots: the WAF jail's enabled flag is
# derived from WAF_MODE, and that has to be re-applied whenever the mode changes.
setup_fail2ban() {
    command -v fail2ban-server >/dev/null 2>&1 || { warn "fail2ban not installed; skipping"; return 0; }
    log "configuring fail2ban"
    install -m 0644 "${STATE_DIR}/fail2ban/action.d/nft-prerouting.conf" /etc/fail2ban/action.d/
    install -m 0644 "${STATE_DIR}/fail2ban/filter.d/caddy-coraza.conf"   /etc/fail2ban/filter.d/

    # One config value drives both halves: the WAF only blocks in On, and only
    # then is it safe to escalate a WAF verdict into an nftables ban. In
    # DetectionOnly the jail is inert so tuning cannot lock anyone out.
    local coraza_enabled=false
    [[ "${WAF_MODE}" == "On" ]] && coraza_enabled=true
    export CORAZA_JAIL_ENABLED="${coraza_enabled}"
    log "coraza fail2ban jail enabled=${coraza_enabled} (waf-mode=${WAF_MODE})"

    envsubst '${PODMAN_SUBNET} ${CORAZA_JAIL_ENABLED}' \
        < "${STATE_DIR}/fail2ban/jail.d/blog.local" > /etc/fail2ban/jail.d/blog.local
    chmod 0644 /etc/fail2ban/jail.d/blog.local
    systemctl enable --now fail2ban
    systemctl reload fail2ban || systemctl restart fail2ban
}

# ---------------------------------------------------------------------------
# Automatic updates
# ---------------------------------------------------------------------------
setup_auto_updates() {
    log "configuring automatic updates"
    install -m 0644 "${STATE_DIR}/dnf/automatic.conf" /etc/dnf/automatic.conf

    # AlmaLinux 10 ships dnf5, where the unit is dnf5-automatic.timer -- but the
    # package providing it has moved around between releases, so resolve it
    # instead of hardcoding a name that may not exist.
    local timer=""
    for candidate in dnf5-automatic.timer dnf-automatic.timer; do
        if systemctl list-unit-files "${candidate}" >/dev/null 2>&1 \
           && systemctl cat "${candidate}" >/dev/null 2>&1; then
            timer="${candidate}"; break
        fi
    done
    if [[ -z "${timer}" ]]; then
        log "no dnf automatic timer present -- installing provider"
        dnf -y install "$(dnf -q provides '*/dnf5-automatic.timer' 2>/dev/null | awk 'NR==1{print $1}')" \
            || dnf -y install dnf-automatic \
            || warn "could not install a dnf-automatic provider"
        for candidate in dnf5-automatic.timer dnf-automatic.timer; do
            systemctl cat "${candidate}" >/dev/null 2>&1 && { timer="${candidate}"; break; }
        done
    fi
    if [[ -n "${timer}" ]]; then
        systemctl enable --now "${timer}"
    else
        warn "no dnf automatic timer enabled"
    fi

    systemctl enable --now podman-auto-update.timer
}

enable_units() {
    log "enabling units"
    systemctl daemon-reload
    systemctl enable --now blog-ar-auth.timer
    systemctl enable --now blog-backup.timer
    systemctl enable --now blog-reboot-window.timer
    # Quadlet-generated units are not "enabled" in the usual sense -- the
    # [Install] section is honoured by the generator at daemon-reload time.
    systemctl start blog.service || warn "blog not started yet (expected before the first image build)"
    systemctl start caddy.service || warn "caddy not started yet (expected before the first image build)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "starting (mode=${MODE})"

    # First, before anything else, so everything below runs the current logic.
    # gcloud ships on the GCE image, so this works before any package install.
    sync_config
    self_update "$@"

    if [[ "${MODE}" == "full" ]]; then
        install_packages
        setup_data_disk
        setup_swap
        configure_podman
        install_helpers
        install_ar_auth
    fi

    # setup_nftables and setup_fail2ban run in BOTH modes, deliberately: they
    # apply configuration that lives in the vm/ tree, so gating them on a full
    # boot would mean a pushed change never takes effect until the next reboot.
    # The fail2ban case is the dangerous one -- flipping wafMode to On would make
    # Caddy issue 403s while the jail acting on them stays disabled. Both are
    # idempotent and self-validating.
    setup_nftables
    setup_fail2ban

    render_all

    if [[ "${MODE}" == "full" ]]; then
        setup_auto_updates
        enable_units
    fi

    log "done"
}

main "$@"
