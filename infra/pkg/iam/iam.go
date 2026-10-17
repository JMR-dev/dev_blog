// Package iam creates the workload identities and grants them the narrowest set
// of roles that still works.
//
// Note what is NOT here: the Gitea Actions identity that runs Pulumi, builds
// and pushes the images, and reaches the VM over IAP (gitea-deploy@). That one is
// created by scripts/bootstrap.sh, because it is the identity performing the very
// `pulumi up` that would create it. Its roles are project-level and listed in
// that script's INFRA_ROLES.
package iam

import (
	"github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/artifactregistry"
	"github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/projects"
	"github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/secretmanager"
	"github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/serviceaccount"
	"github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/storage"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"blog-infra/pkg/config"
	"blog-infra/pkg/secrets"
)

type Accounts struct {
	// VM runs the containers; it reads secrets, pulls images, writes backups,
	// and answers ACME DNS-01 challenges.
	VM *serviceaccount.Account
}

func New(ctx *pulumi.Context, cfg *config.Config, deps []pulumi.Resource) (*Accounts, error) {
	opts := pulumi.DependsOn(deps)

	vm, err := serviceaccount.NewAccount(ctx, "blog-vm-sa", &serviceaccount.AccountArgs{
		AccountId:   pulumi.String("blog-vm"),
		DisplayName: pulumi.String("blog VM"),
		Description: pulumi.String("Workload identity for the blog instance"),
	}, opts)
	if err != nil {
		return nil, err
	}

	// Observability only. Everything with real blast radius is granted per
	// resource further down.
	vmProjectRoles := []string{
		"roles/logging.logWriter",
		"roles/monitoring.metricWriter",
	}
	for _, role := range vmProjectRoles {
		if _, err := projects.NewIAMMember(ctx, "vm-"+role, &projects.IAMMemberArgs{
			Project: pulumi.String(cfg.Project),
			Role:    pulumi.String(role),
			Member:  pulumi.Sprintf("serviceAccount:%s", vm.Email),
		}, opts); err != nil {
			return nil, err
		}
	}

	return &Accounts{VM: vm}, nil
}

// GrantRegistry scopes the VM's image pulls to the one repository rather than
// granting project-wide Artifact Registry roles. Pushes come from gitea-deploy@,
// whose project-level role is granted by scripts/bootstrap.sh.
func GrantRegistry(ctx *pulumi.Context, cfg *config.Config, a *Accounts, repo *artifactregistry.Repository) error {
	_, err := artifactregistry.NewRepositoryIamMember(ctx, "vm-ar-reader", &artifactregistry.RepositoryIamMemberArgs{
		Project:    pulumi.String(cfg.Project),
		Location:   repo.Location,
		Repository: repo.Name,
		Role:       pulumi.String("roles/artifactregistry.reader"),
		Member:     pulumi.Sprintf("serviceAccount:%s", a.VM.Email),
	})
	return err
}

// GrantSecrets gives the VM read access to each listed secret individually --
// not roles/secretmanager.secretAccessor across the project. Read only: the VM
// never creates or rotates a value, so it has no business adding versions.
//
// Takes ids rather than resources because the secrets are created by
// scripts/bootstrap.sh, not by Pulumi; see package secrets for why. A binding on
// a secret that does not exist yet fails the apply, which is the right outcome:
// it means bootstrap.sh was not re-run after secret-names.txt changed.
func GrantSecrets(ctx *pulumi.Context, cfg *config.Config, a *Accounts, list []secrets.Secret) ([]pulumi.Resource, error) {
	var out []pulumi.Resource
	for _, s := range list {
		m, err := secretmanager.NewSecretIamMember(ctx, "vm-read-"+s.ID, &secretmanager.SecretIamMemberArgs{
			Project:  pulumi.String(cfg.Project),
			SecretId: pulumi.String(s.ID),
			Role:     pulumi.String("roles/secretmanager.secretAccessor"),
			Member:   pulumi.Sprintf("serviceAccount:%s", a.VM.Email),
		})
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
}

// GrantBuckets: read-only on config, write-only on backups. The VM can create a
// backup but cannot read or delete existing ones, which limits what ransomware
// on the box could do to the backup history.
func GrantBuckets(ctx *pulumi.Context, a *Accounts, configBucket, backupBucket *storage.Bucket) ([]pulumi.Resource, error) {
	reader, err := storage.NewBucketIAMMember(ctx, "vm-config-reader", &storage.BucketIAMMemberArgs{
		Bucket: configBucket.Name,
		Role:   pulumi.String("roles/storage.objectViewer"),
		Member: pulumi.Sprintf("serviceAccount:%s", a.VM.Email),
	})
	if err != nil {
		return nil, err
	}
	creator, err := storage.NewBucketIAMMember(ctx, "vm-backup-creator", &storage.BucketIAMMemberArgs{
		Bucket: backupBucket.Name,
		Role:   pulumi.String("roles/storage.objectCreator"),
		Member: pulumi.Sprintf("serviceAccount:%s", a.VM.Email),
	})
	if err != nil {
		return nil, err
	}
	return []pulumi.Resource{reader, creator}, nil
}
