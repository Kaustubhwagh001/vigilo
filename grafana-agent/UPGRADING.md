# Upgrading Grafana Agent (classic, static mode)

A short runbook for bumping `GRAFANA_AGENT_VERSION` on an existing
install — binary swap, keep the old binary for rollback, restart the
service. This mirrors what the source onboarding material did by hand
(download new binary, rename the old one as a backup, swap in the new
one, restart), reproduced here as a safe, repeatable sequence.

Read [`README.md`](README.md) first: Grafana Agent (classic/static mode)
is archived upstream with no binaries published past `v0.43.4` on most
release channels, and a few scripts in this repo pin an older
version/asset-name pairing deliberately — **don't** run this against every
script's install at once without checking which ones that applies to.

## Before you start

- Confirm the target version is a real, published release:
  `curl -s https://api.github.com/repos/grafana/agent/releases/tags/<version>`
  (see [`linux/README.md`](linux/README.md) and
  [`integrations/README.md`](integrations/README.md) for how each script's
  `ARTIFACT_BASE_URL` / `ARTIFACT_NAME` convention was verified against
  this same API — the release asset was renamed from
  `agent-linux-amd64.zip` to `grafana-agent-linux-amd64.zip` around v0.31,
  so check which name your target version uses).
- Know which systemd unit you're upgrading (`grafana-agent.service`,
  `mongodb_exporter.service`, `grafana-agent-clickhouse.service`, etc. —
  one per integration script in this repo, not a single shared service).
- Have a maintenance window: this restarts the service, which drops
  in-flight scrapes/WAL writes for the few seconds the process is down.

## Steps

```bash
# 1. Pick the new version and confirm the asset exists.
export GRAFANA_AGENT_VERSION="v0.44.2"   # whatever you're upgrading to
export ARTIFACT_BASE_URL="https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}"
export ARTIFACT_NAME="grafana-agent-linux-amd64"   # agent-linux-amd64 pre-v0.31

# 2. Download the new binary into a scratch directory — don't overwrite
#    the running binary yet.
cd /tmp
curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"

# 3. Back up the currently-installed binary before touching it — this is
#    your rollback path if the new version misbehaves.
cd /usr/local/bin
sudo cp "${ARTIFACT_NAME}" "${ARTIFACT_NAME}.bak"

# 4. Swap in the new binary.
sudo mv "/tmp/${ARTIFACT_NAME}" "/usr/local/bin/${ARTIFACT_NAME}"

# 5. Restart the service that runs it (substitute the actual unit name —
#    see each integration script's header comment for which one it
#    installs).
sudo systemctl restart grafana-agent.service
sudo systemctl status grafana-agent.service --no-pager

# 6. Confirm it's healthy — check the process is up and the config
#    reloaded cleanly, then watch your Mimir/Loki backend for the
#    expected series/streams to keep flowing for this host's tenant(s).
sudo journalctl -u grafana-agent.service -n 50 --no-pager
```

## Rolling back

If the new version misbehaves, reverse step 4: stop the service, move
`${ARTIFACT_NAME}.bak` back over `${ARTIFACT_NAME}`, and restart.

```bash
sudo systemctl stop grafana-agent.service
sudo mv "/usr/local/bin/${ARTIFACT_NAME}.bak" "/usr/local/bin/${ARTIFACT_NAME}"
sudo systemctl start grafana-agent.service
```

## Notes

- This runbook intentionally does not touch `/etc/grafana-agent-*-config.yaml`
  — a version bump alone shouldn't require a config change. If the new
  version deprecates or renames a config key you rely on, handle that as
  its own change, separately from the binary swap.
- For scripts that version-pin the asset name itself (see
  [`integrations/README.md`](integrations/README.md)'s note on the
  `agent-linux-amd64` → `grafana-agent-linux-amd64` rename around v0.31),
  update `ARTIFACT_NAME` alongside `GRAFANA_AGENT_VERSION`, or the download
  in step 2 will 404.
