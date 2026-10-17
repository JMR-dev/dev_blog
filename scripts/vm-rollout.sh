#!/usr/bin/env bash
#
# Rolls the VM onto the current :prod images. Runs ON the VM as root, piped
# over IAP by the pipeline's rollout job and by `make rollout`:
#
#   gcloud compute ssh blog-vm --tunnel-through-iap --command 'sudo bash -s' < scripts/vm-rollout.sh
#
# podman-auto-update first: for a RUNNING container it pulls a newer :prod,
# restarts, and rolls back if the new image never turns healthy.
#
# Then the case it does not cover: auto-update only looks at running
# containers. A unit crash-looping on a broken image is skipped, and quadlet's
# `podman run` keeps using the local copy of :prod, so a fixed image pushed to
# the registry would never reach the box. For any unit that is not active,
# pull :prod explicitly and restart it.
set -euo pipefail

readonly AUTHFILE=/etc/containers/ar-auth.json

systemctl start podman-auto-update.service \
    || echo "podman-auto-update reported a failure -- see: journalctl -u podman-auto-update" >&2

for unit in blog caddy; do
    systemctl is-active --quiet "${unit}" && continue
    image=$(sed -n 's/^Image=//p' "/etc/containers/systemd/${unit}.container")
    [[ -n "${image}" ]] || { echo "no Image= in ${unit}.container" >&2; exit 1; }
    echo "${unit} is not running; pulling ${image} and restarting it"
    podman pull --authfile "${AUTHFILE}" "${image}"
    systemctl restart "${unit}"
done

podman ps --format '{{.Names}}  {{.Image}}  {{.Status}}'

# Exit NOT_ROLLED_OUT unless both units run the registry's :prod. Without this,
# a unit that auto-update rolled back (the new image never turned healthy), or
# whose pull failed, leaves the old image serving -- and the old site answers
# the pipeline's health gate as well as the new one would. A code of its own,
# so the pipeline can tell "reached the VM, rollout did not take" (stop: a retry
# would only restart a bad image again) from "could not reach the VM" (retry).
readonly NOT_ROLLED_OUT=3
failed=0
for unit in blog caddy; do
    systemctl is-active --quiet "${unit}" || { echo "${unit} is not running" >&2; failed=1; }
done
# UPDATED is false when the local image is the registry's, pending when a
# newer one is there, failed when the registry check itself failed.
behind=$(podman auto-update --dry-run --format '{{.Unit}} {{.Updated}}' | awk '$2 != "false"')
if [[ -n "${behind}" ]]; then
    echo "not on the registry's :prod after the rollout (see journalctl -u podman-auto-update):" >&2
    echo "${behind}" >&2
    failed=1
fi
(( failed == 0 )) || exit "${NOT_ROLLED_OUT}"
