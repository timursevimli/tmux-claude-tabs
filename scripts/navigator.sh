#!/usr/bin/env bash
# The navigator: every Claude session on the server in one popup — live ones
# with their badge state, recently ended ones ready to resume.
#
#   navigator.sh open <client> <cwd>    key binding entry: popup (fzf) or menu
#   navigator.sh pick <client> <cwd>    runs inside the popup
#   navigator.sh rows                   row feed (fzf reload)
#   navigator.sh watch <pane> <sid> [n]  follow a session until its
#                                       background work settles
#   navigator.sh poll <token>           per-server poller: follow the
#                                       supervisor files, reconcile on change
#                                       (the hookless path; `poll once` for
#                                       a single diagnostic tick)
#   navigator.sh jump <client> <pane>   focus a live Claude's pane
#   navigator.sh resume <client> <sid> <cwd>   new window, claude --resume
#   navigator.sh new <client> <cwd>     new window, fresh claude
#   navigator.sh newdir <client> <cwd>  directory picker, then `new` (alt-n)
#   navigator.sh dispose <kind> <id> <aux>     kill a live one / forget history
#   navigator.sh jump-last <client>     step through the panes that need you
#
# Jumping is three plain tmux commands (switch-client, select-window,
# select-pane) — sessions live where you started them; nothing is moved into
# special sessions or overlay popups.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
me="$DIR/navigator.sh"
# run-shell format-expands its argument before sh ever sees it, so a '#' in
# the install path or in $HOME is read as a format code (#S, #W, #I...). The
# hook doubles for exactly this reason; printf %q escapes it for SH as '\#',
# which the format expander does not recognise, so %q alone was not enough.
me_fmt="${me//"#"/"##"}"
T=$'\t'

# tmux's #[fg=colourN] wants a 256-colour PALETTE index, but the column this
# used to read from agents.sh is an ANSI SGR number (31 red, 32 green, 34 blue,
# 35 magenta, 90 grey) — right for the \033[Nm badge agents.sh builds for the
# popup, and something else entirely once written into a tmux format: colour31
# is teal, colour32 azure, colour34 and colour35 both green, colour90 magenta.
# So in the DEFAULT hookless mode every badge was the wrong colour — "needs
# you", the one thing this plugin exists for, rendered teal instead of red, and
# working and background were both green and indistinguishable. Map the state
# to the hook's own palette instead, so a badge the poller paints matches the
# one a hook paints for the same state.
badge_colour() { # badge_colour <state>
	case "$1" in
	wait | error) printf 167 ;;   # C_WAIT   red
	tool | compact) printf 109 ;; # C_WORK   blue
	thinking) printf 214 ;;       # C_THINK  orange
	done) printf 142 ;;           # C_DONE   green
	bg | plan) printf 175 ;;      # C_PLAN   pink
	*) printf 245 ;;              # C_IDLE   grey
	esac
}

