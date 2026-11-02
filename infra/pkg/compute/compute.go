// Package compute builds the data disk, its snapshot schedule, and the instance.
package compute

import (
	"fmt"
	"os"
	"strconv"

	gcpcompute "github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/compute"
	"github.com/pulumi/pulumi-gcp/sdk/v10/go/gcp/serviceaccount"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"blog-infra/pkg/config"
	"blog-infra/pkg/network"
	"blog-infra/pkg/registry"
	"blog-infra/pkg/secrets"
	"blog-infra/pkg/storage"
)

// DataDiskDeviceName is what the disk shows up as under /dev/disk/by-id/google-*
// inside the guest. vm/bootstrap.sh mounts it by UUID, but it needs this name to
// find the device the first time, before there is a filesystem to have a UUID.
const DataDiskDeviceName = "blog-data"

type Instance struct {
	VM   *gcpcompute.Instance
	Disk *gcpcompute.Disk
}

type Args struct {
	Network *network.Network
	SA      *serviceaccount.Account
	Buckets *storage.Buckets
	Secrets []secrets.Secret
	// StartupStub is vm/startup.sh. It is the instance's startup script, and
	// metadata_startup_script is FORCE-NEW: any change to this file replaces
	// the VM. That is why it is a stub that fetches vm/bootstrap.sh from the
	// config bucket, rather than bootstrap.sh itself -- bootstrap.sh changes
	// often, and each one would otherwise mean a new instance, a fresh boot
	// disk, and a re-issued TLS certificate.
	StartupStub string
	// ReadyBefore are resources the first boot needs in place: the bucket
	// objects the stub fetches and the IAM grants that let it.
	ReadyBefore []pulumi.Resource
}

