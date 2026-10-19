#!/usr/bin/env bash
# tmux-claude-tabs — Claude Code side.
#
# Wired into ~/.claude/settings.json by hooks/install.sh, one entry per hook event.
# Three jobs, in order of how hot the path is:
#
#   badge     every event: publish the session state into tmux user options on
#             the pane this Claude runs in — hooks are child processes of
#             Claude Code, so $TMUX_PANE is inherited and no PID matching is
#             needed:
#               @claude_tabs_glyph   emoji tinted for the window list
#               @claude_tabs_plain   the same emoji untinted (current window)
#               @claude_tabs_label   short label ("Bash", "needs you")
#               @claude_tabs_state   bare state id ("thinking", "wait", …)
#             The window gets the aggregate of its panes under DIFFERENT names
#             — @claude_tabs_wglyph / _wplain / _wlabel — and those are what
#             the status-line formats read. #{@foo} resolves pane → window, so
#             a shared name is answered by the window's ACTIVE pane and the
#             aggregate is never reached: the "3" in "✅3" was written to the
#             window and never rendered. Panes never set the w-names.
#
#   notify    on transitions into wait/plan/done/error: display-message on
#             every client not currently looking at this window, and
#             optionally ring the pane's tty bell so tmux's own bell
#             machinery kicks in.
#
#   history   on SessionEnd: append (when, session_id, cwd, reason, transcript)
#             to a TSV so the navigator can offer to resume closed sessions —
#             the id Claude prints at exit is otherwise easy to lose. On
#             SessionStart the id is removed again (it is alive: a resume).
#             This part runs even outside tmux.
#
# Usage: claude-tabs.sh <event-label>   (hook JSON arrives on stdin)

set -u

event="${1:-}"
payload=""

# run-shell format-expands its argument, so a plugin path containing #W, #S,
# #I… would be substituted with a window/session name. Verified: "/tmp/x#Sy"
# arrives as "/tmp/xMYSESSy". Double every # once, here.
self_dir="${BASH_SOURCE[0]%/hooks/*}"
self_dir_fmt="${self_dir//"#"/"##"}"

# Opt-in trace for diagnosing a badge that will not settle (`navigator.sh
# trace on`). Gated on a file existing rather than a tmux option: this runs on
# every tool call, and a `tmux show` here would add a round-trip to the hot
# path, while `[ -f ]` is a stat.
trace_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
trace() { # trace <what>
	[ -f "$trace_dir/trace" ] || return 0
	# Turned on to chase one badge and then forgotten, this appended a line on
	# every tool call of every session forever. Roll it at 2MB: one `find` on
	# a path we already stat, and only while tracing is on.
	[ -n "$(find "$trace_dir/trace.log" -size +2048k 2>/dev/null)" ] &&
		mv -f "$trace_dir/trace.log" "$trace_dir/trace.log.1" 2>/dev/null
	printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$event" \
		"$(field hook_event_name)" "${TMUX_PANE:-none}" "$1" \
		>>"$trace_dir/trace.log" 2>/dev/null
}
# Builtin read instead of $(cat): this runs on every single tool call, and the
# whole point is to stay far below the noise floor of the tool it precedes.
[ -t 0 ] || IFS= read -r -d '' payload

# One field out of the hook payload, without shelling out to jq. Every field
# this script reads (tool_name, notification_type, session_id, cwd, …) is a
# plain string without escaped quotes, so a substring cut is exact here and
# costs no process. Returns empty if the key is absent.
# Payloads carrying a tool_input can be tens of kilobytes — an Edit ships file
# contents — and bash pattern matching over a string that size is quadratic:
# measured on a clean container, an 80 KB payload whose key sat at the end took
# 13 seconds inside a hook that runs on every tool call, and 100 KB took over
# 30. Both `#*"key":` and `%%"key":*` behave the same way, because bash retries
# the pattern at every start position. Over this size one awk call per lookup
# is linear and costs a single fork; under it the pure-bash path stays
# fork-free, which is what the hot path needs.
# Parse the payload ONCE, structurally, and answer every later lookup out of
# the result. The old positional cut had three separate bugs, all the same
# mistake — treating JSON as text:
#
#   * it took the first occurrence of a key ANYWHERE in the payload, so a key
#     inside tool_input shadowed the real top-level one (a Task whose input
#     carried its own "cwd" reported that cwd as the session's);
#   * the awk path it switched to above 4 KB ran per LINE and gave up on the
#     first line without the key, so a pretty-printed payload answered
#     "absent" for keys it plainly had;
#   * a string value was cut at the first raw quote, truncating any value
#     holding an escaped one — /home/u/my \"proj\" came back as /home/u/my \.
#
# One pass costs one fork per hook invocation. The old bash path was fork-free
# but is called nineteen times here, and its quadratic pattern matching took
# 13 seconds on an 80 KB payload; one fork is the cheaper half of that trade,
# and the hook already spends several on tmux.
CT_RS=$'\036' # between records
CT_US=$'\037' # between a key and its value
payload_parsed=""
payload_fields=""

_parse_payload() {
	payload_fields="$(printf '%s' "$payload" | awk '
		# Copied in RUNS, not character by character. Appending one character
		# at a time is quadratic in awk, and a 60 KB value in a top-level key
		# took 12 seconds — the very stall this parser replaced. Scanning is
		# cheap; only the concatenation had to go, so the value is taken in one
		# substr per escape-free stretch.
		function rdstr(   out, c, c2, start) {
			# I points just past the opening quote.
			out = ""
			start = I
			while (I <= LN) {
				c = substr(S, I, 1)
				if (c == "\\") {
					out = out substr(S, start, I - start)
					c2 = substr(S, I + 1, 1)
					if (c2 == "n") out = out "\n"
					else if (c2 == "t") out = out "\t"
					else if (c2 == "r") out = out "\r"
					else if (c2 == "u") { out = out "?"; I += 4 }
					else out = out c2
					I += 2
					start = I
					continue
				}
				if (c == "\"") {
					out = out substr(S, start, I - start)
					I++
					return out
				}
				I++
			}
			return out substr(S, start, I - start)
		}
		function skipws() { while (I <= LN && substr(S, I, 1) ~ /[ \t\r\n]/) I++ }
		function skipval(   d, c, instr, esc) {
			# Step over a nested object or array without looking inside it:
			# this is what keeps a nested key from shadowing a top-level one.
			d = 0; instr = 0; esc = 0
			while (I <= LN) {
				c = substr(S, I, 1); I++
				if (instr) {
					if (esc) { esc = 0; continue }
					if (c == "\\") { esc = 1; continue }
					if (c == "\"") instr = 0
					continue
				}
				if (c == "\"") { instr = 1; continue }
				if (c == "{" || c == "[") d++
				else if (c == "}" || c == "]") { d--; if (d == 0) return }
			}
		}
		{ S = S $0 "\n" }
		END {
			US = sprintf("%c", 31); RS_ = sprintf("%c", 30)
			LN = length(S)
			I = index(S, "{")
			if (I == 0) exit
			I++
			while (I <= LN) {
				skipws()
				c = substr(S, I, 1)
				if (c == "}" || c == "") break
				if (c == ",") { I++; continue }
				if (c != "\"") { I++; continue }
				I++
				k = rdstr()
				skipws()
				if (substr(S, I, 1) != ":") continue
				I++
				skipws()
				c = substr(S, I, 1)
				if (c == "\"") {
					I++
					v = rdstr()
				} else if (c == "{" || c == "[") {
					skipval()
					continue
				} else {
					v = ""
					while (I <= LN) {
						c = substr(S, I, 1)
						if (c == "," || c == "}") break
						v = v c; I++
					}
					sub(/[ \t\r\n]+$/, "", v)
					if (v == "null") continue
				}
				# The separators are our framing; a raw one in a value would
				# forge a record.
				gsub(US, "", k); gsub(RS_, "", k)
				gsub(US, "", v); gsub(RS_, "", v)
				# Cap what goes in the cache. Every field this hook reads is a
				# name, a path or an id; a 60 KB blob in some other top-level
				# key would make each later lookup a quadratic bash pattern
				# match over the whole cache — the same stall by another route.
				if (length(v) > 1024) v = substr(v, 1, 1024)
				printf "%s%s%s%s", RS_, k, US, v
			}
		}')"
}

