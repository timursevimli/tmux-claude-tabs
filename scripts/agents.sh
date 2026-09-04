#!/usr/bin/env bash
# Emit one navigator row per Claude worth showing:
#
#   live  a Claude process currently running inside a tmux pane
#   lost  a Claude process running, but not in any pane on this tmux server
#   hist  a session that ended (SessionEnd hook) and can be resumed
#
# Row: rank \t kind \t id \t aux \t cwd \t badge \t where \t dir \
#      \t state \t src \t emoji \t colour \t agent_status \t status_at
#   live: id = pane_id,    aux = pid
#   lost: id = session_id, aux = pid          (rank 4: below every placed
#         session, above the ended ones — there is nowhere to jump to)
#   hist: id = session_id, aux = transcript_path
# Trailing columns 9-14 exist for `navigator sync`. status_age is how many
# seconds ago the supervisor last CHANGED this session's status ("-" when
# unknown, e.g. on the legacy CLI path) — `sync` needs it to tell a fresh
# supervisor verdict from one that predates what the hooks saw. No plumbing field is ever
# empty ("-" placeholder) — IFS-tab `read` collapses consecutive tabs.
# CLAUDE_TABS_PLAIN=1 disables the ANSI colours (the display-menu fallback).
#
# Live truth comes from the supervisor's per-session files (~/.claude/sessions/
# <pid>.json): status busy/shell/idle, statusUpdatedAt for the age column, and
# on recent Claude Code versions the exact tmux pane — reading them costs
# ~0.4ms all told. `claude agents --json` (350ms idle, 4.3s under load) remains
# only as the fallback for Claude Code versions that do not write these files.
# Sessions without the tmux field are located through their controlling tty:
# a pane's #{pane_current_command} names the shell, not the Claude running
# under it, so the tty is the only honest link between a pid and a pane.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

T=$'\t'
NL='
'
now="$(date +%s)"
plain="${CLAUDE_TABS_PLAIN:-}"
live_sids=""
live_base=""

# Bytes 1..255 in order, so awk can turn a byte back into its number with an
# index lookup. sprintf("%c", n) would be the obvious way and is the way this
# breaks: on a UTF-8-aware awk it returns the CHARACTER, not the byte (gawk in
# a UTF-8 locale gives c3 90 for 208, one byte under LC_ALL=C), and the width
# table below would then silently measure every non-ASCII string as zero.
# It travels in the environment, not through -v: awk expands backslash escapes
# in a -v value, and byte 92 of this string is a backslash. ENVIRON is already
# how the pid-tree awk below is fed its index.
# It is put on the two awk commands rather than exported: it is a blob of
# control bytes and nothing else in the process tree wants it.
CT_BYTES="$(printf '%b' "$(printf '\\0%03o' {1..255})")"

