// Package network builds the VPC, its firewall rules, and the static address the
// DNS A record points at.
package network

import (
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/compute"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"blog-infra/pkg/config"
)

// Tag is applied to the instance and targeted by every firewall rule below.
const Tag = "blog"

// IAPRange is the fixed source range Google's IAP TCP forwarding connects from.
// It is the only path to port 22 -- there is no other SSH ingress. The same
// range appears in vm/nftables/host.nft and in fail2ban's ignoreip; IAP is the
// only way back into the box, so it must never be banned.
const IAPRange = "35.235.240.0/20"

// SubnetCIDR must not overlap the VM's pinned podman subnet (blog:podmanSubnet).
const SubnetCIDR = "10.10.0.0/24"

type Network struct {
	Network    *compute.Network
	Subnetwork *compute.Subnetwork
	Address    *compute.Address
}

func New(ctx *pulumi.Context, cfg *config.Config, deps []pulumi.Resource) (*Network, error) {
	opts := pulumi.DependsOn(deps)

	net, err := compute.NewNetwork(ctx, "blog-vpc", &compute.NetworkArgs{
		Name: pulumi.String("blog-vpc"),
		// Custom mode: auto mode would create a subnet in every region, which is
		// a lot of unused surface for a single VM.
		AutoCreateSubnetworks: pulumi.Bool(false),
		Description:           pulumi.String("blog deployment network"),
	}, opts)
	if err != nil {
		return nil, err
	}

	subnet, err := compute.NewSubnetwork(ctx, "blog-subnet", &compute.SubnetworkArgs{
		Name:                  pulumi.String("blog-subnet"),
		Network:               net.ID(),
		IpCidrRange:           pulumi.String(SubnetCIDR),
		Region:                pulumi.String(cfg.Region),
		PrivateIpGoogleAccess: pulumi.Bool(true),
	}, opts)
	if err != nil {
		return nil, err
	}

	addr, err := compute.NewAddress(ctx, "blog-ip", &compute.AddressArgs{
		Name:        pulumi.String("blog-ip"),
		Region:      pulumi.String(cfg.Region),
		AddressType: pulumi.String("EXTERNAL"),
		Description: pulumi.String("Static address for blog-vm; the DNS A record depends on it"),
	}, opts)
	if err != nil {
		return nil, err
	}

	if _, err := compute.NewFirewall(ctx, "blog-allow-web", &compute.FirewallArgs{
		Name:    pulumi.String("blog-allow-web"),
		Network: net.ID(),
		Allows: compute.FirewallAllowArray{
			&compute.FirewallAllowArgs{Protocol: pulumi.String("tcp"), Ports: pulumi.ToStringArray([]string{"80", "443"})},
			// HTTP/3.
			&compute.FirewallAllowArgs{Protocol: pulumi.String("udp"), Ports: pulumi.ToStringArray([]string{"443"})},
		},
		SourceRanges: pulumi.ToStringArray([]string{"0.0.0.0/0"}),
		TargetTags:   pulumi.ToStringArray([]string{Tag}),
		// Port 80 exists only for the HTTP->HTTPS redirect. ACME uses DNS-01, so
		// certificates never depend on inbound 80 and it can be dropped if wanted.
		Description: pulumi.String("Public HTTPS (and HTTP redirect)"),
	}, opts); err != nil {
		return nil, err
	}

	// An extra public TCP port the app serves directly (a protocol Caddy does
	// not proxy -- SSH, SMTP, a game server) needs a rule like this one PLUS
	// three more edits: PublishPort in vm/quadlets/blog.container, an accept
	// line in vm/nftables/host.nft, and the port list of the jail in
	// vm/fail2ban/jail.d/blog.local. Missing the jail means bans do not cover
	// it; see the skill's references/firewall.md.
	//
	// if _, err := compute.NewFirewall(ctx, "blog-allow-extra", &compute.FirewallArgs{
	// 	Name:         pulumi.String("blog-allow-extra"),
	// 	Network:      net.ID(),
	// 	Allows:       compute.FirewallAllowArray{&compute.FirewallAllowArgs{Protocol: pulumi.String("tcp"), Ports: pulumi.ToStringArray([]string{"2222"})}},
	// 	SourceRanges: pulumi.ToStringArray([]string{"0.0.0.0/0"}),
	// 	TargetTags:   pulumi.ToStringArray([]string{Tag}),
	// }, opts); err != nil {
	// 	return nil, err
	// }

	if _, err := compute.NewFirewall(ctx, "blog-allow-iap-ssh", &compute.FirewallArgs{
		Name:    pulumi.String("blog-allow-iap-ssh"),
		Network: net.ID(),
		Allows: compute.FirewallAllowArray{
			&compute.FirewallAllowArgs{Protocol: pulumi.String("tcp"), Ports: pulumi.ToStringArray([]string{"22"})},
		},
		SourceRanges: pulumi.ToStringArray([]string{IAPRange}),
		TargetTags:   pulumi.ToStringArray([]string{Tag}),
		Description:  pulumi.String("Admin SSH via IAP TCP forwarding only"),
	}, opts); err != nil {
		return nil, err
	}

	return &Network{Network: net, Subnetwork: subnet, Address: addr}, nil
}
