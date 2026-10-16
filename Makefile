# Convenience wrappers. Everything here is also runnable by hand; nothing in the
# deployment depends on make.

# Read straight from the stack file rather than `pulumi config get`, so these
# targets work without a Pulumi login.
stackval = $(shell sed -n 's/^  $(1): //p' infra/Pulumi.prod.yaml)
PROJECT ?= $(call stackval,gcp:project)
REGION  ?= $(call stackval,gcp:region)
ZONE    ?= $(call stackval,blog:zone)
VM      ?= blog-vm

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## One-time project setup (run before the first `make up`)
	scripts/bootstrap.sh $(PROJECT) $(REGION)

.PHONY: fmt
fmt: ## Format Go sources
	cd infra && gofmt -w .

# -o blog-infra: Pulumi.yaml points the go runtime at this prebuilt binary, so
#   Pulumi runs it rather than compiling. Without it preview/up fail outright.
# The local stack: production's two images, with caddy/Caddyfile.dev (tls
# internal) instead of ACME. http://localhost:8080 and https://localhost:8443.
.PHONY: dev
dev: ## Build and run the site locally behind the WAF (podman compose)
	CADDY_VERSION=$$(tr -d '[:space:]' < image/caddy.version) \
	CORAZA_VERSION=$$(tr -d '[:space:]' < image/coraza.version) \
		podman compose up --build

.PHONY: check
check: ## Build, vet and test the Pulumi program; syntax-check and lint the shell scripts
	cd infra && go build -o blog-infra . && go vet ./... && go test ./...
	bash -n vm/startup.sh vm/bootstrap.sh scripts/bootstrap.sh
	@# if/else, not `a && b || c`: the latter reports "not installed" and exits 0
	@# when shellcheck runs and FINDS something, so CI would never fail on it.
	@if command -v shellcheck >/dev/null; then \
		shellcheck -S warning vm/startup.sh vm/bootstrap.sh scripts/bootstrap.sh; \
	else echo "shellcheck not installed -- skipped"; fi

.PHONY: preview
preview: check ## Show what `pulumi up` would change
	cd infra && pulumi preview

.PHONY: up
up: check ## Apply the infrastructure (normally Gitea Actions does this on main)
	cd infra && pulumi up

.PHONY: rollout
rollout: ## Pull the latest :prod images onto the VM right now
	gcloud compute ssh $(VM) --zone=$(ZONE) --tunnel-through-iap --project=$(PROJECT) \
		--command 'sudo systemctl start podman-auto-update.service && sudo podman ps'

.PHONY: sync
sync: ## Re-render VM config from the bucket and restart what changed
	gcloud compute ssh $(VM) --zone=$(ZONE) --tunnel-through-iap --project=$(PROJECT) \
		--command 'sudo systemctl start blog-config-sync.service && sudo journalctl -u blog-config-sync -n 40 --no-pager'

.PHONY: ssh
ssh: ## Shell on the VM through IAP
	gcloud compute ssh $(VM) --zone=$(ZONE) --tunnel-through-iap --project=$(PROJECT)

.PHONY: logs
logs: ## Tail app and Caddy logs
	gcloud compute ssh $(VM) --zone=$(ZONE) --tunnel-through-iap --project=$(PROJECT) \
		--command 'sudo journalctl -u blog -u caddy -f'

.PHONY: status
status: ## Health summary from the VM
	gcloud compute ssh $(VM) --zone=$(ZONE) --tunnel-through-iap --project=$(PROJECT) \
		--command 'sudo systemctl status --no-pager blog caddy nftables fail2ban; sudo podman ps; sudo systemctl list-timers --no-pager'

.PHONY: backup
backup: ## Take an on-demand app dump to the backup bucket
	gcloud compute ssh $(VM) --zone=$(ZONE) --tunnel-through-iap --project=$(PROJECT) \
		--command 'sudo systemctl start blog-backup.service && sudo journalctl -u blog-backup -n 20 --no-pager'
