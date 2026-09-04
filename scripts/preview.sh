#!/usr/bin/env bash
# fzf preview: the live screen of a running Claude, or the tail of an ended
# session's transcript.
#   preview.sh live <pane_id> <pid>
#   preview.sh lost <session_id> <pid>
#   preview.sh hist <session_id> <transcript_path>
set -uo pipefail

kind="${1:-}"
id="${2:-}"
aux="${3:-}"

case "$kind" in
live)
	tmux capture-pane -ep -t "$id" 2>/dev/null || echo "(pane is gone — ctrl-r to refresh)"
	;;
lost)
	# A `lost` row is a live Claude the navigator could not place in a pane of
	# this server. There is no screen to capture, and the preview used to come
	# back blank with rc=0 — which reads as "nothing here" for the session you
	# most want to find. Say what it is, then show what IS knowable: the record
	# it published and the process itself.
	printf '\033[90msession %s\033[0m\n\n' "$id"
	echo "No pane to show: this Claude is running, but not in a pane on this"
	echo "tmux server — another tmux server, a plain or IDE terminal, or a"
	echo "session detached from the pane it started in."
	sup="${CLAUDE_TABS_SUPERVISOR_DIR:-$HOME/.claude/sessions}/$aux.json"
	if [ -r "$sup" ]; then
		rec="$(cat "$sup" 2>/dev/null)"
		echo
		echo "what the session file says:"
		for k in status cwd tmux; do
			case "$rec" in
			*"\"$k\":\""*)
				v="${rec#*\"$k\":\"}"
				v="${v%%\"*}"
				printf '  %-7s %s\n' "$k" "$v"
				;;
			esac
		done
	fi
	echo
	case "$aux" in
	'' | *[!0-9]*) echo "(the row carries no pid)" ;;
	*)
		if kill -0 "$aux" 2>/dev/null; then
			echo "process (ctrl-x sends it SIGTERM):"
			ps -o pid=,ppid=,etime=,tty=,args= -p "$aux" 2>/dev/null | cut -c1-200
		else
			echo "(pid $aux is not running any more — ctrl-r to refresh)"
		fi
		;;
	esac
	;;
hist)
	printf '\033[90msession %s\033[0m\n\n' "$id"
	if [ ! -f "$aux" ]; then
		echo "(transcript no longer on disk)"
		echo "resume will still work if Claude keeps the session elsewhere:"
		echo "  claude --resume $id"
		exit 0
	fi
	if command -v jq >/dev/null 2>&1; then
		# Last few assistant replies, newest at the bottom — enough to remember
		# what this session was about.
		out="$(tail -n 300 "$aux" 2>/dev/null |
			jq -rj 'select(.type == "assistant") | .message.content[]? |
				select(.type == "text") | .text + "\n\n---\n\n"' 2>/dev/null |
			tail -c 20000)"
		if [ -n "$out" ]; then
			printf '%s\n' "$out"
			exit 0
		fi
	fi
	tail -n 40 "$aux" 2>/dev/null | cut -c1-400
	;;
esac
