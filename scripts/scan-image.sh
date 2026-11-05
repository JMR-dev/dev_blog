#!/usr/bin/env bash
#
# Gates an image on a Trivy scan: fails on any HIGH or CRITICAL finding that has
# a fix, in the OS packages or in anything else in the image. The images job runs
# it after the build (and the app's smoke test) and before the push, so an image
# that fails it never reaches the registry, and the VM's auto-update never sees
# it. By hand: scripts/scan-image.sh <image>.
#
# Trivy is pinned by digest, since its own release tags were hijacked in 2026.
# The digest is the multi-arch index of aquasec/trivy:0.76.1 (the same on
# ghcr.io). Its trivy binary is byte for byte the one in the release tarballs
# whose checksums Trivy's release workflow signed for tag v0.76.1. To bump: take
# the new tag's index digest (`skopeo inspect --raw
# docker://docker.io/aquasec/trivy:<version> | sha256sum`) and check it the
# same way.
#
# Trivy gets the image over stdin (`docker save | docker run -i`), not the
# daemon's socket: on the Docker-in-Docker runner a -v /var/run/docker.sock path
# would resolve on the daemon's filesystem, not the job container's.
#
# When it fails: rebuild on fresh base layers if the fix is in them; otherwise
# bump the component that carries the finding.
#
# Usage: scripts/scan-image.sh <image>     (docker; CONTAINER=podman for podman)

set -euo pipefail

TRIVY_IMAGE="docker.io/aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"

[[ $# -eq 1 ]] || { echo "usage: $0 <image>" >&2; exit 1; }
image="$1"
container="${CONTAINER:-docker}"

echo "Scanning ${image} with ${TRIVY_IMAGE}"
"$container" save "$image" | "$container" run --rm -i --entrypoint sh "$TRIVY_IMAGE" -c '
  set -e
  cat >/tmp/image.tar
  trivy image --input /tmp/image.tar \
    --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --no-progress
'
