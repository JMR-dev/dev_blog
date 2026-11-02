// Package config turns loose Pulumi stack config into one typed struct, so the
// rest of the program never reaches back into the config bag and every key has
// exactly one spelling.
package config

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// Namespace is the Pulumi config namespace, which must equal the project name
// in Pulumi.yaml for `blog:<key>` to resolve.
const Namespace = "blog"

type Config struct {
	Project string
	Region  string
	Zone    string

	Domain     string
	DNSZone    string
	PodmanCIDR string

	MachineType string
	BootDiskGB  int
	DataDiskGB  int

	// The app container's contract. See vm/quadlets/blog.container.
	AppPort     int
	HealthPath  string
	AppDataPath string

	// WAFMode is the Coraza SecRuleEngine setting. It also decides whether the
	// fail2ban jail that acts on WAF verdicts is enabled at all.
	WAFMode string

	// WatchtowerPeerSecret names the secret in project watchtower-observe that
	// holds this VM's WireGuard peer config for the watchtower VPN.
	// vm/bootstrap.sh fetches it as the VM's own service account and ships
	// logs and metrics through that tunnel (vm/quadlets/alloy.container).
	// Empty means no tunnel and no Alloy. A name, never a value.
	WatchtowerPeerSecret string
}

// A Secret Manager secret id.
var secretIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,255}$`)

func Load(ctx *pulumi.Context) (*Config, error) {
	gcp := config.New(ctx, "gcp")
	c := config.New(ctx, Namespace)

	cfg := &Config{
		Project: gcp.Require("project"),
		Region:  gcp.Get("region"),

		Zone:       c.Get("zone"),
		Domain:     c.Require("domain"),
		DNSZone:    c.Require("dnsZone"),
		PodmanCIDR: c.Get("podmanSubnet"),

		MachineType: c.Get("machineType"),
		BootDiskGB:  c.GetInt("bootDiskGb"),
		DataDiskGB:  c.GetInt("dataDiskGb"),

		AppPort:     c.GetInt("appPort"),
		HealthPath:  c.Get("healthPath"),
		AppDataPath: c.Get("appDataPath"),

		WAFMode: c.Get("wafMode"),

		WatchtowerPeerSecret: c.Get("watchtowerPeerSecret"),
	}

	applyDefaults(cfg)
	return cfg, validate(cfg)
}

func applyDefaults(c *Config) {
	if c.Region == "" {
		c.Region = "us-east1"
	}
	if c.Zone == "" {
		// "-b", not "-a": us-east1 has zones b, c and d and NO -a zone, so the
		// obvious default would generate an invalid zone. "-b" exists in every
		// US region. Set blog:zone explicitly if you care which one.
		c.Zone = c.Region + "-b"
	}
	if c.PodmanCIDR == "" {
		c.PodmanCIDR = "10.89.10.0/24"
	}
	if c.MachineType == "" {
		c.MachineType = "e2-small"
	}
	if c.BootDiskGB == 0 {
		c.BootDiskGB = 20
	}
	if c.DataDiskGB == 0 {
		c.DataDiskGB = 30
	}
	if c.AppPort == 0 {
		c.AppPort = 8080
	}
	if c.HealthPath == "" {
		c.HealthPath = "/healthz"
	}
	if c.AppDataPath == "" {
		c.AppDataPath = "/data"
	}
	if c.WAFMode == "" {
		// Detect first, tune, then block. Starting a WAF in blocking mode in
		// front of an app whose POST bodies legitimately carry code, markdown or
		// SQL is how you get paged on day one.
		c.WAFMode = "DetectionOnly"
	}
}

func validate(c *Config) error {
	if !strings.Contains(c.Domain, ".") {
		return fmt.Errorf("%s:domain %q does not look like a hostname", Namespace, c.Domain)
	}
	if !strings.HasPrefix(c.Zone, c.Region) {
		return fmt.Errorf("%s:zone %q is not in gcp:region %q", Namespace, c.Zone, c.Region)
	}
	switch c.WAFMode {
	case "On", "DetectionOnly", "Off":
	default:
		return fmt.Errorf("%s:wafMode %q must be On, DetectionOnly, or Off", Namespace, c.WAFMode)
	}
	if c.AppPort < 1 || c.AppPort > 65535 {
		return fmt.Errorf("%s:appPort %d is not a port", Namespace, c.AppPort)
	}
	switch c.AppPort {
	case 80, 443, 2019:
		// Caddy owns 80/443 on the host and its admin API on 2019 inside its
		// own container; the app publishing any of them collides on the host
		// network fallback (see vm/bootstrap.sh probe_caddy_network).
		return fmt.Errorf("%s:appPort %d collides with Caddy", Namespace, c.AppPort)
	}
	if !strings.HasPrefix(c.HealthPath, "/") {
		return fmt.Errorf("%s:healthPath %q must start with /", Namespace, c.HealthPath)
	}
	if !strings.HasPrefix(c.AppDataPath, "/") {
		return fmt.Errorf("%s:appDataPath %q must be absolute", Namespace, c.AppDataPath)
	}
	if !strings.HasSuffix(c.PodmanCIDR, "/24") {
		// gatewayFor in package compute derives the .1 gateway from a /24.
		return fmt.Errorf("%s:podmanSubnet %q must be a /24", Namespace, c.PodmanCIDR)
	}
	if c.WatchtowerPeerSecret != "" && !secretIDPattern.MatchString(c.WatchtowerPeerSecret) {
		// The id alone, not a resource path: vm/bootstrap.sh supplies the project.
		return fmt.Errorf("%s:watchtowerPeerSecret %q is not a secret id", Namespace, c.WatchtowerPeerSecret)
	}
	return nil
}

// ARHost is the Artifact Registry endpoint for the configured region.
func (c *Config) ARHost() string { return c.Region + "-docker.pkg.dev" }

// FQDN returns the domain with a trailing dot, as Cloud DNS requires.
func (c *Config) FQDN() string { return c.Domain + "." }