func New(ctx *pulumi.Context, cfg *config.Config, a Args, deps []pulumi.Resource) (*Instance, error) {
	opts := pulumi.DependsOn(deps)

	// A separate disk from the boot disk, so replacing the instance -- for a
	// machine-type change, an image refresh, anything -- never touches the
	// application's data. Protect(true) makes an accidental delete a two-step
	// mistake. A pd-balanced disk can be grown in place later, never shrunk.
	disk, err := gcpcompute.NewDisk(ctx, "blog-data", &gcpcompute.DiskArgs{
		Name:        pulumi.String("blog-data"),
		Zone:        pulumi.String(cfg.Zone),
		Size:        pulumi.Int(cfg.DataDiskGB),
		Type:        pulumi.String("pd-balanced"),
		Description: pulumi.String("blog data: everything you would miss if the VM vanished"),
	}, opts, pulumi.Protect(true))
	if err != nil {
		return nil, err
	}

	// The safety net for the weekly unattended-reboot window, and for everything
	// else that goes wrong at 3am. Crash-consistent, not application-consistent:
	// the app's own dump (vm/hooks/backup.sh) is the portable backup.
	policy, err := gcpcompute.NewResourcePolicy(ctx, "blog-snapshots", &gcpcompute.ResourcePolicyArgs{
		Name:   pulumi.String("blog-daily-snapshots"),
		Region: pulumi.String(cfg.Region),
		SnapshotSchedulePolicy: &gcpcompute.ResourcePolicySnapshotSchedulePolicyArgs{
			Schedule: &gcpcompute.ResourcePolicySnapshotSchedulePolicyScheduleArgs{
				DailySchedule: &gcpcompute.ResourcePolicySnapshotSchedulePolicyScheduleDailyScheduleArgs{
					DaysInCycle: pulumi.Int(1),
					StartTime:   pulumi.String("03:00"),
				},
			},
			RetentionPolicy: &gcpcompute.ResourcePolicySnapshotSchedulePolicyRetentionPolicyArgs{
				MaxRetentionDays: pulumi.Int(14),
				// Keep the history even if the disk itself is deleted.
				OnSourceDiskDelete: pulumi.String("KEEP_AUTO_SNAPSHOTS"),
			},
			SnapshotProperties: &gcpcompute.ResourcePolicySnapshotSchedulePolicySnapshotPropertiesArgs{
				StorageLocations: pulumi.String(cfg.Region),
				Labels:           pulumi.StringMap{"app": pulumi.String("blog")},
			},
		},
	}, opts)
	if err != nil {
		return nil, err
	}

	if _, err := gcpcompute.NewDiskResourcePolicyAttachment(ctx, "blog-data-snapshots", &gcpcompute.DiskResourcePolicyAttachmentArgs{
		Name: policy.Name,
		Disk: disk.Name,
		Zone: pulumi.String(cfg.Zone),
	}, opts); err != nil {
		return nil, err
	}

	stub, err := os.ReadFile(a.StartupStub)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", a.StartupStub, err)
	}

	imageApp := fmt.Sprintf("%s/%s/%s/blog:prod", cfg.ARHost(), cfg.Project, registry.RepoID)
	imageCaddy := fmt.Sprintf("%s/%s/%s/caddy:prod", cfg.ARHost(), cfg.Project, registry.RepoID)

	// Everything vm/bootstrap.sh needs to know about this deployment. All of it
	// is public; secret VALUES never go here (they are world-readable to any
	// process on the box that can reach the metadata server).
	metadata := pulumi.StringMap{
		// OS Login means SSH access follows IAM instead of metadata keys.
		"enable-oslogin":         pulumi.String("TRUE"),
		"google-logging-enabled": pulumi.String("true"),

		"config-bucket": a.Buckets.Config.Name,
		"backup-bucket": a.Buckets.Backup.Name,
		"gcp-project":   pulumi.String(cfg.Project),
		"gcp-region":    pulumi.String(cfg.Region),
		"ar-host":       pulumi.String(cfg.ARHost()),

		// Floating :prod tags -- AutoUpdate=registry has nothing to poll if
		// these are digests.
		"image-app":   pulumi.String(imageApp),
		"image-caddy": pulumi.String(imageCaddy),

		"domain":        pulumi.String(cfg.Domain),
		"app-port":      pulumi.String(strconv.Itoa(cfg.AppPort)),
		"health-path":   pulumi.String(cfg.HealthPath),
		"app-data-path": pulumi.String(cfg.AppDataPath),

		// Drives Coraza's SecRuleEngine and, from the same value, whether the
		// fail2ban jail acting on WAF verdicts is enabled.
		"waf-mode": pulumi.String(cfg.WAFMode),

		"podman-subnet":  pulumi.String(cfg.PodmanCIDR),
		"podman-gateway": pulumi.String(gatewayFor(cfg.PodmanCIDR)),

		"data-disk-device": pulumi.String("/dev/disk/by-id/google-" + DataDiskDeviceName),

		// Names and sources only, from infra/secret-names.txt.
		"secret-names": pulumi.String(secrets.Metadata(a.Secrets)),

		// Not read by the guest -- it exists so `gcloud compute instances
		// describe` shows which revision of vm/ the box was built against. It
		// also means every vm/ change is a (cheap, in-place) metadata update,
		// which keeps that change visible in `pulumi preview`.
		"config-hash": pulumi.String(a.Buckets.ConfigHash),
	}
	// The secret's NAME, in project watchtower-observe; vm/bootstrap.sh reads
	// the peer config itself, as this VM's service account. Left out when
	// unset, so the VM tears the tunnel and Alloy down. Metadata changes in
	// place.
	if cfg.WatchtowerPeerSecret != "" {
		metadata["watchtower-peer-secret"] = pulumi.String(cfg.WatchtowerPeerSecret)
	}

	vm, err := gcpcompute.NewInstance(ctx, "blog-vm", &gcpcompute.InstanceArgs{
		Name:        pulumi.String("blog-vm"),
		Zone:        pulumi.String(cfg.Zone),
		MachineType: pulumi.String(cfg.MachineType),
		Tags:        pulumi.ToStringArray([]string{network.Tag}),
		Description: pulumi.String("blog and Caddy as podman quadlets on AlmaLinux 10"),

		BootDisk: &gcpcompute.InstanceBootDiskArgs{
			InitializeParams: &gcpcompute.InstanceBootDiskInitializeParamsArgs{
				// Image family, not a pinned image: new VMs pick up the monthly
				// refreshed build automatically. The family is never re-resolved
				// for an existing VM, so this causes no diffs.
				Image: pulumi.String("almalinux-cloud/almalinux-10"),
				Size:  pulumi.Int(cfg.BootDiskGB),
				Type:  pulumi.String("pd-balanced"),
			},
		},

		AttachedDisks: gcpcompute.InstanceAttachedDiskArray{
			&gcpcompute.InstanceAttachedDiskArgs{
				Source:     disk.ID(),
				DeviceName: pulumi.String(DataDiskDeviceName),
				Mode:       pulumi.String("READ_WRITE"),
			},
		},

		NetworkInterfaces: gcpcompute.InstanceNetworkInterfaceArray{
			&gcpcompute.InstanceNetworkInterfaceArgs{
				Network:    a.Network.Network.ID(),
				Subnetwork: a.Network.Subnetwork.ID(),
				AccessConfigs: gcpcompute.InstanceNetworkInterfaceAccessConfigArray{
					&gcpcompute.InstanceNetworkInterfaceAccessConfigArgs{
						NatIp: a.Network.Address.Address,
					},
				},
			},
		},

		ServiceAccount: &gcpcompute.InstanceServiceAccountArgs{
			Email: a.SA.Email,
			// cloud-platform plus per-resource IAM, rather than a hand-rolled
			// scope list: scopes are a coarse legacy filter and IAM is where the
			// real restrictions live.
			Scopes: pulumi.ToStringArray([]string{"cloud-platform"}),
		},

		ShieldedInstanceConfig: &gcpcompute.InstanceShieldedInstanceConfigArgs{
			EnableSecureBoot:          pulumi.Bool(true),
			EnableVtpm:                pulumi.Bool(true),
			EnableIntegrityMonitoring: pulumi.Bool(true),
		},

		Metadata: metadata,

		// See Args.StartupStub: force-new, so it must stay a stub.
		MetadataStartupScript: pulumi.String(string(stub)),

		// Lets Pulumi change machine type in place (stop, resize, start)
		// instead of refusing the update.
		AllowStoppingForUpdate: pulumi.Bool(true),

		Labels: pulumi.StringMap{"app": pulumi.String("blog")},
	}, opts, pulumi.DependsOn(a.ReadyBefore))
	if err != nil {
		return nil, err
	}

	return &Instance{VM: vm, Disk: disk}, nil
}

// gatewayFor returns the .1 address of a /24 (config.validate enforces /24). The
// podman network's gateway has to be stated explicitly alongside the pinned
// subnet.
func gatewayFor(cidr string) string {
	var a, b, c, d, bits int
	if _, err := fmt.Sscanf(cidr, "%d.%d.%d.%d/%d", &a, &b, &c, &d, &bits); err != nil {
		return ""
	}
	return fmt.Sprintf("%d.%d.%d.1", a, b, c)
}
