#!/usr/bin/env bash
# tmux-claude-tabs — tmux side.
#
# Splices the Claude Code state emoji into each window's own block in the status
# line, so it is obvious which window it belongs to:
#
#    2  💭 myproject · Bash    3  🔴 api    4  zsh
#
# It does not own the status line: it reads whatever window-status-format your
# theme has set and inserts one segment into it, right before the theme's own
# style tag for #W. That tag then restores the window-name colour, so nothing
# after the emoji is affected. Re-running re-derives the formats instead of
# stacking segments, so `prefix r` is safe.
#
# Values come from hooks/claude-tabs.sh, wired into Claude Code by hooks/install.sh.
#
# Options (set before this script runs):
#   @claude-tabs-current-label  on|off  spell the state out on the current
#                                       window (default: on)
#   @claude-tabs-window-name    cells|off  name a Claude window after its
#                                       session, cut to this many cells (plus
#                                       "…"), instead of the binary's version
#                                       (default: 24)
#   @claude-tabs-click-menu     on|off  middle-click / double-click a tab for a
#                                       menu with its state (default: on)
#   @claude-tabs-auto-hooks     on|off  wire the Claude Code hooks on tmux start
#                                       if they are missing (default: off; the
#                                       README's one-step install turns it on —
#                                       the alternative is running ./hooks/install.sh
#                                       by hand)
#   @claude-tabs-notice-position left|right|off  where the transient
#                                       notification segment is spliced into
#                                       the status line (default: right —
#                                       'left' pushes the window list along)
#   @claude-tabs-nav-key        key     prefix key for the navigator popup
#                                       (default: N; 'off' disables)
#   @claude-tabs-jump-key       key     prefix key that steps through every
#                                       session needing you, wrapping; reports
#                                       and stays put when none does
#                                       (default: J; 'off')
#   @claude-tabs-clear-key      key     prefix key that clears the current
#                                       window's badge (default: M-c; 'off')
#   @claude-tabs-sync-on-load   on|off  seed badges when the plugin loads
#                                       (default: on)
#   @claude-tabs-self-heal      on|off  reconcile+sweep on window switch,
#                                       session change and attach (default: on)
#   @claude-tabs-poll           on|off  per-server poller following the
#                                       supervisor's session files — the
#                                       default path that needs no Claude Code
#                                       hooks at all (default: on)
#
# The full option list, including the reconcile/watcher tuning knobs read by
# scripts/navigator.sh, is in README.md — this block only documents what THIS
# script reads.
#
# Verbs: `claude-tabs.tmux clear <window>` wipes one window's badge;
# `claude-tabs.tmux uninstall` strips the spliced formats, hooks, bindings and
# options from the running server (hooks/install.sh --uninstall calls it for you).

set -u