supervisor_usable() {
	# Files existing is not the same as files being useful: if every session
	# runs outside this tmux server, or the format drifted, agents.sh falls
	# back to the 350ms-4.3s CLI and the cheap-source assumption is wrong.
	# Test what actually matters — does any supervisor file name a pane that
	# exists here — for one tmux round-trip.
	local dir
	dir="$(supervisor_dir)"
	ls "$dir"/*.json >/dev/null 2>&1 || return 1
	{
		tmux list-panes -a -F 'P #{pane_id}' 2>/dev/null
		for f in "$dir"/*.json; do
			[ -f "$f" ] || continue
			line="$(<"$f")" 2>/dev/null || continue
			case "$line" in *'"tmux":"'*) ;; *) continue ;; esac
			pn="${line#*\"tmux\":\"}"; pn="${pn%%\"*}"
			case "$pn" in *%*) printf 'S %s\n' "%${pn##*%}" ;; esac
		done
	} | awk '$1 == "P" { p[$2] = 1; next }
		$1 == "S" && ($2 in p) { found = 1 }
		END { exit(found ? 0 : 1) }'
}

# "Is this pid still the process the record describes?" — the identity check
# agents.sh already makes, hoisted so sweep and the poller can make it too.
# `kill -0` alone only says "some process has this number": a session file left
# behind by a crash or a SIGKILL outlives its process, the OS eventually hands
# the number to something unrelated, and that zombie record then shielded the
# pane it names from the sweep for good — a red "needs you" on a window with no
# Claude in it, and, being "busy", the poller pinned to its 2s interval on an
# otherwise idle machine. Lives here rather than in helpers.sh, which the hook
# and agents.sh share.
#
# The table costs a `ps` fork, so it is built lazily and at most once per pass.
# The poller clears it at the top of every tick on purpose: a table cached
# across ticks would answer with a process list minutes old, and a WRONG start
# time rejects a live session — which files it as ended and wipes its badge.
_ct_proc_starts=""
same_pid_ok() { # same_pid_ok <pid> <record-line>
	local rest ms secs
	case "$2" in *'"startedAt":'*) ;; *) return 0 ;; esac   # no claim to check
	rest="${2#*\"startedAt\":}"
	ms="${rest%%,*}"; ms="${ms%\}}"
	secs="$(epoch_ms "$ms")" || return 0
	[ -n "$_ct_proc_starts" ] || _ct_proc_starts=" $(proc_start_table) "
	same_process "$_ct_proc_starts" "$1" "$secs"
}

urgency() { # urgency <state>
	case "$1" in
	wait) echo 0 ;; error) echo 1 ;; plan) echo 2 ;;
	tool) echo 3 ;; thinking) echo 4 ;; compact) echo 5 ;;
	bg) echo 6 ;; done) echo 7 ;; idle) echo 8 ;; *) echo 9 ;;
	esac
}

recompute_window() { # recompute_window <window-or-pane-target>
	# Rebuild the window badge as worst-of its panes' PANE-scoped states
	# (show -pqv never falls back to the window value the way #{@x} in a
	# format does). Unsets the window badge when no pane has one.
	local tgt="$1" best=99 bp="" pn u st n=0 g pl lb
	while IFS= read -r pn; do
		[ -n "$pn" ] || continue
		st="$(tmux show -pqv -t "$pn" @claude_tabs_state 2>/dev/null)"
		[ -n "$st" ] || continue
		n=$((n + 1))
		# A pane counts toward the session tally on its state alone, but it can
		# only be the one SHOWN if it has something to show. A pane carrying a
		# state with no glyph — a half-written badge, or a state set by hand —
		# used to win the urgency contest and publish an empty aggregate, and
		# the window then rendered no badge at all while its panes had one.
		[ -n "$(tmux show -pqv -t "$pn" @claude_tabs_glyph 2>/dev/null)" ] || continue
		u="$(urgency "$st")"
		if [ "$u" -lt "$best" ]; then best="$u" bp="$pn"; fi
	done <<-EOF
		$(tmux list-panes -t "$tgt" -F '#{pane_id}' 2>/dev/null)
	EOF
	if [ -n "$bp" ]; then
		g="$(tmux show -pqv -t "$bp" @claude_tabs_glyph 2>/dev/null)"
		pl="$(tmux show -pqv -t "$bp" @claude_tabs_plain 2>/dev/null)"
		lb="$(tmux show -pqv -t "$bp" @claude_tabs_label 2>/dev/null)"
		# Same count the hook appends, so a badge repaired here and one written
		# by an event cannot disagree about how many sessions a window holds.
		if [ "$n" -gt 1 ]; then
			g="$g$n"; pl="$pl$n"
		fi
		tmux set -w -t "$tgt" @claude_tabs_state "$(tmux show -pqv -t "$bp" @claude_tabs_state 2>/dev/null)" \; \
			set -w -t "$tgt" @claude_tabs_wlabel "$lb" \; \
			set -w -t "$tgt" @claude_tabs_wglyph "$g" \; \
			set -w -t "$tgt" @claude_tabs_wplain "$pl" 2>/dev/null
	else
		for o in @claude_tabs_glyph @claude_tabs_plain @claude_tabs_label @claude_tabs_state @claude_tabs_at @claude_tabs_seen @claude_tabs_watch @claude_tabs_wglyph @claude_tabs_wplain @claude_tabs_wlabel; do
			tmux set -w -t "$tgt" -u "$o" 2>/dev/null
		done
	fi
}

# "No Claude sessions" is a lie when the files are sitting right there and we
# simply cannot read them: it sends the user hunting a dead poller instead of
# looking at the permissions on the supervisor directory.
no_sessions_reason() {
	local sup n=0 unreadable=0 f
	sup="$(supervisor_dir)"
	[ -d "$sup" ] || { printf 'no Claude sessions (%s does not exist)' "$sup"; return 0; }
	for f in "$sup"/*.json; do
		[ -e "$f" ] || continue
		n=$((n + 1))
		[ -r "$f" ] || unreadable=$((unreadable + 1))
	done
	if [ "$unreadable" -gt 0 ]; then
		printf 'cannot read %d of %d session files in %s — check its permissions' \
			"$unreadable" "$n" "$sup"
	else
		printf 'no Claude sessions (live or recent)'
	fi
}

msg() { # msg <client> <text>
	local c="$1"
	shift
	# display-message FORMAT-EXPANDS its argument, and #(…) in a tmux format
	# runs a command. Every caller here passes something from outside — a cwd
	# out of a supervisor file, a tool name, a session name — so a directory
	# called `#(touch /tmp/pwned)` executed on the way to telling the user it
	# was gone. Double the # once, at the one choke point every caller goes
	# through; no caller wants a format expanded.
	local t="tmux-claude-tabs: $*"
	t="${t//"#"/"##"}"
	if [ -n "$c" ]; then
		tmux display-message -c "$c" "$t" 2>/dev/null
	else
		tmux display-message "$t" 2>/dev/null
	fi
}

lost_note() { # lost_note <client> <pid> <where-column>
	# A `lost` row is a live Claude whose pane this server cannot resolve —
	# the record says "None", names a pane that is gone, or belongs to another
	# tmux server. There is nowhere to jump to, so Enter cannot do what it does
	# for a placed session; but doing NOTHING is the silent drop this row kind
	# was added to end, wearing a new coat. Name the pid and the location the
	# record claims: that string is the only clue left to where the session is.
	local w="${3:-}"
	w="${w#unplaced }"                       # agents.sh labels and pads it
	w="${w%"${w##*[![:space:]]}"}"
	msg "$1" "pid ${2:-?} is a live Claude with no pane on this server${w:+ (record: $w)}"
}

client_session() { # client_session <client>  → session id ($n) of that client
	[ -n "$1" ] || return 0
	tmux list-clients -F "#{client_name}$T#{session_id}" 2>/dev/null |
		awk -F "$T" -v c="$1" '$1 == c { print $2; exit }'
}

spawn() { # spawn <client> <cwd> <shell-command>
	local client="$1" cwd="$2" run="$3" sess cwd_fmt run_fmt
	if [ ! -d "$cwd" ]; then
		msg "$client" "directory is gone: $cwd"
		return 0
	fi
	# new-window format-expands both the start-directory and the command —
	# double any # so a path like ~/dev/c# survives.
	cwd_fmt="${cwd//"#"/"##"}"
	run_fmt="${run//"#"/"##"}"
	sess="$(client_session "$client")"
	if [ -n "$sess" ]; then
		tmux new-window -t "$sess:" -c "$cwd_fmt" "$run_fmt" 2>/dev/null
		tmux switch-client -c "$client" -t "$sess" 2>/dev/null
	else
		tmux new-window -c "$cwd_fmt" "$run_fmt" 2>/dev/null
	fi
}

cmd="${1:-open}"
shift 2>/dev/null || true

case "$cmd" in
open)
	client="${1:-}"
	# Second argument is a PANE ID from the key binding — the path is resolved
	# here rather than travelling through tmux's format expander, which does
	# not escape a newline. A literal path is still accepted so the demo and
	# the suite can call this directly.
	invoke_cwd="${2:-$PWD}"
	case "$invoke_cwd" in
	%[0-9]*)
		invoke_cwd="$(tmux display -p -t "$invoke_cwd" '#{pane_current_path}' 2>/dev/null)"
		[ -n "$invoke_cwd" ] || invoke_cwd="$PWD"
		;;
	esac
	# Repair badges while the popup is up: the rows are being fetched anyway, so
	# a background reconcile costs nothing the user waits for.
	tmux run-shell -b "$(printf '%q' "$me_fmt") sync force >/dev/null 2>&1 || true" 2>/dev/null
	if command -v fzf >/dev/null 2>&1; then
		w="$(get_tmux_option @claude-tabs-popup-width '80%')"
		h="$(get_tmux_option @claude-tabs-popup-height '75%')"
		popup_cmd="$(printf '%q pick %q %q' "$me" "$client" "$invoke_cwd")"
		# display-popup format-expands its command — double the #s
		exec tmux display-popup ${client:+-c "$client"} -w "$w" -h "$h" -E \
			"${popup_cmd//"#"/"##"}"
	fi
	# No fzf: a display-menu with the same rows, minus preview and kill.
	# Menu item commands pass through tmux's command parser and then sh — no
	# quoting survives both for arbitrary paths, so the rows go into a state
	# file and each item carries only its line number (menuact reads the rest).
	rows="$(CLAUDE_TABS_PLAIN=1 "$DIR/agents.sh")"
	if [ -z "$rows" ]; then
		msg "$client" "$(no_sessions_reason)"
		exit 0
	fi
	state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
	priv_mkdir "$state_dir"
	# One file per client: with two clients in the no-fzf menu the second
	# rewrote the rows under the first, whose items carry only a line number,
	# so a pick acted on a different session.
	menu_key="${client//[^A-Za-z0-9._-]/_}"
	menu_file="$state_dir/menu-rows-${menu_key:-none}"
	{
		printf 'C\t%s\t%s\n' "$client" "$invoke_cwd"
		printf '%s\n' "$rows"
	} >"$menu_file"
	me_q="'${me//"#"/"##"}'"
	args=()
	i=0
	total=0
	# The trailing `_rest` is load-bearing: agents.sh emits 14 fields and this
	# read binds 8, so without it the LAST named variable swallows columns
	# 8-14 — state, src, emoji, colour, status, timestamp — and tmux strips
	# the tabs, printing raw internals as the menu label. That was the default
	# navigator for everyone without fzf.
	while IFS="$T" read -r _rank kind id aux cwd badge where dir _rest; do
		[ -n "$kind" ] || continue
		total=$((total + 1))
	done <<<"$rows"
	# tmux menus take single-key shortcuts; 1-9 then a-z keeps every row
	# reachable. It used to stop at 9 with no hint, silently hiding rows —
	# and the default history alone is 15.
	keys='123456789abcdefghijklmnoprstuvwxyz'
	max=${#keys}
	while IFS="$T" read -r _rank kind id aux cwd badge where dir _rest; do
		[ -n "$kind" ] || continue
		i=$((i + 1))
		[ "$i" -gt "$max" ] && break
		# Menu item NAMES are format-expanded by tmux, and #(...) in a format
		# runs a shell command when the menu opens — verified. The name here
		# carries a session cwd and a tool name, so double every # before it
		# reaches tmux.
		item="$badge  $where  $dir"
		args+=("${item//"#"/"##"}" "${keys:$((i - 1)):1}" "run-shell -b \"$me_q menuact $i ${menu_key:-none}\"")
	done <<<"$rows"
	if [ "$total" -gt "$max" ]; then
		args+=("" "$((total - max)) more — install fzf for the full list" "" "")
	fi
	args+=("" "New Claude here" N "run-shell -b \"$me_q menuact new ${menu_key:-none}\"")
	tmux display-menu ${client:+-c "$client"} -T '#[align=centre]Claude sessions' \
		-x C -y C "${args[@]}"
	;;

menuact)
	n="${1:-}"
	state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
	menu_file="$state_dir/menu-rows-${2:-none}"
	[ -f "$menu_file" ] || exit 0
	IFS="$T" read -r _tag client invoke_cwd <"$menu_file"
	if [ "$n" = new ]; then
		exec "$me" new "$client" "$invoke_cwd"
	fi
	case "$n" in *[!0-9]*) exit 0 ;; esac
	row="$(sed -n "$((n + 1))p" "$menu_file")"
	[ -n "$row" ] || exit 0
	IFS="$T" read -r _rank kind id aux cwd _badge where _rest <<<"$row"
	case "$kind" in
	live) exec "$me" jump "$client" "$id" ;;
	hist) exec "$me" resume "$client" "$id" "$cwd" ;;
	lost) lost_note "$client" "$aux" "$where" ;;
	esac
	;;

rows)
	exec "$DIR/agents.sh"
	;;

watch)
	# The event Claude Code does not send. A turn can end with work still
	# running — a backgrounded Bash, a Monitor, a scheduled wake-up — and when
	# that work finishes NOTHING fires in the session: no hook exists for it
	# (confirmed against the docs: TaskCompleted covers only TaskCreate,
	# agent_completed only fires with agent view open). The badge was left to
	# whatever happened to reconcile next, which in practice meant the next
	# window switch. Measured on a live session: 1h52m of a stale hourglass.
	#
	# So: watch that one session's file until it settles. This replaces the
	# old one-shot `recheck`, which could only ever downgrade done -> bg and
	# had no way back — the asymmetry that made the hourglass a one-way door.
	#
	# Deliberately NOT a global tick. It exists only while a specific pane has
	# work we have confirmed is running, and it stops the moment that is no
	# longer true, so an idle machine runs nothing at all.
	pane="${1:-}"
	key="${2:-}"        # session id on the first tick, then the file path
	n="${3:-1}"
	[ -n "$pane" ] && [ -n "$key" ] || exit 0
	# Someone else already resolved this pane (a new turn, a sync, the user).
	tok="${4:-}"
	st="$(tmux show -pqv -t "$pane" @claude_tabs_state 2>/dev/null)"
	case "$st" in done | bg) ;; *) tmux set -pu -t "$pane" @claude_tabs_watch 2>/dev/null; exit 0 ;; esac
	# One watcher per pane. Arming is allowed from anywhere — the hook's stop
	# path, the idle_prompt rescue, a reconcile that painted the hourglass —
	# and each arm stamps the pane with its own token, so an older watcher
	# stands down the moment a newer one takes over instead of both re-arming.
	if [ -n "$tok" ]; then
		[ "$(tmux show -pqv -t "$pane" @claude_tabs_watch 2>/dev/null)" = "$tok" ] || exit 0
	fi

	case "$key" in
	/*) f="$key" ;;
	*)  f="$(grep -l "\"sessionId\":\"$key\"" "$(supervisor_dir)"/*.json 2>/dev/null | head -1)" ;;
	esac
	[ -n "$f" ] && [ -f "$f" ] || exit 0
	# The file outlives the process it describes. Without this a session that
	# died mid-job would leave a record saying "shell" forever, and the watcher
	# would re-arm against it until its tick budget ran out. `kill -0` is a
	# builtin: no process, no cost.
	wpid="${f##*/}"; wpid="${wpid%.json}"
	case "$wpid" in
	'' | *[!0-9]*) ;;
	*) kill -0 "$wpid" 2>/dev/null || { sup_status=gone; } ;;
	esac
	[ "${sup_status:-}" = gone ] ||
		sup_status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)"
	line_upd="$(sed -n 's/.*"statusUpdatedAt":\([0-9]*\).*/\1/p' "$f" 2>/dev/null)"
	[ -n "$line_upd" ] && line_upd=$((line_upd / 1000))

	case "$sup_status" in
	busy | shell)
		# The same freshness rule sync lives by: the file may only overrule a
		# hook badge when its record is NEWER than what the hooks last saw.
		# Without this a watcher armed earlier flipped a fresh ✅ back to ⏳
		# off a record pinned minutes ago — demonstrated with a 300s-stale
		# "shell". A stale record also means there is nothing here worth
		# watching, so no re-arm either: the badge's own paths re-arm when
		# something real happens.
		if [ "$st" = done ]; then
			wseen="$(tmux show -pqv -t "$pane" @claude_tabs_seen 2>/dev/null)"
			case "$wseen" in '' | *[!0-9]*) wseen=0 ;; esac
			wupd="${line_upd:-}"
			if [ -n "$wupd" ] && [ "$wupd" -lt "$wseen" ] 2>/dev/null; then
				tmux set -pu -t "$pane" @claude_tabs_watch 2>/dev/null
				exit 0
			fi
		fi
		# Still working. Paint the hourglass if it is not up yet, then look
		# again later — backing off, because a background job that has already
		# run a minute is not about to need millisecond resolution.
		if [ "$st" = done ]; then
			[ "$sup_status" = shell ] && wlabel="bg shell" || wlabel=busy
			tmux set -p -t "$pane" @claude_tabs_state bg \; \
				set -p -t "$pane" @claude_tabs_label "$wlabel" \; \
				set -p -t "$pane" @claude_tabs_glyph "#[fg=colour175,bold]⏳#[nobold]" \; \
				set -p -t "$pane" @claude_tabs_plain "#[bold]⏳#[nobold]" 2>/dev/null
			# The window shows the most urgent pane — a sibling's red must not
			# be painted over by this pane's hourglass.
			recompute_window "$pane"
		fi
		# Belt and braces only. The watcher already stops when the badge is no
		# longer an hourglass, when the session file goes away, when the
		# process behind it dies, and when the work settles — so this exists
		# to bound a bug of mine, not a cost: 500 ticks is about 8 hours,
		# longer than any background job has a right to be, and the ticks
		# themselves measured 20ms each.
		limit="$(get_tmux_option @claude-tabs-watch-ticks 500)"
		# Re-arming requires a token. Every production arm stamps one; a bare
		# diagnostic call (watch <pane> <sid> 1) acts once and stops — without
		# this, such a call re-armed itself with an EMPTY token, which slid
		# past the one-watcher-per-pane guard forever and kept stamping badges
		# long after the caller was gone.
		[ -n "$tok" ] || limit=0
		if [ "$n" -lt "$limit" ] 2>/dev/null; then
			if   [ "$n" -lt 3 ];  then delay=3
			elif [ "$n" -lt 6 ];  then delay=10
			elif [ "$n" -lt 12 ]; then delay=30
			else                       delay=60
			fi
			tmux run-shell -b \
				"sleep $delay; $(printf '%q' "$me_fmt") watch $pane '${f//"#"/"##"}' $((n + 1)) '$tok' >/dev/null 2>&1 || true" 2>/dev/null
		fi
		;;
	waiting)
		# Blocked on you. This used to fall into the catch-all below and paint
		# ✅ over a session waiting for an answer — the catch-all's comment
		# said "settled", but `waiting`, an unreadable record and the
		# synthetic "gone" all landed there. Stop watching and let the
		# reconcile paint the red; the watcher only ever lowers hourglasses.
		tmux set -pu -t "$pane" @claude_tabs_watch 2>/dev/null
		;;
	*)
		# Settled. Only ever clears an hourglass — a badge the user has not
		# acted on and which says "not your turn". Anything else (a new turn
		# started, red, an error) is left alone.
		if [ "$st" = bg ]; then
			tmux set -p -t "$pane" @claude_tabs_state done \; \
				set -p -t "$pane" @claude_tabs_label done \; \
				set -p -t "$pane" @claude_tabs_glyph "#[fg=colour142,bold]✅#[nobold]" \; \
				set -p -t "$pane" @claude_tabs_plain "#[bold]✅#[nobold]" 2>/dev/null
			recompute_window "$pane"
		fi
		tmux set -pu -t "$pane" @claude_tabs_watch 2>/dev/null
		;;
	esac
	exit 0
	;;

