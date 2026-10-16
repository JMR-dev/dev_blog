#!/usr/bin/env bash
#
# One-time project bootstrap, run from a workstation BEFORE the first
# `pulumi up`. Re-run it after adding a secret to infra/secret-names.txt.
#
# Everything here exists because Pulumi cannot create it:
#
#   * the GCS bucket that holds Pulumi's own state
#   * the passphrase that encrypts that state
#   * the service account that RUNS Pulumi in Gitea Actions (gitea-deploy@),
#     which also pushes the images and reaches the VM over IAP
#   * the Cloud DNS zone for the domain and its NS delegation from the parent
#     zone -- `pulumi destroy` must never be able to take DNS down
#   * the application's secrets (infra/secret-names.txt) -- they must exist
#     before the VM first boots and renders its config, and `pulumi destroy`
#     must not be able to delete them
#
# Idempotent: safe to re-run. It never overwrites a secret that has a value.
#
# Usage: scripts/bootstrap.sh <project-id> [region]   (default region: us-east1)
#
# PARENT_ZONE (env, default `public`) names the existing Cloud DNS zone, in the
# same project, that the domain is delegated from.

set -euo pipefail

PROJECT="${1:-}"
REGION="${2:-us-east1}"

if [[ -z "${PROJECT}" ]]; then
    echo "usage: $0 <project-id> [region]" >&2
    exit 1
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SECRET_LIST="${REPO_ROOT}/infra/secret-names.txt"
STATE_BUCKET="${PROJECT}-pulumi-state"
INFRA_SA="gitea-deploy"
INFRA_SA_EMAIL="${INFRA_SA}@${PROJECT}.iam.gserviceaccount.com"

# The domain and its zone are read from the stack file, so there is one place
# they are spelled.
STACK_FILE="${REPO_ROOT}/infra/Pulumi.prod.yaml"
DOMAIN=$(sed -n 's/^  blog:domain: //p' "${STACK_FILE}")
DNS_ZONE=$(sed -n 's/^  blog:dnsZone: //p' "${STACK_FILE}")
PARENT_ZONE="${PARENT_ZONE:-public}"
[[ -n "${DOMAIN}" && -n "${DNS_ZONE}" ]] || { echo "blog:domain / blog:dnsZone missing from ${STACK_FILE}" >&2; exit 1; }

log() { echo "==> $*"; }

command -v gcloud  >/dev/null || { echo "gcloud is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
[[ -f "${SECRET_LIST}" ]] || { echo "missing ${SECRET_LIST}" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "enabling APIs"
# ---------------------------------------------------------------------------
# The same list as infra/pkg/project. Some must exist before Pulumi can run at
# all (storage for the state bucket, iam for the runner account, secretmanager).
gcloud services enable --project="${PROJECT}" \
    compute.googleapis.com \
    dns.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    iap.googleapis.com \
    storage.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    oslogin.googleapis.com

# ---------------------------------------------------------------------------
log "creating Pulumi state bucket gs://${STATE_BUCKET}"
# ---------------------------------------------------------------------------
if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${STATE_BUCKET}" \
        --project="${PROJECT}" \
        --location="${REGION}" \
        --uniform-bucket-level-access \
        --public-access-prevention
fi
# Versioning is the undo button for a corrupted or truncated state file.
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --project="${PROJECT}"

# ---------------------------------------------------------------------------
log "creating secrets"
# ---------------------------------------------------------------------------
ensure_secret() {
    local name="$1"
    if ! gcloud secrets describe "${name}" --project="${PROJECT}" >/dev/null 2>&1; then
        gcloud secrets create "${name}" --project="${PROJECT}" \
            --replication-policy=automatic --labels=app=blog
    fi
}

has_version() {
    gcloud secrets versions list "$1" --project="${PROJECT}" \
        --filter='state:ENABLED' --limit=1 --format='value(name)' 2>/dev/null | grep -q .
}

# Prints a fresh value for a `generate` secret. 64 hex characters suits most
# signing keys and session secrets. APP-SPECIFIC: if a secret must have a
# particular shape -- a JWT the app itself issues, a base64 key of fixed length,
# a value from the app's own `generate` command -- add a case for its id here.
# A random string where the app expects a JWT produces an instance that starts
# and then fails in confusing ways.
generate_secret() {
    local id="$1"
    case "${id}" in
        # blog-example-jwt) podman run --rm <image> generate-secret jwt ;;
        *) openssl rand -hex 32 ;;
    esac
}

# Pulumi's state encryption passphrase. Generated here so it never lives in a
# shell history or a config file, and so the Gitea Actions pipeline and every
# workstation use the same one. CI reads it from here at job time; it is never
# stored in Gitea.
ensure_secret pulumi-config-passphrase
if ! has_version pulumi-config-passphrase; then
    log "generating Pulumi state passphrase"
    openssl rand -base64 48 | tr -d '\n' \
        | gcloud secrets versions add pulumi-config-passphrase --project="${PROJECT}" --data-file=-
fi

# The application's secrets, from infra/secret-names.txt.
while read -r id source _; do
    [[ -z "${id}" || "${id}" == \#* ]] && continue
    ensure_secret "${id}"
    if has_version "${id}"; then
        log "secret ${id} already populated -- leaving it alone"
        continue
    fi
    case "${source}" in
        generate)
            log "generating ${id}"
            generate_secret "${id}" | tr -d '\n' \
                | gcloud secrets versions add "${id}" --project="${PROJECT}" --data-file=-
            ;;
        operator)
            echo "    NOTE: secret '${id}' has no value yet. Set it with:"
            echo "            printf %s '<value>' | gcloud secrets versions add ${id} --project=${PROJECT} --data-file=-"
            ;;
        *)
            echo "infra/secret-names.txt: ${id} has unknown source '${source}'" >&2
            exit 1
            ;;
    esac
