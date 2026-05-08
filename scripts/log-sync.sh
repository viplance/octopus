#!/usr/bin/env bash
# log-sync.sh — push /tmp/octopus-debug.log to a per-host branch on GitHub
# so the other Mac (and you) can see it in near real time.
#
# Run on each Mac:    ./scripts/log-sync.sh
# Stop with Ctrl-C. The companion log-watch.sh script reads all branches.
#
# Branch layout: logs/<sanitized-hostname>
# Push cadence:  every $INTERVAL seconds (default 5)

set -euo pipefail

INTERVAL="${INTERVAL:-5}"
LOG_FILE="${LOG_FILE:-/tmp/octopus-debug.log}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREE_DIR="${WORKTREE_DIR:-/tmp/octopus-logs-worktree}"

HOSTNAME_RAW="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
HOST_SLUG="$(echo "$HOSTNAME_RAW" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
BRANCH="logs/${HOST_SLUG}"

cd "$REPO_ROOT"

# Create the worktree on the logs branch. If the branch doesn't exist remotely,
# we create it as an orphan so log history doesn't pollute main's history.
setup_worktree() {
  if [ -d "$WORKTREE_DIR/.git" ] || [ -f "$WORKTREE_DIR/.git" ]; then
    return 0
  fi

  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git fetch origin "$BRANCH":"$BRANCH" 2>/dev/null || true
    git worktree add "$WORKTREE_DIR" "$BRANCH"
  else
    # Orphan branch — no shared history with main.
    git worktree add --detach "$WORKTREE_DIR"
    (
      cd "$WORKTREE_DIR"
      git checkout --orphan "$BRANCH"
      git rm -rf . >/dev/null 2>&1 || true
      echo "# OctopusSync logs from ${HOSTNAME_RAW}" > README.md
      git add README.md
      git -c user.name="octopus-log-sync" -c user.email="logs@octopus.local" \
        commit -m "init logs branch for ${HOSTNAME_RAW}" >/dev/null
      git push -u origin "$BRANCH"
    )
  fi
}

push_once() {
  if [ ! -f "$LOG_FILE" ]; then
    return 0
  fi

  cp "$LOG_FILE" "$WORKTREE_DIR/octopus-debug.log"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$WORKTREE_DIR/last-update.txt"
  echo "$HOSTNAME_RAW" > "$WORKTREE_DIR/hostname.txt"

  cd "$WORKTREE_DIR"
  git add octopus-debug.log last-update.txt hostname.txt
  # If the index now matches HEAD (no real change since last push), skip.
  if git diff --cached --quiet; then
    cd "$REPO_ROOT"
    return 0
  fi
  git -c user.name="octopus-log-sync" -c user.email="logs@octopus.local" \
    commit -m "log update from ${HOSTNAME_RAW} $(date -u +%H:%M:%S)" >/dev/null
  # Force-push because we don't care about preserving log-branch history.
  # Each commit is a snapshot; we'd otherwise accumulate noise.
  git push --force-with-lease origin "$BRANCH" 2>&1 | grep -v "^To " || true
  cd "$REPO_ROOT"
}

trap 'echo "[log-sync] stopping"; exit 0' INT TERM

echo "[log-sync] host=${HOSTNAME_RAW} branch=${BRANCH} interval=${INTERVAL}s"
echo "[log-sync] watching ${LOG_FILE}"
setup_worktree

while true; do
  push_once || echo "[log-sync] push failed, will retry"
  sleep "$INTERVAL"
done
