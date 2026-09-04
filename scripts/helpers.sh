# shellcheck shell=bash
# Shared helpers for the navigator scripts (the hook stays self-contained on
# purpose — it is the hot path and must not pay for a source).

get_tmux_option() { # get_tmux_option <name> <default>
	local v
	v="$(tmux show -gqv "$1" 2>/dev/null)"
	[ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "$2"
}

history_file() {
	printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs/history.tsv"
}

supervisor_dir() {
	# Claude Code's supervisor publishes one JSON file per live session here
	# (pid, sessionId, status, statusUpdatedAt, cwd, and on recent versions the
	# tmux pane). Reading it costs ~0.03ms per file against 350ms-4.3s for
	# `claude agents --json` — same truth, three orders of magnitude cheaper.
	# CLAUDE_TABS_SUPERVISOR_DIR exists for tests.
	printf '%s\n' "${CLAUDE_TABS_SUPERVISOR_DIR:-$HOME/.claude/sessions}"
}

history_spool() {
	# One file per ended session. Append = create, forget = rm, prune = rm —
	# every operation is atomic on its own, so unlike the old single-file TSV
	# there is no writer to race and no lock to hold.
	printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs/ended"
}

# Our state directory holds the paths of every project you have run Claude in,
# and the transcript paths that go with them. Create it — and every parent we
# create on the way — readable only by its owner. The umask is set in a
# subshell so nothing else in this process inherits it.
priv_mkdir() { # priv_mkdir <dir>
	(umask 077; mkdir -p "$1") 2>/dev/null
}

# One process table, so a pid can be checked for IDENTITY and not merely for
# existence. `kill -0` only says "some process has this number": a Claude
# killed with SIGKILL leaves its session file behind, the OS reuses the pid,
# and that file then badged a pane for a session that no longer exists.
#
# The session file carries startedAt as an epoch — no timezone to get wrong,
# unlike its procStart, which is a local-looking string written in UTC. Its
# distance from the process's real start (now minus ps etime) was 0-5 seconds
# across every live session on a machine with days of uptime, so a couple of
# minutes of tolerance separates "the same process" from "a recycled number"
# without being brittle.
proc_start_table() { # -> "<pid>=<epoch> <pid>=<epoch> ..."
	local now
	now="$(date +%s)"
	ps -Ao pid=,etime= 2>/dev/null | awk -v now="$now" '
		{
			n = split($2, a, /[-:]/)
			s = a[n]
			if (n >= 2) s += a[n - 1] * 60
			if (n >= 3) s += a[n - 2] * 3600
			if (n >= 4) s += a[n - 3] * 86400
			printf "%s=%d ", $1, now - s
		}'
}

same_process() { # same_process <table> <pid> <startedAt-epoch-seconds>
	local entry started delta
	case "$3" in '' | *[!0-9]*) return 0 ;; esac   # no claim to check
	entry="${1##* $2=}"
	[ "$entry" != "$1" ] || return 0               # pid not in the table
	started="${entry%% *}"
	case "$started" in '' | *[!0-9]*) return 0 ;; esac
	delta=$((started - $3))
	[ "$delta" -lt 0 ] && delta=$((-delta))
	[ "$delta" -le 120 ]
}

# Epoch milliseconds -> seconds, or failure. Two traps live here. A leading
# zero made bash read an all-digit string as octal, and "08"/"09" are not
# octal: the arithmetic failed, and inside a `for f in *.json` loop that
# aborted the whole collection, so every session after the offending file
# silently vanished from the navigator. And an absurd value — a torn read, a
# clock in 1970, a number from another unit — produced a confident wrong age
# rather than an honest "unknown". Force base ten, and require a width that a
# real epoch-ms value has.
epoch_ms() { # epoch_ms <digits>  → seconds on stdout, non-zero if implausible
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	esac
	case "${#1}" in
	12 | 13 | 14 | 15) printf '%s' "$(( 10#$1 / 1000 ))" ;;
	*) return 1 ;;
	esac
}

# `navigator.sh trace on` used to record hook invocations only, so in the
# DEFAULT hookless mode it produced an empty log — which reads as "nothing is
# firing", the opposite of the truth, exactly when someone is trying to work
# out why a badge will not settle. The hook keeps its own copy of this gate
# (a bare stat on the per-tool-call hot path); this one serves the poller.
trace_line() { # trace_line <source> <what>
	_td="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
	[ -f "$_td/trace" ] || return 0
	[ -n "$(find "$_td/trace.log" -size +2048k 2>/dev/null)" ] &&
		mv -f "$_td/trace.log" "$_td/trace.log.1" 2>/dev/null
	printf '%s\t%s\tpoll\t%s\t%s\n' "$(date '+%H:%M:%S')" "$1" \
		"${TMUX_PANE:-none}" "$2" >>"$_td/trace.log" 2>/dev/null
	return 0
}
