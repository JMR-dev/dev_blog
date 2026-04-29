# GitHub repo configuration (OpenTofu)

Manages branch protection (via repository rulesets) and deployment
environments for `JMR-dev/dev_blog`.

This module is also the source-of-truth copy that is mirrored to the
[`gh-repo-bootstrap`](https://github.com/JMR-dev/gh-repo-bootstrap) repo,
which packages it as a reusable module + `gh` CLI extension
(`gh repo-bootstrap <owner>/<repo>`).

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.8
- A GitHub token with `repo` + `admin:repo_hook` scopes. Easiest:
  ```sh
  export GITHUB_TOKEN=$(gh auth token)
  ```
- (For remote state) Cloudflare R2 credentials — copy
  `backend.hcl.example` to `backend.hcl` and fill it in.

## Usage

```sh
# First time only:
tofu init -backend-config=backend.hcl

# Apply:
tofu apply
```

To run with **local state** (no R2 needed) for experimentation, comment
out the `backend "s3"` block in `versions.tf`, then `tofu init` again.

## What it manages

- A repository ruleset on the default branch enforcing:
  - No deletion
  - No force-push
  - Required PR with N approving reviews (configurable)
  - Resolved review threads
  - Optional signed commits
- The set of GitHub deployment environments listed in `environments`.

It does **not** create the repository itself, and does not manage
repo-level settings (merge button options, default branch, topic, etc.).
Add those via `gh api` or import the `github_repository` resource if you
need them under OpenTofu control.