done < "${SECRET_LIST}"

# ---------------------------------------------------------------------------
log "delegating ${DOMAIN} to zone ${DNS_ZONE} from ${PARENT_ZONE}"
# ---------------------------------------------------------------------------
# A zone of its own rather than records in the parent: the VM's DNS-01 grant
# (roles/dns.admin, in infra/pkg/dns) is scoped to ONE zone, and scoping it to
# the parent would let a compromised VM repoint the apex, mail, and every other
# delegation. The zone is not a Pulumi resource for the same reason the parent
# is not: `pulumi destroy` must not be able to delete live DNS.
if ! gcloud dns managed-zones describe "${DNS_ZONE}" --project="${PROJECT}" >/dev/null 2>&1; then
    gcloud dns managed-zones create "${DNS_ZONE}" \
        --project="${PROJECT}" \
        --dns-name="${DOMAIN}." \
        --visibility=public \
        --description="${DOMAIN}, delegated from ${PARENT_ZONE}. Created by scripts/bootstrap.sh."
fi

# Both lists come back ';'-separated; compare them sorted.
sorted_list() { tr ';' '\n' | sed '/^$/d' | sort | paste -sd, -; }
zone_ns=$(gcloud dns managed-zones describe "${DNS_ZONE}" --project="${PROJECT}" \
    --format='value(nameServers)' | sorted_list)
[[ -n "${zone_ns}" ]] || { echo "zone ${DNS_ZONE} reports no name servers" >&2; exit 1; }
parent_ns=$(gcloud dns record-sets describe "${DOMAIN}." --type=NS --zone="${PARENT_ZONE}" \
    --project="${PROJECT}" --format='value(rrdatas)' 2>/dev/null | sorted_list || true)

if [[ -z "${parent_ns}" ]]; then
    log "  adding NS ${DOMAIN}. -> ${zone_ns} in ${PARENT_ZONE}"
    gcloud dns record-sets create "${DOMAIN}." --type=NS --ttl=300 \
        --zone="${PARENT_ZONE}" --project="${PROJECT}" --rrdatas="${zone_ns}"
elif [[ "${parent_ns}" != "${zone_ns}" ]]; then
    # Never overwritten automatically: a mismatch means someone else delegated
    # this name, and replacing it would hijack their zone.
    echo "${PARENT_ZONE} already delegates ${DOMAIN} to ${parent_ns}, not to zone ${DNS_ZONE} (${zone_ns})." >&2
    echo "Resolve that by hand before continuing." >&2
    exit 1
else
    log "  delegation already in place"
fi