# Column padding must count terminal CELLS. awk's length() counts BYTES under
# mawk (stock Debian) and BSD awk (stock macOS) — "готово" measures 12 there,
# so pad() added six spaces too few and the next column started six cells
# early. This user works in Russian: labels, cwd paths and tmux session names
# are routinely Cyrillic, so that is the normal case here, not an exotic one.
#
# Both awk programs below need this and awk has no include, so it lives here
# once and is prepended to each. They are invoked under LC_ALL=C — load-
# bearing, not tidiness: gawk in a UTF-8 locale makes length()/substr()
# character-based, which would feed this byte decoder characters and measure
# every multi-byte string as 0. Under LC_ALL=C mawk, gawk and BSD awk agree on
# bytes, and this walks the UTF-8 itself. Verified identical on all three.
CELLS_AWK='
function _cwsetup(   i, z, wd) {
	for (i = 1; i < 256; i++) _ord[substr(ENVIRON["CT_BYTES"], i, 1)] = i
	# Zero cells: combining marks (Latin, Cyrillic, Hebrew, Arabic), the
	# zero-width joiners and bidi controls, variation selectors, and the tag
	# block emoji flag sequences use. Decimal, not 0x…: BSD awk hands a
	# number literal to strtod and hex there is not portable.
	z = "768 879 1155 1161 1425 1469 1471 1471 1473 1474 1476 1477 1479 1479"
	z = z " 1552 1562 1611 1631 1648 1648 1750 1756 1759 1764 1767 1768 1770 1773"
	z = z " 8203 8207 8234 8238 8288 8303 8400 8432 65024 65039 65056 65071"
	z = z " 65279 65279 917504 921599"
	_zn = split(z, _zr, " ")
	# Two cells: East_Asian_Width Wide and Fullwidth — Hangul, CJK, the
	# fullwidth forms and the emoji planes. ⏹ U+23F9 (9209) is deliberately
	# absent: it is width N, the one badge glyph that is a single cell, and
	# the ended rows are padded on that assumption.
	wd = "4352 4447 8986 8987 9001 9002 9193 9196 9200 9200 9203 9203"
	wd = wd " 9725 9726 9748 9749 9800 9811 9855 9855 9875 9875 9889 9889"
	wd = wd " 9898 9899 9917 9918 9924 9925 9934 9934 9940 9940 9962 9962"
	wd = wd " 9970 9971 9973 9973 9978 9978 9981 9981 9989 9989 9994 9995"
	wd = wd " 10024 10024 10060 10060 10062 10062 10067 10069 10071 10071"
	wd = wd " 10133 10135 10160 10160 10175 10175 11035 11036 11088 11088 11093 11093"
	wd = wd " 11904 12350 12353 13311 13312 19903 19968 40959 40960 42127"
	wd = wd " 43360 43391 44032 55203 63744 64255 65040 65049 65072 65135"
	wd = wd " 65280 65376 65504 65510 94176 94180 94208 100343 100352 101589"
	wd = wd " 110592 110882 126976 126976 127183 127183 127374 127374 127377 127386"
	wd = wd " 127488 127569 127744 128591 128640 128764 128992 129003"
	wd = wd " 129292 129535 129648 129782 131072 196605 196608 262141"
	_wn = split(wd, _wr, " ")
	_cwok = 1
}
function _cells(cp,   i) {
	if (cp < 32 || cp == 127) return 0   # control; ESC included, so a styled
	if (cp < 127) return 1               # string measures as its text alone
	for (i = 1; i <= _zn; i += 2) if (cp >= _zr[i] && cp <= _zr[i + 1]) return 0
	for (i = 1; i <= _wn; i += 2) if (cp >= _wr[i] && cp <= _wr[i + 1]) return 2
	return 1                             # Cyrillic, Greek, Arabic, …
}
function cw(s,   n, i, j, b, k, cp, w) {
	if (!_cwok) _cwsetup()
	w = 0; n = length(s); i = 1
	while (i <= n) {
		b = _ord[substr(s, i, 1)]
		if (b < 128)      { k = 1; cp = b }
		else if (b < 192) { k = 1; cp = 65533 }   # stray continuation byte
		else if (b < 224) { k = 2; cp = b - 192 }
		else if (b < 240) { k = 3; cp = b - 224 }
		else              { k = 4; cp = b - 240 }
		# A truncated sequence at the end (a label cut mid-character by
		# whoever wrote it) counts as one cell rather than reading past $0.
		if (i + k - 1 > n) { w = w + 1; break }
		for (j = 1; j < k; j++) cp = cp * 64 + (_ord[substr(s, i + j, 1)] - 128)
		i = i + k
		w = w + _cells(cp)
	}
	return w
}
'

