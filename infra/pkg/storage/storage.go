// Package storage holds the buckets and, importantly, uploads the vm/ tree
// as Pulumi-managed objects.
//
// Uploading the VM configuration through Pulumi (rather than a `gcloud storage
// rsync` in a build step) means `pulumi preview` shows exactly which quadlet or
// template changed, and drift on the bucket is visible in state.
package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/storage"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"blog-infra/pkg/config"
)

type Buckets struct {
	Config *storage.Bucket
	Backup *storage.Bucket
	// Objects are the uploaded vm/ files. The instance depends on them: its
	// startup stub fetches vm/bootstrap.sh from the bucket on first boot, so
	// the objects must exist before the VM does.
	Objects []pulumi.Resource
	// ConfigHash changes whenever any file under vm/ changes. It is written into
	// instance metadata so a config change is visible from `describe`, and so
	// there is something to compare against when debugging drift.
	ConfigHash string
}

func New(ctx *pulumi.Context, cfg *config.Config, vmDir string, deps []pulumi.Resource) (*Buckets, error) {
	opts := pulumi.DependsOn(deps)

	configBucket, err := storage.NewBucket(ctx, "blog-config", &storage.BucketArgs{
		Name:     pulumi.Sprintf("%s-blog-config", cfg.Project),
		Location: pulumi.String(strings.ToUpper(cfg.Region)),
		// Uniform access: per-object ACLs are a footgun and IAM already covers it.
		UniformBucketLevelAccess: pulumi.Bool(true),
		PublicAccessPrevention:   pulumi.String("enforced"),
		Versioning:               &storage.BucketVersioningArgs{Enabled: pulumi.Bool(true)},
		ForceDestroy:             pulumi.Bool(true),
	}, opts)
	if err != nil {
		return nil, err
	}

	backupBucket, err := storage.NewBucket(ctx, "blog-backups", &storage.BucketArgs{
		Name:                     pulumi.Sprintf("%s-blog-backups", cfg.Project),
		Location:                 pulumi.String(strings.ToUpper(cfg.Region)),
		UniformBucketLevelAccess: pulumi.Bool(true),
		PublicAccessPrevention:   pulumi.String("enforced"),
		Versioning:               &storage.BucketVersioningArgs{Enabled: pulumi.Bool(true)},
		LifecycleRules: storage.BucketLifecycleRuleArray{
			&storage.BucketLifecycleRuleArgs{
				Action: &storage.BucketLifecycleRuleActionArgs{
					Type:         pulumi.String("SetStorageClass"),
					StorageClass: pulumi.String("NEARLINE"),
				},
				Condition: &storage.BucketLifecycleRuleConditionArgs{Age: pulumi.Int(30)},
			},
			&storage.BucketLifecycleRuleArgs{
				Action:    &storage.BucketLifecycleRuleActionArgs{Type: pulumi.String("Delete")},
				Condition: &storage.BucketLifecycleRuleConditionArgs{Age: pulumi.Int(365)},
			},
		},
		// No ForceDestroy: dumps are the disaster-recovery path and should not
		// disappear because someone ran `pulumi destroy`.
	}, opts, pulumi.Protect(true))
	if err != nil {
		return nil, err
	}

	objects, hash, err := uploadTree(ctx, configBucket, vmDir)
	if err != nil {
		return nil, err
	}

	return &Buckets{
		Config:     configBucket,
		Backup:     backupBucket,
		Objects:    objects,
		ConfigHash: hash,
	}, nil
}

// uploadTree mirrors vmDir into gs://<bucket>/vm/ and returns the objects and a
// content hash of the whole tree.
func uploadTree(ctx *pulumi.Context, bucket *storage.Bucket, vmDir string) ([]pulumi.Resource, string, error) {
	var paths []string
	err := filepath.WalkDir(vmDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		paths = append(paths, path)
		return nil
	})
	if err != nil {
		return nil, "", fmt.Errorf("walking %s: %w", vmDir, err)
	}
	// Deterministic order, so the hash is stable across machines.
	sort.Strings(paths)

	var objects []pulumi.Resource
	sum := sha256.New()
	for _, p := range paths {
		rel, err := filepath.Rel(vmDir, p)
		if err != nil {
			return nil, "", err
		}
		rel = filepath.ToSlash(rel)

		content, err := os.ReadFile(p)
		if err != nil {
			return nil, "", err
		}
		sum.Write([]byte(rel))
		sum.Write(content)

		obj, err := storage.NewBucketObject(ctx, "vm/"+rel, &storage.BucketObjectArgs{
			Name:   pulumi.String("vm/" + rel),
			Bucket: bucket.Name,
			Source: pulumi.NewFileAsset(p),
		})
		if err != nil {
			return nil, "", err
		}
		objects = append(objects, obj)
	}
	return objects, hex.EncodeToString(sum.Sum(nil))[:16], nil
}