self="${BASH_SOURCE[0]}"
case "$self" in /*) ;; *) self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")" ;; esac
# tpm hands the plugin dir over WITH a trailing slash, so BASH_SOURCE can carry
# ".../plugins//tmux-claude-tabs/...". Squeeze repeated slashes: the hook
# de-duplicator matches by this path, and an unsqueezed copy would not match a
# squeezed one — every reload then appended another hook.
while [ "$self" != "${self//\/\///}" ]; do self="${self//\/\///}"; done
repo="$(dirname "$self")"
# Every run-shell string below crosses two parsers: tmux (formats: # is
# special) and sh (spaces). Double the #s and wrap the paths in sh single
# quotes; a single quote in the install path is not supported.
self_q="'${self//"#"/"##"}'"
nav_q="'${repo//"#"/"##"}/scripts/navigator.sh'"
# shellcheck source=scripts/helpers.sh
. "$repo/scripts/helpers.sh"

# Pane-scoped badge values plus the window-only display copies (see the
# segments below for why those exist).
badge_opts='@claude_tabs_glyph @claude_tabs_plain @claude_tabs_label @claude_tabs_state @claude_tabs_at @claude_tabs_seen @claude_tabs_watch @claude_tabs_wglyph @claude_tabs_wplain @claude_tabs_wlabel'

# `claude-tabs.tmux clear <target>` wipes the badge for one window. The target
# is passed in because run-shell inherits the *server* environment — its -t flag
# does not export TMUX_PANE — but it does expand #{window_id}.
if [ "${1:-}" = clear ]; then
	target="${2:-${TMUX_PANE:-}}"
	[ -n "$target" ] || exit 0
	# `set -p -t <window>` resolves to the window's *active* pane, so walk all
	# of its panes — the stale badge may belong to a background one.
	panes="$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null)"
	[ -n "$panes" ] || panes="$target"
	for o in $badge_opts; do
		for pn in $panes; do
			tmux set -p -t "$pn" -u "$o" 2>/dev/null
		done
		tmux set -w -t "$target" -u "$o" 2>/dev/null
	done
	exit 0
fi

opt() { # opt <name> <default>
	local v
	v="$(tmux show -gqv "$1" 2>/dev/null)"
	[ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

# Any key whose binding points into this plugin is ours to manage, and is
# re-derived from the options on every load. Without this, changing
# @claude-tabs-nav-key left the old key bound forever, and 'off' never
# released a key at all — including middle/double-click on the status line,
# stolen from the user's own bindings with no way back.
unbind_ours() {
	tmux list-keys 2>/dev/null |
		awk -v repo="$repo" '
			{
				line = $0; gsub("/+", "/", line)
				if (index(line, repo) == 0) next
				for (i = 1; i < NF; i++) if ($i == "-T") { print $(i + 1), $(i + 2); break }
			}' |
		while read -r tbl k; do
			[ -n "${k:-}" ] && tmux unbind-key -T "$tbl" "$k" 2>/dev/null
		done
	return 0
}

# Surgical hook removal: only OUR entries (matched by command content), unset
# by index, highest first so removals do not renumber what is left. `show -g
# <hook>` lists hooks of every scope — show-hooks -g misses pane-level ones
# like pane-exited. A blanket `set-hook -gu` would wipe hooks other plugins
# or the user installed.
remove_our_hooks() { # remove_our_hooks <event>...
	local ev idx
	for ev in "$@"; do
		tmux show -g "$ev" 2>/dev/null |
			awk -v ev="$ev" -v repo="$repo" '
				{ line = $0; gsub("/+", "/", line) }
				$1 ~ "^" ev "\\[" && index(line, repo) {
				gsub(".*\\[|\\].*", "", $1); print $1 }' |
			sort -rn | while IFS= read -r idx; do
			[ -n "$idx" ] && tmux set-hook -gu "${ev}[$idx]" 2>/dev/null
		done
	done
	return 0
}

# The formats read WINDOW-ONLY option names. #{@foo} in a format resolves
# pane → window → session → global, so a name the panes also set is answered
# by the window's ACTIVE pane and the window's own value is never reached:
# with three Claudes in one window the aggregate "✅3" sat in the window
# option while the tab rendered the active pane's plain "✅", and the most
# urgent pane's label lost to whichever pane you happened to be on. Panes
# never set the w-names, so the lookup always falls through to the window.
glyph_seg='#{?@claude_tabs_wglyph, #{@claude_tabs_wglyph},}'
plain_seg='#{?@claude_tabs_wplain, #{@claude_tabs_wplain},}'
label_seg='#{?@claude_tabs_wlabel, · #{@claude_tabs_wlabel},}'
[ "$(opt @claude-tabs-current-label on)" = off ] && label_seg=''

# Drop a previously injected `#{?@claude_tabs_*,…,}` segment so this script can
# run again over its own output.
strip_segments_named() { # strip_segments_named <string> <segment-prefix>
	local s="$1" pre="$2" head tail
	while [ "${s#*"$pre"}" != "$s" ]; do
		head="${s%%"$pre"*}"
		tail="${s#*"$pre"}"
		tail="${tail#*,\}}"
		s="$head$tail"
	done
	printf '%s' "$s"
}

strip_segments() {
	local s="$1" pre head tail
	# The three pre-0.2 names are stripped too: a reload over a format spliced
	# by an older version must not leave its segment sitting next to the new one.
	for pre in '#{?@claude_tabs_wglyph,' '#{?@claude_tabs_wplain,' '#{?@claude_tabs_wlabel,' \
		'#{?@claude_tabs_glyph,' '#{?@claude_tabs_plain,' '#{?@claude_tabs_label,'; do
		while [ "${s#*"$pre"}" != "$s" ]; do
			head="${s%%"$pre"*}"
			tail="${s#*"$pre"}"
			tail="${tail#*,\}}"
			s="$head$tail"
		done
	done
	printf '%s' "$s"
}

# Insert the emoji before the last `#[…]` style tag that precedes the window
# name: that tag sets the name's colour, so it undoes our fg for everything
# after it. Themes spell the name #W or #T; catppuccin spells it neither — its
# format is built entirely from #{@option} references, with #T hidden inside
# @catppuccin_window_text. With no anchor to find, prepend rather than give up:
# a badge at the head of the window block beats the silent no-op this used to
# be on the most-starred tmux theme.
# Splices the segment before EVERY #W/#T, not just the first. A very common
# theme shape is `#{?<flag>,<styled #W>,<other styled #W>}` — one rendering for
# the zoomed/bell/current case and one for the rest — and splicing only the
# first put the badge inside a branch the terminal almost never draws, so no
# badge ever appeared. Doing every occurrence costs one extra segment in the
# format and shows the badge whichever branch tmux takes.
#
# A theme that spells the name neither #W nor #T — older catppuccin built its
# format entirely from option references — gets the badge prepended instead of
# silently dropped.
insert_glyph() {
	local s="$1" seg="$2" out="" anchor before rest tag
	case "$s" in
	*'#W'* | *'#T'*) ;;
	*)
		printf '%s%s' "$seg" "$s"
		return
		;;
	esac
	while :; do
		anchor=""
		case "$s" in *'#W'*) anchor='#W' ;; esac
		case "$s" in
		*'#T'*)
			if [ -z "$anchor" ]; then
				anchor='#T'
			else
				# Both present: take whichever comes first.
				case "${s%%'#T'*}" in
				*'#W'*) ;;
				*) anchor='#T' ;;
				esac
			fi
			;;
		esac
		[ -n "$anchor" ] || break
		before="${s%%"$anchor"*}"
		rest="${s#*"$anchor"}"
		# The theme's own style tag for the name must stay immediately before
		# it, so it lands AFTER our segment and restores the name's colour.
		tag=""
		case "$before" in
		*'#['*)
			tag="#[${before##*'#['}"
			before="${before%'#['*}"
			;;
		esac
		out="$out$before$seg$tag$anchor"
		s="$rest"
	done
	printf '%s%s' "$out" "$s"
}

# The label goes after #W, and after the zoom flag if the theme has one.
insert_label() {
	local s="$1" head rest inner tail anchor="" zoom='#{?window_zoomed_flag,'
	[ -n "$label_seg" ] || {
		printf '%s' "$s"
		return
	}
	case "$s" in
	*'#W'*) anchor='#W' ;;
	*'#T'*) anchor='#T' ;;
	*)
		# No anchor: the glyph was prepended, so append the label.
		printf '%s%s' "$s" "$label_seg"
		return
		;;
	esac
	head="${s%%"$anchor"*}$anchor"
	rest="${s#*"$anchor"}"
	case "$rest" in
	"$zoom"*)
		inner="${rest#"$zoom"}"
		tail="${inner#*,\}}"
		head="$head${rest%"$tail"}"
		rest="$tail"
		;;
	esac
	printf '%s%s%s' "$head" "$label_seg" "$rest"
}

# `claude-tabs.tmux uninstall` takes back everything the load path set up.
# Dropping the @plugin line alone removes nothing: the spliced formats, the
# self-heal hooks and the key bindings live in the tmux SERVER and outlive
# every config reload — the old removal story was "kill the server", which is
# a lot to ask for removing a status-line plugin.
if [ "${1:-}" = uninstall ]; then
	fmt="$(tmux show -gv window-status-format 2>/dev/null)"
	[ -n "$fmt" ] && tmux setw -g window-status-format "$(strip_segments "$fmt")"
	fmt="$(tmux show -gv window-status-current-format 2>/dev/null)"
	[ -n "$fmt" ] && tmux setw -g window-status-current-format "$(strip_segments "$fmt")"
	for side in status-left status-right; do
		cur="$(tmux show -gv "$side" 2>/dev/null)"
		case "$cur" in
		*@claude_tabs_notice*)
			tmux set -g "$side" "$(strip_segments_named "$cur" '#{?@claude_tabs_notice,')" ;;
		esac
	done
	unbind_ours
	remove_our_hooks after-select-window after-select-pane client-session-changed \
		client-attached pane-exited pane-died after-kill-pane \
		window-layout-changed window-linked window-unlinked
	case "$(tmux show -gv automatic-rename-format 2>/dev/null)" in
	*@claude_tabs_saved_arf*)
		tmux setw -g automatic-rename-format \
			"$(tmux show -gqv @claude_tabs_saved_arf 2>/dev/null)" 2>/dev/null
		rename_windows ;;
	esac
	tmux list-panes -a -F '#{pane_id}' 2>/dev/null | while IFS= read -r pn; do
		for o in $badge_opts @claude_tabs_sname; do tmux set -p -t "$pn" -u "$o" 2>/dev/null; done
	done
	tmux list-windows -a -F '#{window_id}' 2>/dev/null | while IFS= read -r wn; do
		for o in $badge_opts; do tmux set -w -t "$wn" -u "$o" 2>/dev/null; done
	done
	# Put back the status-side length our notice segment raised. Only where we
	# recorded one: a server we never raised keeps whatever the theme set.
	for _p in status-left-length:@claude_tabs_saved_sll \
		status-right-length:@claude_tabs_saved_srl; do
		_saved="$(tmux show -gqv "${_p#*:}" 2>/dev/null)"
		case "$_saved" in
		'' | *[!0-9]*) ;;
		*) tmux set -g "${_p%%:*}" "$_saved" 2>/dev/null ;;
		esac
	done
	# @claude_tabs_poll_token going away is what stops the poller: it checks
	# the token every tick and exits when it no longer matches.
	for o in @claude_tabs_synced_at @claude_tabs_notice @claude_tabs_notice_tok \
		@claude_tabs_jump_cursor @claude_tabs_poll_token @claude_tabs_hooks_at \
		@claude_tabs_saved_sll @claude_tabs_saved_srl @claude_tabs_saved_arf; do
		tmux set -gu "$o" 2>/dev/null
	done
	exit 0
fi

# The transient notification segment. It goes in status-left/right rather than
# through display-message, because a tmux message is drawn OVER the whole
# status line for its duration — the window list vanishes while it is up.
# Right, not left. Measured on a 196-column terminal whose window list wants
# 236: the notice took 30 more columns off an already-overflowing list, so
# announcing "this session finished" pushed several tabs out of view for the
# four seconds it was up — the plugin partly destroying the very view it was
# reporting on. status-right is the cheaper thing to displace, since the
# window list is the whole point.
notice_pos="$(opt @claude-tabs-notice-position right)"
notice_seg='#{?@claude_tabs_notice,#[fg=colour214]#{@claude_tabs_notice}#[default] ,}'

# Strip our segment from BOTH sides first, then insert on the chosen one. Only
# checking the target side meant `off` never removed anything and switching
# left→right left the old segment in place, rendering the notice twice.
strip_notice() { # strip_notice <status-left|status-right>
	local cur new
	cur="$(tmux show -gv "$1" 2>/dev/null)"
	case "$cur" in
	*@claude_tabs_notice*) ;;
	*) return 0 ;;
	esac
	new="$(strip_segments_named "$cur" '#{?@claude_tabs_notice,')"
	tmux set -g "$1" "$new"
}
strip_notice status-left
strip_notice status-right

case "$notice_pos" in
left)
	tmux set -g status-left "$(tmux show -gv status-left 2>/dev/null)${notice_seg}"
	# The notice is ~50 columns; a theme's status-left-length would clip it
	# to "✅ do". Raising a maximum costs nothing while no notice is up.
	len="$(tmux show -gv status-left-length 2>/dev/null)"
	case "$len" in '' | *[!0-9]*) len=10 ;; esac
	if [ "$len" -lt 140 ]; then
		# Record the theme's own value once, so uninstall can put it back —
		# raising it and never restoring left every server we had ever loaded
		# on with a 140-column status side. Guarded, because a reload must not
		# record our own 140 as the original.
		[ -z "$(tmux show -gqv @claude_tabs_saved_sll 2>/dev/null)" ] &&
			tmux set -g @claude_tabs_saved_sll "$len"
		tmux set -g status-left-length 140
	fi
	;;
right)
	tmux set -g status-right "${notice_seg}$(tmux show -gv status-right 2>/dev/null)"
	len="$(tmux show -gv status-right-length 2>/dev/null)"
	case "$len" in '' | *[!0-9]*) len=10 ;; esac
	if [ "$len" -lt 140 ]; then
		# Record the theme's own value once, so uninstall can put it back —
		# raising it and never restoring left every server we had ever loaded
		# on with a 140-column status side. Guarded, because a reload must not
		# record our own 140 as the original.
		[ -z "$(tmux show -gqv @claude_tabs_saved_srl 2>/dev/null)" ] &&
			tmux set -g @claude_tabs_saved_srl "$len"
		tmux set -g status-right-length 140
	fi
	;;
esac

fmt="$(tmux show -gv window-status-format 2>/dev/null)"
tmux setw -g window-status-format "$(insert_glyph "$(strip_segments "$fmt")" "$glyph_seg")"

fmt="$(tmux show -gv window-status-current-format 2>/dev/null)"
fmt="$(insert_glyph "$(strip_segments "$fmt")" "$plain_seg")"
tmux setw -g window-status-current-format "$(insert_label "$fmt")"

# Window names. Claude's process is named after its version, so automatic-rename
# called every Claude window "2_1_302". Claude puts the session's name in the
# pane title as "✳ <name>"; a window whose active pane runs Claude is named
# after that instead. Windows renamed by hand have automatic-rename off and are
# never touched. The user's own format is kept in an option and referenced
# through #{E:}, not pasted in: a bare comma in it would split our #{?…}.
# The regex has no {n} quantifier on purpose — a bare } ends a tmux format.
arf="$(tmux show -gv automatic-rename-format 2>/dev/null)"
case "$arf" in
*@claude_tabs_saved_arf*) ;;   # ours, from an earlier load: keep the saved one
*) tmux set -g @claude_tabs_saved_arf "$arf" ;;
esac
name_w="$(opt @claude-tabs-window-name 24)"
case "$name_w" in
'' | *[!0-9]* | 0)
	case "$arf" in
	*@claude_tabs_saved_arf*)
		tmux setw -g automatic-rename-format "$(tmux show -gqv @claude_tabs_saved_arf)" ;;
	esac
	;;
*)
	# The short session name ("rusolv-28", or what /rename set) that sync
	# publishes on the pane as @claude_tabs_sname — the long pane title made
	# nine tabs too wide for one screen. Without it (no poller yet, or poll
	# off), the pane title, but only one carrying Claude's glyph: before
	# Claude sets one, the pane title is the hostname or whatever the shell
	# left there. Then, innermost first: drop the glyph; turn # into _
	# (tmux before 3.4 keeps it, and #[…] in a window name restyles the tab);
	# swap . and : for look-alikes, which tmux 3.7 would turn into _ in a
	# window name ("MEMORY_md"). A literal colon cannot be written inside a
	# modifier, hence [[.colon.]]. The cut keeps N cells, then adds the "…".
	g='(✳|✢|✶|✻|✽|·|⠂|⠐)'
	tmux setw -g automatic-rename-format "#{?#{&&:#{m/r:^([0-9]+[._][0-9]+[._][0-9]+|claude)\$,#{pane_current_command}},#{||:#{@claude_tabs_sname},#{m/r:^$g ,#{pane_title}}}},#{=/$name_w/…:#{s/[[.colon.]]/꞉/:#{s/[.]/․/:#{s/[#]/_/:#{?@claude_tabs_sname,#{@claude_tabs_sname},#{s/^$g //:pane_title}}}}}},#{E:@claude_tabs_saved_arf}}"
	;;
esac
rename_windows

# Every binding below is re-derived from the options on this load; stale ones
# from a previous load (a changed key, an option turned off) go first.
unbind_ours

# tmux has no hover event — there is no MouseMove* key to bind — so the nearest
# thing is a click that does not switch windows: middle-click or double-click a
# tab to read its full state. Only the current window shows the label inline.
if [ "$(opt @claude-tabs-click-menu on)" != off ]; then
	# The state goes in the title: a menu *item* starting with "-" (tmux's way
	# of spelling "disabled") is eaten by the option parser instead.
	title='#[align=centre]#{window_index}: #{window_name}#{?@claude_tabs_wlabel, — #{@claude_tabs_wlabel},}'
	for key in MouseDown2Status SecondClick1Status; do
		tmux bind-key -n "$key" display-menu -T "$title" -t = -x M -y S \
			'Go to window' g 'select-window -t =' \
			'Clear badge' c "run-shell -b -t = \"$self_q clear #{window_id}\"" \
			'' \
			'Close' q ''
	done
fi

# Claude has no idea it was killed with the pane, so a hard kill can leave a
# stale badge behind: this key clears it for the current window. An option
# like every other key — the README promises "all remappable, 'off' releases
# any of them", and this one used to be the exception that made that false.
clear_key="$(opt @claude-tabs-clear-key M-c)"
if [ -n "$clear_key" ] && [ "$clear_key" != off ]; then
	tmux bind-key "$clear_key" run-shell -b "$self_q clear #{window_id}"
fi

# The navigator: every Claude on the server in one popup — live ones with
# their state, recently ended ones ready to resume. Falls back to a
# display-menu when fzf is missing.
nav_key="$(opt @claude-tabs-nav-key N)"
if [ -n "$nav_key" ] && [ "$nav_key" != off ]; then
	# #{q:...} escapes for UNQUOTED sh use — wrapping it in quotes would make
	# the backslashes literal and break on any path with a space.
	# -b: see the note above the click menu. The popup targets its client
	# explicitly, so it opens on the right one either way.
	# The PANE ID, not its path. run-shell format-expands its argument and then
	# hands the result to sh, and #{q:} escapes sh metacharacters but NOT a
	# newline — measured: a value containing one comes back with the newline
	# intact. So a directory whose name carried a newline (a hostile archive or
	# clone is enough) ended the sh command and ran the rest as a second one.
	# A pane id is %<digits> and cannot carry anything; navigator.sh asks tmux
	# for the path itself, where no format expansion is involved.
	tmux bind-key "$nav_key" run-shell -b \
		"$nav_q open #{q:client_name} #{q:pane_id}"
fi

# Step through the sessions that need you (needs-you, plan approval, error).
# Goes nowhere when none does — see navigator.sh jump-last for why.
jump_key="$(opt @claude-tabs-jump-key J)"
if [ -n "$jump_key" ] && [ "$jump_key" != off ]; then
	tmux bind-key "$jump_key" run-shell -b \
		"$nav_q jump-last #{q:client_name}"
fi

# One-time migration: the old single-file history becomes the spool (one file
# per ended session; no locks needed since every operation is atomic).
hist_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-claude-tabs"
# Directories an older version created world-readable are tightened in place,
# once. They hold the path of every project you have run Claude in, and the
# transcript paths beside them. Only the plugin's own directory is touched.
for d in "$hist_dir" "$hist_dir/ended" "$hist_dir/turns"; do
	[ -d "$d" ] && chmod 700 "$d" 2>/dev/null
done
if [ -f "$hist_dir/history.tsv" ] && [ ! -f "$hist_dir/history.tsv.migrated" ]; then
	(umask 077; mkdir -p "$hist_dir/ended") 2>/dev/null
	# Copy each row verbatim — a tab-IFS read would collapse empty fields and
	# shift the columns.
	awk -F'\t' -v dir="$hist_dir/ended" '
		$2 != "" {
			f = $2; gsub("/", "_", f); f = dir "/" f
			if (!(f in done)) { print $0 > f; close(f); done[f] = 1 }
		}' "$hist_dir/history.tsv" 2>/dev/null
	# Only retire the original once the copy actually produced something. The
	# rename used to happen regardless, so a migration that failed — no space,
	# a permission problem, a malformed row — took the whole resume history
	# with it and left an empty spool.
	if [ -n "$(ls -A "$hist_dir/ended" 2>/dev/null)" ]; then
		mv "$hist_dir/history.tsv" "$hist_dir/history.tsv.migrated" 2>/dev/null
	fi
fi

# Seed badges for Claudes already running when tmux (re)starts — otherwise a
# session that is simply idle shows nothing until its next event. Backgrounded:
# `claude agents --json` takes ~350ms and must not stall config loading.
if [ "$(opt @claude-tabs-sync-on-load on)" != off ]; then
	tmux run-shell -b "$nav_q sync force >/dev/null 2>&1 || true" 2>/dev/null
fi

# The default no-hooks path: one poller per server follows the supervisor's
# session files and reconciles when they change, so badges work with nothing
# written outside tmux. The token is both the single-instance guard and the
# kill switch — a reload stamps a new one and the old poller stands down on
# its next tick; `off` unsets it and the poller exits the same way.
if [ "$(opt @claude-tabs-poll on)" != off ]; then
	ptok="$$.$(date +%s).$RANDOM"
	tmux set -g @claude_tabs_poll_token "$ptok" 2>/dev/null
	# The poller is a daemon, but it is still a run-shell job: anything it ever
	# printed would land on the user's screen like any other job's output. exec,
	# not "|| true": the daemon exits 0 by design, and exec keeps tmux's sh from
	# living beside it for the whole server lifetime as a wrapper process.
	tmux run-shell -b "exec $nav_q poll '$ptok' >/dev/null 2>&1" 2>/dev/null
else
	tmux set -gu @claude_tabs_poll_token 2>/dev/null
fi

# Self-healing. Hooks describe events, and some things Claude Code does in the
# background (the away-summary pass, for one) fire an event that looks like
# work starting with no Stop to close it — that badge would say "working"
# forever. Reconciling when you switch windows costs nothing when nothing is
# wrong (throttled to @claude-tabs-sync-every seconds) and repairs the badge
# exactly when you are looking at the tab bar.
if [ "$(opt @claude-tabs-self-heal on)" != off ]; then
	# after-select-pane deliberately not included: pane focus changes far too
	# often for something that spawns `claude agents --json`, and the root
	# cause it used to paper over (background PostToolUse events) is filtered
	# at the source now.
	# Every command below ends in ">/dev/null 2>&1 || true" INSIDE the run-shell
	# string. tmux shows a background job's output — and its non-zero exit, as
	# "'…' returned N" — to the user, as a status message that hides the window
	# list or as a page over the pane. These run on every window switch and
	# every layout change, so a stray line from any future edit would reach
	# the screen; the shell swallows it here regardless.
	claude_tabs_hook() { # claude_tabs_hook <event> <command>
		remove_our_hooks "$1"
		tmux set-hook -ga "$1" "$2" 2>/dev/null
	}
	for ev in after-select-window client-session-changed client-attached; do
		claude_tabs_hook "$ev" "run-shell -b \"$nav_q sync >/dev/null 2>&1 || true\""
	done
	# Panes dying take their pane-scoped badge with them but leave the window
	# copy behind — sweep it when that happens. pane-exited fires when the
	# pane's process ends on its own, after-kill-pane when it is killed.
	for ev in pane-exited pane-died after-kill-pane; do
		claude_tabs_hook "$ev" "run-shell -b \"$nav_q sweep >/dev/null 2>&1 || true\""
	done
	# A pane MOVED between windows used to leave its badge on the old window and
	# put none on the new one, permanently — move-pane, join-pane and break-pane
	# are ordinary housekeeping and the tab bar then lied in both directions at
	# once. tmux has no after-move-pane; measured on 3.3a and 3.7, the events
	# that actually fire are window-layout-changed (all three operations) and
	# window-linked / window-unlinked (break and join only). Layout-changed also
	# fires on every resize step; measured, that costs 13% on a fifty-step drag
	# and leaves nothing behind, so it is simply allowed.
	for ev in window-layout-changed window-linked window-unlinked; do
		claude_tabs_hook "$ev" "run-shell -b \"$nav_q recompute #{window_id} deferrable >/dev/null 2>&1 || true\""
	done
	# One-time repaint after the poll-mode colour fix. Badges already on the
	# screen keep whatever was written when they were painted, and the poller
	# only repaints on a state CHANGE — so an idle session would have sat there
	# in the wrong colour indefinitely. The six old values are ANSI SGR numbers
	# and none of them collides with the palette entries we write now, so the
	# mapping is unambiguous.
	for _scope in p w; do
		case "$_scope" in
		p) _list="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"; _opts="@claude_tabs_glyph" ;;
		*) _list="$(tmux list-windows -a -F '#{window_id}' 2>/dev/null)"; _opts="@claude_tabs_wglyph" ;;
		esac
		for _t in $_list; do
			for _o in $_opts; do
				_g="$(tmux show-options -${_scope}qv -t "$_t" "$_o" 2>/dev/null)"
				case "$_g" in
				*fg=colour31,*) _n="${_g/fg=colour31,/fg=colour167,}" ;;
				*fg=colour32,*) _n="${_g/fg=colour32,/fg=colour142,}" ;;
				*fg=colour33,*) _n="${_g/fg=colour33,/fg=colour214,}" ;;
				*fg=colour34,*) _n="${_g/fg=colour34,/fg=colour109,}" ;;
				*fg=colour35,*) _n="${_g/fg=colour35,/fg=colour175,}" ;;
				*fg=colour90,*) _n="${_g/fg=colour90,/fg=colour245,}" ;;
				*) continue ;;
				esac
				tmux set-option -${_scope} -t "$_t" "$_o" "$_n" 2>/dev/null
			done
		done
	done

	# Legacy cleanup: v0.3.0 and earlier blanket-unset after-select-pane and
	# re-added itself there; drop only our own entry if one is still around.
	remove_our_hooks after-select-pane
fi

if [ "$(opt @claude-tabs-self-heal on)" = off ]; then
	# Turning the option off must also take the previously wired hooks down —
	# they outlive plugin loads otherwise.
	remove_our_hooks after-select-window after-select-pane client-session-changed \
		client-attached pane-exited pane-died after-kill-pane \
		window-layout-changed window-linked window-unlinked
fi

# Opt-in convenience for TPM users who would rather not run hooks/install.sh.
# The failure is reported, not swallowed: with jq missing the installer exits
# non-zero with a perfectly good message, and discarding it produced the worst
# outcome this plugin can have — tmux side installs cleanly, formats splice,
# keys bind, and no badge can EVER appear because no hook was written, with
# nothing on screen to say why.
if [ "$(opt @claude-tabs-auto-hooks off)" = on ]; then
	if ! err="$("$repo/hooks/install.sh" --quiet 2>&1)"; then
		tmux set -g @claude_tabs_notice \
			"⚠ tmux-claude-tabs: hooks NOT installed — ${err%%$'\n'*}" 2>/dev/null
		tmux display-message "tmux-claude-tabs: hooks not installed — ${err%%$'\n'*}" 2>/dev/null
	fi
fi

exit 0