recompute)
	# Rebuild one window's badge from its surviving panes (used by the hook's
	# end/clear path, which must not blank a sibling's red).
	[ -n "${1:-}" ] || exit 0
	# This verb is also wired to window-layout-changed, the only event tmux
	# offers for a pane moving between windows (there is no after-move-pane).
	# That event also fires on every resize STEP, so the hook passes "deferrable"
	# and the cost of the noisy case was MEASURED rather than assumed: fifty
	# resize steps on a four-pane window cost 3.76 s unthrottled against 3.31 s
	# with a one-second throttle, and neither left a process behind. The throttle
	# bought 13% and lost correctness — a window created and given a pane inside
	# the same second had its event dropped and its badge never arrived — so
	# there is no throttle. What the flag still buys is the deferral below.
	if [ "${2:-}" = deferrable ]; then
		# The window aggregation lock exists so two aggregations cannot race, so
		# a layout event arriving mid-aggregation must DEFER rather than barge
		# in: the holder finishes and its own deferred recompute lands the final
		# answer. Without this a `split-window` fired a recompute that overwrote
		# a badge another writer was in the middle of setting.
		_wid="${1#@}"
		_wl="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs/turns/win-${_wid}.lock"
		[ -d "$_wl" ] && exit 0
	fi
	recompute_window "$1"
	exit 0
	;;

sweep)
	# A pane died (tmux pane-exited/pane-died/after-kill-pane hook). Two kinds
	# of leftovers: a window badge whose owning pane is gone, and a pane badge
	# whose Claude is gone while the pane (a shell) lives on. #{@x} in a
	# format falls back pane→window, so the check MUST use show -pqv.
	sup="$(supervisor_dir)"
	# Body in a function: bash 3.2 mis-parses a `case` inside $( ), taking
	# the `)` of a case pattern as the end of the substitution. Stock macOS
	# ships 3.2, where this made sweep a no-op that also aborted.
	# Sets live_panes, and unmapped=1 when some live session could not be
	# placed by this cheap rule.
	#
	# The rule is DELIBERATELY weaker than agents.sh's: that one also finds a
	# session through its controlling tty when the record has no usable pane —
	# an older Claude Code, a record naming another tmux server, or the
	# literal "None" the 2.1.x line writes. So a pane agents.sh badges can be
	# invisible here, and clearing on that basis erased a live session's
	# badge: the red one it had just painted for a permission prompt, which
	# fires no further hook while the prompt is up, so it did not come back.
	# Rather than duplicate the tty walk, notice when the cheap rule came up
	# short and decline to clear anything at all — the same conservative call
	# the empty-live_panes guard below already makes.
	#
	# The pane id is also checked against the session name, as agents.sh does:
	# ~/.claude/sessions is shared between tmux servers while pane ids are
	# per-server, so a record from another server was shielding whatever
	# happened to share its number here.
	_live_panes() {
		local lp pn sess_here
		unmapped=0
		for f in "$sup"/*.json; do
			[ -f "$f" ] || continue
			line="$(<"$f")" 2>/dev/null || continue
			# Same liveness rule as agents.sh: a lingering file for a dead pid
			# must not shield its pane's badge from the sweep.
			lp="${f##*/}"; lp="${lp%.json}"
			case "$lp" in
			'' | *[!0-9]*) continue ;;
			*) kill -0 "$lp" 2>/dev/null || continue ;;
			esac
			# ...and the identity half of it: a file whose pid the OS has
			# handed to something else is not a session, and letting it count
			# shielded its pane from every sweep, permanently.
			same_pid_ok "$lp" "$line" || continue
			# A background task's record describes work, not a pane of its
			# own; its parent's record is what shields the pane.
			case "$line" in *'"kind":"bg"'*) continue ;; esac
			case "$line" in *'"tmux":"'*) ;; *) unmapped=1; continue ;; esac
			pn="${line#*\"tmux\":\"}"; pn="${pn%%\"*}"
			case "$pn" in
			*%*) ;;
			*) unmapped=1; continue ;;
			esac
			sess_here="$(tmux display -p -t "%${pn##*%}" '#{session_name}' 2>/dev/null)"
			if [ -n "$sess_here" ] && [ "$sess_here" = "${pn%%:*}" ]; then
				printf '%s ' "%${pn##*%}"
			else
				unmapped=1
			fi
		done
	}
	# Stamped BEFORE the snapshot: a session that starts and paints its badge
	# while we are reading the session files is not in that snapshot, and
	# clearing on it would erase a badge younger than the evidence against it.
	snap_t="$(date +%s)"
	unmapped=0
	# One process table for the whole sweep: _live_panes runs in a command
	# substitution, so a table it built there could not reach the second loop,
	# and the identity check would pay for two `ps` calls instead of one. Built
	# only when there is a record to check at all — a pane dying on a server
	# with no Claude on it must stay free.
	for f in "$sup"/*.json; do
		[ -f "$f" ] && { _ct_proc_starts=" $(proc_start_table) "; break; }
	done
	live_panes=" $(_live_panes) "
	# A subshell cannot hand a variable back, so ask the same question again
	# here: is there a live session this rule could not place?
	for f in "$sup"/*.json; do
		[ -f "$f" ] || continue
		line="$(<"$f")" 2>/dev/null || continue
		lp="${f##*/}"; lp="${lp%.json}"
		case "$lp" in '' | *[!0-9]*) continue ;; *) kill -0 "$lp" 2>/dev/null || continue ;; esac
		same_pid_ok "$lp" "$line" || continue
		case "$line" in *'"kind":"bg"'*) continue ;; esac
		case "$line" in
		*'"tmux":"'*)
			pn="${line#*\"tmux\":\"}"; pn="${pn%%\"*}"
			case "$pn" in
			*%*)
				case "$live_panes" in
				*" %${pn##*%} "*) ;;
				*) unmapped=1 ;;
				esac
				;;
			*) unmapped=1 ;;
			esac
			;;
		*) unmapped=1 ;;
		esac
	done
	tmux list-panes -a -F "#{window_id}$T#{pane_id}" 2>/dev/null |
		while IFS="$T" read -r w pn; do
			[ -n "$pn" ] || continue
			st="$(tmux show -pqv -t "$pn" @claude_tabs_state 2>/dev/null)"
			pane_seen="$(tmux show -pqv -t "$pn" @claude_tabs_seen 2>/dev/null)"
			case "$pane_seen" in '' | *[!0-9]*) pane_seen=0 ;; esac
			if [ -n "$st" ] && [ -n "${live_panes// /}" ] && [ "$unmapped" = 0 ] &&
				[ "$pane_seen" -lt "$snap_t" ]; then
				case "$live_panes" in
				*" $pn "*) ;;
				*)
					# Badged pane with no live Claude behind it (hard kill).
					for o in @claude_tabs_glyph @claude_tabs_plain @claude_tabs_label @claude_tabs_state @claude_tabs_at @claude_tabs_seen @claude_tabs_watch; do
						tmux set -p -t "$pn" -u "$o" 2>/dev/null
					done
					st=""
					;;
				esac
			fi
			# Second field: does this pane STILL carry a badge (after the
			# clearing decision above)? The window loop below needs it, and
			# asking tmux again there would be one extra round-trip per pane.
			printf '%s%s%s\n' "$w" "$T" "${st:+1}"
		done | awk -F"$T" '
			{ seen[$1] = 1; if ($2 != "") badged[$1] = 1 }
			END { for (w in seen) printf "%s\t%s\n", w, (w in badged ? 1 : 0) }
		' | while IFS="$T" read -r w has_badged_pane; do
		[ -n "$w" ] || continue
		if [ -z "$(tmux show -wqv -t "$w" @claude_tabs_state 2>/dev/null)" ]; then
			# No window badge — but a PANE here has one, so the aggregate has
			# to be built from scratch rather than skipped. That is exactly
			# what a pane arriving from another window looks like: move-pane,
			# join-pane, break-pane and swap-pane carry the pane-scoped badge
			# with the pane and leave the window's copy behind, and nothing
			# else in the plugin rebuilds a window whose panes' states did not
			# change. Measured: the red "needs you" sat on the window that no
			# longer held the session and never appeared on the one that did,
			# through a window switch and 121 s of polling.
			[ "$has_badged_pane" = 1 ] || continue
		fi
		recompute_window "$w"
	done
	exit 0
	;;

