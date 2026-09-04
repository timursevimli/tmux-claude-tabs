#!/usr/bin/env bash
# Contract check against the REAL ~/.claude/sessions on this machine: does the
# current Claude Code still write files our fast path can parse? Run after a
# Claude update; regression.sh covers logic, this covers the undocumented
# format assumption. Exit 0 = fine (or nothing to check), 1 = format drifted.
set -u
sup="${CLAUDE_TABS_SUPERVISOR_DIR:-$HOME/.claude/sessions}"
ls "$sup"/*.json >/dev/null 2>&1 || { echo "contract: no supervisor files (nothing to check)"; exit 0; }
total=0; parsed=0; bg=0
for f in "$sup"/*.json; do
	[ -f "$f" ] || continue
	total=$((total + 1))
	row="$(cat "$f" 2>/dev/null)"
	# Both kinds matter: a background task is its own session, and dropping
	# those is what once left a pane reading "done" while one was running.
	case "$row" in
	*'"kind":"interactive"'*) ;;
	*'"kind":"bg"'*) bg=$((bg + 1)) ;;
	*) continue ;;
	esac
	pid="${row#*\"pid\":}"; pid="${pid%%[,\}]*}"
	st="${row#*\"status\":\"}"; st="${st%%\"*}"
	case "$pid" in *[!0-9]*) continue ;; esac
	[ -n "$st" ] && [ "$st" != "$row" ] || continue
	parsed=$((parsed + 1))
done
echo "contract: $parsed parsable sessions ($bg of them background) out of $total files"
if [ "$total" -gt 0 ] && [ "$parsed" -eq 0 ]; then
	echo "contract: FORMAT DRIFT — files exist but none parse; the plugin is on the CLI slow path" >&2
	exit 1
fi
exit 0
