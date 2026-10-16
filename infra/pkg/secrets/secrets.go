// Package secrets names the application's Secret Manager secrets. It
// deliberately creates nothing.
//
// The secrets are created and populated by scripts/bootstrap.sh, outside
// Pulumi, for two reasons:
//
//  1. Ordering. The VM boots during the same `pulumi up` that would create
//     them, and wants to render the app's config immediately. Values that
//     exist before the first apply remove the race entirely.
//
//  2. Blast radius. `pulumi destroy` must not be able to delete the keys every
//     existing session and signed token depends on. Same reasoning as the
//     pre-existing DNS zone and the backup bucket.
//
// Pulumi still grants the VM access to them by id -- an IAM binding does not
// require owning the resource -- and never reads a value.
package secrets

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// Prefix every secret id carries. vm/bootstrap.sh strips it to build the
// SECRET_<NAME> variable the config templates reference.
const Prefix = "blog-"

// ACMEEmail is special-cased by vm/bootstrap.sh into Caddy's global options.
const ACMEEmail = Prefix + "acme-email"

// File is relative to infra/, which is where Pulumi runs the program.
const File = "secret-names.txt"

type Source string

const (
	// Generate: populated by scripts/bootstrap.sh; required by the VM.
	Generate Source = "generate"
	// Operator: populated by hand; optional on the VM.
	Operator Source = "operator"
)

type Secret struct {
	ID     string
	Source Source
}

var idPattern = regexp.MustCompile(`^[a-z][a-z0-9-]*[a-z0-9]$`)

// Load parses secret-names.txt. A malformed line is an error, not a skip: a
// silently dropped secret is a VM that never renders its config.
func Load(path string) ([]Secret, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	defer f.Close()

	var out []Secret
	seen := map[string]bool{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s:%d: want `<secret-id> <generate|operator>`, got %q", path, n, line)
		}
		id, src := fields[0], Source(fields[1])
		if !strings.HasPrefix(id, Prefix) || !idPattern.MatchString(id) {
			return nil, fmt.Errorf("%s:%d: secret id %q must match %s[a-z0-9-]+", path, n, id, Prefix)
		}
		if src != Generate && src != Operator {
			return nil, fmt.Errorf("%s:%d: source %q must be generate or operator", path, n, src)
		}
		if seen[id] {
			return nil, fmt.Errorf("%s:%d: %s listed twice", path, n, id)
		}
		seen[id] = true
		out = append(out, Secret{ID: id, Source: src})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// Metadata encodes the list for the VM as "id:source,id:source". Names and
// sources are not sensitive; values never pass through here.
func Metadata(list []Secret) string {
	parts := make([]string, len(list))
	for i, s := range list {
		parts[i] = s.ID + ":" + string(s.Source)
	}
	return strings.Join(parts, ",")
}