trace)
	# `navigator.sh trace on|off|show` — records every hook invocation, for
	# working out why a badge will not settle.
	dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
	case "${1:-show}" in
	on)
		priv_mkdir "$dir" && : >"$dir/trace"
		echo "tracing to $dir/trace.log"
		if [ -z "$(tmux show -gqv @claude_tabs_hooks_at 2>/dev/null)" ]; then
			echo "note: no hook has fired on this server, so this is poll mode —"
			echo "      the log records poller passes, not per-tool-call events"
		fi
		;;
	off)
		rm -f "$dir/trace"
		echo "tracing off (log kept at $dir/trace.log)"
		;;
	*) tail -n "${2:-40}" "$dir/trace.log" 2>/dev/null || echo "no trace log yet" ;;
	esac
	;;

sync)
	# Two jobs, both against `claude agents --json` as the source of truth:
	#
	#   seed     a live Claude with no badge at all — after installing the
	#            plugin, after a tmux server restart, or a session that was
	#            already running before the hooks existed.
	#   rescue   a badge stuck on an active state while Claude itself reports
	#            idle. A turn that ends without Stop (Esc interrupt) leaves
	#            "working" on screen forever; the hooks cannot know, but the
	#            supervisor does.
	#
	# A hook-published badge is otherwise never touched: it knows the tool
	# name, which this can only guess. The stamp guard keeps a badge set
	# milliseconds ago from being overruled by a snapshot taken before it.
	# Numbers a user can mistype. "20s" made every arithmetic comparison in
	# this pass fail, so no badge was ever repaired and nothing said why.
	num_opt() { # num_opt <name> <default>
		local v
		v="$(get_tmux_option "$1" "$2")"
		case "$v" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
	}
	stale_after="$(num_opt @claude-tabs-stale-after 20)"
	now="$(date +%s)"
	# Throttle: this is also wired to window switches, and each run costs a
	# ~350ms `claude agents --json`. "force" (the key binding, plugin load)
	# always runs; "poll" comes from the poller, which already gated on the
	# supervisor files actually having changed — throttling it again would
	# just delay the reaction the poller exists to provide.
	case "${1:-}" in
	force | poll) ;;
	*)
		last="$(get_tmux_option @claude_tabs_synced_at 0)"
		if supervisor_usable; then
			every="$(num_opt @claude-tabs-sync-every 20)"
		else
			# Legacy source is a 350ms-4.3s CLI call — keep it rare.
			every="$(num_opt @claude-tabs-sync-every 180)"
		fi
		[ "$((now - last))" -ge "$every" ] || exit 0
		;;
	esac
	tmux set -g @claude_tabs_synced_at "$now" 2>/dev/null

	# One pass at a time. Reading the stamp and then acting on it is a
	# check-then-act, and `jump` trips both client-session-changed and
	# after-select-window, so two throttled passes started in the same second
	# by construction. Neither could corrupt a badge — every write is
	# re-validated against the pane just before it lands — but each pays for
	# its own agents.sh, and under load that is the expensive half of a
	# reconcile. mkdir is the atomic primitive available to a shell.
	sync_lock="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs/sync.lock"
	priv_mkdir "${sync_lock%/*}"
	# An unwritable state directory — one a root/sudo run created, an
	# XDG_DATA_HOME that moved, a full disk — makes every mkdir below fail with
	# EACCES, which reads exactly like "another pass holds it". Measured: five
	# consecutive `sync poll` and an explicit `sync force` all returned 3 with
	# no output at all, and every badge froze on whatever it last said, for
	# good — including the prefix-r a user reaches for when a badge is stuck.
	# Serialising passes is a cost optimisation, not a correctness requirement
	# (every write below is re-validated against the pane just before it
	# lands), so run UNLOCKED rather than not at all, and say so where it can
	# be seen. Same persistent-notice idiom the loader uses for a failed hook
	# install: the condition is permanent, so the notice is too.
	if ! [ -w "${sync_lock%/*}" ]; then
		trace_line sync "state dir not writable — running unlocked: ${sync_lock%/*}"
		# The notice lands in a tmux format, where #[...] is a style tag.
		nd="${sync_lock%/*}"; nd="${nd//"#"/"##"}"
		tmux set -g @claude_tabs_notice \
			"⚠ tmux-claude-tabs: $nd is not writable" 2>/dev/null
		sync_lock=""
	fi
	sync_unlock() {
		[ -n "$sync_lock" ] || return 0
		# Release only the lock THIS pass took. The release used to remove
		# whatever lock was there, so a pass that had been robbed of its lock
		# went on to delete the thief's on its way out and left it running
		# unprotected. rmdir cannot remove a directory that still holds the
		# pid file, so that goes first.
		case "$(cat "$sync_lock/pid" 2>/dev/null)" in
		"$$") rm -f "$sync_lock/pid" 2>/dev/null; rmdir "$sync_lock" 2>/dev/null ;;
		esac
		return 0
	}
	if [ -n "$sync_lock" ]; then
	# Reclaim a lock whose holder can no longer release it. The holder's pid
	# makes that immediate and — unlike breaking the lock on a timer — it can
	# never take the lock away from a pass that is still running. Measured: a
	# SIGKILLed pass blocked every reconcile for a full 62 s before this.
	if [ -d "$sync_lock" ]; then
		sl_holder="$(cat "$sync_lock/pid" 2>/dev/null)"
		case "$sl_holder" in
		'' | *[!0-9]*)
			# No pid to ask about: a lock from an older version, or one caught
			# between the mkdir and the pid write. Fall back to the timer — a
			# pass takes ~200ms, so a minute is far past any honest run.
			[ -n "$(find "$sync_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] &&
				{ rm -f "$sync_lock/pid"; rmdir "$sync_lock"; } 2>/dev/null
			;;
		*)
			kill -0 "$sl_holder" 2>/dev/null ||
				{ rm -f "$sync_lock/pid"; rmdir "$sync_lock"; } 2>/dev/null
			;;
		esac
	fi
	# Exit 3, not 0: "did not run" has to be distinguishable from "ran and
	# found nothing". The poller memoised the snapshot either way, so a pass
	# that lost the lock was recorded as handled and NEVER retried — the badge
	# then stayed on the old state until the session's status changed again,
	# which for a real Claude can be many minutes.
	# An explicit `force` — prefix r, the plugin load, the navigator opening,
	# every background session ending — WAITS for the lock instead of skipping,
	# because bailing out there means a user action silently did nothing. It
	# waits ten seconds against a pass's ~200ms and then gives up: it must
	# never BREAK a lock a live pass holds, which is what it used to do. That
	# pass is doing exactly this work, so its result is this pass's result,
	# while breaking in ran two reconciles at once (7 of 8 trials) and left the
	# second unprotected the moment the first released.
	if [ "${1:-}" = force ]; then
		lock_ok=0
		_try=0
		while [ "$_try" -lt 100 ]; do
			if mkdir "$sync_lock" 2>/dev/null; then lock_ok=1; break; fi
			_try=$((_try + 1))
			sleep 0.1
		done
		[ "$lock_ok" = 1 ] || {
			trace_line sync "force: gave up after 10s, lock held by a live pass"
			# 0, not 3: every caller of `force` is a run-shell, and tmux shows a
			# job's non-zero exit to the user as "'…' returned 3" — a black page
			# in the pane until Enter. Nobody reads this code; the poller uses
			# `poll`, below.
			exit 0
		}
	else
		mkdir "$sync_lock" 2>/dev/null || {
			# Worth a trace line: "the pass did not run" is the single most
			# useful thing to know when a badge is not settling.
			trace_line sync "skipped: lock held"
			# Only the poller wants to know (it must not advance its snapshot).
			# The hook form — `sync` from after-select-window on every window
			# switch — ran under run-shell, where exit 3 was DISPLAYED whenever
			# a switch collided with a poll pass holding this lock: "'…sync'
			# returned 3" over the pane, or a one-line status message that hid
			# the window list for display-time. Measured on tmux 3.3a.
			[ "${1:-}" = poll ] && exit 3
			exit 0
		}
	fi
	printf '%s' "$$" >"$sync_lock/pid" 2>/dev/null
	trap 'sync_unlock' EXIT
	fi

	# Who owns the badges right now? The hook script stamps this global on
	# every event it paints; when nothing has stamped it for 10 minutes the
	# hooks are either not installed (the default install) or silent, and the
	# supervisor's files are the only witness left. That changes how a
	# contradiction is read below: the conflict arms model "a hook said X and
	# the supervisor disagrees", and routing a hookless machine through them
	# painted ⏳ "cannot say what" on every ordinary turn.
	hooks_at="$(get_tmux_option @claude_tabs_hooks_at 0)"
	case "$hooks_at" in '' | *[!0-9]*) hooks_at=0 ;; esac
	poll_owned=0
	[ "$((now - hooks_at))" -ge 600 ] && poll_owned=1

	# Cheap pre-scan before the expensive part. Everything below spawns
	# `claude agents --json`, which costs ~350ms on an idle machine and was
	# measured at 4.3s under load average 43 — far too much to pay on a window
	# switch when nothing is wrong. One tmux round-trip answers "is any badge
	# even a candidate for repair": an active state older than the staleness
	# threshold. Seeding empty badges still needs the full pass, so `force`
	# (plugin load, the key binding) skips this shortcut.
	# The pre-scan exists only to avoid the legacy CLI's 350ms-4.3s cost. With
	# the supervisor files the whole pass is ~200ms, and gating on "some badge
	# looks stale" would miss the mirror case entirely (a ✅ while the session
	# is still busy is not a stale-looking badge).
	case "${1:-}" in force | poll) prescan=skip ;; *) prescan=run ;; esac
	if [ "$prescan" = run ] && ! supervisor_usable; then
		# The pre-scan waits longer than the rescue itself does: a badge that
		# is genuinely stuck stays stuck forever, so there is no hurry, while a
		# session merely running a slow tool goes quiet for a minute or two and
		# would otherwise trigger the expensive pass for nothing.
		scan_after="$(num_opt @claude-tabs-scan-after 120)"
		[ "$scan_after" -ge "$stale_after" ] 2>/dev/null || scan_after="$stale_after"
		if ! tmux list-panes -a -F '#{@claude_tabs_state}#{l:	}#{@claude_tabs_at}' 2>/dev/null |
			awk -F'\t' -v now="$now" -v limit="$scan_after" '
				$1 == "thinking" || $1 == "tool" || $1 == "compact" || $1 == "bg" {
					if ($2 == "" || now - $2 >= limit) { found = 1 }
				}
				END { exit(found ? 0 : 1) }
			'; then
			exit 0
		fi
	fi
	rows="$("$DIR/agents.sh" 2>/dev/null)"
	# The short session name ("rusolv-28") on each Claude pane, which the
	# window name reads — tmux cannot read the session files itself. One
	# list-panes for what is there now; only a pane whose name changed is
	# written, and its window renamed at once (an idle pane prints nothing,
	# and tmux re-runs automatic-rename only on output).
	{
		tmux list-panes -a -F "#{pane_id}$T#{@claude_tabs_sname}" 2>/dev/null
		printf '#=rows\n%s\n' "$rows"
	} | awk -F'\t' '
		$0 == "#=rows" { r = 1; next }
		!r { cur[$1] = $2; have[$1] = 1; next }
		$2 == "live" && ($3 in have) {
			live[$3] = 1
			n = ($15 == "-" ? "" : $15); if (cur[$3] != n) print $3 "\t" n
		}
		# A pane whose session is gone loses the name too: `claude doctor`,
		# `claude -p` or a Claude started under another config dir would
		# otherwise carry the old session name on the tab.
		END { for (p in cur) if (cur[p] != "" && !(p in live)) print p "\t" }
	' | while IFS="$T" read -r pane sname; do
		if [ -n "$sname" ]; then
			tmux set -p -t "$pane" @claude_tabs_sname "$sname" 2>/dev/null
		else
			tmux set -p -t "$pane" -u @claude_tabs_sname 2>/dev/null
		fi
		rename_windows "$pane"
	done
	printf '%s\n' "$rows" | while IFS="$T" read -r _rank kind pane _pid _cwd _badge _where _dir state src emoji colour agent_status sup_age _sname; do
		[ "$kind" = live ] || continue
		[ -n "$pane" ] && [ -n "$state" ] || continue
		# What the pane's own badge said when the snapshot was taken, compared
		# again just before writing. For a src=f row there was no badge at all
		# and $state came from the supervisor, so the value to match is empty —
		# comparing against the supervisor's verdict would skip every seeding
		# write, which is most of what a first sync does.
		if [ "$src" = f ]; then was=""; else was="$state"; fi
		if [ "$src" != f ]; then
			# Hook-owned badge: only overrule one the supervisor contradicts.
			at="$(tmux show -pqv -t "$pane" @claude_tabs_at 2>/dev/null)"
			[ -n "$at" ] || at=0
			seen="$(tmux show -pqv -t "$pane" @claude_tabs_seen 2>/dev/null)"
			case "$seen" in '' | *[!0-9]*) seen=0 ;; esac
			if [ "$poll_owned" = 1 ]; then
				# NO freshness gate here, deliberately. That rule compares the
				# supervisor's statusUpdatedAt against @claude_tabs_seen, and
				# it only makes sense when a HOOK wrote that stamp — then it
				# really does mean "something observed this session later than
				# the record". With no hooks installed the poller writes it
				# itself, so it means no more than "we painted at T", and
				# comparing our own output against the only source we have is
				# self-defeating: once painted, a badge could never be revised.
				#
				# Seen live on a session that had gone from waiting to a
				# background shell: supervisor said shell with an UNCHANGED
				# statusUpdatedAt older than our paint, so every later pass
				# refused to correct and the tab read "needs you" for twenty
				# minutes while the session was busy. statusUpdatedAt is not
				# reliably monotonic, which is the deeper reason not to lean
				# on it as a freshness signal here.
				#
				# Map the supervisor's verdict directly instead of using the
				# conflict arms below: those read a contradiction as "events
				# were lost", which on a hookless machine painted the hourglass
				# on every ordinary new turn.
				case "$agent_status:$state" in
				busy:tool | waiting:wait | shell:bg) continue ;;   # no change
				busy:*)    state=tool; emoji="🔧" ;;
				waiting:*) state=wait; emoji="🔴" ;;
				shell:*)   state=bg;   emoji="⏳" ;;
				idle:tool | idle:thinking | idle:compact | idle:bg | idle:wait | idle:plan)
					# The turn ended — or an open prompt was dismissed: a prompt
					# still on screen reports "waiting", never "idle" (measured).
					state=done; emoji="✅"
					;;
				# done stays done and idle stays idle until the session itself
				# moves; error is a record of something that happened, and
				# clearing it would hide what you have not seen.
				*) continue ;;
				esac
			else
			# The supervisor says this session is BLOCKED on you. That is
			# raised first and WITHOUT the freshness gate below. The gate
			# exists to stop an old snapshot from clearing a fresh red badge —
			# it is about not LOSING a needs-you — and applying it to the arm
			# that PAINTS one inverted its purpose: every hook event stamps
			# @claude_tabs_seen with its own clock, while statusUpdatedAt is
			# written on change and never refreshed, so after any hook fired
			# later than the last status change the rescue was skipped on every
			# pass, permanently. Reproduced: a session sitting at a permission
			# prompt never went red. A premature red costs a glance; a missing
			# one costs the thing this plugin is for.
			case "$agent_status" in
			waiting)
				case "$state" in
				wait | plan | error) ;;   # already saying so
				*)
					[ "$((now - at))" -ge "$stale_after" ] || continue
					state=wait; emoji="🔴"
					;;
				esac
				;;
			esac
			if [ "$state" != wait ] || [ "$agent_status" != waiting ]; then
			# Everything below either clears or downgrades a badge, and there
			# the gate belongs: the supervisor may only overrule a hook badge
			# when its record is the fresher witness.
			case "$sup_age" in
			'' | *[!0-9]*) ;;   # unknown age (legacy CLI path): allow
			*) [ "$sup_age" -ge "$seen" ] || continue ;;
			esac
			case "$state:$agent_status" in
			thinking:idle | tool:idle | compact:idle | bg:idle)
				# Looks busy to us, idle to Claude: the turn ended without an
				# event we could see.
				[ "$((now - at))" -ge "$stale_after" ] || continue
				state=done; emoji="✅"
				;;
			thinking:waiting | tool:waiting | compact:waiting | bg:waiting)
				[ "$((now - at))" -ge "$stale_after" ] || continue
				state=wait; emoji="🔴"
				;;
			wait:idle | plan:idle)
				# A permission prompt answered with Esc fires NO closing hook —
				# measured: PermissionRequest arrives, then nothing at all — so
				# the red badge would stay forever on a session that is free.
				# Safe to clear precisely because a prompt that is still up
				# reports "waiting", never "idle" (measured too). `error` is
				# deliberately NOT here: it is a record of something that
				# happened, and clearing it would hide what you have not seen.
				[ "$((now - at))" -ge "$stale_after" ] || continue
				state=done; emoji="✅"
				;;
			done:waiting | idle:waiting)
				# The session is blocked on input while our badge says the
				# ball is in nobody's court. Seen live: three resumed sessions
				# sitting on "Resume from summary — Enter to confirm" with a
				# 💤 badge, because SessionStart set idle and the prompt that
				# followed fires no hook at all. This is the one case the
				# whole plugin exists for, so it must never be missed.
				[ "$((now - at))" -ge "$stale_after" ] || continue
				state=wait; emoji="🔴"
				;;
			done:busy | done:shell | idle:busy | idle:shell)
				# The mirror image, and the one a stuck badge lands in: Claude
				# is working while our badge says the session is yours. Events
				# were lost, or work outlives the turn in a way the hooks did
				# not name. ⏳ is the honest answer — something is running, we
				# cannot say what.
				#
				# But only when the supervisor is the FRESHER witness. Its
				# status is written on change, never refreshed, so a background
				# task Claude never reaped leaves "shell" pinned forever —
				# measured live at 2h09m on a session sitting at an idle
				# prompt. Without this guard that stale record fights the hooks
				# in a loop the user sees as a badge flipping done → bg → done
				# on its own: a hook sets done, the next pass overrules it back
				# off the same hours-old evidence, forever. Hooks that observed
				# the session AFTER the supervisor last changed its mind are
				# the better witness, so they win.
				[ "$((now - at))" -ge "$stale_after" ] || continue
				state=bg; emoji="⏳"
				;;
			*) continue ;;
			esac
			fi
			fi
		fi
		case "$state" in
		wait) label="needs you" ;;
		bg) [ "$agent_status" = shell ] && label="bg shell" || label=busy ;;
		tool) label="working" ;;
		*) label="$state" ;;
		esac
		# Last look before writing. Everything above was decided against a
		# snapshot taken by agents.sh, which measured ~200ms and can reach
		# seconds on the CLI fallback — long enough for a hook to have painted
		# a real "needs you" in the meantime. Writing the snapshot's verdict on
		# top of that would replace a red badge with a green one on the pane
		# that is blocked, which is the single failure this plugin exists to
		# prevent. If the pane no longer says what the snapshot said, the
		# snapshot is stale: leave it alone and let the next pass decide.
		now_state="$(tmux show -pqv -t "$pane" @claude_tabs_state 2>/dev/null)"
		[ "$now_state" = "$was" ] || continue
		# A hook that already painted this same state knows more than this
		# pass does: it can name the tool ("allow Edit?", "allow Bash?") where
		# the label case above can only say "needs you". Nothing changed here,
		# so the write is not a repair — and replacing the richer label with
		# the generic one destroyed the single piece of information that says
		# WHICH prompt is waiting, with no further hook coming to put it back
		# while the prompt is up. Measured: gone within one pass, 8 times in 8.
		if [ "$was" = "$state" ] && [ "$src" != f ]; then
			hook_label="$(tmux show -pqv -t "$pane" @claude_tabs_label 2>/dev/null)"
			[ -n "$hook_label" ] && label="$hook_label"
		fi
		trace_line paint "$pane -> $state ($emoji)"
		tmux set -p -t "$pane" @claude_tabs_glyph "#[fg=colour$(badge_colour "$state"),bold]$emoji#[nobold]" \; \
			set -p -t "$pane" @claude_tabs_plain "#[bold]$emoji#[nobold]" \; \
			set -p -t "$pane" @claude_tabs_label "$label" \; \
			set -p -t "$pane" @claude_tabs_state "$state" \; \
			set -p -t "$pane" @claude_tabs_seen "$now" \; \
			set -p -t "$pane" -u @claude_tabs_at 2>/dev/null
		# Window badge is worst-of-panes, never a blind copy of this pane.
		recompute_window "$pane"
		# In poll mode the hook's notification path never runs, so a transition
		# written here IS the news — announce it the way the hook does, with
		# the transient status-line segment. The message style and the bell
		# stay hook-only. Hook-mode rescues remain silent: poll_owned is 0
		# whenever a hook has spoken in the last 10 minutes, and a rescue is a
		# correction, not news.
		if [ "$poll_owned" = 1 ] && [ "$was" != "$state" ]; then
			n_on="$(get_tmux_option @claude-tabs-notify on)"
			n_states="$(get_tmux_option @claude-tabs-notify-states 'wait plan done error')"
			n_style="$(get_tmux_option @claude-tabs-notify-style status)"
			case " $n_states " in *" $state "*) ;; *) n_on=off ;; esac
			if [ "$n_on" = on ] && [ "$n_style" != off ]; then
				ninfo="$(tmux display -p -t "$pane" "#{session_name}$T#{window_id}$T#{window_index}" 2>/dev/null)"
				nsess="${ninfo%%"$T"*}"; nrest="${ninfo#*"$T"}"
				nwin_id="${nrest%%"$T"*}"; nwin_idx="${nrest#*"$T"}"
				# Only when nobody is already looking at that window.
				if ! tmux list-clients -F "#{session_name}$T#{window_id}" 2>/dev/null |
					grep -qxF "$nsess$T$nwin_id"; then
					njkey="$(get_tmux_option @claude-tabs-jump-key J)"
					ndur="$(get_tmux_option @claude-tabs-notify-duration 4000)"
					case "$ndur" in '' | *[!0-9]*) ndur=4000 ;; esac
					[ "$ndur" -lt 1000 ] && ndur=1000
					# Formats are expanded wherever this text lands — double the #s.
					nmsg="$emoji ${label//"#"/"##"} · ${nsess//"#"/"##"}:$nwin_idx · $njkey = jump"
					ntok="$$-$now-$RANDOM"
					tmux set -g @claude_tabs_notice "$nmsg" \; \
						set -g @claude_tabs_notice_tok "$ntok" 2>/dev/null
					# A stale expiry must exit 0. This was "[ token matches ] && tmux set -gu",
					# so the ORDINARY case — a newer notice already replaced this one, or the
					# notice was cleared by hand — failed the test, returned 1, and tmux printed
					# the whole command back at the user as an error over the status line. The
					# cleanup routine for notifications was itself producing a notification.
					tmux run-shell -b "sleep $((ndur / 1000)); [ \"\$(tmux show -gqv @claude_tabs_notice_tok)\" = '$ntok' ] && tmux set -gu @claude_tabs_notice \; set -gu @claude_tabs_notice_tok || true" 2>/dev/null
				fi
			fi
		fi
		# Painting the hourglass without arming a watcher is what left a tab
		# saying "still working" overnight: the hook's paths arm one, this one
		# did not, and nothing else can lower it. The session file is named
		# after the pid, so no lookup is needed.
		if [ "$state" = bg ] && [ -n "${_pid:-}" ]; then
			sup_fmt="$(supervisor_dir)"; sup_fmt="${sup_fmt//"#"/"##"}"
			wtok="$$-$now-$RANDOM"
			tmux set -p -t "$pane" @claude_tabs_watch "$wtok" 2>/dev/null
			tmux run-shell -b \
				"sleep 5; $(printf '%q' "$me_fmt") watch $pane '${sup_fmt}/$_pid.json' 1 '$wtok' >/dev/null 2>&1 || true" 2>/dev/null
		fi
	done
	# A pane nothing changed about never reaches the line above, so a window
	# whose aggregate is stale for a reason other than its panes' states —
	# the session count, after an upgrade or after this window was split —
	# would stay wrong until its next event. `force` is the seeding pass
	# (plugin load, prefix r), rare enough to pay for a full rebuild.
	if [ "${1:-}" = force ]; then
		tmux list-windows -a -F '#{window_id}' 2>/dev/null | while IFS= read -r wid; do
			[ -n "$wid" ] && recompute_window "$wid"
		done
	fi
	# Sweep rides along, under the same throttle. A SIGKILLed Claude in a
	# pane that lives on as a shell fires no pane-exited and produces no live
	# row for the loop above to repair — its badge was permanent until the
	# user cleared it by hand. Sweep looks for exactly that: a badge with no
	# session behind it.
	# Released BEFORE the exec: exec replaces this process image, so the EXIT
	# trap never runs and the lock would leak on every single pass — which is
	# exactly what happened, and it made every later sync bail out until the
	# stale-lock reclaim aged it out a minute later.
	sync_unlock
	trap - EXIT
	exec "$me" sweep
	;;

