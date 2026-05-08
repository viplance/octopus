#!/usr/bin/env bash
# log-watch.sh — pull every logs/* branch and print a merged, host-tagged tail.
#
# Run on either Mac (or a third machine):    ./scripts/log-watch.sh
# Refreshes every $INTERVAL seconds (default 3).

set -euo pipefail

INTERVAL="${INTERVAL:-3}"
TAIL_LINES="${TAIL_LINES:-40}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${CACHE_DIR:-/tmp/octopus-logs-cache}"

mkdir -p "$CACHE_DIR"
cd "$REPO_ROOT"

GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
GRAY=$'\033[0;90m'
RESET=$'\033[0m'

trap 'echo; echo "[log-watch] stopping"; exit 0' INT TERM

while true; do
  # `clear` requires a TTY/TERM; fall back to ANSI escape if it fails.
  clear 2>/dev/null || printf '\033[2J\033[H'
  echo "${CYAN}=== OctopusSync log watch — $(date -u +%H:%M:%SZ) ===${RESET}"
  echo

  # Discover all logs/* branches on origin.
  branches="$(git ls-remote --heads origin 'logs/*' 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||')"

  if [ -z "$branches" ]; then
    echo "${YELLOW}No logs/* branches found on origin yet. Start log-sync.sh on a Mac.${RESET}"
    sleep "$INTERVAL"
    continue
  fi

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    # Update the remote-tracking ref. We never touch local branches because
    # log-sync.sh may have one of them checked out in its worktree, and
    # `git fetch origin <branch>:<branch>` would fail in that case.
    git fetch origin "$branch" 2>/dev/null || true
    remote_ref="refs/remotes/origin/${branch}"

    host_slug="${branch#logs/}"
    host_file="$CACHE_DIR/${host_slug}.log"
    host_meta="$CACHE_DIR/${host_slug}.meta"
    host_name="$CACHE_DIR/${host_slug}.name"

    git show "$remote_ref:octopus-debug.log" > "$host_file" 2>/dev/null || : > "$host_file"
    git show "$remote_ref:last-update.txt" > "$host_meta" 2>/dev/null || echo "?" > "$host_meta"
    git show "$remote_ref:hostname.txt" > "$host_name" 2>/dev/null || echo "$host_slug" > "$host_name"

    pretty_name="$(cat "$host_name")"
    last_update="$(cat "$host_meta")"
    line_count="$(wc -l < "$host_file" | tr -d ' ')"

    echo "${CYAN}── ${pretty_name} ${GRAY}(${branch}, ${line_count} lines, last push ${last_update})${RESET}"

    tail -n "$TAIL_LINES" "$host_file" | while IFS= read -r line; do
      case "$line" in
        *"[Connection] READY"*)         echo "  ${GREEN}${line}${RESET}" ;;
        *"FAILED"*|*"failed"*)          echo "  ${RED}${line}${RESET}" ;;
        *"accepting inbound"*)          echo "  ${GREEN}${line}${RESET}" ;;
        *"connecting to peer"*)         echo "  ${YELLOW}${line}${RESET}" ;;
        *"not initiating"*)             echo "  ${GRAY}${line}${RESET}" ;;
        *)                              echo "  ${line}" ;;
      esac
    done
    echo
  done <<< "$branches"

  sleep "$INTERVAL"
done
