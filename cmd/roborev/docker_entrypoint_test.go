package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// entrypointScript returns the absolute path to the production docker entrypoint,
// resolved from this test file's location so it works regardless of CWD.
func entrypointScript(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	require.True(t, ok, "runtime.Caller failed")
	p := filepath.Join(filepath.Dir(thisFile), "..", "..", "docker-entrypoint.sh")
	if _, err := os.Stat(p); err != nil {
		t.Skipf("entrypoint script not found at %s: %v", p, err)
	}
	return p
}

// writeRuntimeMeta writes a daemon.<pid>.json runtime record with the given
// bound address, mirroring what the daemon's kit runtime store emits.
func writeRuntimeMeta(t *testing.T, dataDir string, pid int, address string) {
	t.Helper()
	dir := filepath.Join(dataDir, "runtime")
	require.NoError(t, os.MkdirAll(dir, 0o755))
	body := `{"pid": ` + strconv.Itoa(pid) + `, "network": "tcp", "address": "` + address + `", "service": "roborev"}`
	require.NoError(t, os.WriteFile(filepath.Join(dir, "daemon."+strconv.Itoa(pid)+".json"), []byte(body), 0o600))
}

// runResolve invokes the entrypoint's resolve-only seam for the given pid and
// returns (stdout, exitCode). It never starts the daemon or socat.
func runResolve(t *testing.T, dataDir string, pid, maxTries int) (string, int) {
	t.Helper()
	cmd := exec.Command("sh", entrypointScript(t))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"ROBOREV_DATA_DIR=" + dataDir,
		"ROBOREV_RESOLVE_ONLY=1",
		"ROBOREV_RESOLVE_PID=" + strconv.Itoa(pid),
		"ROBOREV_RESOLVE_MAX_TRIES=" + strconv.Itoa(maxTries),
	}
	out, err := cmd.Output()
	code := 0
	if err != nil {
		var ee *exec.ExitError
		require.ErrorAs(t, err, &ee, "unexpected non-exit error")
		code = ee.ExitCode()
	}
	return strings.TrimSpace(string(out)), code
}

// liveHelperPID starts a short-lived process and returns its PID; the process is
// killed at test cleanup. Used as a stand-in for a "running daemon" pid.
func liveHelperPID(t *testing.T) int {
	t.Helper()
	c := exec.Command("sleep", "30")
	require.NoError(t, c.Start())
	t.Cleanup(func() { _ = c.Process.Kill(); _, _ = c.Process.Wait() })
	return c.Process.Pid
}

func TestDockerEntrypointResolveBackend(t *testing.T) {
	t.Run("resolves the address for the live pid and ignores stale records", func(t *testing.T) {
		dir := t.TempDir()
		pid := liveHelperPID(t)
		writeRuntimeMeta(t, dir, pid, "127.0.0.1:7401")
		// A stale record from a previous run with a different (dead) pid + wrong port.
		writeRuntimeMeta(t, dir, 999999, "127.0.0.1:9999")

		addr, code := runResolve(t, dir, pid, 50)
		assert.Equal(t, 0, code)
		assert.Equal(t, "127.0.0.1:7401", addr, "must read the PID-keyed record, not the stale one")
	})

	t.Run("times out without guessing when no record appears", func(t *testing.T) {
		dir := t.TempDir()
		pid := liveHelperPID(t)
		// Only a stale, non-matching record exists.
		writeRuntimeMeta(t, dir, 999999, "127.0.0.1:9999")

		addr, code := runResolve(t, dir, pid, 3)
		assert.Equal(t, 1, code, "should fail rather than fall back to a guessed address")
		assert.Empty(t, addr)
	})

	t.Run("reports daemon death when the pid is gone", func(t *testing.T) {
		dir := t.TempDir()
		dead := exec.Command("sleep", "30")
		require.NoError(t, dead.Start())
		pid := dead.Process.Pid
		require.NoError(t, dead.Process.Kill())
		_, _ = dead.Process.Wait()

		_, code := runResolve(t, dir, pid, 50)
		assert.Equal(t, 2, code, "a dead daemon pid should be reported distinctly")
	})
}