poll)
	# The hookless path: one poller per tmux server follows the supervisor's
	# session files and reconciles when — and only when — something changed.
	# A quiet tick is the cheap case: every file is read with $(<f), fields
	# come out by parameter expansion, and the only processes spawned are one
	# tmux round-trip for the token and the sleep itself. The full reconcile
	# (`sync poll`) runs solely on a real change.
	#
	#   navigator.sh poll <token>            the daemon — claude-tabs.tmux
	#                                        spawns it when @claude-tabs-poll
	#                                        is on (the default)
	#   navigator.sh poll once [statefile]   one tick, for tests and diagnosis
	#
	# The daemon exits when the server goes away (the token read fails), when
	# @claude-tabs-poll is turned off (the token is unset), and when a newer
	# poller takes over (the token changed) — a reload never stacks two.
	tok="${1:-}"
	[ -n "$tok" ] || exit 0
	sup="$(supervisor_dir)"
	# Bodies in functions: bash 3.2 mis-parses a `case` inside $( ) — the
	# same trap agents.sh and sweep already stepped around.
	poll_nl='
'
	_poll_carry_line() { # _poll_carry_line <pid> — re-emit its last good line
		# Reads $last, the memo of the previous tick, and appends to $snap_out.
		# A record that would not parse this tick is a torn or truncated write,
		# not an ended session: Claude Code rewrites these files with O_TRUNC,
		# so a zero-byte read is expected, not exotic. _poll_ended already
		# declines to file such a pid — but the memo was then written WITHOUT
		# it, so the session's REAL exit later was no change at all: never
		# filed in the resume spool, and its badge never cleared. Measured: one
		# truncated read left a red "needs you" on a window with no Claude in
		# it, permanently, through 95 s and a poller beating the whole time.
		# Re-emitting the last good line here keeps it in the position the glob
		# put it in, so the snapshot stays byte-comparable with the memo, and
		# costs no fork at all.
		local rest
		case "$last" in
		"$1|"*) rest="$last" ;;
		*"$poll_nl$1|"*) rest="$1|${last#*"$poll_nl$1|"}" ;;
		*) return 0 ;;
		esac
		snap_out="$snap_out${rest%%"$poll_nl"*}$poll_nl"
	}
	_poll_snap() {
		# One line per live session into $snap_out: pid|kind|status|sid|cwd|
		# tmuxfield|name. Sets a variable instead of printing — capturing with $( )
		# would fork a subshell on every tick, and the quiet tick is the case
		# this whole verb is optimised for. Same liveness rule as agents.sh —
		# a lingering file for a dead pid is not a session.
		local f line pid kind status sid cwd tmuxf nm
		snap_out=""
		# One process table per tick, never one cached across ticks — see
		# same_pid_ok. Costs a `ps` only on a tick that has a record to check.
		_ct_proc_starts=""
		# Pids whose file is there and whose process is alive but whose record
		# would not parse — a torn or momentarily empty write. They are NOT
		# ended sessions, and treating them as such filed live ones into the
		# resume history and wiped their badges.
		snap_unparsed=""
		for f in "$sup"/*.json; do
			[ -f "$f" ] || continue
			# Builtin read, not $(<f): the substitution forks a subshell per
			# file, which at nine sessions was most of a quiet tick's cost.
			# read exits 1 at EOF with no delimiter — the variable is filled
			# all the same.
			# The pid comes from the FILENAME and must be known before the
			# empty-read guard below uses it. It was read one line too late,
			# so an empty file blamed the PREVIOUS iteration's pid — and on
			# the first file of the glob there was none, so `set -u` killed
			# the daemon outright. Either way a live session went missing:
			# filed into the resume history and its badge cleared.
			pid="${f##*/}"; pid="${pid%.json}"
			case "$pid" in '' | *[!0-9]*) continue ;; esac
			line=""
			# Order matters: bash applies redirections left to right, so with
			# `<"$f" 2>/dev/null` a failed open is reported before stderr is
			# silenced, and the raw error lands in the popup.
			IFS= read -r -d '' line 2>/dev/null <"$f"
			# Carry only for a pid that is still RUNNING: an empty file whose
			# process is gone is not a torn write, and re-emitting it would
			# pin a badge to a session that really has ended.
			[ -n "$line" ] || {
				kill -0 "$pid" 2>/dev/null && _poll_carry_line "$pid"
				snap_unparsed="$snap_unparsed $pid"
				continue
			}
			kill -0 "$pid" 2>/dev/null || continue
			# A file left behind by a crash whose pid the OS has since reused
			# is not a session: it never leaves the snapshot again, so its
			# exit is never noticed, and a "busy" one holds the poller at the
			# fast interval on a permanently idle machine.
			#
			# Only pids that are NEW to the snapshot are checked, and that is
			# enough by construction: a pid stops existing before it can be
			# handed out again, and a tick with the process gone drops it from
			# the snapshot — so a recycled pid always comes back as a new one.
			# The check costs a `ps` (measured: 28ms with 608 processes) and
			# this keeps it off every quiet tick, which forks nothing at all.
			case "$last" in
			"$pid|"* | *"$poll_nl$pid|"*) ;;
			*) same_pid_ok "$pid" "$line" || continue ;;
			esac
			case "$line" in
			*'"kind":"interactive"'*) kind=i ;;
			*'"kind":"bg"'*) kind=b ;;
			# Same carry as the empty read above: half a record is a torn
			# write, and the pid is known alive by here.
			*) _poll_carry_line "$pid"; snap_unparsed="$snap_unparsed $pid"; continue ;;
			esac
			case "$line" in *'"status":"'*) ;; *) _poll_carry_line "$pid"; snap_unparsed="$snap_unparsed $pid"; continue ;; esac
			status="${line#*\"status\":\"}"; status="${status%%\"*}"
			sid=""
			case "$line" in *'"sessionId":"'*) sid="${line#*\"sessionId\":\"}"; sid="${sid%%\"*}" ;; esac
			cwd=""
			case "$line" in *'"cwd":"'*) cwd="${line#*\"cwd\":\"}"; cwd="${cwd%%\"*}" ;; esac
			tmuxf=""
			case "$line" in *'"tmux":"'*) tmuxf="${line#*\"tmux\":\"}"; tmuxf="${tmuxf%%\"*}" ;; esac
			# The name too, last: a /rename has to reach the tab, and only a
			# changed snapshot runs the pass that publishes it.
			nm=""
			case "$line" in *'"name":"'*) nm="${line#*\"name\":\"}"; nm="${nm%%\"*}" ;; esac
			snap_out="$snap_out$pid|$kind|$status|$sid|$cwd|$tmuxf|$nm
