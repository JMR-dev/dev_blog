// Invariant tests under Pulumi's mock runtime: no cloud calls, no credentials.
// `make check` runs them. When you change what the stack must guarantee (a
// metadata key, a grant, a validation rule), change it here too.
//
// Run from infra/ (the module root) or with `make check`. They read
// secret-names.txt and ../vm/startup.sh relative to the package directory,
// which is where `go test` runs them.

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"blog-infra/pkg/secrets"
)

type rec struct {
	typ, name string
	inputs    resource.PropertyMap
}

type mocks struct {
	mu   sync.Mutex
	recs []rec
}

func (m *mocks) NewResource(a pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	m.mu.Lock()
	m.recs = append(m.recs, rec{a.TypeToken, a.Name, a.Inputs})
	m.mu.Unlock()
	out := a.Inputs.Copy()
	switch a.TypeToken {
	case "gcp:compute/address:Address":
		out["address"] = resource.NewStringProperty("203.0.113.9")
	case "gcp:serviceaccount/account:Account":
		out["email"] = resource.NewStringProperty(a.Name + "@demo.iam.gserviceaccount.com")
	}
	return a.Name + "_id", out, nil
}

func (m *mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) {
	if a.Token == "gcp:dns/getManagedZone:getManagedZone" {
		return resource.PropertyMap{"name": resource.NewStringProperty("zone"), "dnsName": resource.NewStringProperty("example.org.")}, nil
	}
	return resource.PropertyMap{}, nil
}

func cfgWith(extra map[string]string) map[string]string {
	cfg := map[string]string{
		"gcp:project":  "demo",
		"gcp:region":   "us-east1",
		"blog:domain":  "blog.example.org",
		"blog:dnsZone": "zone",
	}
	for k, v := range extra {
		cfg[k] = v
	}
	return cfg
}

func runErr(t *testing.T, cfg map[string]string) (*mocks, error) {
	b, _ := json.Marshal(cfg)
	t.Setenv("PULUMI_CONFIG", string(b))
	m := &mocks{}
	err := pulumi.RunErr(program, pulumi.WithMocks("blog", "prod", m))
	return m, err
}

func run(t *testing.T, extra map[string]string) *mocks {
	m, err := runErr(t, cfgWith(extra))
	if err != nil {
		t.Fatalf("program failed: %v", err)
	}
	return m
}

func byType(m *mocks, typ string) []rec {
	var out []rec
	for _, r := range m.recs {
		if r.typ == typ {
			out = append(out, r)
		}
	}
	return out
}

func TestDefaults(t *testing.T) {
	m := run(t, nil)
	vms := byType(m, "gcp:compute/instance:Instance")
	if len(vms) != 1 {
		t.Fatalf("want 1 instance, got %d", len(vms))
	}
	in := vms[0].inputs
	stub, _ := os.ReadFile("../vm/startup.sh")
	if got := in["metadataStartupScript"].StringValue(); got != string(stub) {
		t.Errorf("startup script is not vm/startup.sh (len %d vs %d)", len(got), len(stub))
	}
	md := in["metadata"].ObjectValue()
	want := map[string]string{
		"secret-names":   "blog-acme-email:operator",
		"app-port":       "8080",
		"health-path":    "/healthz",
		"app-data-path":  "/data",
		"waf-mode":       "DetectionOnly",
		"podman-gateway": "10.89.10.1",
		"image-app":      "us-east1-docker.pkg.dev/demo/blog/blog:prod",
		"domain":         "blog.example.org",
	}
	for k, v := range want {
		if got := md[resource.PropertyKey(k)].StringValue(); got != v {
			t.Errorf("metadata %s = %q, want %q", k, got, v)
		}
	}
	// No peer configured, no key: the VM then keeps the tunnel and Alloy down.
	for _, k := range []string{"startup-script", "acme-email", "watchtower-peer-secret"} {
		if _, ok := md[resource.PropertyKey(k)]; ok {
			t.Errorf("metadata must not carry %s", k)
		}
	}
	var granted []string
	for _, r := range byType(m, "gcp:secretmanager/secretIamMember:SecretIamMember") {
		granted = append(granted, r.inputs["secretId"].StringValue()+"="+r.inputs["role"].StringValue())
	}
	if strings.Join(granted, ",") != "blog-acme-email=roles/secretmanager.secretAccessor" {
		t.Errorf("secret grants: %v", granted)
	}
	for _, r := range m.recs {
		if strings.HasPrefix(r.typ, "kubernetes:") || strings.HasPrefix(r.typ, "gcp:container") {
			t.Errorf("unexpected %s", r.typ)
		}
	}
	objs := byType(m, "gcp:storage/bucketObject:BucketObject")
	names := map[string]bool{}
	for _, o := range objs {
		names[o.inputs["name"].StringValue()] = true
	}
	for _, n := range []string{"vm/bootstrap.sh", "vm/startup.sh", "vm/quadlets/blog.container", "vm/nftables/host.nft"} {
		if !names[n] {
			t.Errorf("missing bucket object %s", n)
		}
	}
	t.Logf("%d resources, %d vm/ objects", len(m.recs), len(objs))
}