sup="$(supervisor_dir)"
sup_files=0
ls "$sup"/*.json >/dev/null 2>&1 && sup_files=1
if [ "$sup_files" = 1 ]; then
	# Fast path. Pane resolution happens here, in one place, so what follows
	# only formats: every session either ends up with a pane id (tag B) or is
	# marked unplaced (tag U), and nothing downstream has to know how that was
	# decided.
	#
	# The two indexes are flat strings rather than associative arrays, which
	# stock macOS bash 3.2 does not have.
	# Newline-separated, not space-separated. A tmux session name may contain
	# a space, which split an entry down the middle and made the lookup return
	# a truncated location; a session name cannot contain a newline.
	pane_by_tty="$NL$(tmux list-panes -a \
		-F '#{pane_tty}|#{pane_id}|#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null |
		sed 's|^/dev/||')$NL"
	where_by_pane="$NL$(tmux list-panes -a \
		-F '#{pane_id}|#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)$NL"
	proc_starts=" $(proc_start_table) "
	pid_ttys=""
	pid_tree=""

	# Each file is read with $(<f): no fork, and nothing is concatenated and
	# re-split, so neither a trailing newline (which would once have glued every
	# session into a single row) nor a file vanishing mid-glob because its
	# session just exited can break the pass.
	# Body in a function, not inline in $( ): bash 3.2 mis-parses a `case`
	# inside a command substitution — its scanner takes the `)` closing a
	# case pattern as the end of the substitution. Stock macOS ships 3.2,
	# and the whole fast path was dead there. A function body parses fine;
	# the substitution then contains only a simple command.
	_collect_live() {
		for f in "$sup"/*.json; do
			[ -f "$f" ] || continue
			# Braces, not a redirect on the assignment: bash applies the
			# redirection after the expansion, so an unreadable file printed a
			# raw "Permission denied" that landed in the popup.
			{ line="$(<"$f")"; } 2>/dev/null || continue
			# "bg" as well as "interactive": Claude Code runs background tasks as
			# their own sessions, with no tmux field and a pid that is a descendant
			# of the TUI's. Dropping them is why a pane could sit on "done" while a
			# background task was demonstrably working in it — measured live, with
			# the pane's own record idle for 29 minutes and its bg descendant busy.
			case "$line" in
			*'"kind":"interactive"'*) kind=i ;;
			*'"kind":"bg"'*)          kind=b ;;
			*) continue ;;
			esac

			# Parameter expansion only: a $(…) helper per field would fork five
			# times per session, which measured 3.5x slower than the whole pass.
			# Strings end at the next quote, numbers at the next comma or brace.
			# A numeric field ends at the next comma, or at the closing brace when
			# it is last; a bracket expression cannot express that, because the }
			# would close the expansion itself.
			rest="${line#*\"pid\":}";             pid="${rest%%,*}";    pid="${pid%\}}"
		# The file outlives the process it describes. A Claude killed with
		# SIGKILL fires no SessionEnd, and until something reaps the file it
		# kept producing a "live" row here — which then made sweep protect the
		# dead session's badge instead of clearing it. kill -0 is a builtin.
		case "$pid" in
		'' | *[!0-9]*) continue ;;
		*) kill -0 "$pid" 2>/dev/null || continue ;;
		esac
			# ...and that it is the SAME process, not a recycled number. A pid
			# says nothing on its own: a Claude killed with SIGKILL leaves its
			# file behind, the OS hands the number to something else, and the
			# record then badged a pane for a session that is gone. startedAt
			# is the field to check — an epoch, so no timezone to misread,
			# unlike procStart, which is written UTC in a local-looking shape.
			# Measured against every live session on a machine with days of
			# uptime, it sits within 0-5s of the process's real start.
			# Every one of these needs the presence guard the `tmux` field
			# below already had. `${line#*"key":"}` returns the string UNCHANGED
			# when the key is absent, and `%%"*` then cuts it back to a lone
			# "{" — which is what the navigator showed as the directory, and as
			# the state label, for any record missing a field.
			case "$line" in
			*'"startedAt":'*)
				rest="${line#*\"startedAt\":}"; started="${rest%%,*}"; started="${started%\}}"
				if started_s="$(epoch_ms "$started")"; then
					same_process "$proc_starts" "$pid" "$started_s" || continue
				fi
				;;
			esac
			case "$line" in
			*'"sessionId":"'*) rest="${line#*\"sessionId\":\"}"; sid="${rest%%\"*}" ;;
			*) sid="" ;;
			esac
			case "$line" in
			*'"status":"'*) rest="${line#*\"status\":\"}"; status="${rest%%\"*}" ;;
			*) status="" ;;
			esac
			case "$line" in
			*'"cwd":"'*) rest="${line#*\"cwd\":\"}"; cwd="${rest%%\"*}" ;;
			*) cwd="" ;;
			esac
			case "$line" in
			*'"statusUpdatedAt":'*) rest="${line#*\"statusUpdatedAt\":}"; upd="${rest%%,*}"; upd="${upd%\}}" ;;
			*) upd="" ;;
			esac
			case "$line" in *'"tmux":"'*) rest="${line#*\"tmux\":\"}"; tmuxf="${rest%%\"*}" ;; *) tmuxf="" ;; esac

			# The supervisor names the pane as "Session:@window.%pane". Pane ids are
			# per-server — %5 here and %5 on another tmux server are different panes
			# — so the field is trusted only when its session name matches what this
			# server calls that pane.
			pane=""; where=""; tag=B
			case "$tmuxf" in
			*%*)
				cand="%${tmuxf##*%}"
				entry="${where_by_pane##*"$NL$cand|"}"
				if [ "$entry" != "$where_by_pane" ]; then
					here="${entry%%"$NL"*}"
					if [ "${tmuxf%%:*}" = "${here%%:*}" ]; then
						pane="$cand"; where="$here"
					fi
				fi
				;;
			esac
			if [ -z "$pane" ]; then
				# No usable tmux field: an older Claude Code, a stale one naming
				# another server, or — since 2.1.x — a record that literally says
				# "tmux":"None". Find the process by its controlling tty, because a
				# pane's #{pane_current_command} names the shell, not the Claude
				# running under it.
				#
				# Then keep walking up the parents. Claude Code no longer does the
				# work in the process sitting in the pane: the TUI spawns a daemon,
				# which spawns the agent on a tty of its own that is not a pane at
				# all. That descendant is the one that goes busy, and its record has
				# no tmux field — so without this walk the only visible record for
				# the pane is the TUI's, which stays idle while work is running.
				# The whole walk is one awk: a fork per hop would cost more than the
				# rest of the pass.
				[ -n "$pid_tree" ] || pid_tree="$(ps -Ao pid=,ppid=,tty= 2>/dev/null)"
				entry="$(printf '%s\n' "$pid_tree" |
					CT_IDX="$pane_by_tty" awk -v p="$pid" '
						BEGIN { idx = ENVIRON["CT_IDX"] }
						{ up[$1] = $2; tty[$1] = $3 }
						END {
							for (i = 0; i < 8 && p != "" && p != 0; i++) {
								t = tty[p]
								if (t != "" && t != "??") {
									k = "\n" t "|"
									j = index(idx, k)
									if (j > 0) {
										r = substr(idx, j + length(k))
										sub(/\n.*/, "", r)
										print r
										exit
									}
								}
								p = up[p]
							}
						}')"
				if [ -n "$entry" ]; then
					pane="${entry%%|*}"; where="${entry##*|}"
				elif [ "$kind" = i ]; then
					# Alive, and not reachable from any pane on this server:
					# the record says "None" or names a pane (or a session)
					# this server does not have, AND no ancestor of the pid
					# within 8 hops holds a pane tty. A second tmux server, a
					# plain terminal, an IDE terminal, a Claude detached from
					# its pane. This used to `continue`, and the silence cost
					# twice over: the session it hid most often is the one you
					# open the navigator to find — a `waiting` Claude blocked
					# on a permission prompt, which ranks 0, top of the list —
					# and its sessionId never reached live_sids, so a session
					# that had ended once and is running again unplaced came
					# back as an "ended, 10m ago" row whose Enter runs
					# `claude --resume` on a session already running.
					# Row kind `lost`, ranked below every placed session; the
					# pane column is a "?<pid>" placeholder that never reaches
					# tmux (see the option batch below).
					# `where` for a PLACED session comes from tmux, which escapes a tab in
					# a session name before it ever reaches us. This one is copied
					# verbatim out of the record, so it is the one string in the row
					# that can still carry a raw delimiter. Measured with a record whose
					# tmux field held a tab: the row kept 14 fields but the tab pushed a
					# fragment of the claim into column 3, which for a lost row is the
					# session id the navigator hands to dispose.
					pane="?$pid"; where="${tmuxf:-None}"
					where="${where//$'\t'/ }"; where="${where//$'\n'/ }"; where="${where//$'\r'/ }"
					tag=U
				else
					# A background task with no pane is nothing to navigate
					# TO: its whole job is to make its pane's badge honest and
					# it has no pane. Dropped exactly as before, so the noise
					# floor on a machine with a dozen sessions does not move.
					continue
				fi
			fi

			if [ "$kind" = b ]; then
				# A background task is not "your turn is being processed", so it
				# never shows the working glyph. "shell" is the state this plugin
				# already means by "something is running that is not your turn",
				# and it renders as the hourglass. An idle one says nothing at all
				# about the pane, so it is dropped rather than competing with the
				# interactive record. A bg task blocked on a permission prompt does
				# need you, so "waiting" is kept as-is.
				case "$status" in
				idle) continue ;;
				busy | shell) status=shell ;;
				esac
			fi

			# Absolute seconds, not an age: the consumer compares freshness against
			# its own clock, and two scripts each subtracting their own `now` made a
			# record written in the same second look a second older than the badge —
			# enough to suppress every reconcile arm.
			age=-1
			if upd_s="$(epoch_ms "$upd")"; then age="$upd_s"; fi
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' \
				"$tag" "$pane" "$pid" "$status" "${cwd:--}" "$where" "$sid" "$age"
		done
	}
	live_base="$(_collect_live)"
