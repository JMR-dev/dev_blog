#!/usr/bin/env bash
#
# The instance's startup script. GCE runs it as root on every boot.
#
# A STUB, on purpose. Pulumi sets this file as metadata_startup_script, and that
# field is FORCE-NEW: any change to this file replaces the VM -- a new boot disk,
# a full first-boot bootstrap, and a re-issued TLS certificate (Let's Encrypt
# allows 5 duplicates a week). So this file does one thing and should almost
# never change: fetch the real bootstrap script from the config bucket and exec
# it. Put changes in vm/bootstrap.sh, which ships through the bucket like every
# other file under vm/ and costs nothing to change.
set -euo pipefail

readonly DST=/usr/local/sbin/blog-bootstrap

log() { echo "[blog-startup] $*" >&2; }

bucket=$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://169.254.169.254/computeMetadata/v1/instance/attributes/config-bucket) \
    || { log "FATAL: config-bucket metadata missing"; exit 1; }

# On a brand-new instance the VM's read grant on the bucket can take a minute or
# two to propagate, so keep trying. On a reboot of an existing VM there is a copy
# from last time to fall back on, so give up sooner.
attempts=30
[[ -x "${DST}" ]] && attempts=3

tmp=$(mktemp)
for ((i = 1; i <= attempts; i++)); do
    # gcloud ships on the GCE AlmaLinux images, so this works before any package
    # is installed.
    if gcloud storage cp --quiet "gs://${bucket}/vm/bootstrap.sh" "${tmp}" 2>/dev/null; then
        # Atomic replace onto a fresh inode, same reason as in bootstrap.sh.
        install -m 0755 "${tmp}" "${DST}.new"
        mv -f "${DST}.new" "${DST}"
        break
    fi
    log "vm/bootstrap.sh not fetchable yet (attempt ${i}/${attempts})"
    sleep 10
done
rm -f "${tmp}"

[[ -x "${DST}" ]] || { log "FATAL: no bootstrap script available"; exit 1; }
exec "${DST}"
