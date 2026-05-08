#!/usr/bin/env bash
# test-connection.sh — run on either Mac. Verifies that BOTH peers reach
# [Connection] READY within $TIMEOUT seconds, by reading their logs/* branches.
#
# Prereqs: log-sync.sh must already be running on both Macs and OctopusSync
# must be launched on both (with Accessibility/Input Monitoring granted).
#
# Exit code: 0 = both READY, 1 = timeout / partial.

set -euo pipefail

TIMEOUT="${TIMEOUT:-60}"
POLL="${POLL:-3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_ROOT"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GRAY=$'\033[0;90m'
RESET=$'\033[0m'

echo "Waiting for two peers to both report [Connection] READY (timeout ${TIMEOUT}s)..."

deadline=$(( $(date +%s) + TIMEOUT ))
ready_hosts=""

while [ "$(date +%s)" -lt "$deadline" ]; do
  branches="$(git ls-remote --heads origin 'logs/*' 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||')"
  branch_count="$(echo "$branches" | grep -c . || true)"

  if [ "$branch_count" -lt 2 ]; then
    echo "${GRAY}  only ${branch_count} log branch(es) so far, waiting...${RESET}"
    sleep "$POLL"
    continue
  fi

  ready_hosts=""
  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    git fetch origin "$branch" >/dev/null 2>&1 || continue
    remote_ref="refs/remotes/origin/${branch}"
    if git show "$remote_ref:octopus-debug.log" 2>/dev/null | grep -q "\[Connection\] READY"; then
      host_slug="${branch#logs/}"
      ready_hosts="${ready_hosts}${host_slug} "
    fi
  done <<< "$branches"

  ready_count="$(echo "$ready_hosts" | wc -w | tr -d ' ')"
  echo "  branches=${branch_count} ready=${ready_count} [${ready_hosts}]"

  if [ "$ready_count" -ge 2 ]; then
    echo
    echo "${GREEN}✓ Both peers reached READY: ${ready_hosts}${RESET}"
    exit 0
  fi

  sleep "$POLL"
done

echo
echo "${RED}✗ Timed out after ${TIMEOUT}s. Hosts that reached READY: [${ready_hosts:-none}]${RESET}"
echo "${YELLOW}Run ./scripts/log-watch.sh to inspect both logs.${RESET}"
exit 1