// CI/CD is Gitea Actions, running as gitea-deploy@ (created by
// scripts/bootstrap.sh). Nothing Cloud Build-shaped belongs in the stack, and no
// second deploy identity should creep back in.
func TestNoCloudBuild(t *testing.T) {
	m := run(t, nil)
	for _, r := range m.recs {
		if strings.HasPrefix(r.typ, "gcp:cloudbuild") || strings.HasPrefix(r.typ, "gcp:cloudscheduler") {
			t.Errorf("unexpected %s %s", r.typ, r.name)
		}
	}
	sas := byType(m, "gcp:serviceaccount/account:Account")
	if len(sas) != 1 || sas[0].inputs["accountId"].StringValue() != "blog-vm" {
		t.Errorf("want only the blog-vm service account, got %v", sas)
	}
	for _, b := range byType(m, "gcp:storage/bucket:Bucket") {
		if strings.Contains(b.inputs["name"].StringValue(), "build-source") {
			t.Errorf("unexpected build-source bucket")
		}
	}
}

// The VM may write DNS records only in its own (delegated) zone: a compromised
// blog VM must not be able to repoint the parent zone's apex or mail records.
// Project-level DNS access is read-only.
func TestDNSScope(t *testing.T) {
	m := run(t, nil)
	zoneGrants := byType(m, "gcp:dns/dnsManagedZoneIamMember:DnsManagedZoneIamMember")
	if len(zoneGrants) != 1 || zoneGrants[0].inputs["managedZone"].StringValue() != "zone" {
		t.Errorf("want one grant on the configured zone, got %v", zoneGrants)
	}
	for _, r := range byType(m, "gcp:projects/iAMMember:IAMMember") {
		if role := r.inputs["role"].StringValue(); strings.HasPrefix(role, "roles/dns.") && role != "roles/dns.reader" {
			t.Errorf("project-level %s on %s", role, r.inputs["member"].StringValue())
		}
	}
	if n := len(byType(m, "gcp:dns/managedZone:ManagedZone")); n != 0 {
		t.Errorf("the zone must not be Pulumi-owned, got %d ManagedZone resources", n)
	}
}

// The watchtower peer goes to the VM by name only: the metadata carries the
// secret's id, the VM reads the value as its own service account, and this
// program grants nothing for it (watchtower's bootstrap.sh does, in its own
// project).
func TestWatchtowerPeer(t *testing.T) {
	m := run(t, map[string]string{"blog:watchtowerPeerSecret": "wireguard-blog-vm-peer"})
	md := byType(m, "gcp:compute/instance:Instance")[0].inputs["metadata"].ObjectValue()
	if got := md["watchtower-peer-secret"].StringValue(); got != "wireguard-blog-vm-peer" {
		t.Errorf("metadata watchtower-peer-secret = %q", got)
	}
	for _, r := range byType(m, "gcp:secretmanager/secretIamMember:SecretIamMember") {
		if id := r.inputs["secretId"].StringValue(); strings.Contains(id, "wireguard") {
			t.Errorf("unexpected grant on %s: the peer's secret is not this project's", id)
		}
	}
}

func TestValidation(t *testing.T) {
	for _, c := range []map[string]string{
		{"blog:appPort": "443"},
		{"blog:podmanSubnet": "10.89.0.0/16"},
		{"blog:wafMode": "Block"},
		{"blog:healthPath": "healthz"},
		{"blog:zone": "us-west1-a"},
		{"blog:watchtowerPeerSecret": "projects/watchtower-observe/secrets/wireguard-blog-vm-peer"},
	} {
		if _, err := runErr(t, cfgWith(c)); err == nil {
			t.Errorf("%v: want a validation error", c)
		}
	}
}

func TestSecretsFile(t *testing.T) {
	dir := t.TempDir()
	for body, ok := range map[string]bool{
		"blog-a generate\nblog-b operator\n": true,
		"blog-a generate extra\n":            false,
		"other-a generate\n":                 false,
		"blog-a sometimes\n":                 false,
		"blog-a generate\nblog-a operator\n": false,
	} {
		p := filepath.Join(dir, "s.txt")
		os.WriteFile(p, []byte(body), 0o644)
		_, err := secrets.Load(p)
		if (err == nil) != ok {
			t.Errorf("%q: err=%v, want ok=%v", body, err, ok)
		}
	}
}