field() {
	local rest
	if [ -z "$payload_parsed" ]; then
		payload_parsed=1
		_parse_payload
	fi
	case "$payload_fields" in
	*"$CT_RS$1$CT_US"*) ;;
	*) return 0 ;;
	esac
	rest="${payload_fields#*"$CT_RS$1$CT_US"}"
	printf '%s' "${rest%%"$CT_RS"*}"
}

T='	'

# A session id travels into run-shell command strings below, so it is checked
# rather than trusted: the same defect was found and fixed in the navigator's
# resume path, where a quote in an id broke out of the quoting. Claude Code
# writes UUIDs; anything else is not an id we could act on anyway.
safe_sid() { # safe_sid <id> — echo it back only when it looks like one
	case "${1:-}" in
	'' | *[!A-Za-z0-9._-]*) ;;
	*) printf '%s' "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
# Session history — runs with or without tmux, so sessions closed in a plain
# terminal are recoverable too.
# ---------------------------------------------------------------------------
hist_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
spool="$hist_dir/ended"

# Our state directory holds the paths of every project you have run Claude in,
# and the transcript paths that go with them. Create it — and every parent we
# create on the way — readable only by its owner. The umask is set in a
# subshell so nothing else in this process inherits it.
priv_mkdir() { # priv_mkdir <dir>
	(umask 077; mkdir -p "$1") 2>/dev/null
}

# Tab and newline are the spool's field and row framing, and field() turns the
# payload's \t and \n escapes back into real bytes on purpose — so an
# unsanitised value forges whole extra rows. A cwd is enough, and Unix allows
# `mkdir $'a\nb'`: a session ended in such a directory wrote a second row
# carrying an attacker's session id and transcript path, and the navigator then
# previewed the file that row named (reproduced with /etc/passwd). The
# navigator was hardened against exactly this shape; the spool was missed.
oneline() { # oneline <text>
	local s="${1-}"
	s="${s//$'\n'/ }"
	s="${s//$'\t'/ }"
	printf '%s' "${s//$'\r'/ }"
}

# The session's name, read once at the end from its transcript: the last
# /rename, else the agent name, else the AI title — the same choice Claude
# makes for the pane title. Duplicated in scripts/helpers.sh: this script
# sources nothing.
transcript_title() { # transcript_title <transcript.jsonl>
	[ -f "${1:-}" ] || return 0
	LC_ALL=C grep -a -E '"type":"(custom-title|agent-name|ai-title)"' "$1" 2>/dev/null |
		LC_ALL=C awk '
			match($0, /"(customTitle|agentName|aiTitle)":"([^"\\]|\\.)*"/) {
				s = substr($0, RSTART, RLENGTH); k = s
				sub(/":".*/, "", k); sub(/^"/, "", k)
				sub(/^"[A-Za-z]*":"/, "", s); sub(/"$/, "", s)
				gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
				t[k] = s
			}
			END { print (t["customTitle"] != "" ? t["customTitle"] : t["agentName"] != "" ? t["agentName"] : t["aiTitle"]) }'
}