# ---------------------------------------------------------------------------
log "creating the Pulumi runner service account ${INFRA_SA_EMAIL}"
# ---------------------------------------------------------------------------
# This is the chicken-and-egg account: it is the identity that runs `pulumi up`,
# so it cannot be created by `pulumi up`.
if ! gcloud iam service-accounts describe "${INFRA_SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
    gcloud iam service-accounts create "${INFRA_SA}" \
        --project="${PROJECT}" \
        --display-name="Gitea Actions: deploy (runs Pulumi, pushes images)" \
        --description="Used by .gitea/workflows/pipeline.yml through the GCP_SA_KEY Actions secret"

    # Service account creation is eventually consistent. Binding a role to an
    # account the IAM API cannot see yet fails with
    #   INVALID_ARGUMENT: Service account ... does not exist
    # even though creation just succeeded. Wait for it to appear.
    log "waiting for ${INFRA_SA_EMAIL} to propagate"
    for _ in $(seq 1 30); do
        gcloud iam service-accounts describe "${INFRA_SA_EMAIL}" \
            --project="${PROJECT}" >/dev/null 2>&1 && break
        sleep 2
    done
fi

# `describe` returning the account is necessary but not sufficient -- the IAM
# policy backend can still reject it for a while longer. And each
# add-iam-policy-binding is a read-modify-write of the whole project policy, so
# a run of them in sequence can also collide with itself. Retry on both.
add_project_binding() {
    local member="$1" role="$2" out=""
    for attempt in $(seq 1 10); do
        if out=$(gcloud projects add-iam-policy-binding "${PROJECT}" \
                    --member="${member}" \
                    --role="${role}" \
                    --condition=None \
                    --quiet 2>&1); then
            return 0
        fi
        case "${out}" in
            *"does not exist"*|*oncurrent*)
                sleep $(( attempt * 3 ))
                ;;
            *)
                echo "${out}" >&2
                return 1
                ;;
        esac
    done
    echo "giving up on ${role}:" >&2
    echo "${out}" >&2
    return 1
}

# Broad by necessity -- Pulumi manages IAM, compute, DNS, storage and secrets
# bindings. The same identity pushes the images and runs the IAP rollout: every
# Gitea Actions job shares one runner (and its docker daemon), so a second,
# narrower key would sit right next to this one and isolate nothing. The blast
# radius is bounded by the PROJECT instead -- this account exists only here.
INFRA_ROLES=(
    roles/compute.admin
    roles/dns.admin
    roles/artifactregistry.admin
    roles/secretmanager.admin
    roles/iam.serviceAccountAdmin
    roles/iam.serviceAccountUser
    roles/resourcemanager.projectIamAdmin
    roles/serviceusage.serviceUsageAdmin
    # Creates the config and backup buckets and uploads the vm/ tree. Covers
    # the state bucket too.
    roles/storage.admin
    roles/iap.tunnelResourceAccessor
    roles/compute.osAdminLogin
    roles/logging.logWriter
)
for role in "${INFRA_ROLES[@]}"; do
    log "  granting ${role}"
    add_project_binding "serviceAccount:${INFRA_SA_EMAIL}" "${role}"
done

cat <<SUMMARY

Bootstrap complete.

  Pulumi backend : gs://${STATE_BUCKET}
  Pulumi runner  : ${INFRA_SA_EMAIL}
  DNS            : zone ${DNS_ZONE} (${DOMAIN}.), delegated from ${PARENT_ZONE}

Next:
  1. Set any 'operator' secrets listed above (at least blog-acme-email).
  2. Check the delegation resolves (DNS-01 cannot work otherwise):
       dig +short NS ${DOMAIN}
  3. Initialise the stack. Use the passphrase generated above, NOT a new one --
     \`stack init\` would otherwise encrypt the stack with a key CI never sees:
       gcloud auth application-default login
       export PULUMI_CONFIG_PASSPHRASE=\$(gcloud secrets versions access latest \\
           --secret=pulumi-config-passphrase --project=${PROJECT})
       cd infra && pulumi login gs://${STATE_BUCKET} && pulumi stack init prod
       # commit the encryptionsalt: line it adds to Pulumi.prod.yaml
       make -C .. preview
  4. Give Gitea Actions the runner's key, as the repository secret GCP_SA_KEY
     (Settings -> Actions -> Secrets), then delete the local copy:
       gcloud iam service-accounts keys create key.json --iam-account=${INFRA_SA_EMAIL}
  5. Push to main. .gitea/workflows/pipeline.yml runs \`pulumi up\`, builds and
     pushes the images, and rolls them out. Until the first image push the
     :prod images do not exist and both services retry every 30s.

SUMMARY