fi

# The supervisor files are an undocumented format: fall back on FITNESS, not
# mere existence. If the files are there but a format change made every row
# unparsable, the documented CLI takes over — and a canary marks the drift so
# it is a visible "update the plugin" instead of a silently empty navigator.
if [ -z "$live_base" ] && command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
	# Legacy path. Only reachable on a Claude Code old enough to have no
	# supervisor files at all, so it optimises for being obvious rather than
	# for forks: build a tty→pane index once, then look each session up in it.
	rows="$(claude agents --json 2>/dev/null |
		jq -r '.[] | select(.kind == "interactive") |
			[.pid, (.status // "?"), .sessionId, .cwd] | @tsv' 2>/dev/null)" || rows=""
	if [ -n "$rows" ]; then
		# " tty|pane|where tty|pane|where ... " — a flat string beats an
		# associative array, which stock macOS bash 3.2 does not have.
		pane_index=" $(tmux list-panes -a \
			-F '#{pane_tty}|#{pane_id}|#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null |
			sed 's|^/dev/||' | tr '\n' ' ') "
		pid_ttys="$(ps -Ao pid=,tty= 2>/dev/null)"
		_collect_legacy() {
			printf '%s\n' "$rows" | while IFS="$T" read -r pid status sid cwd; do
				[ -n "$pid" ] || continue
				tty="$(printf '%s\n' "$pid_ttys" | awk -v p="$pid" '$1 == p { print $2; exit }')"
				[ -n "$tty" ] && [ "$tty" != "??" ] || continue
				entry="${pane_index##* $tty|}"
				[ "$entry" != "$pane_index" ] || continue   # this Claude is not in tmux
				entry="${entry%% *}"
				printf 'B\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' \
					"${entry%%|*}" "$pid" "$status" "${cwd:--}" \
					"${entry##*|}" "$sid" -1
			done
		}
		live_base="$(_collect_legacy)"
	fi
	if [ "$sup_files" = 1 ] && [ -n "$live_base" ]; then
		# Files present yet unparsable, while the CLI sees live sessions:
		# the supervisor format has drifted. Note it (once per day) where the
		# user will see it.
		drift="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs/format-drift"
		if [ -z "$(find "$drift" -mmin -1440 2>/dev/null)" ]; then
			priv_mkdir "${drift%/*}" && : >"$drift" 2>/dev/null
			tmux set -g @claude_tabs_notice "⚠ tmux-claude-tabs: supervisor format changed — running on the slow path, update the plugin" 2>/dev/null
			tmux run-shell -b 'sleep 15; tmux set -gu @claude_tabs_notice' 2>/dev/null
		fi
	fi
fi

# One pane, several Claude processes. The TUI, its daemon, a bg-pty spare and
# the agent actually doing the work all resolve to the same pane now, and only
# one badge can be right — so a pane's status is the most active among them.
# Seen live: the pane's own record idle for 29 minutes while its descendant sat
# at busy, and the tab said "done" the whole time.
live_all_sids=""
if [ -n "$live_base" ]; then
	# Every session stays in live_sids, collapsed or not — and unplaced (tag
	# U) as well as placed: that list is what keeps a running session out of
	# the "ended, resume me" history. Unplaced sessions used to be dropped
	# before this line, so a session that had ended once and was running again
	# outside any pane came back as history, and Enter on it ran
	# `claude --resume` against a session that was already running.
	live_all_sids="$(printf '%s\n' "$live_base" | cut -f7 | tr '\n' ' ')"
	live_base="$(printf '%s\n' "$live_base" | awk -F'\t' '
		function rank(s) {
			# Needs-you first, then working, then background work, then idle.
			if (s == "waiting") return 0
			if (s == "busy")    return 1
			if (s == "shell")   return 2
			return 3
		}
		{
			p = $2; r = rank($4); a = ($8 < 0 ? 2147483647 : $8)
			if (!(p in seen)) { order[++n] = p; seen[p] = 1 }
			# On a rank tie keep the FRESHEST record. This read `a >= ba[p]`,
			# so it skipped the newer one and kept the older; that stale
			# statusUpdatedAt then went out as column 14, where the reconcile
			# reads it as freshness and refused every later correction for the
			# pane.
			else if (r > br[p] || (r == br[p] && a <= ba[p])) next
			best[p] = $0; br[p] = r; ba[p] = a
		}
		END { for (i = 1; i <= n; i++) print best[order[i]] }
	')"
fi

if [ -n "$live_base" ]; then
	live_sids="$live_all_sids"
	# Pane-scoped badge options, read precisely: #{@x} in a format falls back
	# pane → window, so a pane whose Claude predates the hooks would inherit a
	# sibling's window-level state. `show -pqv` never falls back — but prints
	# nothing at all when unset, so sentinel lines keep the stream parseable.
	opt_args=()
	while IFS="$T" read -r tag pane _rest; do
		# `lost` rows carry a "?<pid>" placeholder, not a pane. Asking tmux
		# about it would fail the whole compound command and lose every other
		# pane's badge with it — one unplaceable session would blank the list.
		[ "$tag" = B ] || continue
		[ -n "$pane" ] || continue
		opt_args+=(
			display-message -p -t "$pane" "#=P#{pane_id}" ";"
			show -pqv -t "$pane" @claude_tabs_state ";"
			display-message -p "#=L" ";"
			show -pqv -t "$pane" @claude_tabs_label ";"
			display-message -p "#=E" ";"
			show -pqv -t "$pane" @claude_tabs_plain ";"
			display-message -p "#=X"
		)
		opt_args+=(";")
	done <<<"$live_base"
	# Every live session can be unplaced, and then there is no pane to ask
	# about at all. Expanding an empty array under `set -u` is an error on
	# stock macOS bash 3.2, and `unset arr[-1]` on one is not much better.
	opts=""
	if [ "${#opt_args[@]}" -gt 0 ]; then
		unset 'opt_args[${#opt_args[@]}-1]'   # trailing ";"
		opts="$(tmux "${opt_args[@]}" 2>/dev/null)"
	fi

	{
		printf '%s\n' "$opts"
		printf '%s\n' "$live_base"
	} | CT_BYTES="$CT_BYTES" LC_ALL=C awk -F'\t' -v home="$HOME" -v plain="$plain" -v now="$now" \
		"$CELLS_AWK"'
		# Columns 6 and 7 are padded to a fixed VISIBLE width. They reach the
		# popup joined by the tab delimiter, and a terminal advances a tab to
		# the next multiple of eight — so a short label ("idle") landed a whole
		# stop left of a long one ("allow Edit?") and the list rendered ragged.
		# Padding here (and --tabstop=1 in the popup) makes the columns line up
		# for the fzf list and the no-fzf menu alike. The colour escapes are
		# not cells at all, so the width is counted on the parts rather than on
		# the finished string, and each part is measured with cw() — length()
		# counts bytes here, which put every Cyrillic row six cells out.
		function pad(s, vis, want,   n) {
			n = want - vis
			while (n-- > 0) s = s " "
			return s
		}
		/^#=P/ { cp = substr($0, 4); sect = "s"; next }
		/^#=L/ { sect = "l"; next }
		/^#=E/ { sect = "e"; next }
		/^#=X/ { sect = ""; cp = ""; next }
		$1 != "B" && $1 != "U" && cp != "" {
			if      (sect == "s") st[cp] = $0
			else if (sect == "l") lb[cp] = $0
			else if (sect == "e") { e = $0; gsub(/#\[[^]]*\]/, "", e); em[cp] = e }
			next
		}
		$1 == "B" || $1 == "U" {
			p = $2; pid = $3; status = $4; cwd = $5; where = $6; age = $8
			state = st[p]; label = lb[p]; e = em[p]
			src = (state == "") ? "f" : "h"
			if (state == "") {
				# Session predates the hooks — fall back to the supervisor
				# status (busy / shell / waiting / idle).
				if (status == "waiting")     { state = "wait"; label = "waiting" }
				else if (status == "busy")   { state = "tool"; label = "working" }
				else if (status == "shell")  { state = "bg";   label = "bg shell" }
				else                         { state = "idle"; label = status }
				e = ""
			}
			if (label == "") label = state
			# Stored with its # doubled, because tmux format-expands it on the
			# way to the status line. This popup expands nothing, so undo it or
			# a tool called `a#b` reads here as `a##b`.
			gsub(/##/, "#", label)

			# r is the sort rank, and it used to read the other way round:
			# every state that was DOING something ranked 3, below done (1) and
			# idle (2). So the harder a session was working, the further down
			# the navigator it sank — with six finished sessions on screen the
			# one actually running was off the bottom, which is the opposite of
			# what you open this list to find out.
			#
			# Needs you, then running, then the reference material.
			if      (state == "wait")     { d = "🔴"; c = 31; r = 0 }
			else if (state == "plan")     { d = "📋"; c = 35; r = 0 }
			else if (state == "error")    { d = "❌"; c = 31; r = 0 }
			else if (state == "thinking") { d = "💭"; c = 33; r = 1 }
			else if (state == "compact")  { d = "📦"; c = 34; r = 1 }
			else if (state == "bg")       { d = "⏳"; c = 35; r = 1 }
			else if (state == "done")     { d = "✅"; c = 32; r = 2 }
			else if (state == "idle")     { d = "💤"; c = 90; r = 3 }
			else                          { d = "🔧"; c = 34; r = 1 }
			if (e == "") e = d   # pane emoji wins: it knows 🤖 from 🔧

			path = cwd
			if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

			# Last-activity age for display. `age` is an absolute timestamp and
			# must stay one — it is also the freshness column downstream, so
			# the human form goes in its own variable.
			a = ""
			if (age >= 0) {
				secs = now - age
				# A supervisor written by a clock ahead of ours is not a session
				# that will be updated in the future, and one from 1970 is not
				# twenty thousand days old. Clamp both ends.
				if (secs < 0) secs = 0
				if      (secs < 3600)    a = int(secs / 60) "m"
				else if (secs < 86400)   a = int(secs / 3600) "h"
				else if (secs < 8640000) a = int(secs / 86400) "d"
				else                     a = "99d+"
			}
			w = (a == "") ? where : sprintf("%s %s", where, a)
			w = pad(w, cw(w), 17)

			badge = plain != "" ? sprintf("%s %s", e, label) \
			                    : sprintf("%s \033[%dm%s\033[0m", e, c, label)
			# cw(e), not a hardcoded 2: the pane emoji comes from an option
			# the hook writes, and ⏹ is one cell where 🔧 is two.
			badge = pad(badge, cw(e) + 1 + cw(label), 19)
			if (cwd == "") cwd = "-"
			if ($1 == "U") {
				# No pane to jump to, so the row is keyed by the sessionId and
				# carries the pid as aux — enough to identify it and to signal
				# it. The `where` column shows what the record CLAIMED rather
				# than a location this server can offer: that string is the
				# only clue left to where the session went.
				w = "unplaced " where
				w = pad(w, cw(w), 17)
				printf "4\tlost\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n",
					$7, pid, cwd, badge, w, path, state, src, e, c,
					(status == "" ? "-" : status), (age < 0 ? "-" : age)
				next
			}
			printf "%d\tlive\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n",
				r, p, pid, cwd, badge, w, path, state, src, e, c, (status == "" ? "-" : status),
				(age < 0 ? "-" : age)
		}
	# Freshest first inside a rank. Without the second key the order within a
	# group was whatever sort happened to produce, so six identical-looking
	# "done" rows shuffled between refreshes. Column 14 is status_age, and it is
	# "-" only on the legacy CLI path where every row is "-", so it is a no-op
	# there rather than a mixed-up ordering. (The column is an absolute
	# timestamp; larger = fresher, so this key sorts DESCENDING. It was
	# ascending, which put the session quiet longest at the top of each group —
	# the exact raggedness the comment claims to have fixed.)
	' | sort -t "$T" -k1,1n -k14,14rn
fi

# Ended sessions, newest first. Two sources: the spool directory (one file per
# session, no locks needed) and the legacy single-file TSV.
shown="$(get_tmux_option @claude-tabs-history-shown 15)"
{
	spool="$(history_spool)"
	if [ -d "$spool" ]; then
		# One cat over everything: our files end with a newline, a file
		# vanishing mid-read is skipped rather than aborting, and the rows
		# sort newest-first by their own timestamp column.
		cat "$spool"/* 2>/dev/null | sort -t"$T" -k1,1rn
	fi
	# NOT the .migrated file: migration copies every row into the spool first,
	# so reading it back would only resurrect entries the user forgot.
	# history.tsv itself still matters for users who have not reloaded tmux
	# since the upgrade.
	hist="$(history_file)"
	[ -f "$hist" ] && awk -F'\t' '{ L[NR] = $0 } END { for (i = NR; i >= 1; i--) print L[i] }' "$hist"
} | CT_BYTES="$CT_BYTES" LC_ALL=C awk -F'\t' -v now="$now" -v home="$HOME" -v max="$shown" \
	-v live="$live_sids" -v plain="$plain" \
	"$CELLS_AWK"'
		# Columns 6 and 7 are padded to a fixed VISIBLE width. They reach the
		# popup joined by the tab delimiter, and a terminal advances a tab to
		# the next multiple of eight — so a short label ("idle") landed a whole
		# stop left of a long one ("allow Edit?") and the list rendered ragged.
		# Padding here (and --tabstop=1 in the popup) makes the columns line up
		# for the fzf list and the no-fzf menu alike. The colour escapes are
		# not cells at all, so the width is counted on the parts rather than on
		# the finished string, and each part is measured with cw() — a Cyrillic
		# SessionEnd reason ("готово") measures 12 under length().
		function pad(s, vis, want,   n) {
			n = want - vis
			while (n-- > 0) s = s " "
			return s
		}
	BEGIN { n = split(live, ls, " "); for (i = 1; i <= n; i++) if (ls[i] != "") alive[ls[i]] = 1 }
	{
		ts = $1; sid = $2; cwd = $3; reason = $4; tp = $5
		if (out >= max) next
		if (sid == "" || (sid in alive) || (sid in seen)) next
		seen[sid] = 1

		# The same clamp the live block carries, and it was missed here when
		# that one was fixed: a spool row timestamped an hour ahead of us
		# rendered "-60m ago", and a non-numeric timestamp "20700d ago". A
		# clock ahead of ours is not a session that ended in the future.
		age = now - ts
		if (ts + 0 <= 0 || age < 0) age = 0
		if      (age < 3600)    a = int(age / 60) "m"
		else if (age < 86400)   a = int(age / 3600) "h"
		else if (age < 8640000) a = int(age / 86400) "d"
		else                    a = "99d+"
		if (reason == "") reason = "ended"
		if (cwd == "") cwd = "-"
		if (tp == "") tp = "-"

		path = cwd
		if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

		# "⏹" is U+23F9, East_Asian_Width N — ONE cell, unlike every badge
		# emoji, which are two. Counting it as two padded these rows a cell
		# short and left the ended block visibly out of line with the live one.
		agecol = pad(a " ago", cw(a) + 4, 17)
		if (plain != "")
			printf "5\thist\t%s\t%s\t%s\t%s\t%s\t%s\tended\t-\t-\t0\t-\t-\n",
				sid, tp, cwd, pad("⏹ " reason, 2 + cw(reason), 19), agecol, path
		else
			printf "5\thist\t%s\t%s\t%s\t%s\t%s\t\033[90m%s\033[0m\tended\t-\t-\t0\t-\t-\n",
				sid, tp, cwd,
				pad("⏹ \033[90m" reason "\033[0m", 2 + cw(reason), 19),
				pad("\033[90m" a " ago\033[0m", cw(a) + 4, 17), path
		out++
	}
'

# The empty case — no sessions live, none ended — is the ordinary state of a
# fresh machine, not a failure. Without this the history block's trailing
# test leaked its status out as the script's own.
exit 0