"
		done
	}
	_poll_ended() { # _poll_ended <previous-snapshot> <current> <unparsed-pids>
		# A session that vanished between ticks ended with no SessionEnd we
		# could see — no hooks installed, or a SIGKILL. Record it so the
		# navigator's resume list works in poll mode. The hook's own record
		# wins when both exist: it knows the reason and the transcript.
		local spool pid kind status sid cwd tmuxf mc tp pane here o limit n f
		spool="$(history_spool)"
		printf '%s\n' "$1" | while IFS='|' read -r pid kind status sid cwd tmuxf _nm; do
			[ "$kind" = i ] && [ -n "$sid" ] || continue
			case "$2" in *"|$sid|"*) continue ;; esac   # alive (a resume keeps the sid)
			# Its record failed to parse this tick rather than going away.
			case " $3 " in *" $pid "*) continue ;; esac
			if [ ! -f "$spool/${sid//\//_}" ]; then
				priv_mkdir "$spool"
				# Best-effort transcript path from the standard projects
				# layout; "-" when the guess misses, and the preview degrades
				# gracefully.
				mc="${cwd//\//-}"; mc="${mc//./-}"
				tp="$HOME/.claude/projects/$mc/$sid.jsonl"
				[ -f "$tp" ] || tp="-"
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$sid" "$cwd" ended "$tp" \
					"$(transcript_title "$tp")" >"$spool/${sid//\//_}" 2>/dev/null
			fi
			# Clear the pane the record named. Sweep handles this too, but it
			# deliberately refuses to act when NO live session remains — the
			# guard that protects hook badges on machines with no supervisor
			# files — so the last session's death would leave its badge behind
			# forever. Same trust rule as agents.sh: the pane id counts only
			# when the record's session name matches what this server calls it,
			# and only when no surviving record still names the same pane.
			case "$tmuxf" in *%*) ;; *) continue ;; esac
			case "$2" in *"|$tmuxf"* | *"|$tmuxf|"*) continue ;; esac
			pane="%${tmuxf##*%}"
			here="$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)"
			[ "$here" = "${tmuxf%%:*}" ] || continue
			for o in @claude_tabs_glyph @claude_tabs_plain @claude_tabs_label \
				@claude_tabs_state @claude_tabs_at @claude_tabs_seen @claude_tabs_watch; do
				tmux set -p -t "$pane" -u "$o" 2>/dev/null
			done
			"$me" recompute "$pane" 2>/dev/null
		done
		# Same cap the hook's end path applies, so a hookless machine cannot
		# grow the spool without bound.
		limit="$(get_tmux_option @claude-tabs-history-limit 200)"
		case "$limit" in '' | *[!0-9]*) limit=200 ;; esac
		n=0
		ls -t "$spool" 2>/dev/null | while IFS= read -r f; do
			n=$((n + 1))
			[ "$n" -gt "$limit" ] && rm -f "$spool/$f" 2>/dev/null
		done
		return 0
	}
	if [ "$tok" = once ]; then
		prevf="${2:-}"
		last=""
		[ -n "$prevf" ] && [ -f "$prevf" ] && last="$(<"$prevf")"
		_poll_snap; snap="${snap_out%$'\n'}"
		syncrc=0
		if [ "$snap" != "$last" ]; then
			[ -n "$last" ] && _poll_ended "$last" "$snap" "$snap_unparsed"
			"$me" sync poll >/dev/null 2>&1 || syncrc=$?
		fi
		# Same rule as the daemon: a pass that lost the lock has not handled
		# this snapshot, so do not write it out as handled.
		[ -n "$prevf" ] && [ "$syncrc" != 3 ] && printf '%s' "$snap" >"$prevf"
		exit 0
	fi
	last=""
	first=1
	while :; do
		# One round-trip answers everything a tick asks tmux: is the server
		# alive, is this poller still the anointed one, and both intervals.
		# Splitting these into `show` calls doubled the cost of a quiet tick.
		info="$(tmux display -p "#{@claude_tabs_poll_token}$T#{@claude-tabs-poll-every}$T#{@claude-tabs-poll-idle-every}" 2>/dev/null)" || info=""
		if [ -n "$info" ]; then
			cur_tok="${info%%"$T"*}"
			rest="${info#*"$T"}"
			ev_fast="${rest%%"$T"*}"
			ev_idle="${rest#*"$T"}"
		else
			# display -p needs a session to answer in; a server sitting at
			# zero sessions still answers `show`. Only give up when that
			# fails too — which is the server being gone.
			cur_tok="$(tmux show -gqv @claude_tabs_poll_token 2>/dev/null)"
			ev_fast=""
			ev_idle=""
		fi
		[ "$cur_tok" = "$tok" ] || exit 0
		_poll_snap; snap="${snap_out%$'\n'}"
		if [ "$snap" != "$last" ]; then
			[ -n "$last" ] && _poll_ended "$last" "$snap" "$snap_unparsed"
			# The very first tick skips the reconcile when sync-on-load has
			# already scheduled one for exactly this state — two full passes
			# per plugin load would be pure waste.
			syncrc=0
			if [ -z "$first" ] || [ "$(get_tmux_option @claude-tabs-sync-on-load on)" = off ]; then
				"$me" sync poll >/dev/null 2>&1 || syncrc=$?
			fi
			# Only remember the snapshot when the reconcile actually ran.
			# Exit 3 means another pass held the lock, so leave `last` alone
			# and try again on the next tick.
			[ "$syncrc" = 3 ] || last="$snap"
		fi
		first=""
		# Faster while anything is actually running or waiting; slower when
		# every session is idle — the only thing to catch then is a prompt
		# being submitted, and the hooks path exists for people who want that
		# to be instant.
		case "$snap" in
		*'|busy|'* | *'|shell|'* | *'|waiting|'*) delay="${ev_fast:-2}" ;;
		*) delay="${ev_idle:-10}" ;;
		esac
		case "$delay" in '' | *[!0-9]*) delay=2 ;; esac
		[ "$delay" -lt 1 ] && delay=1
		sleep "$delay"
	done
	;;

