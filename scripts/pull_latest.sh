#!/usr/bin/env bash
# scripts/pull_latest.sh — on the public host, pulls the latest committed DB
# from main and restarts the two backend services so they pick it up.
#
# Wire to a cron, e.g. 15 minutes after the GitHub Actions nightly job:
#   15 3 * * * cd /opt/solar-system-db && ./scripts/pull_latest.sh >> /var/log/solar-pull.log 2>&1

set -euo pipefail

cd "$(dirname "$0")/.."

echo "[$(date -u +%FT%TZ)] pulling latest from origin/main"
git fetch origin
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse origin/main)

if [[ "$local_sha" == "$remote_sha" ]]; then
  echo "  already up to date at $local_sha"
  exit 0
fi

git reset --hard origin/main
echo "  updated to $(git rev-parse HEAD)"

# Both services hold the SQLite file open with mmap — recycle them so they
# re-open the freshly-pulled file. The DB is mounted read-only into the
# containers; the file on disk has changed, but a restart is required for
# SQLite to release any cached pages.
docker compose restart rest-api mcp-server

echo "[$(date -u +%FT%TZ)] done"
