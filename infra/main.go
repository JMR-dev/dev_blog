// Command blog-infra provisions the blog deployment: a single AlmaLinux 10 VM
// running podman quadlets, fronted by Caddy with ACME DNS-01 against an
// existing Cloud DNS zone and the Coraza WAF. Images are built, pushed and
// rolled out by Gitea Actions (.gitea/workflows/pipeline.yml), which also runs
// this program.
//
// The program is deliberately thin. Each package owns one slice of the
// infrastructure and the wiring order below is the dependency order.
package main

import (
	"path/filepath"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"blog-infra/pkg/compute"
	"blog-infra/pkg/config"
	"blog-infra/pkg/dns"
	"blog-infra/pkg/iam"
	"blog-infra/pkg/network"
	"blog-infra/pkg/project"
	"blog-infra/pkg/registry"
	"blog-infra/pkg/secrets"
	"blog-infra/pkg/storage"
)

// The vm/ tree lives one level up from infra/, where Pulumi runs the program.
const vmDir = "../vm"

func main() { pulumi.Run(program) }

// program is separate from main so main_test.go can run it under Pulumi's mock
// runtime.
func program(ctx *pulumi.Context) error {
	cfg, err := config.Load(ctx)
	if err != nil {
		return err
	}
	secretList, err := secrets.Load(secrets.File)
	if err != nil {
		return err
	}

	// Everything depends on these: a resource created against an API that is
	// still enabling fails in confusing ways.
	apis, err := project.EnableAPIs(ctx)
	if err != nil {
		return err
	}

	net, err := network.New(ctx, cfg, apis)
	if err != nil {
		return err
	}

	accounts, err := iam.New(ctx, cfg, apis)
	if err != nil {
		return err
	}

	repo, err := registry.New(ctx, cfg, apis)
	if err != nil {
		return err
	}
	if err := iam.GrantRegistry(ctx, cfg, accounts, repo); err != nil {
		return err
	}

	// The secrets themselves are created by scripts/bootstrap.sh; Pulumi
	// only grants access to them.
	secretGrants, err := iam.GrantSecrets(ctx, cfg, accounts, secretList)
	if err != nil {
		return err
	}

	buckets, err := storage.New(ctx, cfg, vmDir, apis)
	if err != nil {
		return err
	}
	bucketGrants, err := iam.GrantBuckets(ctx, accounts, buckets.Config, buckets.Backup)
	if err != nil {
		return err
	}

	// The zone already exists and is delegated; this only adds the A record
	// and the zone-scoped permission Caddy needs for DNS-01.
	if _, err := dns.New(ctx, cfg, net.Address, accounts.VM.Email, apis); err != nil {
		return err
	}

	// The first boot fetches bootstrap.sh from the bucket and reads every
	// secret, so the objects and the grants must exist before the VM does.
	// IAM is eventually consistent even so; the startup stub and the render
	// step both tolerate a grant that has not propagated yet.
	readyBefore := append(append(append([]pulumi.Resource{}, buckets.Objects...), bucketGrants...), secretGrants...)

	inst, err := compute.New(ctx, cfg, compute.Args{
		Network:     net,
		SA:          accounts.VM,
		Buckets:     buckets,
		Secrets:     secretList,
		StartupStub: filepath.Join(vmDir, "startup.sh"),
		ReadyBefore: readyBefore,
	}, apis)
	if err != nil {
		return err
	}

	ctx.Export("address", net.Address.Address)
	ctx.Export("url", pulumi.Sprintf("https://%s/", cfg.Domain))
	ctx.Export("instance", inst.VM.Name)
	ctx.Export("zone", pulumi.String(cfg.Zone))
	ctx.Export("registry", pulumi.Sprintf("%s/%s/%s", cfg.ARHost(), cfg.Project, registry.RepoID))
	ctx.Export("configBucket", buckets.Config.Name)
	ctx.Export("backupBucket", buckets.Backup.Name)
	ctx.Export("configHash", pulumi.String(buckets.ConfigHash))
	ctx.Export("vmServiceAccount", accounts.VM.Email)
	// Printed so the runbook never has to guess the flags.
	ctx.Export("sshCommand", pulumi.Sprintf(
		"gcloud compute ssh %s --zone=%s --tunnel-through-iap --project=%s",
		inst.VM.Name, cfg.Zone, cfg.Project))

	return nil
}
