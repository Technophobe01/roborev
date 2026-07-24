// PostgreSQL sync configuration.

package config

import (
	"os"
	"regexp"
	"strings"
)

// SyncConfig holds configuration for PostgreSQL sync
type SyncConfig struct {
	// Enabled enables sync to PostgreSQL
	Enabled bool `toml:"enabled"`

	// PostgresURL is the connection string for PostgreSQL.
	// Supports ${VAR} environment-variable expansion and ${file:/path}
	// references whose (trimmed) file contents are substituted — the latter
	// lets a credential live in a 0600 file instead of inline in this config,
	// and lets a daemon started outside the process that set the env still
	// resolve the password.
	PostgresURL string `toml:"postgres_url" sensitive:"true"`

	// Interval is how often to sync (e.g., "5m", "1h"). Default: 1h
	Interval string `toml:"interval"`

	// MachineName is a friendly name for this machine (optional)
	MachineName string `toml:"machine_name"`

	// ConnectTimeout is the connection timeout (e.g., "5s"). Default: 5s
	ConnectTimeout string `toml:"connect_timeout"`

	// RepoNames provides custom display names for synced repos by identity.
	// Example: {"git@github.com:org/repo.git": "my-project"}
	RepoNames map[string]string `toml:"repo_names"`
}

// PostgresURLExpanded returns the PostgreSQL URL with ${file:/path} references
// resolved to the trimmed file contents and ${VAR} environment variables
// expanded. Returns empty string if URL is not set. A ${file:/path} that cannot
// be read (like an unset ${VAR}) expands to empty, so the connection fails at
// dial time rather than the reference leaking through verbatim.
func (c *SyncConfig) PostgresURLExpanded() string {
	if c.PostgresURL == "" {
		return ""
	}
	return os.Expand(c.PostgresURL, func(key string) string {
		if path, ok := strings.CutPrefix(key, "file:"); ok {
			b, err := os.ReadFile(strings.TrimSpace(path))
			if err != nil {
				return ""
			}
			return strings.TrimSpace(string(b))
		}
		return os.Getenv(key)
	})
}

// GetRepoDisplayName returns the configured display name for a repo identity,
// or empty string if no override is configured.
func (c *SyncConfig) GetRepoDisplayName(identity string) string {
	if c == nil || c.RepoNames == nil {
		return ""
	}
	return c.RepoNames[identity]
}

// Validate checks the sync configuration for common issues.
// Returns a list of warnings (non-fatal issues).
func (c *SyncConfig) Validate() []string {
	var warnings []string

	if !c.Enabled {
		return warnings
	}

	if c.PostgresURL == "" {
		warnings = append(warnings, "sync.enabled is true but sync.postgres_url is not set")
		return warnings
	}

	// Flag references that will expand to empty: an unset ${VAR}, or a
	// ${file:/path} whose file cannot be read. Both leave the URL without a
	// resolved value (typically the password) and the connection fails at dial.
	if strings.Contains(c.PostgresURL, "${") {
		re := regexp.MustCompile(`\$\{([^}]+)\}`)
		for _, match := range re.FindAllStringSubmatch(c.PostgresURL, -1) {
			if len(match) < 2 {
				continue
			}
			if path, ok := strings.CutPrefix(match[1], "file:"); ok {
				if _, err := os.Stat(strings.TrimSpace(path)); err != nil {
					warnings = append(warnings, "sync.postgres_url references a file that cannot be read: "+strings.TrimSpace(path))
					break
				}
			} else if os.Getenv(match[1]) == "" {
				warnings = append(warnings, "sync.postgres_url may contain unexpanded environment variables")
				break
			}
		}
	}

	return warnings
}