pick)
	client="${1:-}"
	invoke_cwd="${2:-}"
	rows="$("$DIR/agents.sh")"
	if [ -z "$rows" ]; then
		msg "$client" "$(no_sessions_reason)"
		exit 0
	fi
	extra=()
	fo="$(get_tmux_option @claude-tabs-fzf-options '')"
	[ -n "$fo" ] && eval "extra=($fo)"
	export FZF_DEFAULT_OPTS=''
	# For bindings a user adds through @claude-tabs-fzf-options: they need to
	# call back into this script (`rows` to reload, `dispose` to kill) and
	# should not have to hardcode where the plugin was cloned.
	export CLAUDE_TABS_NAV="$me"
	# Live rows. Without this the list is a snapshot from the moment the popup
	# opened: a badge that flipped while you were looking stayed wrong until a
	# manual ctrl-r. fzf's own watch idiom — the load event re-arms a delayed
	# reload-sync of itself — refreshes rows AND preview every few seconds,
	# and --track keeps the cursor on the same session while rows reorder.
	# Gated on fzf 0.42+ (--track); older fzf keeps the ctrl-r behaviour.
	#
	# The interval's floor is the fetch itself, not taste: a row pass measured
	# 0.18-1.05s on a loaded machine, and on the legacy path every reload is a
	# 350ms-4.3s `claude agents --json`. reload-sync serialises (the next
	# fetch starts only after the last one landed), so a short interval can
	# never stack — it just raises the duty cycle while the popup is open.
	refresh="$(get_tmux_option @claude-tabs-popup-refresh '')"
	[ "$refresh" = off ] && refresh=0
	case "$refresh" in
	'')
		if supervisor_usable; then refresh=2; else refresh=5; fi
		;;
	*[!0-9]*) refresh=2 ;;
	esac
	fzv="$(fzf --version 2>/dev/null)"
	fzmaj="${fzv%%.*}"
	fzrest="${fzv#*.}"
	fzmin="${fzrest%%[!0-9]*}"
	case "$fzmaj" in '' | *[!0-9]*) fzmaj=0 ;; esac
	case "$fzmin" in '' | *[!0-9]*) fzmin=0 ;; esac
	watch_args=()
	if [ "$refresh" -gt 0 ]; then
		# Needs fzf 0.42+ (--track); older fzf keeps the ctrl-r behaviour.
		if [ "$fzmaj" -gt 0 ] || [ "$fzmin" -ge 42 ]; then
			watch_args=(--track
				--bind "load:reload-sync(sleep $refresh; $(printf '%q' "$me") rows)+refresh-preview")
		fi
	fi
	# alt-n swaps the popup for a directory picker (`newdir` below) via
	# become, which replaces the fzf process inside the same popup pty.
	# become needs fzf 0.38+; below that the key stays unbound and the
	# header does not advertise it.
	hdr='enter: go/resume · ctrl-x: kill/forget · ctrl-n: new claude here · ctrl-r: refresh'
	if [ "$fzmaj" -gt 0 ] || [ "$fzmin" -ge 38 ]; then
		hdr='enter: go/resume · ctrl-x: kill/forget · ctrl-n: new here · alt-n: new in dir… · ctrl-r: refresh'
		watch_args+=(--bind "alt-n:become($(printf '%q newdir %q %q' "$me" "$client" "$invoke_cwd"))")
	fi
	# --tabstop=1: the delimiter between the shown fields is a tab, and a
	# terminal advances it to the next multiple of eight, which made the list
	# ragged whenever labels differed in length. agents.sh pads columns 6 and 7
	# to fixed widths; this stops the tab from undoing that.
	sel="$(printf '%s\n' "$rows" | fzf --ansi --delimiter="$T" --with-nth=6,7,8 \
		--tabstop=1 --reverse --cycle --no-multi \
		--header="$hdr" \
		--preview="$(printf '%q' "$DIR/preview.sh") {2} {3} {4}" \
		--preview-window='up,65%,follow' \
		--bind="ctrl-r:reload($(printf '%q' "$me") rows)" \
		--bind="ctrl-x:execute-silent($(printf '%q' "$me") dispose {2} {3} {4})+reload(sleep 0.3; $(printf '%q' "$me") rows)" \
		--bind="ctrl-n:execute-silent($(printf '%q new %q %q' "$me" "$client" "$invoke_cwd"))+abort" \
		${watch_args[@]+"${watch_args[@]}"} \
		${extra[@]+"${extra[@]}"})" || exit 0
	[ -n "$sel" ] || exit 0
	IFS="$T" read -r _rank kind id aux cwd _badge where _rest <<<"$sel"
	case "$kind" in
	live) exec "$me" jump "$client" "$id" ;;
	hist) exec "$me" resume "$client" "$id" "$cwd" ;;
	lost) lost_note "$client" "$aux" "$where" ;;
	esac
	;;

jump)
	client="${1:-}"
	pane="${2:-}"
	sess="$(tmux display -p -t "$pane" '#{session_id}' 2>/dev/null)" || sess=""
	if [ -z "$sess" ]; then
		msg "$client" "that pane is gone"
		exit 0
	fi
	[ -n "$client" ] && tmux switch-client -c "$client" -t "$sess" 2>/dev/null
	tmux select-window -t "$pane" 2>/dev/null
	tmux select-pane -t "$pane" 2>/dev/null
	;;