# Appends are the only write from this hot path — atomic enough on their own.
# Rewrites (prune here, forget in the navigator) go through a mkdir lock, so a
# storm of sessions ending at once cannot lose each other's lines. Resumed
# sessions are NOT rewritten out on start: the navigator filters live ids at
# display time instead.
case "$event" in
end)
	sid="$(field session_id)"
	if [ -n "$sid" ]; then
		# One file per ended session: append = create, forget = rm, prune =
		# rm. Each is atomic on its own, so unlike the old single-file TSV
		# there is no writer to race and no lock to hold.
		priv_mkdir "$spool"
		reason="$(field end_reason)"
		[ -n "$reason" ] || reason="$(field reason)"
		tp="$(field transcript_path)"
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$(date +%s)" "$(oneline "$sid")" "$(oneline "$(field cwd)")" \
			"$(oneline "${reason:-ended}")" "$(oneline "$tp")" \
			"$(oneline "$(transcript_title "$tp")")" \
			>"$spool/${sid//\//_}" 2>/dev/null
		# Prune: drop the oldest beyond the limit, and sweep this session's
		# turn/bg markers plus any marker older than a day (GC for sessions
		# that never fired SessionEnd).
		limit=200
		if [ -n "${TMUX:-}" ]; then
			v="$(tmux show -gqv @claude-tabs-history-limit 2>/dev/null)"
			[ -n "$v" ] && limit="$v"
		fi
		n=0
		ls -t "$spool" 2>/dev/null | while IFS= read -r f; do
			n=$((n + 1))
			[ "$n" -gt "$limit" ] && rm -f "$spool/$f" 2>/dev/null
		done
		rm -f "$hist_dir/turns/${sid//\//_}" "$hist_dir/turns/${sid//\//_}.bg" 2>/dev/null
		find "$hist_dir/turns" -type f -mmin +1440 -delete 2>/dev/null
	fi
	;;
esac

# ---------------------------------------------------------------------------
# Background tasks: the one event nobody else can send.
# ---------------------------------------------------------------------------
# Claude Code runs a background task as its own session, spawned through a
# daemon onto a tty that is not a pane, with neither $TMUX nor $TMUX_PANE in
# its environment. Its hooks do fire — proven by its SessionEnd landing in the
# spool above — but the block below used to drop them, and with them the only
# signal that a pane's background work is over. The parent session gets no
# event of its own for that, so the hourglass sat there until something else
# happened to reconcile: measured at 1h52m on a real session.
#
# The pane is deliberately NOT resolved here. Only the server is needed, and
# then `sync` recomputes every pane from scratch — including merging the
# several Claude processes that share one pane. Writing a badge from here
# instead would be actively wrong: this session ending says "the background
# work finished", not "the pane is free", and stamping done over a pane whose
# interactive session is mid-turn would be worse than the stale hourglass.
if [ -z "${TMUX_PANE:-}" ] && [ -z "${TMUX:-}" ]; then
	case "$event" in
	stop | end)
		command -v tmux >/dev/null 2>&1 || exit 0
		anc="$PPID"
		for _hop in 1 2 3 4 5 6 7 8; do
			[ -n "$anc" ] && [ "$anc" != 0 ] && [ "$anc" != 1 ] || break
			envtmux="$(ps eww -p "$anc" 2>/dev/null | tr ' ' '\n' |
				sed -n 's/^TMUX=//p' | head -1)"
			# ps eww prints argv and environment in one stream, so "TMUX=" can
			# match a fragment of some ancestor's COMMAND LINE — seen live as
			# envtmux='"$(tmux'. Accept only the real shape, socket,pid,index;
			# anything else keeps walking. (macOS also hides platform-binary
			# environments from ps eww entirely, so a /bin/bash-only ancestry
			# yields nothing — in production the TMUX holder is Claude's own
			# process, which is visible.)
			case "$envtmux" in /*,*,*) ;; *) envtmux="" ;; esac
			if [ -n "$envtmux" ]; then
				# sleep 3 for the same reason the post-turn recheck waits:
				# Claude rewrites the parent session's status from "shell" to
				# "idle" around this event, and a sync that won the race would
				# just re-read the old value and leave the hourglass up.
				TMUX="$envtmux" tmux run-shell -b \
					"sleep 3; '$self_dir_fmt/scripts/navigator.sh' sync force >/dev/null 2>&1 || true" 2>/dev/null
				break
			fi
			anc="$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')"
		done
		;;
	esac
	exit 0
fi

# ---------------------------------------------------------------------------
# Badge + notifications — tmux only from here on.
# ---------------------------------------------------------------------------
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Emoji carry their own colour, so the state reads the same on the dark blocks
# and on the theme's bright fill for the current window. They are all two cells
# wide and none of them needs a variation selector, so tab widths stay stable
# as the state changes. The colour below only matters if a terminal falls back
# to a monochrome glyph.
C_IDLE=245  # grey
C_WORK=109  # blue
C_THINK=214 # orange
C_WAIT=167  # red
C_DONE=142  # green
C_PLAN=175  # pink

state=""
icon=""
glyph=""
plain=""
label=""
rescue=""
locked=""

# set_state <state-id> <colour> <emoji> <label>
set_state() {
	state="$1"
	icon="$3"
	# tmux honours #[...] style tags inside an option value — that is how the
	# glyph gets its colour — so a label carrying one would restyle the rest
	# of the status line. An MCP server chooses its own tool names, and those
	# land here. Double every # once, as every other path into a format does.
	set -- "$1" "$2" "$3" "${4-}"
	set -- "$1" "$2" "$3" "${4//"#"/"##"}"
	# bold for weight, #[nobold] so the theme's own tag for #W stays intact
	glyph="#[fg=colour$2,bold]$3#[nobold]"
	plain="#[bold]$3#[nobold]"
	label="$4"
}

# Is a turn actually running? A real turn always opens with UserPromptSubmit or
# a PreToolUse, and Stop closes it. Claude Code also works in the background —
# the away-summary pass fires a PostToolUse-shaped event minutes after a turn is
# over, with no Stop behind it to close it again — and taking that at face value
# leaves the badge on "working" forever. The marker is a file, not a tmux
# option: `:>` and `[ -f ]` cost nothing, a tmux round-trip on every tool call
# would.
turn_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs/turns"
turn_key="$(field session_id)"
[ -n "$turn_key" ] || turn_key="${TMUX_PANE#%}"
turn_file="$turn_dir/${turn_key//\//_}"

turn_open() {
	[ -d "$turn_dir" ] || priv_mkdir "$turn_dir"
	: >"$turn_file" 2>/dev/null
}
turn_close() { rm -f "$turn_file" 2>/dev/null; }

# Work the session launched that outlives the turn: a Monitor watching a
# command, a Bash run in the background, a scheduled wake-up. Stop fires while
# these are still pending, and calling that "done" is wrong — the session is
# not waiting for you, it is waiting for its own shell and will resume by
# itself. The marker records which tool it was, so the badge can name it.
# One line per outstanding item, because a turn can leave several: a Monitor
# and two subagents at once. Subagents announce their own end (SubagentStop),
# so they are removed one at a time; a Monitor or a backgrounded shell has no
# completion event and simply lasts until the next turn.
bg_file="$turn_file.bg"
# One lock, both writers. mkdir is the atomic primitive a shell has; the
# holder's pid inside it makes a lock left by a killed hook reclaimable without
# a timer. It returns 0 ONLY when the lock is really ours, which the previous
# version had no way to say: after ten 50ms tries both callers fell out of the
# loop, did their write unlocked — the lost update the lock exists to prevent —
# and then ran rm -f/rmdir on the LIVE holder's lock on the way out, admitting a
# third writer behind it. Measured on this tree before the fix: a live holder's
# lock stolen in 1 of 1 deterministic runs, and 18 of 25 runs with 20 parallel
# SubagentStops left phantom agents on the list and the tab stuck on ⏳.
# Reclaiming a stale lock has to be a CLAIM, not a delete. With a dozen hooks
# deciding the same lock is dead in the same instant, one process's `rmdir`
# removes the lock a neighbour has just legitimately taken, and that neighbour
# then writes outside any lock. Renaming a directory is atomic: exactly one
# mover wins, the losers find it already gone and go back to competing for
# `mkdir` honestly. Measured with a thirty-minute-old lock owned by an
# unrelated live process and twelve concurrent SubagentStops: 6 of 6 trials
# lost a drop before any of this, 2 of 6 with the staleness handled but the
# reclaim left as a delete, 0 of 6 with the rename.
reclaim_lock() { # reclaim_lock <lock-dir> — 0 if WE were the one that cleared it
	local dead="$1.dead.$$"
	mv "$1" "$dead" 2>/dev/null || return 1
	rm -f "$dead/pid" 2>/dev/null
	rmdir "$dead" 2>/dev/null
	return 0
}
bg_lock() { # bg_lock <lock-dir> — 0 only when acquired; release only then
	local lock="$1" dir="${1%/*}" holder i
	for ((i = 0; i < 100; i++)); do
		if mkdir "$lock" 2>/dev/null; then
			printf '%s' "$$" >"$lock/pid" 2>/dev/null
			return 0
		fi
		# mkdir fails either because somebody holds the lock — the ordinary
		# case, wait for them — or because the state directory cannot be
		# written at all, where waiting out the budget on a path that runs on
		# every tool call is the only thing waiting could achieve. `[ -d
		# "$lock" ]` cannot tell those apart: under contention the holder
		# usually releases in the microseconds before that test, and reading
		# the gap as "unwritable" made 7 of 20 parallel SubagentStops give up
		# without dropping. Ask about the directory instead. (`-w` is an
		# access(2) builtin — no fork — and root, for whom it always says yes,
		# is also the user whose mkdir never fails on mode bits.)
		[ -w "$dir" ] || return 1
		# `read` and `kill -0` are builtins; the old `cat` per attempt put a
		# fork inside the very fork storm this budget has to survive. The
		# redirect must be wrapped, not merely followed by 2>/dev/null: a
		# holder is regularly caught between its mkdir and its pid write, and
		# bash reports THAT failure from outside the command's own redirections
		# — "No such file or directory" on the hook's stderr, where Claude Code
		# shows it. Confirmed on bash 3.2 and 5.2 alike.
		holder=""
		{ IFS= read -r holder <"$lock/pid"; } 2>/dev/null
		case "$holder" in
		'' | *[!0-9]*)
			# No readable pid — an older version, a torn write, or a holder
			# killed between the mkdir and the write. Age is the only evidence
			# left, and without this arm every later hook waited out the whole
			# budget for a lock nobody held: 621ms per event, measured.
			[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] &&
				reclaim_lock "$lock"
			;;
		*)
			# `kill -0` proves a process EXISTS, not that it is the one that took
			# this lock. A recycled pid, or a holder that was stopped, keeps a
			# dead lock alive forever — measured, a thirty-minute-old lock owned
			# by an unrelated live process lost the drop in 6 of 6 trials. Age is
			# the tie-breaker, the same one the window lock uses: the critical
			# section here is about ten milliseconds, so a minute is not a busy
			# holder, it is a corpse. Checked every tenth attempt because `find`
			# is a fork and this loop runs inside the fork storm it must survive.
			if ! kill -0 "$holder" 2>/dev/null ||
				{ [ $((i % 10)) -eq 0 ] &&
					[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
				reclaim_lock "$lock"
			fi
			;;
		esac
		sleep 0.05
	done
	# Five seconds for a critical section measured at ~10ms: this holder is not
	# busy, it is gone in a way `kill -0` cannot see — its pid recycled by an
	# unrelated process, or itself stopped. Break the lock open and TAKE it, so
	# the caller's write still happens under a lock it holds. The old code's
	# answer here — write without one, then delete the holder's lock — is the
	# defect itself.
	# Retried, not attempted once. When a dozen SubagentStops reach this point
	# together they all break the lock open in the same instant; one wins the
	# mkdir and the other eleven used to return failure and skip their drop —
	# 6 of 6 trials left a finished subagent on the list that way. The winner
	# holds it for milliseconds, so waiting a moment is all that was missing.
	for ((i = 0; i < 20; i++)); do
		reclaim_lock "$lock"
		if mkdir "$lock" 2>/dev/null; then
			printf '%s' "$$" >"$lock/pid" 2>/dev/null
			return 0
		fi
		sleep 0.05
	done
	return 1
}
bg_unlock() { # bg_unlock <lock-dir> — never call this unless bg_lock returned 0
	rm -f "$1/pid" 2>/dev/null
	rmdir "$1" 2>/dev/null
}
bg_add() { # bg_add <line>
	[ -d "$turn_dir" ] || priv_mkdir "$turn_dir"
	# Same lock as bg_drop_one: an append that lands inside another hook's
	# read-modify-write is thrown away by its rename.
	local lock="$bg_file.lock" held=""
	bg_lock "$lock" && held=1
	# Deliberately appended even without the lock. O_APPEND puts a short line
	# down in one write, so an unlocked append can corrupt nobody; the only way
	# to lose it is a concurrent rewrite's rename, and that costs one missing
	# hourglass, re-derived at the next turn-ending event. A lost DROP is the
	# failure that never heals — that one gets the strict treatment below.
	printf '%s\n' "$1" >>"$bg_file" 2>/dev/null
	if [ -n "$held" ]; then
		bg_unlock "$lock"
	fi
}
bg_drop_one() { # bg_drop_one <prefix> — remove the first line starting with it
	[ -f "$bg_file" ] || return 0
	# Under a lock, and only under one. Parallel subagents finishing together
	# is the ordinary case, and this is a read-modify-write: two hooks both
	# read the same two lines, each dropped one, and each renamed its copy over
	# the other, so one drop was lost and a finished agent stayed on the list —
	# an hourglass where the badge should have said done.
	local lock="$bg_file.lock"
	if ! bg_lock "$lock"; then
		# Not acquired, so nothing here is touched and nothing is released.
		# Both ways of getting here say the rewrite must not happen: the state
		# directory cannot be written — and the temp file below goes into that
		# same directory — or another waiter took the lock we broke open, and
		# writing alongside it is the lost update this lock exists to prevent.
		trace "bg drop skipped: lock unobtainable"
		return 0
	fi
	awk -v p="$1" 'dropped != 1 && index($0, p) == 1 { dropped = 1; next } { print }' \
		"$bg_file" >"$bg_file.tmp.$$" 2>/dev/null &&
		mv "$bg_file.tmp.$$" "$bg_file" 2>/dev/null || rm -f "$bg_file.tmp.$$"
	[ -s "$bg_file" ] || rm -f "$bg_file" 2>/dev/null
	bg_unlock "$lock"
}
bg_close() { rm -f "$bg_file" 2>/dev/null; }

# Does the supervisor still see a background shell for this session? Its
# status goes busy (turn running) -> shell (turn over, backgrounded shell
# still alive) -> idle, which is exactly the ⏳ distinction — and it covers
# background work started in an EARLIER turn, which our per-turn markers
# deliberately forget. Reading the files costs ~0.4ms; the hook only asks on
# turn-ending events, never on the hot tool path.
supervisor_busy() { # supervisor_busy <session-id>  -> prints busy|shell|""
	local dir="${CLAUDE_TABS_SUPERVISOR_DIR:-$HOME/.claude/sessions}" f
	[ -n "$1" ] || return 0
	f="$(grep -l "\"sessionId\":\"$1\"" "$dir"/*.json 2>/dev/null | head -1)"
	[ -n "$f" ] || return 0
	case "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)" in
	shell) printf 'shell' ;;
	busy) printf 'busy' ;;
	esac
}
# What Claude Code itself says is still running, straight out of the Stop
# payload's background_tasks array — {id,type,status,description} per entry.
# Measured live: the array is present and accurate at turn end, completed
# tasks simply vanish from it, and NO Stop fires when one finishes (two
# captured payloads two minutes apart, the finished shell gone from the
# second). So this replaces our guesswork about what STARTED; the watcher
# still owns detecting when it ENDS, because that event does not exist.
#
# Monitors are excluded deliberately. An artifact watcher or a log tail is
# "running" for hours and is not work you are waiting on — counting it kept
# the hourglass up on sessions that were free, and the supervisor's own
# "shell" status has the same blind spot because it is derived the same way.
#
# Parsed with awk rather than jq: this must run with no runtime dependency.
# Objects are split on {"id":" — a delimiter free text will not contain — and
# a chunk only counts if it carries both "type" and "status", so entries from
# a sibling array (session_crons) cannot be mistaken for tasks.
bg_payload_scan() { # -> "<count>\t<description of the newest>"
	case "$payload" in *'"background_tasks":'*) ;; *) return 0 ;; esac
	printf '%s' "$payload" | awk '
		function region(s,   i, ch, depth, instr, esc, out) {
			i = index(s, "\"background_tasks\":[")
			if (i == 0) return ""
			s = substr(s, i + length("\"background_tasks\":["))
			depth = 1
			for (i = 1; i <= length(s); i++) {
				ch = substr(s, i, 1)
				if (esc) { esc = 0; out = out ch; continue }
				if (ch == "\\") { esc = 1; out = out ch; continue }
				if (ch == "\"") { instr = !instr; out = out ch; continue }
				if (!instr) {
					if (ch == "[" || ch == "{") depth++
					else if (ch == "]" || ch == "}") { depth--; if (depth == 0) return out }
				}
				out = out ch
			}
			return out
		}
		# The entry ends at its own balanced closing brace, not at the first
		# "}" byte: `sub(/\}.*/, "", c)` also cut at a brace inside a string,
		# so a task described as "fix the {2,4} regex" was truncated before its
		# "status" field and silently dropped from the count — the hourglass
		# went missing while the task was still running.
		function cut_obj(s,   i, ch, depth, instr, esc, out) {
			depth = 1
			for (i = 1; i <= length(s); i++) {
				ch = substr(s, i, 1)
				if (esc) { esc = 0; out = out ch; continue }
				if (ch == "\\") { esc = 1; out = out ch; continue }
				if (ch == "\"") { instr = !instr; out = out ch; continue }
				if (!instr) {
					if (ch == "{" || ch == "[") depth++
					else if (ch == "}" || ch == "]") { depth--; if (depth == 0) return out }
				}
				out = out ch
			}
			return out
		}
		# Same mistake in the value: cutting at the first quote truncated any
		# description containing an escaped one.
		function jstr(s, key,   i, ch, esc, out) {
			i = index(s, "\"" key "\":\"")
			if (i == 0) return ""
			i += length(key) + 4
			for (; i <= length(s); i++) {
				ch = substr(s, i, 1)
				if (esc) { esc = 0; out = out ch; continue }
				if (ch == "\\") { esc = 1; continue }
				if (ch == "\"") return out
				out = out ch
			}
			return out
		}
		{
			# Isolate the array first, tracking quotes and nesting: without
			# this a session_crons entry of the same shape counted as a running
			# task and would have pinned the hourglass on a scheduled job.
			r = region($0)
			n = split(r, chunk, /\{"id":"/)
			for (i = 2; i <= n; i++) {
				c = cut_obj(chunk[i])
				if (c !~ /"type":"/ || c !~ /"status":"/) continue
				if (c !~ /"status":"running"/) continue
				if (c ~ /"type":"monitor"/) continue
				count++
				d = jstr(c, "description")
				if (d != "") desc = d
			}
			printf "%d\t%s", count + 0, desc
		}'
}

# The newest outstanding item, as a label: "agent:Explore" -> "Explore…"
bg_label() {
	local last
	last="$(tail -n 1 "$bg_file" 2>/dev/null)"
	case "$last" in
	agent:*) printf '%s…' "${last#agent:}" ;;
	tool:*) printf '%s' "${last#tool:}" ;;
	*) printf 'waiting' ;;
	esac
}

case "$event" in
start)
	turn_close
	set_state idle "$C_IDLE" "💤" "idle"
	;;
prompt)
	# A new turn: whatever the session was waiting on has either fired (that is
	# why it woke) or been superseded by what you just asked for.
	turn_open
	bg_close
	set_state thinking "$C_THINK" "💭" "thinking"
	;;
tool)
	turn_open
	tool="$(field tool_name)"
	# Tools that leave something running after the turn ends.
	case "$tool" in
	Monitor | ScheduleWakeup) bg_add "tool:$tool" ;;
	Bash | BashOutput)
		case "$payload" in
		*'"run_in_background":true'* | *'"run_in_background": true'*)
			bg_add "tool:background shell"
			;;
		esac
		;;
	esac
	case "$tool" in
	ExitPlanMode) set_state plan "$C_PLAN" "📋" "plan?" ;;
	"") set_state tool "$C_WORK" "🔧" "working" ;;
	*) set_state tool "$C_WORK" "🔧" "${tool#mcp__}" ;;
	esac
	;;
post)
	# Only meaningful inside a turn. Outside one it is background noise that
	# would resurrect a finished session — see turn_open above.
	if [ ! -f "$turn_file" ]; then
		trace "ignored: no turn in progress"
		exit 0
	fi
	set_state thinking "$C_THINK" "💭" "working"
	;;
permission)
	turn_open
	tool="$(field tool_name)"
	set_state wait "$C_WAIT" "🔴" "allow ${tool:-tool}?"
	;;
notify)
	kind="$(field notification_type)"
	case "$kind" in
	permission_prompt | elicitation_dialog | agent_needs_input)
		set_state wait "$C_WAIT" "🔴" "needs you"
		;;
	idle_prompt)
		# Fires ~60s after the turn ends with no input from you. Never red —
		# that is reserved for a session that cannot continue without you, and
		# painting it red is what made every finished session turn red a minute
		# later. But it does prove the turn is over, which rescues a badge left
		# stuck on an active state by a turn that ended without Stop (an Esc
		# interrupt fires no hook at all). Silent: the news is a minute stale.
		# Deliberately not bg: waiting on a Monitor for an hour with no input
		# from you is exactly what idle_prompt reports, and treating that as a
		# stuck badge turned every ⏳ back into a false ✅ a minute later. A bg
		# badge that really is stale is corrected by `sync` instead, which asks
		# the supervisor rather than guessing.
		case "$(tmux display -p -t "$TMUX_PANE" '#{@claude_tabs_state}' 2>/dev/null)" in
		thinking | tool | compact)
			turn_close
			set_state done "$C_DONE" "✅" "done"
			rescue=1
			;;
		bg)
			# Still an hourglass a minute after the turn ended: either the
			# watcher gave up, or this badge came from a reconcile that never
			# armed one. Do not guess — the session may legitimately be
			# waiting on an hour-long job — hand it back to the watcher, which
			# asks the session file instead.
			sid="$(safe_sid "$(field session_id)")"
			if [ -n "$sid" ]; then
				wtok="$$-$RANDOM-$RANDOM"
				tmux set -p -t "$TMUX_PANE" @claude_tabs_watch "$wtok" \; \
					run-shell -b "'$self_dir_fmt/scripts/navigator.sh' watch $TMUX_PANE '$sid' 1 '$wtok' >/dev/null 2>&1 || true" 2>/dev/null
			fi
			exit 0
			;;
		*) exit 0 ;;
		esac
		;;
	agent_completed)
		turn_close
		set_state done "$C_DONE" "✅" "done"
		;;
	*)
		trace "ignored notification: $kind"
		exit 0
		;;
	esac
	;;
subagent)
	turn_open
	agent="$(field agent_type)"
	# Subagents routinely outlive the turn that spawned them — SubagentStop has
	# been seen arriving three minutes after Stop — so they count as work the
	# session is waiting on, not as work that ended with the turn.
	bg_add "agent:${agent:-agent}"
	set_state tool "$C_WORK" "🤖" "${agent:-agent}…"
	;;

subagent-done)
	bg_drop_one "agent:"
	if [ -f "$turn_file" ]; then
		set_state thinking "$C_THINK" "💭" "working"
	elif [ -f "$bg_file" ]; then
		# Turn is over and something else is still outstanding.
		set_state bg "$C_PLAN" "⏳" "$(bg_label)"
	elif [ "$(supervisor_busy "$(field session_id)")" = shell ]; then
		# Our markers are empty but a backgrounded shell — very likely started
		# in an earlier turn — is still running. Not done.
		set_state bg "$C_PLAN" "⏳" "bg shell"
	else
		# Turn is over and that was the last thing it was waiting on.
		set_state done "$C_DONE" "✅" "done"
	fi
	;;
compact)
	set_state compact "$C_WORK" "📦" "compacting"
	;;
stop)
	turn_close
	bg_scan="$(bg_payload_scan)"
	bg_n="${bg_scan%%	*}"
	bg_desc="${bg_scan#*	}"
	case "$bg_n" in '' | *[!0-9]*) bg_n=0 ;; esac
	if [ "$bg_n" -gt 0 ]; then
		# Claude Code told us outright what is still running. No marker file to
		# trust, no supervisor status to race — and the description names the
		# actual job instead of a generic "waiting".
		bglabel="${bg_desc:-$(bg_label)}"
		case "$bglabel" in ?????????????????????*) bglabel="$(printf '%.20s…' "$bglabel")" ;; esac
		set_state bg "$C_PLAN" "⏳" "$bglabel"
		# ...and nothing will tell us when it does. No hook fires for a
		# background job finishing, so follow the session file until it
		# settles, or the hourglass stays up until an unrelated reconcile
		# happens to notice — measured at 1h52m on a live session.
		sid="$(safe_sid "$(field session_id)")"
		if [ -n "$sid" ]; then
			wtok="$$-$RANDOM-$RANDOM"
			tmux set -p -t "$TMUX_PANE" @claude_tabs_watch "$wtok" \; \
				run-shell -b "sleep 3; '$self_dir_fmt/scripts/navigator.sh' watch $TMUX_PANE '$sid' 1 '$wtok' >/dev/null 2>&1 || true" 2>/dev/null
		fi
	elif [ -z "$bg_scan" ] && [ -f "$bg_file" ]; then
		# No background_tasks field at all — an older Claude Code. Fall back to
		# the per-turn markers this used to rely on entirely.
		set_state bg "$C_PLAN" "⏳" "$(bg_label)"
	else
		# The array said nothing is running, so nothing is: done. Deliberately
		# NOT asking the supervisor here either — measured on 2.1.247, its
		# status is still "busy" at the Stop instant in 4/4 runs and flips to
		# "shell" 43-87ms later, so an inline check can only ever answer wrong.
		# The watcher below covers work started in an EARLIER turn, which the
		# payload's array does not mention.
		set_state done "$C_DONE" "✅" "done"
		# Second opinion, off the hot path: in ~3s ask the supervisor's
		# session file whether this session is actually still busy (work we
		# have no event for), and quietly flip ✅ to ⏳ if so. Timing-proof:
		# whichever of hook and supervisor updates first, the recheck runs
		# after both.
		sid="$(safe_sid "$(field session_id)")"
		if [ -n "$sid" ]; then
			wtok="$$-$RANDOM-$RANDOM"
			tmux set -p -t "$TMUX_PANE" @claude_tabs_watch "$wtok" \; \
				run-shell -b "sleep 3; '$self_dir_fmt/scripts/navigator.sh' watch $TMUX_PANE '$sid' 1 '$wtok' >/dev/null 2>&1 || true" 2>/dev/null
		fi
	fi
	;;
error)
	turn_close
	reason="$(field error_type)"
	set_state error "$C_WAIT" "❌" "${reason:-error}"
	;;
end | clear)
	turn_close
	bg_close
	trace "-> cleared"
	for opt in @claude_tabs_glyph @claude_tabs_plain @claude_tabs_label @claude_tabs_state @claude_tabs_at @claude_tabs_seen @claude_tabs_watch; do
		tmux set -p -t "$TMUX_PANE" -u "$opt" 2>/dev/null
	done
	# The window badge is worst-of-panes: hand it to the surviving sibling
	# with the most urgent state instead of blanking a red "needs you" that
	# belongs to a Claude still running next door.
	tmux run-shell -b \
		"'$self_dir_fmt/scripts/navigator.sh' recompute $TMUX_PANE >/dev/null 2>&1 || true" 2>/dev/null
	# No refresh-client here or below: tmux already redraws when an option a
	# format reads changes. Forcing one per event meant a full status redraw
	# for every client on every tool call — measured peaks of 21 events per
	# second across sessions, which is what made the bar flicker under load.
	exit 0
	;;
*) exit 0 ;;
esac

# States worth interrupting you for. The jump key no longer reads anything we
# write here: it scans the panes themselves, so there is no global "last one"
# to keep current — and no stale pointer to teleport you to a two-day-old pane.
attention=""
case "$state" in wait | plan | done | error) attention=1 ;; esac
# A rescue is a correction, not news: no notification, no jump target.
[ -n "$rescue" ] && attention=""

prev=""
notify_on=on
notify_states="wait plan done error"
notify_style=status
dur=4000
bell=off
jump_key=J
sess="" win_id="" win_idx="" tty=""
if [ -n "$attention" ]; then
	# One round-trip for everything the notify path needs. #{@dash-names}
	# resolve pane → window → session → global, so the global options land
	# here too. One field per LINE: a control-byte separator (US) is escaped
	# into literal "\037" text by tmux 3.4's output path, and tab is IFS
	# whitespace (runs around empty fields collapse) — newline does neither.
	NL='
'
	info="$(tmux display -p -t "$TMUX_PANE" "#{@claude_tabs_state}${NL}#{@claude-tabs-notify}${NL}#{@claude-tabs-notify-states}${NL}#{@claude-tabs-notify-duration}${NL}#{@claude-tabs-bell}${NL}#{@claude-tabs-jump-key}${NL}#{session_name}${NL}#{window_id}${NL}#{window_index}${NL}#{pane_tty}${NL}#{@claude-tabs-notify-style}" 2>/dev/null)"
	{
		read -r prev
		read -r o_notify
		read -r o_states
		read -r o_dur
		read -r o_bell
		read -r o_jump
		read -r sess
		read -r win_id
		read -r win_idx
		read -r tty
		read -r o_style
	} <<EOF
$info
EOF
	[ -n "$o_style" ] && notify_style="$o_style"
	[ -n "$o_notify" ] && notify_on="$o_notify"
	[ -n "$o_states" ] && notify_states="$o_states"
	[ -n "$o_dur" ] && dur="$o_dur"
	# A non-numeric duration blew up the arithmetic below ("value too great
	# for base"), and anything under a second slept 0 and wiped the notice the
	# instant it appeared. The option is user input; treat it like it.
	case "$dur" in '' | *[!0-9]*) dur=4000 ;; esac
	[ "$dur" -lt 1000 ] && dur=1000
	[ -n "$o_bell" ] && bell="$o_bell"
	[ -n "$o_jump" ] && jump_key="$o_jump"
fi

# One tmux invocation instead of many: the round-trip to the tmux server is by
# far the most expensive thing this script does.
trace "-> $state"

# Stamp active states so `navigator sync` can tell "stuck for minutes" from
# "started a millisecond ago" before it overrules them. printf -v is a builtin:
# no fork on the hot path.
printf -v stamp '%(%s)T' -1 2>/dev/null
# Stock macOS bash 3.2 has no %(fmt)T — one date fork there, none anywhere else.
# ${stamp:-} is load-bearing: on 3.2 the failed printf leaves the variable
# UNSET rather than empty, so a bare "$stamp" aborts under set -u before
# ever reaching this fallback — the hook died on every prompt/tool/post.
case "${stamp:-}" in '' | *[!0-9]*) stamp="$(date +%s)" ;; esac

# Two stamps, deliberately different. @claude_tabs_at answers "how long has
# this pane looked busy" and so exists only while it does — clearing it on a
# terminal state is what stops a finished session from ever reading as stuck.
# @claude_tabs_seen answers "when did a hook last look at this pane at all",
# for every state including done, because `sync` needs to know whether the
# supervisor's verdict is older or newer than what the hooks witnessed.
active=""
case "$state" in thinking | tool | compact | bg) active=1 ;; esac

# The window shows the most urgent state among its panes, not the last
# writer's: with two Claudes in one window, a red "needs you" must not be
# overwritten by the neighbour finishing. One extra round-trip, active pane
# events only pay it when the window actually has other badged panes.
win_urgency() { # win_urgency <state>
	case "$1" in
	wait) echo 0 ;; error) echo 1 ;; plan) echo 2 ;;
	tool) echo 3 ;; thinking) echo 4 ;; compact) echo 5 ;;
	bg) echo 6 ;; done) echo 7 ;; idle) echo 8 ;; *) echo 9 ;;
	esac
}
w_glyph="$glyph" w_plain="$plain" w_label="$label" w_state="$state"
# One round-trip gives both the pane list and the window id. The lock is keyed
# on the WINDOW: ${TMUX_PANE#%} is the pane number, so siblings never contended
# and the mutual exclusion the old comment claimed never existed.
win_info="$(tmux list-panes -t "$TMUX_PANE" -F "#{window_id} #{pane_id}" 2>/dev/null)"
win_id_for_lock="${win_info%% *}"
win_panes="$(printf '%s\n' "$win_info" | cut -d' ' -f2)"
multi=""
case "$win_panes" in *"
"*) multi=1 ;; esac

# LAST LOOK before the write, and it has to be here rather than where the
# state was chosen. Each subagent-done drops its own marker under the lock,
# then decides its state by re-reading the marker file — but the tmux write is
# eighty lines further on, outside the lock. So only the hook that removed the
# LAST line ever decides "done", and whether the tab ends up right depends on
# whose write happens to land last. Measured at N=20 concurrent SubagentStops
# under load: about 7 in 100 trials finished with every drop recorded, no lock
# contention at all, and the tab still on the hourglass, because a "bg" writer
# landed after the "done" one. Re-reading here costs one stat on a path that
# has already done a dozen, and closes it to the microseconds between this
# test and the tmux call.
# Scoped to subagent-done, and it has to be: a running background SHELL task
# is also `bg`, and it has no line in this file at all — it comes out of the
# payload's background_tasks. Testing the file alone downgraded a task that
# was demonstrably still running to "done", on every platform.
if [ "${event:-}" = subagent-done ] && [ "$state" = bg ] &&
	[ -n "${bg_file:-}" ] && [ ! -s "$bg_file" ]; then
	set_state done "$C_DONE" "✅" "done"
fi
sets=(
	set -p -t "$TMUX_PANE" @claude_tabs_glyph "$glyph" ";"
	set -p -t "$TMUX_PANE" @claude_tabs_plain "$plain" ";"
	set -p -t "$TMUX_PANE" @claude_tabs_label "$label" ";"
	set -p -t "$TMUX_PANE" @claude_tabs_state "$state"
)
# A single-pane window needs no aggregation: its badge IS this pane's, so it
# rides along in the same invocation.
if [ -z "$multi" ]; then
	sets+=(
		";" set -w -t "$TMUX_PANE" @claude_tabs_wglyph "$glyph" ";"
		set -w -t "$TMUX_PANE" @claude_tabs_wplain "$plain" ";"
		set -w -t "$TMUX_PANE" @claude_tabs_wlabel "$label" ";"
		set -w -t "$TMUX_PANE" @claude_tabs_state "$state"
	)
fi
if [ -n "$active" ]; then
	sets+=(";" set -p -t "$TMUX_PANE" @claude_tabs_at "$stamp")
	sets+=(";" set -w -t "$TMUX_PANE" @claude_tabs_at "$stamp")
else
	sets+=(";" set -p -t "$TMUX_PANE" -u @claude_tabs_at)
	sets+=(";" set -w -t "$TMUX_PANE" -u @claude_tabs_at)
fi
sets+=(";" set -p -t "$TMUX_PANE" @claude_tabs_seen "$stamp")
# Server-wide "the hooks are alive" stamp, riding in the same invocation so it
# costs nothing. While it is fresh, `sync` reads a badge/supervisor
# contradiction through the hook-conflict arms; once it has been quiet for ten
# minutes the poller owns the badges and maps the supervisor's verdict
# directly — which is how the plugin works with no hooks installed at all.
sets+=(";" set -g @claude_tabs_hooks_at "$stamp")
tmux "${sets[@]}" 2>/dev/null

# Multi-pane windows aggregate AFTER the pane write, so the reader always sees
# its own value, and under a lock it actually waits for: the old code took the
# lock non-blockingly and carried on regardless when it was held, which is why
# two siblings could still interleave and pin a stale aggregate — a sibling's
# red "needs you" got overwritten by this pane finishing.
if [ -n "$multi" ]; then
	win_lock="$turn_dir/win-${win_id_for_lock#@}.lock"
	[ -d "$turn_dir" ] || priv_mkdir "$turn_dir"
	# Reclaim a lock a killed holder left behind — but only when the holder is
	# really gone. Reclaiming on age alone took the lock away from a hook that
	# was merely slow (a loaded machine, a stopped process) and let both
	# aggregate at once: the exact interleaving this lock exists to prevent.
	if [ -d "$win_lock" ]; then
		holder="$(cat "$win_lock/pid" 2>/dev/null)"
		case "$holder" in
		'' | *[!0-9]*)
			# No pid recorded — an older version, or a torn write. Age is the
			# weaker rule, but better than waiting on a lock nobody holds.
			if [ -n "$(find "$win_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
				rm -f "$win_lock/pid" 2>/dev/null
				rmdir "$win_lock" 2>/dev/null
			fi
			;;
		*)
			# `kill -0` proves a process EXISTS, not that it is the one that
			# took the lock. Once that pid has been recycled by something
			# unrelated it answers yes forever and the lock is never reclaimed:
			# measured, every hook on that window then cost 0.60s instead of
			# 0.13s — on the per-tool-call path, permanently. This critical
			# section is a handful of tmux round-trips, so a lock this old is
			# not one a hook is holding, whatever the pid says.
			if ! kill -0 "$holder" 2>/dev/null ||
				[ -n "$(find "$win_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
				rm -f "$win_lock/pid" 2>/dev/null
				rmdir "$win_lock" 2>/dev/null
			fi
			;;
		esac
	fi
	locked=""
	for _try in 1 2 3 4 5 6 7 8 9 10; do
		if mkdir "$win_lock" 2>/dev/null; then
			printf '%s' "$$" >"$win_lock/pid" 2>/dev/null
			locked=1
			break
		fi
		sleep 0.05
	done
	if [ -z "$locked" ]; then
		# Half a second and the lock is still held: on a loaded machine forks
		# take hundreds of milliseconds and the holder is simply slow, not
		# dead. Proceeding unlocked here is exactly the interleaving the lock
		# exists to prevent — the pre-lock code did that, and a sibling's red
		# got pinned under a stale aggregate. Defer instead: a full recompute
		# a second from now reads every pane fresh, after both writers.
		tmux run-shell -b \
			"sleep 1; '$self_dir_fmt/scripts/navigator.sh' recompute $TMUX_PANE >/dev/null 2>&1 || true" 2>/dev/null
	else
		best=99 n_claude=0
		while IFS= read -r pn; do
			[ -n "$pn" ] || continue
			ost="$(tmux show -pqv -t "$pn" @claude_tabs_state 2>/dev/null)"
			[ -n "$ost" ] || continue
			n_claude=$((n_claude + 1))
			ou="$(win_urgency "$ost")"
			if [ "$ou" -lt "$best" ]; then
				og="$(tmux show -pqv -t "$pn" @claude_tabs_glyph 2>/dev/null)"
				# A pane with a state but no glyph has nothing to publish.
				# Taking it anyway wrote an EMPTY aggregate to the window, and
				# since the formats read window-only names there is no pane
				# value to fall back on: the tab lost its badge entirely.
				[ -n "$og" ] || continue
				best="$ou"
				w_state="$ost"
				w_glyph="$og"
				w_plain="$(tmux show -pqv -t "$pn" @claude_tabs_plain 2>/dev/null)"
				w_label="$(tmux show -pqv -t "$pn" @claude_tabs_label 2>/dev/null)"
			fi
		done <<-EOF
			$win_panes
		EOF
		if [ "$best" -lt 99 ]; then
			# Two Claudes in one window used to look exactly like one. The count
			# rides on the glyph rather than taking a second segment, so a split
			# window costs one cell and an ordinary one costs nothing. It sits
			# after #[nobold] on purpose: the digit keeps the state's colour but
			# not its weight, so the emoji still reads first. The label is left
			# alone — it is already shown next to the glyph on the current
			# window, where "done (3 sessions)" would just repeat the digit.
			if [ "$n_claude" -gt 1 ]; then
				w_glyph="$w_glyph$n_claude"
				w_plain="$w_plain$n_claude"
			fi
			tmux set -w -t "$TMUX_PANE" @claude_tabs_wglyph "$w_glyph" \; \
				set -w -t "$TMUX_PANE" @claude_tabs_wplain "$w_plain" \; \
				set -w -t "$TMUX_PANE" @claude_tabs_wlabel "$w_label" \; \
				set -w -t "$TMUX_PANE" @claude_tabs_state "$w_state" 2>/dev/null
		fi
		# The pid file we wrote when taking the lock lives INSIDE it, so a
		# bare rmdir can never succeed: every multi-pane window kept its
		# lock directory for good, owned by a dead pid, and every later hook
		# had to go through the stale-reclaim path instead of finding it free.
		rm -f "$win_lock/pid" 2>/dev/null
		rmdir "$win_lock" 2>/dev/null
	fi
fi

# Notify once per transition: PermissionRequest and the matching Notification
# both land on "wait", a subagent's completion and the turn's Stop both land on
# "done" — the second of each pair is suppressed by prev == state.
if [ -n "$attention" ] && [ -z "$rescue" ] && [ "$prev" != "$state" ] && [ "$notify_on" = on ]; then
	case " $notify_states " in
	*" $state "*)
		# Formats are expanded wherever this text lands — double any # in it
		# $label is already doubled by set_state; doubling again would put a
		# literal "##" on screen.
		msg="$icon $label · ${sess//"#"/"##"}:$win_idx · $jump_key = jump"
		if [ "$notify_style" = message ]; then
			# tmux draws a message OVER the whole status line for its
			# duration: the window list disappears while it is up. Kept as an
			# option, but not the default for exactly that reason.
			tmux list-clients -F "#{client_name}${T}#{session_name}${T}#{window_id}" 2>/dev/null |
				while IFS="$T" read -r cname csess cwin; do
					[ -n "$cname" ] || continue
					[ -n "$csess" ] || continue
					# Skip clients already looking at this window.
					[ "$csess" = "$sess" ] && [ "$cwin" = "$win_id" ] && continue
					tmux display-message -c "$cname" -d "$dur" "$msg" 2>/dev/null ||
						tmux display-message -c "$cname" "$msg" 2>/dev/null
				done
		elif [ "$notify_style" != off ]; then
			# The notice is one global segment, so "is anyone looking at this
			# window" replaces the message path's per-client check.
			if tmux list-clients -F "#{session_name}${T}#{window_id}" 2>/dev/null |
				grep -qxF "$sess${T}$win_id"; then
				exit 0
			fi
			# A transient segment in the status line instead: it sits next to
			# the window list rather than on top of it. The token lets a stale
			# expiry give up when a newer notice has replaced this one.
			tok="$$-$stamp$RANDOM"
			tmux set -g @claude_tabs_notice "$msg" \; \
				set -g @claude_tabs_notice_tok "$tok" 2>/dev/null
			# A stale expiry must exit 0. This was "[ token matches ] && tmux set -gu",
			# so the ORDINARY case — a newer notice already replaced this one, or the
			# notice was cleared by hand — failed the test, returned 1, and tmux printed
			# the whole command back at the user as an error over the status line. The
			# cleanup routine for notifications was itself producing a notification.
			tmux run-shell -b "sleep $((dur / 1000)); [ \"\$(tmux show -gqv @claude_tabs_notice_tok)\" = '$tok' ] && tmux set -gu @claude_tabs_notice \; set -gu @claude_tabs_notice_tok || true" 2>/dev/null
		fi
		if [ "$bell" = on ] && [ -n "$tty" ] && [ -w "$tty" ]; then
			printf '\a' >"$tty" 2>/dev/null
		fi
		;;
	esac
fi

exit 0