jump-last)
	client="${1:-}"
	# Every pane that needs you, and nothing else. This used to read a single
	# global slot holding the last pane that spoke up, which failed twice over:
	# with three sessions waiting it could only reach one of them, and when
	# nothing was waiting it still jumped — silently switching tmux SESSION to
	# land on a pane whose last event was two days old. Scan the panes instead
	# and step through them on repeated presses.
	#
	# wait/plan/error only. "done" also lights the badge, but it means the ball
	# is in your court with nothing blocked — cycling past six finished
	# sessions to reach the one stuck on a permission prompt is not help.
	#
	# The state is read with `show -pqv`, never `#{@claude_tabs_state}` in a
	# format: that falls back pane -> window -> session -> global, so a pane
	# with no Claude would report its window's badge and get into the cycle.
	scan_args=()
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		scan_args+=(
			display-message -p -t "$pid" "#=P#{pane_id}" ";"
			show -pqv -t "$pid" @claude_tabs_state ";"
			display-message -p "#=X" ";"
		)
	done < <(tmux list-panes -a -F '#{window_index}	#{pane_index}	#{pane_id}' 2>/dev/null |
		sort -t"$T" -k1,1n -k2,2n | cut -f3)
	needy=""
	if [ ${#scan_args[@]} -gt 0 ]; then
		unset 'scan_args[${#scan_args[@]}-1]'   # trailing ";"
		scan="$(tmux "${scan_args[@]}" 2>/dev/null | awk '
			/^#=P/ { p = substr($0, 4); s = ""; next }
			/^#=X/ {
				if (s == "wait" || s == "plan" || s == "error") print p
				else if (s == "done") d++
				else if (s == "idle") i++
				else if (s != "")     r++
				p = ""; next
			}
			{ if (p != "") s = $0 }
			END { printf "#=C %d %d %d\n", d, i, r }
		')"
		needy="$(printf '%s\n' "$scan" | grep -v '^#=C' || true)"
		tally="$(printf '%s\n' "$scan" | sed -n 's/^#=C //p')"
	fi

	if [ -z "$needy" ]; then
		# Nothing is blocked, so go nowhere. This used to fall back to a single
		# global slot holding the last pane that spoke up, and that was a trap:
		# with nothing needing you the key silently teleported you into another
		# tmux SESSION, to a pane whose last event was two days old. A key that
		# means "take me to what needs me" must not move you when nothing does
		# — say so instead, and leave browsing to the navigator popup.
		read -r n_done n_idle n_run <<<"${tally:-0 0 0}"
		detail=""
		for pair in "$n_run running" "$n_done finished" "$n_idle idle"; do
			set -- $pair
			[ "${1:-0}" -gt 0 ] 2>/dev/null || continue
			detail="${detail:+$detail, }$1 $2"
		done
		msg "$client" "nothing needs you${detail:+ · $detail}"
		exit 0
	fi

	# Advance from where you already are when you are standing on one of them,
	# so a second press moves on instead of re-selecting the same pane.
	if [ -n "$client" ]; then
		cur="$(tmux display -p -c "$client" '#{pane_id}' 2>/dev/null)"
	else
		cur="$(tmux display -p '#{pane_id}' 2>/dev/null)"
	fi
	case " $(printf '%s ' $needy)" in
	*" $cur "*) cursor="$cur" ;;
	*)          cursor="$(get_tmux_option @claude_tabs_jump_cursor '')" ;;
	esac
	pick="$(printf '%s\n' "$needy" | awk -v c="$cursor" '
		{ a[NR] = $0 }
		END {
			if (NR == 0) exit
			k = 0
			for (i = 1; i <= NR; i++) if (a[i] == c) k = i
			i = (k % NR) + 1
			print i "\t" NR "\t" a[i]
		}')"
	idx="${pick%%$T*}"; rest="${pick#*$T}"
	total="${rest%%$T*}"; pane="${rest#*$T}"
	[ -n "$pane" ] || exit 0
	tmux set -g @claude_tabs_jump_cursor "$pane" 2>/dev/null
	"$me" jump "$client" "$pane"
	# Only worth saying when there is more than one — otherwise the jump itself
	# is the whole message.
	if [ "$total" -gt 1 ] 2>/dev/null; then
		msg "$client" "needs you $idx/$total · $(tmux display -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)"
	fi
	;;

resume)
	client="${1:-}"
	sid="${2:-}"
	cwd="${3:-}"
	# The id is pasted into a shell command, so it is checked, not trusted. It
	# reaches us from the ended-session spool, which is written from a hook
	# payload — and a single quote in it broke out of the quoting: a crafted
	# id ending "; <command> ;" ran that command in a new window (proven, then
	# fixed here). Claude Code writes UUIDs; anything that is not one is not
	# a session we can resume anyway, so refuse rather than escape.
	case "$sid" in
	'' | *[!A-Za-z0-9._-]*)
		msg "$client" "refusing a session id with unexpected characters"
		exit 0
		;;
	esac
	ccmd="$(get_tmux_option @claude-tabs-command claude)"
	spawn "$client" "$cwd" "$ccmd --resume '$sid'"
	;;

new)
	client="${1:-}"
	cwd="${2:-}"
	ccmd="$(get_tmux_option @claude-tabs-command claude)"
	spawn "$client" "$cwd" "$ccmd"
	;;

newdir)
	# alt-n from the popup: a new Claude in a directory YOU pick. Candidates
	# are every directory a live or recent session runs in, with the one the
	# popup was opened from on top — so a plain Enter does exactly what
	# ctrl-n does — and --print-query lets any typed path through even when
	# it matches nothing in the list.
	client="${1:-}"
	invoke_cwd="${2:-}"
	list="$({
		printf '%s\n' "$invoke_cwd"
		"$DIR/agents.sh" 2>/dev/null | cut -f5
	} | awk 'NF && $0 != "-" && !seen[$0]++')"
	# Keep only directories that still exist. A typed path skips this filter
	# and is validated by spawn, which reports "directory is gone" instead of
	# silently doing nothing.
	dirs=""
	while IFS= read -r d; do
		[ -d "$d" ] && dirs="$dirs$d
"
	done <<-EOF
		$list
	EOF
	out="$(printf '%s' "$dirs" | fzf --print-query --reverse \
		--header='new Claude in… · top row = where you opened the popup · or type any path' \
		--preview='ls -A1 -- {} 2>/dev/null | head -50' \
		--preview-window='right,40%')"
	rc=$?
	[ "$rc" -le 1 ] || exit 0   # 130: ESC — cancelled, spawn nothing
	q="$(printf '%s\n' "$out" | sed -n 1p)"
	pick="$(printf '%s\n' "$out" | sed -n 2p)"
	case "$q" in "~") q="$HOME" ;; "~/"*) q="$HOME${q#\~}" ;; esac
	# What you typed beats what fzf matched, when what you typed is itself a
	# directory. Measured: typing /tmp/x with /tmp/x/sub in the list fuzzy-
	# matches the row, and Enter would have started Claude in the wrong
	# place. Only absolute paths qualify — a filter word like "api" that
	# happens to name a subdirectory of the popup's cwd must still filter.
	case "$q" in
	/*) [ -d "$q" ] && pick="$q" ;;
	esac
	dir="${pick:-$q}"
	[ -n "$dir" ] || exit 0
	exec "$me" new "$client" "$dir"
	;;

dispose)
	kind="${1:-}"
	id="${2:-}"
	aux="${3:-}"
	if [ "$kind" = live ] || [ "$kind" = lost ]; then
		# `lost` belongs here with `live`, not in the history branch: it IS a
		# running session — one this server merely cannot place in a pane — and
		# its pid is in aux exactly as a live row's is. It used to fall through
		# to "forget a history entry", which left the spool untouched and the
		# process running: ctrl-x on the row did nothing at all. The liveness
		# re-check below reads the supervisor file by pid, which an unplaced
		# session has like any other, so it works here unchanged.
		# TERM, not KILL: a clean exit fires SessionEnd, which clears the badge
		# and files the session into history — still resumable from here.
		case "$aux" in "" | *[!0-9]*) exit 0 ;; esac
		# The row may be minutes old; re-check that this pid is still an
		# interactive Claude before signalling it (pids get reused).
		# Re-check that this pid is still an interactive Claude before
		# signalling it — rows can be a minute old and pids get reused. The
		# supervisor's own file answers that without needing `claude` or jq,
		# neither of which the README lists for this key; they were being
		# required, and their absence made ctrl-x a silent no-op.
		alive=no
		sup_f="$(supervisor_dir)/$aux.json"
		if [ -f "$sup_f" ]; then
			# The file alone proves nothing: a SIGKILLed Claude leaves one
			# behind, and after the pid is recycled this check passed for a
			# process that was not Claude at all — which then got SIGTERM.
			# Same identity test agents.sh uses.
			sup_line="$(cat "$sup_f" 2>/dev/null)"
			sup_started="${sup_line#*\"startedAt\":}"
			sup_started="${sup_started%%,*}"; sup_started="${sup_started%\}}"
			case "$sup_line" in
			*'"kind":"interactive"'*)
				case "$sup_started" in
				'' | *[!0-9]*) kill -0 "$aux" 2>/dev/null && alive=yes ;;
				*)
					# `kill -0` FIRST: same_process answers "yes" for a pid it
					# cannot find in the table, which is the right default when
					# the question is "has this number been recycled" and the
					# wrong one here — a session that ended since the row was
					# drawn was reported alive, so ctrl-x signalled nothing,
					# said nothing, and exited 1. A `lost` row makes that easy
					# to hit: there is no pane to notice it is gone.
					kill -0 "$aux" 2>/dev/null &&
						same_process "$(proc_start_table)" "$aux" "$((sup_started / 1000))" &&
						alive=yes
					;;
				esac
				;;
			esac
		elif command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
			claude agents --json 2>/dev/null |
				jq -e --argjson p "$aux" \
					'any(.[]; .kind == "interactive" and .pid == $p)' >/dev/null 2>&1 &&
				alive=yes
		fi
		if [ "$alive" != yes ]; then
			msg "" "that session is already gone (nothing killed)"
			exit 0
		fi
		kill -TERM "$aux" 2>/dev/null
	else
		rm -f "$(history_spool)/${id//\//_}" 2>/dev/null
		hist="$(history_file)"
		if [ -n "$id" ] && [ -f "$hist" ]; then
			# Same mkdir lock as the hook's prune, so a rewrite here cannot
			# swallow a SessionEnd append landing at the same moment.
			[ -n "$(find "$hist.lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] &&
				rmdir "$hist.lock" 2>/dev/null
			mkdir "$hist.lock" 2>/dev/null || exit 0
			# grep -v exits 1 when nothing is left — still a successful filter.
			grep -vF "$T$id$T" "$hist" >"$hist.tmp.$$" 2>/dev/null
			if [ "$?" -le 1 ]; then
				mv "$hist.tmp.$$" "$hist"
			else
				rm -f "$hist.tmp.$$"
			fi
			rmdir "$hist.lock" 2>/dev/null
		fi
	fi
	;;
esac
