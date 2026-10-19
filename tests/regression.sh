#!/usr/bin/env bash
# Self-contained regression for tmux-claude-tabs, run inside a Linux container.
# Expects the repo mounted read-only at /repo; tmux, bash, jq installed.
set -u

# Every tmux call in this file goes to a dedicated socket, never the user's
# server: the suite sets GLOBAL options and hooks (window-status-format,
# after-select-window, status-left...) and would otherwise rewrite a live
# config. Child scripts are not affected by a shell function, so they follow
# $TMUX — exported below to the same socket.
CLAUDE_TABS_TEST_SOCKET="${CLAUDE_TABS_TEST_SOCKET:-claude-tabs-test}"
tmux() { command tmux -L "$CLAUDE_TABS_TEST_SOCKET" "$@"; }

REPO="${REPO:-/repo}"          # container default; override to run on a host
export XDG_DATA_HOME=/tmp/xdg
export CLAUDE_TABS_SUPERVISOR_DIR=/tmp/fakesup
rm -rf /tmp/xdg /tmp/fakesup; mkdir -p /tmp/fakesup
SPOOL="$XDG_DATA_HOME/tmux-claude-tabs/ended"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (got [$2] want [$3])"; fi; }
# A skipped check is not a passed check. Counting them as passes made "80
# passed" mean different things on different platforms.
skip=0
# Byte comparison that survives a minimal Fedora/RHEL image, which ships no
# diffutils — hooks/install.sh's own same_file() already falls back this way, and
# these checks were written without it: they failed on Fedora for want of
# `cmp`, not for any difference in the bytes.
same_bytes() { # same_bytes <a> <b>
	if command -v cmp >/dev/null 2>&1; then
		cmp -s "$1" "$2"
	else
		[ "$(cksum <"$1")" = "$(cksum <"$2")" ]
	fi
}

sk() { skip=$((skip+1)); echo "SKIP: $1"; }

if [ -r /etc/os-release ]; then
	os="$(. /etc/os-release && echo "$PRETTY_NAME")"
else
	os="$(uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r)"
fi
echo "--- env: $os | tmux $(tmux -V | cut -d' ' -f2) | bash $BASH_VERSION | awk: $(awk -W version </dev/null 2>&1 | head -1)"

tmux kill-server 2>/dev/null; sleep 0.2
tmux -f /dev/null new-session -d -s alpha 'sleep 300'; tmux new-window -t alpha: 'sleep 300'; tmux new-session -d -s beta 'sleep 300'
export TMUX="$(tmux display -p '#{socket_path}'),$(tmux display -p '#{pid}'),0"
(unset TMUX; exec </dev/null >/dev/null 2>&1
	sleep 300 | command tmux -L "$CLAUDE_TABS_TEST_SOCKET" -C attach -t alpha) &
for i in $(seq 1 40); do client=$(tmux list-clients -F '#{client_name}' 2>/dev/null|head -1); [ -n "$client" ] && break; sleep 0.1; done
[ -n "${client:-}" ] || { echo "ABORT: no control client"; exit 1; }
T=$(tmux list-panes -t alpha:1 -F '#{pane_id}'|head -1)
hk() { printf '%s' "${2:-{\"session_id\":\"s1\"\}}" | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" "$1"; }
# No watcher re-arming anywhere in the suite: every `hk stop` would otherwise
# leave a backgrounded sleeper on the test server, re-arming for minutes
# after the check that spawned it has passed. The watcher itself is tested
# by invoking it directly.
tmux set -g @claude-tabs-watch-ticks 0 2>/dev/null
# No poll daemon either: every plugin load below would spawn one, and a
# reconcile firing seconds behind the fixtures would make the checks racy.
# The poll verb itself is tested directly, one tick at a time.
tmux set -g @claude-tabs-poll off 2>/dev/null
st() { tmux show -pqv -t "${1:-$T}" @claude_tabs_state; }; ws() { tmux show -wqv -t "${1:-$T}" @claude_tabs_state; }
lb() { tmux show -pqv -t "${1:-$T}" @claude_tabs_label; }

# --- driving the popup and the no-fzf menu FOR REAL.
# Both end in a tmux command that wants an interactive client, and this suite's
# client is a control-mode one: display-popup kills the server outright, and
# display-menu just blocks (measured: a 15s timeout, no menu drawn, and no
# format expansion — so "the injection did not fire" on this client is true
# whether the defence is there or not, which is a check that cannot fail).
# What IS observable is the argv the code hands tmux. A shim records that and
# forwards everything else to the real binary; the recorded strings are then
# put through tmux's own expander, which is the thing the defence must survive.
# This replaced six checks that only grepped the source: with all six
# behaviours deleted and the greppable string left alive in a comment, the
# suite scored exactly its clean 186/0/8.
CT_SHIM=/tmp/ct-shim; rm -rf "$CT_SHIM"; mkdir -p "$CT_SHIM"
# `type -P`, not `command -v`: this file defines a tmux FUNCTION, and
# command -v would answer with its name.
cat >"$CT_SHIM/tmux" <<EOF
#!/bin/sh
case "\$1" in
display-menu | display-popup)
	printf '%s\n' "\$@" >>"\${CT_TMUX_LOG:-/dev/null}"; exit 0 ;;
esac
exec $(type -P tmux) "\$@"
EOF
chmod +x "$CT_SHIM/tmux"
# The fzf shim lives in its OWN directory: the menu drive below needs a PATH
# with the tmux shim on it and no fzf anywhere, so the two cannot share one.
CT_SHIM_FZF=/tmp/ct-shim-fzf; rm -rf "$CT_SHIM_FZF"; mkdir -p "$CT_SHIM_FZF"
cat >"$CT_SHIM_FZF/fzf" <<'EOF'
#!/bin/sh
# `pick` version-gates its bindings, so answer that before recording.
[ "$1" = --version ] && { echo '0.44.1 (suite shim)'; exit 0; }
printf '%s\n' "$@" >>"$CT_FZF_LOG"
exit 1
EOF
chmod +x "$CT_SHIM_FZF/fzf"
# navigator.sh takes the display-menu branch only when fzf is absent, and
# `command -v` walks straight past a non-executable placeholder to the real
# binary — so the only way to hide fzf is a PATH that genuinely has none on
# it. One `ln` per PATH directory: 0.2s, measured.
CT_NOFZF=/tmp/ct-nofzf; rm -rf "$CT_NOFZF"; mkdir -p "$CT_NOFZF"
# Split on ':' via IFS, not `tr ':' ' '` — a macOS PATH routinely holds a
# directory with a space in it.
ct_oifs="$IFS"; IFS=:
for d in $PATH; do
	[ -d "$d" ] && ln -s "$d"/* "$CT_NOFZF/" 2>/dev/null
done
IFS="$ct_oifs"
rm -f "$CT_NOFZF/fzf"

# Terminal CELLS, for the column-alignment checks. Deliberately NOT agents.sh's
# width table: measuring a padder with the padder's own arithmetic agrees with
# it however wrong it is. Byte values come from od so no awk here has to be
# told what a byte is, and the five checks beside the fixture pin every range
# this file can reach to Unicode's East_Asian_Width — verified identical to
# python3's unicodedata on every string the fixture produces.
cells() {
	printf '%s' "$1" | od -An -v -tu1 | LC_ALL=C awk '
	function wide(c) {
		return (c >= 4352 && c <= 4447) ||       # Hangul Jamo
		       (c >= 8986 && c <= 8987) || (c >= 9001 && c <= 9002) ||
		       (c >= 9193 && c <= 9203) ||       # ⏩…⏳ (⏹ 9209 is NOT wide)
		       (c >= 9748 && c <= 9749) || (c >= 9800 && c <= 9811) ||
		       (c == 9889) || (c == 9924) || (c == 9925) || (c == 9989) ||
		       (c == 10024) || (c == 10060) || (c == 10062) ||
		       (c >= 11035 && c <= 11036) || (c == 11088) || (c == 11093) ||
		       (c >= 11904 && c <= 12350) ||     # CJK radicals, kana punct.
		       (c >= 12353 && c <= 19903) ||     # kana, CJK compat, ext A
		       (c >= 19968 && c <= 40959) ||     # CJK unified ideographs
		       (c >= 44032 && c <= 55203) ||     # Hangul syllables
		       (c >= 63744 && c <= 64255) ||     # CJK compat ideographs
		       (c >= 65281 && c <= 65376) ||     # fullwidth forms
		       (c >= 65504 && c <= 65510) ||
		       (c >= 127744 && c <= 129535) ||   # the emoji planes
		       (c >= 129648 && c <= 129791)
	}
	function zero(c) {   # combining marks, ZWJ/bidi, variation selectors
		return (c >= 768 && c <= 879) || (c >= 8203 && c <= 8207) ||
		       (c >= 65024 && c <= 65039)
	}
	{ for (i = 1; i <= NF; i++) b[++n] = $i + 0 }
	END {
		w = 0; i = 1
		while (i <= n) {
			c = b[i]
			if (c < 128)      { k = 1; cp = c }
			else if (c < 192) { k = 1; cp = 65533 }   # stray continuation
			else if (c < 224) { k = 2; cp = c - 192 }
			else if (c < 240) { k = 3; cp = c - 224 }
			else              { k = 4; cp = c - 240 }
			if (i + k - 1 > n) { w = w + 1; break }
			for (j = 1; j < k; j++) cp = cp * 64 + (b[i + j] - 128)
			i = i + k
			if (cp < 32 || cp == 127 || zero(cp)) continue
			w = w + (wide(cp) ? 2 : 1)
		}
		print w
	}'
}

# --- state machine
hk prompt; hk tool '{"session_id":"s1","tool_name":"Bash"}'; hk stop; ck "plain turn" "$(st)" "done"
hk post; ck "ghost post ignored" "$(st)" "done"
hk prompt; hk tool '{"session_id":"s1","tool_name":"Monitor"}'; hk stop; ck "Monitor -> bg" "$(st)/$(lb)" "bg/Monitor"
hk notify '{"session_id":"s1","notification_type":"idle_prompt"}'; ck "idle_prompt keeps bg" "$(st)" "bg"
hk prompt; hk subagent '{"session_id":"s1","agent_type":"Explore"}'; hk stop; ck "agent outlives turn" "$(st)" "bg"
hk subagent-done; ck "agent done" "$(st)" "done"
hk prompt; hk subagent '{"session_id":"s1","agent_type":"A"}'; hk subagent '{"session_id":"s1","agent_type":"B"}'; hk stop
hk subagent-done; ck "1 of 2 agents" "$(st)" "bg"; hk subagent-done; ck "2 of 2 -> done" "$(st)" "done"
# --- the bg-marker lock has to BE a lock. Parallel subagents finishing at once
# is the ordinary case and the drop is a read-modify-write, so a hook that
# cannot get the lock must do nothing at all — the old version wrote anyway
# after ten tries and then deleted the live holder's lock directory on the way
# out, losing a SubagentStop and leaving the tab on ⏳ forever (1 of 1
# deterministic, 18 of 25 under load).
BGLOCK="$XDG_DATA_HOME/tmux-claude-tabs/turns/lk1.bg.lock"
hk prompt '{"session_id":"lk1"}'
hk subagent '{"session_id":"lk1","agent_type":"A"}'
hk subagent '{"session_id":"lk1","agent_type":"B"}'
hk stop '{"session_id":"lk1"}'
BGF="$XDG_DATA_HOME/tmux-claude-tabs/turns/lk1.bg"
ck "two agents leave two markers" "$(wc -l <"$BGF" 2>/dev/null | tr -d ' ')" "2"
# A pid that is genuinely alive, or the holder is reclaimable and this measures
# the reclaim rather than the lock.
mkdir -p "$BGLOCK"; printf '%s' "$$" >"$BGLOCK/pid"
hk subagent-done '{"session_id":"lk1"}' >/dev/null 2>&1 &
bgpid=$!
sleep 1
ck "a hook that cannot take the bg lock leaves the holder's lock alone" \
	"$([ -d "$BGLOCK" ] && [ "$(cat "$BGLOCK/pid" 2>/dev/null)" = "$$" ] && echo held || echo stolen)" "held"
ck "...and does not do its rewrite unlocked" \
	"$(wc -l <"$BGF" 2>/dev/null | tr -d ' ')" "2"
rm -f "$BGLOCK/pid"; rmdir "$BGLOCK" 2>/dev/null
wait "$bgpid" 2>/dev/null
ck "...and drops its agent once the lock is free" \
	"$(wc -l <"$BGF" 2>/dev/null | tr -d ' ')" "1"
hk subagent-done '{"session_id":"lk1"}'; rm -f "$BGF" "$XDG_DATA_HOME/tmux-claude-tabs/turns/lk1"
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
tmux set -pu -t "$T" @claude_tabs_label; tmux set -wu -t "$T" @claude_tabs_label
ck "stamp set on active" "$(hk prompt; hk tool '{"session_id":"s1","tool_name":"Bash"}'; [ -n "$(tmux show -pqv -t "$T" @claude_tabs_at)" ] && echo yes)" "yes"
hk stop; ck "stamp cleared" "$(tmux show -pqv -t "$T" @claude_tabs_at)" ""
# --- notifications
tmux switch-client -c "$client" -t beta 2>/dev/null; sleep 0.2
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
hk permission '{"session_id":"s1","tool_name":"RGF"}'; sleep 0.3
ck "notice set (hidden)" "$([ -n "$(tmux show -gqv @claude_tabs_notice)" ] && echo yes)" "yes"
tmux set -gu @claude_tabs_notice
tmux switch-client -c "$client" -t alpha 2>/dev/null; tmux select-window -t alpha:1; sleep 0.2
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
hk permission '{"session_id":"s1","tool_name":"RGV"}'; sleep 0.3
ck "visible suppressed" "$(tmux show -gqv @claude_tabs_notice)" ""
# --- spool history
env -u TMUX -u TMUX_PANE bash -c 'printf "%s" "{\"session_id\":\"h1\",\"cwd\":\"/tmp\",\"transcript_path\":\"/tmp/x\"}" | XDG_DATA_HOME='"$XDG_DATA_HOME"' '"$REPO"'/hooks/claude-tabs.sh end'
ck "spool append" "$(ls "$SPOOL" | wc -l | tr -d ' ')" "1"
"$REPO/scripts/navigator.sh" dispose hist h1 /tmp/x; ck "spool forget" "$(ls "$SPOOL" 2>/dev/null | wc -l | tr -d ' ')" "0"
# The session's name is captured from the transcript at the end: /rename beats
# the AI title, and a title quoted inside a message is not a title.
printf '%s\n' '{"type":"ai-title","aiTitle":"Old title","sessionId":"h2"}' \
	'{"type":"user","message":"\"type\":\"custom-title\",\"customTitle\":\"FAKE\""}' \
	'{"type":"custom-title","customTitle":"Мой \"проект\"","sessionId":"h2"}' >/tmp/ct-h2.jsonl
env -u TMUX -u TMUX_PANE bash -c 'printf "%s" "{\"session_id\":\"h2\",\"cwd\":\"/tmp\",\"transcript_path\":\"/tmp/ct-h2.jsonl\"}" | XDG_DATA_HOME='"$XDG_DATA_HOME"' '"$REPO"'/hooks/claude-tabs.sh end'
ck "spool records the session name" "$(cut -f6 "$SPOOL/h2")" 'Мой "проект"'
ck "the ended row shows it" "$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" | awk -F'\t' '$3=="h2" {print $8}')" '/tmp  Мой "проект"'
"$REPO/scripts/navigator.sh" dispose hist h2 /tmp/ct-h2.jsonl; rm -f /tmp/ct-h2.jsonl
# --- supervisor fast path (files without trailing newline, like the real ones)
# The watcher verifies the process behind a session file is alive, so
# fixtures need a pid that actually exists. This shell will do.
LIVEPID=$$
# agents.sh and sweep drop records whose process is dead (a lingering file for
# a dead pid must neither produce rows nor shield a badge), so every fixture
# session needs a process that is actually alive. One sleeper per fake session.
FIXPIDS=""
# Sets FIXPID rather than echoing it: `V=$(fixpid)` would block for the
# sleeper's whole life, because the background child inherits the command
# substitution's stdout and $() waits for that pipe to close. The redirect
# matters for the same reason anywhere else this might get captured.
fixpid() {
	sleep 600 >/dev/null 2>&1 &
	FIXPID=$!
	FIXPIDS="$FIXPIDS $FIXPID"
}
# Fixtures carry a REAL timestamp. The reconciler will only let the supervisor
# overrule a hook badge when its record is at least as fresh as what the hooks
# last saw, so a 1970 epoch (which no Claude Code ever writes) suppresses every
# arm and makes these checks measure the guard instead of the behaviour.
# It must also be taken WHEN THE FIXTURE IS WRITTEN, not once at the top: a
# timestamp captured minutes earlier is older than the badge the hook just
# wrote, and the guard rejects it for exactly the right reason.
printf '%s' "{\"pid\":$LIVEPID,\"sessionId\":\"sv1\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp/p1\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"alpha:@1.$T\"}" > "/tmp/fakesup/$LIVEPID.json"
printf '%s' "{\"pid\":22222,\"sessionId\":\"sv2\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp/p2\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 ))}" > /tmp/fakesup/22222.json
rows="$("$REPO/scripts/agents.sh")"
ck "fast path row for tmux-field session" "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$T" '$2=="live" && $3==p {print $13}')" "busy"
ck "no-tty session filtered" "$(printf '%s\n' "$rows" | grep -c sv2)" "0"
# The name column: the pane title without Claude's glyph; before the session
# has a title, the name from the session file.
printf '%s' "{\"pid\":$LIVEPID,\"sessionId\":\"sv1\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp/p1\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"alpha:@1.$T\",\"name\":\"p1-ab\",\"nameSource\":\"derived\"}" > "/tmp/fakesup/$LIVEPID.json"
tmux select-pane -t "$T" -T '✳ Fix the login bug'
ck "a live row shows the pane title" \
	"$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" | awk -F'\t' -v p="$T" '$2=="live" && $3==p {print $8}')" "/tmp/p1  Fix the login bug"
for title in '✳ Claude Code' 'myhost.local' 'Привет мир'; do
	tmux select-pane -t "$T" -T "$title"
	ck "a title without Claude's glyph is not a name: $title" \
		"$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" | awk -F'\t' -v p="$T" '$2=="live" && $3==p {print $8}')" "/tmp/p1  p1-ab"
done
tmux select-pane -t "$T" -T ''
# The watcher, both directions. It replaced a one-shot `recheck` that could
# only downgrade done -> bg and had no way back, which is what let an hourglass
# outlive its background work by an hour and change.
hk prompt; hk stop
printf '%s' "{\"pid\":$LIVEPID,\"sessionId\":\"s1\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 ))}" > "/tmp/fakesup/$LIVEPID.json"
"$REPO/scripts/navigator.sh" watch "$T" s1 1; ck "watch: done -> bg (shell)" "$(st)/$(lb)" "bg/bg shell"
# a supervisor that reports plain busy keeps the vaguer label
printf '%s' "{\"pid\":$LIVEPID,\"sessionId\":\"s1\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 ))}" > "/tmp/fakesup/$LIVEPID.json"
tmux set -p -t "$T" @claude_tabs_state done; tmux set -w -t "$T" @claude_tabs_state done
"$REPO/scripts/navigator.sh" watch "$T" s1 1; ck "watch: done -> bg (busy)" "$(st)/$(lb)" "bg/busy"
# ...and back again once the work settles, which the old recheck could not do.
printf '%s' "{\"pid\":$LIVEPID,\"sessionId\":\"s1\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 ))}" > "/tmp/fakesup/$LIVEPID.json"
"$REPO/scripts/navigator.sh" watch "$T" s1 1; ck "watch: bg -> done when it settles" "$(st)/$(lb)" "done/done"
# It must never clear anything but an hourglass.
tmux set -p -t "$T" @claude_tabs_state wait; tmux set -w -t "$T" @claude_tabs_state wait
"$REPO/scripts/navigator.sh" watch "$T" s1 1; ck "watch: leaves a red badge alone" "$(st)" "wait"
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
# A session file outlives the process it describes. Without a liveness check
# the watcher would believe a dead session's "shell" forever and re-arm
# against it until its tick budget ran out.
sleep 120 & wpid=$!
printf '%s' "{\"pid\":$wpid,\"sessionId\":\"lv\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 ))}" > "/tmp/fakesup/$wpid.json"
tmux set -p -t "$T" @claude_tabs_state done
"$REPO/scripts/navigator.sh" watch "$T" lv 1
ck "watch: a live session's shell raises the hourglass" "$(st)" "bg"
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
"$REPO/scripts/navigator.sh" watch "$T" lv 1
ck "watch: a dead session's stale file does not pin it" "$(st)" "done"
rm -f "/tmp/fakesup/$wpid.json"
# The tab and the popup must never disagree. They are separate renderers over
# the same pane options — the window format reads them directly, agents.sh
# reads them with `show -pqv` — so a writer that updates one and not the other
# would go unnoticed until a user saw two different answers on one screen.
# Fixtures from earlier checks would otherwise be found first by the sessionId
# grep, and the assertion below compares PANE state with the popup's row for
# that same pane — comparing against the window would instead measure the
# aggregate, which a sibling pane's stale badge can decide.
rm -f /tmp/fakesup/*.json
sleep 120 & wpid=$!
xsess="$(tmux display -p -t "$T" '#{session_name}:#{window_id}.#{pane_id}')"
printf '%s' "{\"pid\":$wpid,\"sessionId\":\"xs\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$xsess\"}" > "/tmp/fakesup/$wpid.json"
tmux set -p -t "$T" @claude_tabs_state done
"$REPO/scripts/navigator.sh" watch "$T" xs 1
ck "tab and popup agree while work runs" \
	"$(st)/$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' -v p="$T" '$2=="live" && $3==p {print $9}')" "bg/bg"
printf '%s' "{\"pid\":$wpid,\"sessionId\":\"xs\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$xsess\"}" > "/tmp/fakesup/$wpid.json"
"$REPO/scripts/navigator.sh" watch "$T" xs 1
ck "tab and popup agree after it settles" \
	"$(st)/$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' -v p="$T" '$2=="live" && $3==p {print $9}')" "done/done"
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; rm -f "/tmp/fakesup/$wpid.json"
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
rm -f /tmp/fakesup/*.json
# --- window aggregate + end handoff
hk prompt; hk stop
tmux split-window -t alpha:1 -d 'sleep 200'; P2=$(tmux list-panes -t alpha:1 -F '#{pane_id}' | grep -v "^$T$" | head -1)
printf '{"session_id":"s2","tool_name":"Write"}' | TMUX_PANE=$P2 "$REPO/hooks/claude-tabs.sh" permission
ck "window aggregates wait" "$(ws)" "wait"
hk prompt; hk stop; ck "done does not mask wait" "$(ws)" "wait"
hk end; sleep 3.5
ck "end hands window to sibling" "$(ws)" "wait"
# --- sweep
printf '{"session_id":"s2"}' | TMUX_PANE=$P2 "$REPO/hooks/claude-tabs.sh" stop
tmux kill-pane -t "$P2" 2>/dev/null; sleep 0.3
"$REPO/scripts/navigator.sh" sweep
ck "sweep clears orphan window" "$(tmux show -wqv -t alpha:1 @claude_tabs_state 2>/dev/null)" ""

# --- badge injection + idempotency + notice segment
tmux setw -g window-status-format '#[default] #I #[default] #W '
tmux setw -g window-status-current-format '#[default] #I #[default] #W#{?window_zoomed_flag,*Z,} '
"$REPO/claude-tabs.tmux" >/dev/null 2>&1; "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "glyph seg idempotent" "$(tmux show -gv window-status-format | grep -o '#{?@claude_tabs_wglyph,'|wc -l|tr -d ' ')" "1"
# The notice lives on the RIGHT by default now, so this reads the side it is
# actually spliced into — two loads must still leave exactly one segment.
ck "notice seg idempotent" "$(tmux show -gv status-right | grep -o '#{?@claude_tabs_notice,'|wc -l|tr -d ' ')" "1"
T=$(tmux list-panes -t alpha:1 -F '#{pane_id}'|head -1)
# The two loads above each fired a backgrounded `sync force`, and with the
# fake supervisor dir still empty those fall through to the CLI, which is slow
# enough to land in the middle of this check and rebuild the window from panes
# that have no badge yet. Let them finish before asking what is on the tab;
# whether a reconcile may overrule a LIVE badge is the freshness tests' job,
# and it is measured there rather than raced here.
sleep 2
printf '{"session_id":"s9","tool_name":"Edit"}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" tool
r="$(tmux display -p -t alpha:1 '#{E:window-status-current-format}' | sed 's/#\[[^]]*\]//g')"
case "$r" in *"🔧"*"Edit"*) ck "badge renders" ok ok;; *) ck "badge renders" "$r" "🔧..Edit";; esac
# A pane holding a state with no glyph must not win the window aggregate and
# publish an empty one. The formats read window-only names, so an empty
# aggregate is not masked by the pane value any more — the tab simply lost its
# badge. This reproduced about one run in three before the guard.
BLANKP=$(tmux split-window -d -t "$T" -P -F '#{pane_id}' 'sleep 200')
tmux set -p -t "$BLANKP" @claude_tabs_state wait     # state only: no glyph
printf '{"session_id":"s9b","tool_name":"Edit"}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" tool
ck "a glyphless pane cannot blank the window badge" \
	"$([ -n "$(tmux show -wqv -t alpha:1 @claude_tabs_wplain)" ] && echo shown || echo blank)" "shown"
"$REPO/scripts/navigator.sh" recompute "$T"
ck "recompute will not publish an empty aggregate either" \
	"$([ -n "$(tmux show -wqv -t alpha:1 @claude_tabs_wplain)" ] && echo shown || echo blank)" "shown"
tmux kill-pane -t "$BLANKP" 2>/dev/null
# --- hook surgery
tmux set-hook -g after-select-window 'display -p usercmd' 2>/dev/null
"$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "user hook survives" "$(tmux show -g after-select-window | grep -c usercmd)" "1"
ck "ours added once" "$(tmux show -g after-select-window | grep -c "$REPO")" "1"
tmux set -g @claude-tabs-self-heal off; "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "off removes ours" "$(tmux show -g after-select-window 2>/dev/null | grep -c "$REPO")" "0"
tmux set -gu @claude-tabs-self-heal
# a tpm-style load path carries a doubled slash; the de-duplicator must still
# recognise its own hook, or every reload appends another one
"$REPO/claude-tabs.tmux" >/dev/null 2>&1
bash "$(dirname "$REPO")//$(basename "$REPO")/claude-tabs.tmux" >/dev/null 2>&1
ck "doubled-slash reload does not duplicate" "$(tmux show -g after-select-window | grep -c navigator)" "1"
# --- migration (empty cwd field must not shift)
mkdir -p "$XDG_DATA_HOME/tmux-claude-tabs"
printf '111\tm2\t\tclear\t/tmp/t\n' > "$XDG_DATA_HOME/tmux-claude-tabs/history.tsv"
"$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "migration verbatim" "$(cat "$SPOOL/m2" 2>/dev/null)" "$(printf '111\tm2\t\tclear\t/tmp/t')"
# --- hooks/install.sh (needs jq)
S=/tmp/settings.json; echo '{}' > "$S"
"$REPO/hooks/install.sh" --settings "$S" --quiet
ck "install wires 13 events" "$(jq '.hooks|keys|length' "$S")" "13"
# Keys alone would pass with the wrong command, label or timeout in every one
# of them. Assert the shape: 13 entries, each one command pointing at OUR hook
# with a 5s timeout, and the labels the hook actually dispatches on.
ck "every entry runs our hook with timeout 5" \
	"$(jq '[.hooks[][].hooks[] | select((.command|contains("hooks/claude-tabs.sh")) and .timeout == 5 and .type == "command")] | length' "$S")" "13"
ck "the labels are the ones the hook dispatches on" \
	"$(jq -r '[.hooks[][].hooks[].command | sub(".* ";"")] | sort | join(" ")' "$S")" \
	"compact end error notify permission post post prompt start stop subagent subagent-done tool"
env -u TMUX "$REPO/hooks/install.sh" --uninstall --settings "$S" --quiet
ck "uninstall clean" "$(jq -c . "$S")" "{}"


# --- supervisor_usable: fitness, not existence
: > /tmp/sup-usable.sh
sed -n "/^supervisor_usable()/,/^}/p" "$REPO/scripts/navigator.sh" > /tmp/sup-usable.sh
# Two ways this whole block can end up measuring nothing, both reproduced.
# (1) The extraction is a text match on the definition line, so a purely
# cosmetic reformat ("supervisor_usable () {") empties the file — and every
# check below then passes for the wrong reason, because an undefined function
# exits 127 and 127 reads here as "no".
# (2) They run against a COPY, so navigator.sh can stop calling the real one:
# with all three call sites replaced by constants the function was dead code
# and the suite still scored its clean 186/0/8.
# The count is pinned rather than floored on purpose — "at least one" would
# have stayed green through two thirds of that mutation.
ck "usable: the extraction found the function" \
	"$(grep -c '^supervisor_usable()' /tmp/sup-usable.sh)" "1"
ck "usable: navigator.sh still calls it" \
	"$(grep -v '^[[:space:]]*#' "$REPO/scripts/navigator.sh" | grep -c '[[:space:]]supervisor_usable')" "3"
usable() { ( . "$REPO/scripts/helpers.sh"; . /tmp/sup-usable.sh; supervisor_usable && echo yes || echo no ); }
rm -f /tmp/fakesup/*.json
ck "usable: empty dir" "$(usable)" "no"
printf '%s' "{\"pid\":1,\"sessionId\":\"u1\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"x:@1.%9999\"}" > /tmp/fakesup/1.json
ck "usable: foreign pane" "$(usable)" "no"
# the session name must match this server's, or the cross-server guard
# (a pane id means nothing without it) correctly drops the row
# real supervisor format: "Session:@window.%pane"
wsess="$(tmux display -p -t "$T" '#{session_name}:#{window_id}.#{pane_id}')"
fixpid; FP2=$FIXPID
printf '%s' "{\"pid\":$FP2,\"sessionId\":\"u2\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$FP2.json"
ck "usable: our pane" "$(usable)" "yes"
# --- sync keeps the "bg shell" label instead of overwriting it with "busy"
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null; tmux set -wu -t "$T" @claude_tabs_state 2>/dev/null
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" sync force
ck "sync labels shell as bg shell" "$(st)/$(lb)" "bg/bg shell"
# --- a session blocked on input while our badge says idle must go red
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null; tmux set -wu -t "$T" @claude_tabs_state 2>/dev/null
hk start   # SessionStart -> idle, the state a resumed session sits in
fixpid; FP3=$FIXPID
printf '%s' "{\"pid\":$FP3,\"sessionId\":\"u3\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$FP3.json"
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" sync force
ck "idle + supervisor waiting -> red" "$(st)/$(lb)" "wait/needs you"
rm -f /tmp/fakesup/*.json
rm -f /tmp/fakesup/*.json

# --- a stale "shell" must not overrule a newer hook badge (the ✅⇄⏳ flapper).
# Claude writes statusUpdatedAt only when the status CHANGES, so a background
# task it never reaped pins "shell" for hours. Seen live at 2h09m on a session
# sitting at an idle prompt: every sync flipped the ✅ a hook had just written
# back to ⏳, the next hook wrote ✅ again, forever.
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null; tmux set -wu -t "$T" @claude_tabs_state 2>/dev/null
old_ms=$(( ($(date +%s) - 7200) * 1000 ))
fixpid; FP9=$FIXPID
printf '%s' "{\"pid\":$FP9,\"sessionId\":\"u9\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$old_ms,\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$FP9.json"
hk stop    # a hook says done, right now — newer evidence than the supervisor's
ck "hook stamps @claude_tabs_seen on a terminal state" \
	"$([ -n "$(tmux show -pqv -t "$T" @claude_tabs_seen)" ] && echo yes || echo no)" yes
tmux set -gu @claude_tabs_synced_at; "$REPO/scripts/navigator.sh" sync force
ck "stale shell does not overrule a fresher done" "$(st)" "done"
# ...while a shell newer than the hook badge still must.
printf '%s' "{\"pid\":$FP9,\"sessionId\":\"u9\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( ($(date +%s) + 60) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$FP9.json"
tmux set -gu @claude_tabs_synced_at; "$REPO/scripts/navigator.sh" sync force
ck "fresh shell still rescues a done badge" "$(st)/$(lb)" "bg/bg shell"
# ...and it must arm a watcher while doing so. Painting the hourglass from a
# reconcile without one is what left a tab reading "still working" all night:
# the hook's paths arm one, this path did not, and nothing else lowers it.
ck "a reconcile that paints the hourglass arms a watcher" \
	"$([ -n "$(tmux show -pqv -t "$T" @claude_tabs_watch)" ] && echo armed || echo none)" "armed"
rm -f /tmp/fakesup/*.json


# --- review findings: regressions for each fixed defect
# F1: the hook must survive stock bash 3.2 (printf -v leaves stamp UNSET there)
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3'; then
	tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
	printf '%s' '{"session_id":"b32","tool_name":"Bash"}' | TMUX_PANE=$T /bin/bash "$REPO/hooks/claude-tabs.sh" tool >/dev/null 2>&1
	ck "bash 3.2: hook writes a badge" "$(st)" "tool"
else
	sk "bash 3.2: no 3.x at /bin/bash"
fi
# F2: a red badge the supervisor reports as idle must clear (Esc'd permission prompt)
tmux set -p -t "$T" @claude_tabs_state wait; tmux set -w -t "$T" @claude_tabs_state wait
tmux set -p -t "$T" @claude_tabs_at 1
fixpid; FP4=$FIXPID
printf '%s' "{\"pid\":$FP4,\"sessionId\":\"u4\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$FP4.json"
tmux set -gu @claude_tabs_synced_at; "$REPO/scripts/navigator.sh" sync force
ck "stuck red clears when supervisor is idle" "$(st)" "done"
rm -f /tmp/fakesup/*.json
# F3: a theme with neither #W nor #T must still get a badge (catppuccin)
tmux setw -g window-status-format '#[bg=blue]#{@ctp_num}#[bg=black]#{@ctp_text}'
"$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "themeless-anchor format still spliced" \
	"$(tmux show -gv window-status-format | grep -o '#{?@claude_tabs_wglyph,' | wc -l | tr -d ' ')" "1"
# F4: menu item names must not carry a live #() into tmux
rm -f /tmp/ct-menu-pwn
tmux set -p -t "$T" @claude_tabs_label '#(touch /tmp/ct-menu-pwn)x'
CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" >/dev/null 2>&1
ck "no command execution from a crafted label" "$([ -f /tmp/ct-menu-pwn ] && echo pwned || echo safe)" "safe"
# The other half of that surface — the display-menu ITEM NAMES navigator.sh
# builds, which tmux format-expands — is driven for real further down, next to
# the rest of the menu checks. It used to live here as a grep for the doubling
# expression, and a grep is satisfied by a comment: with the doubling deleted
# and the expression preserved as a comment the suite stayed green.
# F5: the THIRD half of that surface, and the one nothing looked at: msg().
# display-message format-expands its argument too, and every navigator message
# goes through this one function carrying something from outside — a cwd out of
# a supervisor file, a session name, a tool name. A directory called
# `#(touch …)` ran that command on the way to reporting it was gone. Measured
# with the doubling deleted: all 220 checks green.
#
# Driven the way the menu is, and for the same reason: this suite's client is a
# control-mode one, and tmux runs no #() job for it — so a message sent HERE is
# called safe whether the defence exists or not. Record the argv instead, then
# put that string through tmux's own expander on a throwaway server.
#
# Its own shim, matching `display-message` only when it is not a `-p` QUERY:
# the jump scan sends a batch that starts `display-message -p`, and swallowing
# that would break a later check rather than measure this one.
CT_SHIM_MSG=/tmp/ct-shim-msg; rm -rf "$CT_SHIM_MSG"; mkdir -p "$CT_SHIM_MSG"
cat >"$CT_SHIM_MSG/tmux" <<EOF
#!/bin/sh
if [ "\$1" = display-message ] && [ "\$2" != -p ]; then
	printf '%s\n' "\$@" >>"\${CT_MSG_LOG:-/dev/null}"; exit 0
fi
exec $(type -P tmux) "\$@"
EOF
chmod +x "$CT_SHIM_MSG/tmux"
rm -f /tmp/ct-msg-pwn /tmp/ct-msg-args
CT_MSG_LOG=/tmp/ct-msg-args PATH="$CT_SHIM_MSG:$PATH" \
	"$REPO/scripts/navigator.sh" new '' '/nonexistent/#(touch /tmp/ct-msg-pwn)x' >/dev/null 2>&1
ck "a crafted directory reaches display-message with its # doubled" \
	"$(grep -c '##(touch /tmp/ct-msg-pwn)x' /tmp/ct-msg-args 2>/dev/null || true)" "1"
ct_mexp="$CLAUDE_TABS_TEST_SOCKET-msgexpand"
env -u TMUX tmux -L "$ct_mexp" kill-server 2>/dev/null
env -u TMUX tmux -L "$ct_mexp" -f /dev/null new-session -d 'sleep 30' 2>/dev/null
ct_mline="$(grep -m1 '(touch /tmp/ct-msg-pwn)x' /tmp/ct-msg-args 2>/dev/null)"
# Expanded REPEATEDLY, not once. The job runs in the background and the first
# expansion comes back empty at once, so the file is what to wait for — but a
# single expansion also loses to a server that is still coming up, and this
# check then reports "safe" about a string that is not: measured 1 run in 4
# with the doubling deleted. Re-expanding covers both, and a mutant trips it on
# the first or second pass; only the healthy case pays the whole budget.
for _i in 1 2 3 4 5 6 7 8 9 10; do
	env -u TMUX tmux -L "$ct_mexp" display-message -p "$ct_mline" >/dev/null 2>&1
	[ -f /tmp/ct-msg-pwn ] && break
	sleep 0.3
done
ck "...and the message survives tmux's format expander" \
	"$([ -f /tmp/ct-msg-pwn ] && echo pwned || echo safe)" "safe"
env -u TMUX tmux -L "$ct_mexp" kill-server 2>/dev/null
rm -f /tmp/ct-msg-args /tmp/ct-msg-pwn
# F6: supervisor files WITH a trailing newline must not collapse into one row.
# Two DIFFERENT panes on purpose: rows for the same pane are deliberately
# collapsed now (see the bg-task tests below), which would mask the gluing.
rm -f /tmp/fakesup/*.json
tmux split-window -d -t alpha:1 'sleep 200' 2>/dev/null
NLP2=$(tmux list-panes -t alpha:1 -F '#{pane_id}' | grep -v "^$T$" | head -1)
wsess2="$(tmux display -p -t "$NLP2" '#{session_name}:#{window_id}.#{pane_id}')"
fixpid; FP7=$FIXPID
fixpid; FP8=$FIXPID
printf '{"pid":%s,"sessionId":"nl1","kind":"interactive","status":"idle","cwd":"/tmp/a","statusUpdatedAt":1,"tmux":"%s"}\n' "$FP7" "$wsess" > "/tmp/fakesup/$FP7.json"
printf '{"pid":%s,"sessionId":"nl2","kind":"interactive","status":"idle","cwd":"/tmp/b","statusUpdatedAt":1,"tmux":"%s"}\n' "$FP8" "$wsess2" > "/tmp/fakesup/$FP8.json"
ck "trailing newlines do not glue sessions" "$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' '$2=="live"' | wc -l | tr -d ' ')" "2"
tmux kill-pane -t "$NLP2" 2>/dev/null

# --- background tasks: the pane's own record is idle while its bg descendant
# works. Claude Code 2.1.x runs a background task as its own session, kind
# "bg", with "tmux":"None" and a pid descended from the TUI's, on a tty that is
# not a pane. The only record naming the pane then says idle — and the tab read
# "done" for 29 minutes while a task was demonstrably running. Measured live.
rm -f /tmp/fakesup/*.json /tmp/ct-tui.pid /tmp/ct-bg.pid
if ! ps eww -p $$ 2>/dev/null | grep -q 'TMUX='; then
	# macOS hides platform-binary (/bin/bash) environments from ps eww, so on
	# an all-/bin/bash ancestry the hook's TMUX walk can see nothing and these
	# checks can never pass. In production the TMUX holder is Claude Code's
	# own process, which is visible; here it would be this very shell.
	sk "bg-ancestry checks: ps eww cannot see this shell's environment"
else
# A pane whose process has a child with NO controlling terminal, exactly the
# shape the real thing has: the walk must skip the "??" and take the parent's.
tmux split-window -d -t alpha:1 \
	"bash -c 'python3 -c \"import os,time; os.setsid(); time.sleep(200)\" & echo \$! > /tmp/ct-bg.pid; echo \$\$ > /tmp/ct-tui.pid; sleep 200'" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s /tmp/ct-bg.pid ] && [ -s /tmp/ct-tui.pid ] && break; sleep 0.3; done
BGP=$(tmux list-panes -t alpha:1 -F '#{pane_id}' | grep -v "^$T$" | head -1)
tuipid="$(cat /tmp/ct-tui.pid 2>/dev/null)"; bgpid="$(cat /tmp/ct-bg.pid 2>/dev/null)"
if [ -n "$BGP" ] && [ -n "$tuipid" ] && [ -n "$bgpid" ]; then
	bgsess="$(tmux display -p -t "$BGP" '#{session_name}:#{window_id}.#{pane_id}')"
	printf '{"pid":%s,"sessionId":"tui","kind":"interactive","status":"idle","cwd":"/tmp","statusUpdatedAt":%d,"tmux":"%s"}' \
		"$tuipid" "$(( $(date +%s) * 1000 ))" "$bgsess" > "/tmp/fakesup/$tuipid.json"
	printf '{"pid":%s,"sessionId":"bgtask","kind":"bg","status":"busy","cwd":"/tmp","statusUpdatedAt":%d,"tmux":"None"}' \
		"$bgpid" "$(( ($(date +%s) + 30) * 1000 ))" > "/tmp/fakesup/$bgpid.json"
	ck "a bg task is attributed to its ancestor's pane" \
		"$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' -v p="$BGP" '$2=="live" && $3==p {print $13}')" "shell"
	ck "one pane yields one row, not one per process" \
		"$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' -v p="$BGP" '$2=="live" && $3==p' | wc -l | tr -d ' ')" "1"
	# ...and the badge follows: done + a working bg task becomes the hourglass.
	tmux set -p -t "$BGP" @claude_tabs_state done; tmux set -p -t "$BGP" @claude_tabs_label done
	tmux set -pu -t "$BGP" @claude_tabs_seen 2>/dev/null
	tmux set -gu @claude_tabs_synced_at; "$REPO/scripts/navigator.sh" sync force
	ck "done + a running bg task -> hourglass" "$(st "$BGP")/$(lb "$BGP")" "bg/bg shell"
	# An idle bg task says nothing about the pane and must not speak for it.
	printf '{"pid":%s,"sessionId":"bgtask","kind":"bg","status":"idle","cwd":"/tmp","statusUpdatedAt":%d,"tmux":"None"}' \
		"$bgpid" "$(( $(date +%s) * 1000 ))" > "/tmp/fakesup/$bgpid.json"
	ck "an idle bg task does not speak for the pane" \
		"$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' -v p="$BGP" '$2=="live" && $3==p {print $13}')" "idle"
	kill "$bgpid" 2>/dev/null
	tmux kill-pane -t "$BGP" 2>/dev/null
else
	sk "bg-task fixture could not be built"
fi
rm -f /tmp/fakesup/*.json /tmp/ct-tui.pid /tmp/ct-bg.pid
fi

# --- the Stop payload's background_tasks array is authoritative about what is
# still running. Measured live: it is present and accurate at turn end,
# finished tasks vanish from it, and no Stop fires when one completes — so it
# settles what STARTED, while the watcher still owns detecting the END.
rm -f /tmp/fakesup/*.json
BGT_REAL='{"hook_event_name":"Stop","session_id":"bt1","background_tasks":[{"id":"m1","type":"monitor","status":"running","description":"live updates for artifact"},{"id":"s1","type":"shell","status":"running","description":"Sleep for 25 seconds"}],"session_crons":[]}'
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
printf '%s' "$BGT_REAL" | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" stop >/dev/null 2>&1
ck "a running shell task raises the hourglass, named" "$(st)/$(lb)" "bg/Sleep for 25 seconds"
# A monitor is not work you are waiting on. Counting it kept the hourglass up
# on sessions that were free — the supervisor's own "shell" status has the
# same blind spot, which is why this reads the array instead.
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
printf '%s' '{"hook_event_name":"Stop","session_id":"bt2","background_tasks":[{"id":"m1","type":"monitor","status":"running","description":"watching"}],"session_crons":[]}' \
	| TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" stop >/dev/null 2>&1
ck "a monitor alone does not raise the hourglass" "$(st)" "done"
# An empty array means nothing is running, whatever our own markers think.
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
printf '%s' '{"hook_event_name":"Stop","session_id":"bt3","background_tasks":[],"session_crons":[]}' \
	| TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" stop >/dev/null 2>&1
ck "an empty array means done" "$(st)" "done"
# A session_crons entry of the same shape must not be mistaken for a task —
# the first version of the scanner counted it and would have pinned a
# scheduled job as background work.
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
printf '%s' '{"hook_event_name":"Stop","session_id":"bt4","background_tasks":[],"session_crons":[{"id":"c1","type":"cron","status":"running","description":"nightly"}]}' \
	| TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" stop >/dev/null 2>&1
ck "a cron is not a background task" "$(st)" "done"
# No field at all (older Claude Code) must fall back to the per-turn markers.
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
hk prompt
printf '%s' '{"session_id":"bt5","tool_name":"Bash","tool_input":{"run_in_background":true}}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" tool >/dev/null 2>&1
printf '%s' '{"hook_event_name":"Stop","session_id":"bt5"}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" stop >/dev/null 2>&1
# Asserted as `bg`, not "bg or done": `done` is precisely what you get when the
# fallback arm is GONE, so accepting both made this unfailable. Measured — with
# the arm disabled the state flipped bg -> done and this check stayed green
# while three unrelated state-machine checks caught the regression for it.
ck "no background_tasks field degrades to the old markers" "$(st)" "bg"
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null; tmux set -wu -t "$T" @claude_tabs_state 2>/dev/null

# --- navigator order: what is running must not sink below what is finished.
# The rank used to be inverted — every active state ranked below done and idle
# — so with six finished sessions on screen the one actually working was off
# the bottom of the popup, which is the opposite of why you open it.
rm -f /tmp/fakesup/*.json
n_ms=$(( $(date +%s) * 1000 ))
mk() { printf '{"pid":%s,"sessionId":"o%s","kind":"interactive","status":"%s","cwd":"/tmp","statusUpdatedAt":%s,"tmux":"%s"}' \
	"$1" "$1" "$2" "$3" "$wsess" > "/tmp/fakesup/$1.json"; }
fixpid; FPRANK=$FIXPID
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null; tmux set -wu -t "$T" @claude_tabs_state 2>/dev/null
# One pane can only carry one row, so rank order is checked per state by
# running the pass once per state and reading the rank column.
for pair in "waiting:0" "busy:1" "shell:1" "idle:3"; do
	stt="${pair%%:*}"; want="${pair##*:}"
	mk "$FPRANK" "$stt" "$n_ms"
	ck "rank of supervisor '$stt' is $want" \
		"$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' '$2=="live"{print $1; exit}')" "$want"
	rm -f "/tmp/fakesup/$FPRANK.json"
done
# done is hook-owned, not a supervisor status: set the badge and check it ranks
# below the running states but above idle.
mk "$FPRANK" idle "$n_ms"
tmux set -p -t "$T" @claude_tabs_state done
ck "rank of a done badge is 2" \
	"$("$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' '$2=="live"{print $1; exit}')" "2"
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
rm -f /tmp/fakesup/*.json
rm -f /tmp/fakesup/*.json


# --- ultra-review findings
# U1: notice-position must strip from both sides (off removes; switching moves)
tmux set -g status-left 'L '; tmux set -g status-right ' R'
tmux set -g @claude-tabs-notice-position left;  "$REPO/claude-tabs.tmux" >/dev/null 2>&1
tmux set -g @claude-tabs-notice-position right; "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "notice moves sides, not duplicates" "$(tmux show -gv status-left | grep -c notice)/$(tmux show -gv status-right | grep -c notice)" "0/1"
tmux set -g @claude-tabs-notice-position off; "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "notice-position off removes it" "$(tmux show -gv status-left | grep -c notice)/$(tmux show -gv status-right | grep -c notice)" "0/0"
tmux set -gu @claude-tabs-notice-position
# U2: two panes of one window racing — a sibling's red must survive
tmux split-window -d -t alpha:1 'sleep 200' 2>/dev/null
RP1=$(tmux list-panes -t alpha:1 -F '#{pane_id}' | head -1)
RP2=$(tmux list-panes -t alpha:1 -F '#{pane_id}' | tail -1)
race_bad=0
for _r in 1 2 3 4 5; do
	tmux set -pu -t "$RP1" @claude_tabs_state 2>/dev/null; tmux set -pu -t "$RP2" @claude_tabs_state 2>/dev/null
	printf '%s' '{"session_id":"ra","tool_name":"Write"}' | TMUX_PANE=$RP1 "$REPO/hooks/claude-tabs.sh" permission &
	rj1=$!
	printf '%s' '{"session_id":"rb"}' | TMUX_PANE=$RP2 "$REPO/hooks/claude-tabs.sh" stop &
	rj2=$!
	# Named PIDs only: a bare `wait` would also wait on the control client,
	# which lives for the whole run.
	wait "$rj1" "$rj2"
	[ "$(tmux show -wqv -t alpha:1 @claude_tabs_state)" = wait ] || race_bad=$((race_bad + 1))
done
ck "concurrent siblings keep the red" "$race_bad" "0"
tmux kill-pane -t "$RP2" 2>/dev/null
T=$(tmux list-panes -t alpha:1 -F '#{pane_id}' | head -1)
# U3: sync must actually clear the stamp (a stray ; used to end the tmux chain)
tmux set -p -t "$T" @claude_tabs_state thinking; tmux set -p -t "$T" @claude_tabs_at 1
tmux set -w -t "$T" @claude_tabs_state thinking
fixpid; FP6=$FIXPID
printf '%s' "{\"pid\":$FP6,\"sessionId\":\"u6\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$T" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$FP6.json"
tmux set -gu @claude_tabs_synced_at; "$REPO/scripts/navigator.sh" sync force
ck "sync clears the stamp" "$(st)/$(tmux show -pqv -t "$T" @claude_tabs_at)" "done/"
rm -f /tmp/fakesup/*.json

# --- prefix J steps through every pane that needs you, not just the last one.
# @claude_tabs_last is a single slot, so with three sessions waiting it could
# only ever reach one of them and the next event overwrote it.
# Pane ids come from new-window -P, not `list-panes | tail`: new-window takes
# the first FREE index, so the newest window is not necessarily the last row.
JW1=$T
JW2=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
JW3=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
JTRAP=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
tmux set -p -t "$JW1" @claude_tabs_state wait
tmux set -p -t "$JW2" @claude_tabs_state error
tmux set -p -t "$JW3" @claude_tabs_state plan
# The trap: a WINDOW-level badge on a pane with none of its own. #{@x} in a
# format falls back pane -> window, so reading it that way would sweep this
# pane into the cycle even though no Claude runs in it.
tmux set -w -t "$JTRAP" @claude_tabs_state wait
# Expected order is screen order, computed the same way the code computes it,
# rather than assumed from the order the fixture happened to create them in.
# Spaces, not \t: tmux does not expand backslash escapes in a format string,
# so '#{a}\t#{b}' emits a literal backslash-t and every field parse downstream
# silently reads the whole line.
jorder="$(tmux list-panes -a -F '#{window_index} #{pane_index} #{pane_id}' |
	sort -k1,1n -k2,2n | awk '{print $3}' |
	grep -xE "$JW1|$JW2|$JW3" | tr '\n' ' ')"
jfirst="${jorder%% *}"
# Park on a pane that is NOT in the cycle, so the walk starts at the first
# entry rather than advancing from wherever the harness happened to be. That
# also proves JTRAP really is excluded: if the fallback trap were live, the
# cursor would find it here and the sequence would start one step along.
# stdout discarded: an earlier check deliberately leaves a global
# after-select-window hook installed (it verifies our hook surgery does not
# clobber a user's), and it prints on every select-window from here on.
tmux select-window -t "$JTRAP" >/dev/null; tmux select-pane -t "$JTRAP"
tmux set -gu @claude_tabs_jump_cursor
seq=""
for _ in 1 2 3 4; do
	"$REPO/scripts/navigator.sh" jump-last "" >/dev/null 2>&1
	seq="$seq$(tmux show -gqv @claude_tabs_jump_cursor) "
done
ck "prefix J cycles every pane that needs you" "$seq" "$jorder$jfirst "
# grep, not a case-in-$( ): bash 3.2 mis-parses that construct at run time,
# and this very line once took the whole suite down on stock macOS.
ck "a window-level badge does not join the cycle" \
	"$(printf '%s' " $seq " | grep -qF " $JTRAP " && echo swept || echo excluded)" "excluded"
# Standing on one of them advances instead of re-selecting it.
jsecond="$(printf '%s' "${jorder#* }" | cut -d' ' -f1)"
tmux select-window -t "$jfirst" >/dev/null; tmux select-pane -t "$jfirst"
tmux set -gu @claude_tabs_jump_cursor
"$REPO/scripts/navigator.sh" jump-last "" >/dev/null 2>&1
ck "J advances from the pane you are on" "$(tmux show -gqv @claude_tabs_jump_cursor)" "$jsecond"
# Nothing blocked: the key must not move you. It used to fall back to a global
# slot holding the last pane that spoke up, which silently switched tmux
# SESSION to land on a pane whose last event was two days old.
for pp in "$JW1" "$JW2" "$JW3"; do tmux set -p -t "$pp" @claude_tabs_state done 2>/dev/null; done
tmux set -wu -t "$JTRAP" @claude_tabs_state 2>/dev/null
tmux select-window -t "$JW3" >/dev/null; tmux select-pane -t "$JW3"
tmux set -g @claude_tabs_last "$JW2"     # a stale pointer must be ignored now
tmux set -gu @claude_tabs_jump_cursor
"$REPO/scripts/navigator.sh" jump-last "" >/dev/null 2>&1
ck "with nothing blocked J stays put" "$(tmux display -p '#{pane_id}')" "$JW3"
ck "a stale @claude_tabs_last no longer teleports" \
	"$(tmux show -gqv @claude_tabs_jump_cursor)" ""
for pp in "$JW2" "$JW3" "$JTRAP"; do tmux kill-pane -t "$pp" 2>/dev/null; done
tmux set -gu @claude_tabs_last; tmux set -gu @claude_tabs_jump_cursor

# --- a background task's hook has no $TMUX and no $TMUX_PANE, and is the only
# thing that knows the pane's background work is over. Dropping it left the
# hourglass up until something else happened to reconcile — measured at 1h52m
# on a live session. It must now find the server through its ancestors and ask
# for a reconcile.
if ! ps eww -p $$ 2>/dev/null | grep -q 'TMUX='; then
	# Same ps-eww limitation as the attribution block above.
	sk "bg-reconcile checks: ps eww cannot see this shell's environment"
else
rm -f /tmp/fakesup/*.json
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
# An interactive record naming $T, so the sync the bg hook fires has a badge
# to seed — that seeding is what the strengthened assertion below measures.
printf '%s' "{\"pid\":$LIVEPID,\"sessionId\":\"bgseed\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$T" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$LIVEPID.json"
tmux set -gu @claude_tabs_synced_at
cat > /tmp/ct-bg-inner.sh <<INNER
#!/usr/bin/env bash
printf '%s' '{"session_id":"bgx"}' | "$REPO/hooks/claude-tabs.sh" stop
INNER
chmod +x /tmp/ct-bg-inner.sh
# The parent carries \$TMUX, the child has neither — exactly the shape Claude
# Code gives a background session. The trailing "; :" matters: with a single
# command bash execs it and replaces itself, and the parent holding \$TMUX
# would be gone before the walk could see it.
TMUX="$(tmux display -p '#{socket_path},#{pid},0')" TMUX_PANE="$T" \
	bash -c 'env -u TMUX -u TMUX_PANE /tmp/ct-bg-inner.sh; :'
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
	[ -n "$(tmux show -gqv @claude_tabs_synced_at)" ] && break
	sleep 0.5
done
ck "a background session's hook reconciles through its ancestor" \
	"$([ -n "$(tmux show -gqv @claude_tabs_synced_at)" ] && echo synced || echo silent)" "synced"
# ...and the sync it fired did real work: the pane badge got seeded from the
# fixture. Asserting only synced_at proved a sync ran, not that it repaired
# anything — a sync that failed instantly would still have set the stamp.
# Polled: synced_at is stamped at the START of the pass, rows land later.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
	[ "$(st)" = idle ] && break
	sleep 0.5
done
ck "the reconcile it fired seeded the badge" "$(st)" "idle"
rm -f /tmp/ct-bg-inner.sh
tmux set -gu @claude_tabs_synced_at
# That ancestor-fired sync force is still finishing here: it execs a sweep
# whose pane snapshot predates the aggregation fixtures below, and losing
# that race let the sweep wipe CW2/CW3 mid-check — seen once in six runs.
# The badge lands mid-pass, so give the tail (window rebuild + sweep) room.
sleep 2
fi

# --- a window holding several Claudes must not look like one holding a single
# Claude. The worst state still wins the glyph; the count rides after it.
CW1=$T
CW2=$(tmux split-window -d -t "$CW1" -P -F '#{pane_id}' 'sleep 200')
CW3=$(tmux split-window -d -t "$CW1" -P -F '#{pane_id}' 'sleep 200')
tmux set -p -t "$CW1" @claude_tabs_state done
tmux set -p -t "$CW1" @claude_tabs_glyph  '#[fg=colour32,bold]OK#[nobold]'
tmux set -p -t "$CW1" @claude_tabs_plain  '#[bold]OK#[nobold]'
tmux set -p -t "$CW2" @claude_tabs_state done
tmux set -p -t "$CW2" @claude_tabs_glyph  '#[fg=colour32,bold]OK#[nobold]'
tmux set -p -t "$CW3" @claude_tabs_state wait
tmux set -p -t "$CW3" @claude_tabs_glyph  '#[fg=colour31,bold]RED#[nobold]'
tmux set -p -t "$CW3" @claude_tabs_plain  '#[bold]RED#[nobold]'
# The winning pane needs a LABEL. Without one both sides of the label check
# below were the empty string, and recompute_window's whole label propagation
# could be deleted with all 188 checks still green — while claude-tabs.tmux
# renders '#{?@claude_tabs_wglyph, . #{@claude_tabs_wlabel},}', so the text on
# every repaired tab would have silently vanished.
tmux set -p -t "$CW3" @claude_tabs_label  'needs you'
"$REPO/scripts/navigator.sh" recompute "$CW1"
ck "the worst state still wins the window glyph" \
	"$(tmux show -wqv -t "$CW1" @claude_tabs_state)" "wait"
ck "three Claudes in a window show the count" \
	"$(tmux show -wqv -t "$CW1" @claude_tabs_wglyph)" '#[fg=colour31,bold]RED#[nobold]3'
ck "the plain glyph carries it too (menu fallback)" \
	"$(tmux show -wqv -t "$CW1" @claude_tabs_wplain)" '#[bold]RED#[nobold]3'
ck "the label is left alone, the digit is not repeated" \
	"$(tmux show -wqv -t "$CW1" @claude_tabs_wlabel)" "needs you"
# ...and it must REACH THE SCREEN. Every check above reads the option; the
# status line reads a format, and #{@foo} there resolves pane -> window, so a
# name the panes also set is answered by the window's ACTIVE pane. The
# aggregate "RED3" sat in the window option while the tab rendered the active
# pane's "OK" — the count never appeared for any window whose active pane had
# a badge, which is nearly all of them. Expanding the format is what a client
# does; verified identical to a real attached client's screen.
CWW=$(tmux display -p -t "$CW1" '#{window_id}')
ck "the aggregate reaches the rendered tab, not just the option" \
	"$(tmux display-message -p -t "$CWW" '#{E:window-status-format}' | grep -c 'RED#\[nobold\]3')" "1"
ck "the rendered tab does not fall back to the active pane" \
	"$(tmux display-message -p -t "$CWW" '#{E:window-status-format}' | grep -c 'OK#\[nobold\]')" "0"
# Down to one Claude: no count at all, not a "1".
tmux set -pu -t "$CW2" @claude_tabs_state; tmux set -pu -t "$CW3" @claude_tabs_state
"$REPO/scripts/navigator.sh" recompute "$CW1"
ck "a single Claude gets no count" \
	"$(tmux show -wqv -t "$CW1" @claude_tabs_wglyph)" '#[fg=colour32,bold]OK#[nobold]'
tmux kill-pane -t "$CW2" 2>/dev/null; tmux kill-pane -t "$CW3" 2>/dev/null
for o in @claude_tabs_glyph @claude_tabs_plain @claude_tabs_label @claude_tabs_state \
	@claude_tabs_wglyph @claude_tabs_wplain @claude_tabs_wlabel; do
	tmux set -pu -t "$CW1" "$o" 2>/dev/null; tmux set -wu -t "$CW1" "$o" 2>/dev/null
done
# U4: --uninstall --tmux-conf removes the line instead of appending one
printf '# mine\nset -g mouse on\n' > /tmp/ct-conf.tmux; echo '{}' > /tmp/ct-set.json
"$REPO/hooks/install.sh" --settings /tmp/ct-set.json --tmux-conf /tmp/ct-conf.tmux --quiet
env -u TMUX "$REPO/hooks/install.sh" --uninstall --settings /tmp/ct-set.json --tmux-conf /tmp/ct-conf.tmux --quiet
ck "uninstall removes the tmux.conf line" "$(grep -c claude-tabs /tmp/ct-conf.tmux)" "0"
ck "uninstall keeps the user's config" "$(grep -c 'mouse on' /tmp/ct-conf.tmux)" "1"
# ...and the round trip must be a round trip. Install writes a blank separator,
# its own comment and the run-shell line; the removal only ever took the last
# two, so every cycle left one more empty line behind and a one-line tmux.conf
# was six lines after five rounds. Three cycles, compared as BYTES — counting
# our line finds nothing wrong with a file that is growing.
printf '# mine\nset -g mouse on\n' > /tmp/ct-cyc.tmux; cp /tmp/ct-cyc.tmux /tmp/ct-cyc.orig
echo '{}' > /tmp/ct-cyc.json
for _c in 1 2 3; do
	env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-cyc.json --tmux-conf /tmp/ct-cyc.tmux --quiet >/dev/null 2>&1
	env -u TMUX "$REPO/hooks/install.sh" --uninstall --settings /tmp/ct-cyc.json --tmux-conf /tmp/ct-cyc.tmux --quiet >/dev/null 2>&1
done
ck "three install/uninstall cycles leave tmux.conf byte-identical" \
	"$(same_bytes /tmp/ct-cyc.tmux /tmp/ct-cyc.orig && echo identical || wc -l < /tmp/ct-cyc.tmux | tr -d ' ')" "identical"
# The floor: a cycle that appends nothing would also compare equal.
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-cyc.json --tmux-conf /tmp/ct-cyc.tmux --quiet >/dev/null 2>&1
ck "...because the install really does add the line each time" \
	"$(grep -c 'claude-tabs\.tmux' /tmp/ct-cyc.tmux)" "1"
rm -f /tmp/ct-cyc.tmux /tmp/ct-cyc.tmux.bak-* /tmp/ct-cyc.orig /tmp/ct-cyc.json*
# U6: the tmux.conf removal must only delete a line that is NOTHING BUT our
# run-shell invocation. Dropping any line that mentions the path next to "run"
# ate the user's own command: an if-shell wrapping our line lost its else
# branch, and a backslash-continued one lost its body and left a dangling
# continuation that breaks the next config load. The awk also has to run
# inside an `if` — as a bare command its "nothing found" exit tripped set -e,
# killed the script, and left two stray files behind.
SQ="'"
# env -u TMUX throughout: hooks/install.sh --uninstall also clears the tmux side
# (formats, bindings, hooks) when it can see a server, and these checks are
# about the FILES. Without it they quietly uninstalled the plugin from the
# suite's own server and every later assertion failed.
conf_case() { # conf_case <file-content>
	printf '%s' "$1" > /tmp/ct-u6.tmux
	echo '{}' > /tmp/ct-u6.json
	U6OUT="$(env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u6.json --tmux-conf /tmp/ct-u6.tmux --uninstall 2>&1)"
	U6RC=$?
	U6BODY="$(cat /tmp/ct-u6.tmux)"
	rm -f /tmp/ct-u6.tmux.bak-* /tmp/ct-u6.tmux.tmp.* /tmp/ct-u6.json* /tmp/ct-u6.tmux
}
conf_case "set -g mouse on
run-shell \"${SQ}/p/claude-tabs.tmux${SQ}\"
set -g status on
"
ck "U6: a line of ours alone is removed" "$(printf '%s' "$U6BODY" | grep -c claude-tabs || true)" "0"
ck "U6: the user's lines survive" "$(printf '%s' "$U6BODY" | grep -c 'mouse on')" "1"

conf_case "if-shell \"[ -z \\\"\$SSH\\\" ]\" \"run-shell ${SQ}/p/claude-tabs.tmux${SQ}\" \"set -g status-right ok\"
"
ck "U6: an if-shell keeps its else branch" "$(printf '%s' "$U6BODY" | grep -c 'status-right ok')" "1"
# Matched on the blocked branch's OWN wording. "left it alone" is also what the
# installer says when it found no line of ours at all, so grepping for it could
# not tell "correctly refused to touch a larger command" from "never recognised
# the line": with the detection disabled the diagnostic degraded into "nothing
# found here" and this check stayed green.
ck "U6: and the run is reported, not performed" \
	"$(printf '%s' "$U6OUT" | grep -c 'inside a larger command')" "1"

conf_case "if-shell \"[ -z \\\"\$SSH\\\" ]\" \\\\
  \"run-shell ${SQ}/p/claude-tabs.tmux${SQ}\"
set -g status-interval 5
"
ck "U6: a continued command is not decapitated" "$(printf '%s' "$U6BODY" | grep -c 'status-interval 5')" "1"
ck "U6: its body is still there" "$(printf '%s' "$U6BODY" | grep -c 'claude-tabs.tmux')" "1"

conf_case "# see /p/claude-tabs.tmux for details
set -g mouse on
"
ck "U6: a bare mention is left alone" "$(printf '%s' "$U6BODY" | grep -c 'for details')" "1"
ck "U6: and set -e does not kill the run" "$U6RC" "0"

# U8: install+uninstall must give the user's settings.json back unchanged,
# including entries belonging to other tools. Dropping any entry whose hooks
# array came out empty also deleted a matcher-only stanza that never had one —
# legal to write, and somebody else's data.
printf '%s' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"other-tool"}]},{"matcher":"only-a-matcher"},{"hooks":[]}]},"env":{"KEEP":"yes"}}' > /tmp/ct-u8.json
cp /tmp/ct-u8.json /tmp/ct-u8-orig.json
"$REPO/hooks/install.sh" --settings /tmp/ct-u8.json --quiet >/dev/null 2>&1
ck "U8: another tool's hook survives our install" \
	"$(jq -r '[.hooks.Stop[] | select(.hooks[]?.command == "other-tool")] | length' /tmp/ct-u8.json)" "1"
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u8.json --uninstall --quiet >/dev/null 2>&1
# Named for what it measures. Both sides go through `jq -S -c`, so this is
# CONTENT identity — nothing added, nothing lost, whatever the layout. Byte
# identity is a different promise and is checked on its own below; a check
# called "byte-identically" that canonicalises both sides is the same kind of
# lie as a behaviour asserted by grepping for its source string.
ck "U8: the file round-trips with nothing added or lost" \
	"$(jq -S -c . /tmp/ct-u8.json)" "$(jq -S -c . /tmp/ct-u8-orig.json)"
rm -f /tmp/ct-u8.json* /tmp/ct-u8-orig.json

# U8b: and BYTES, for the case where the installer has nothing to change. jq is
# the only writer here, so any pass that rewrites the file reformats it even
# when it changes no meaning: a one-line "env" exploded over three lines, a BOM
# deleted, CRLF rewritten to LF — a large spurious diff in the user's own
# version control, with the backup then the only copy of their formatting.
# hooks/install.sh guards it with same_json(); nothing here noticed whether that
# guard was there. Written with a BOM and CRLF on purpose: those are the two
# jq destroys silently, and a check on a file jq would format the same way
# cannot see the difference.
printf '\357\273\277{\r\n  "env": {"KEEP": "yes"}\r\n}\r\n' > /tmp/ct-u8b.json
cp /tmp/ct-u8b.json /tmp/ct-u8b-orig.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u8b.json --uninstall --quiet >/dev/null 2>&1
ck "U8b: an uninstall with no hooks of ours leaves the bytes alone" \
	"$(same_bytes /tmp/ct-u8b.json /tmp/ct-u8b-orig.json && echo identical || echo reformatted)" "identical"
# The same on the install side: hooks already wired in, then hand-formatted the
# way a person (or another tool) would leave them.
printf '{}' > /tmp/ct-u8c.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u8c.json --quiet >/dev/null 2>&1
{ printf '\357\273\277'; sed 's/$/\r/' /tmp/ct-u8c.json; } > /tmp/ct-u8c-hand.json
cp /tmp/ct-u8c-hand.json /tmp/ct-u8c.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u8c.json --quiet >/dev/null 2>&1
ck "U8b: and a re-install with nothing to add leaves them alone too" \
	"$(same_bytes /tmp/ct-u8c.json /tmp/ct-u8c-hand.json && echo identical || echo reformatted)" "identical"
# The floor: a file it really does have to change must still be changed, or
# "left the bytes alone" is satisfied by an installer that writes nothing.
printf '{"env":{"KEEP":"yes"}}' > /tmp/ct-u8d.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u8d.json --quiet >/dev/null 2>&1
ck "U8b: ...and a file that DOES need the hooks still gets them" \
	"$(jq -r '.hooks | keys | length' /tmp/ct-u8d.json 2>/dev/null)" "13"
rm -f /tmp/ct-u8b.json* /tmp/ct-u8b-orig.json /tmp/ct-u8c.json* /tmp/ct-u8c-hand.json /tmp/ct-u8d.json*

# U9: the navigator binding must carry a pane ID, never the pane's PATH.
# run-shell format-expands its argument and #{q:} escapes sh metacharacters
# but NOT a newline (measured), so a directory whose name held one ended the
# command and ran the rest as a second one.
"$REPO/claude-tabs.tmux" >/dev/null 2>&1   # the install tests above took the tmux side down
sleep 2                                     # and its load fires a backgrounded sync force
ck "U9: the navigator key passes a pane id" \
	"$(tmux list-keys -T prefix 2>/dev/null | grep 'navigator.sh. open' | grep -c 'q:pane_id')" "1"
ck "U9: and never the path" \
	"$(tmux list-keys -T prefix 2>/dev/null | grep 'navigator.sh. open' | grep -c 'pane_current_path' || true)" "0"
# The property itself, with no directory involved: #{q:} escapes sh
# metacharacters but leaves a newline intact, so anything user-named must not
# travel through the expander. A pane id is %<digits> and cannot carry one.
tmux set -g @ct-nl-probe "$(printf 'a\nb')"
ck "U9: q: does not escape a newline" \
	"$(tmux display -p 'x #{q:@ct-nl-probe}' | wc -l | tr -d ' ')" "2"
ck "U9: a pane id expands to a single line" \
	"$(tmux display -p -t "$T" 'x #{q:pane_id}' | wc -l | tr -d ' ')" "1"
tmux set -gu @ct-nl-probe
# `open` ends in display-popup, and a popup on this suite's control-mode client
# kills the server outright — so the shim from the top of this file stands in
# for it and records the command the popup would have run. That command carries
# the RESOLVED path, which is the property: the pane id must be turned into a
# directory here rather than by run-shell's expander. Grepping navigator.sh for
# 'pane_current_path' proved nothing — with the resolution replaced by `:` and
# the name kept in a trailing comment the suite stayed green.
mkdir -p /tmp/ct-cwdprobe
# macOS symlinks /tmp to /private/tmp, so tmux reports the RESOLVED path and a
# literal "/tmp/ct-cwdprobe" never matches there. Ask the filesystem what the
# directory is actually called rather than assuming.
CWPDIR="$(cd /tmp/ct-cwdprobe && pwd -P)"
CWP=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' -c /tmp/ct-cwdprobe 'sleep 200')
CT_TMUX_LOG=/tmp/ct-open-args; : >"$CT_TMUX_LOG"
CT_TMUX_LOG="$CT_TMUX_LOG" PATH="$CT_SHIM:$PATH" \
	"$REPO/scripts/navigator.sh" open "$client" "$CWP" >/dev/null 2>&1
ck "U9: open accepts a pane id and resolves it" \
	"$(grep -c "pick .* $CWPDIR$" "$CT_TMUX_LOG")" "1"
ck "U9: and the pane id itself never reaches the popup command" \
	"$(grep -c -- "$CWP\$" "$CT_TMUX_LOG")" "0"
tmux kill-window -t "$CWP" 2>/dev/null; rm -f "$CT_TMUX_LOG"; rmdir /tmp/ct-cwdprobe 2>/dev/null
sleep 2   # `open` fires a backgrounded sync force before the popup; let it land

# U10: a mistyped numeric option must fall back, not disable every repair.
tmux set -g @claude-tabs-stale-after '20s'
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
hk prompt >/dev/null 2>&1
tmux set -gu @claude_tabs_synced_at
err="$("$REPO/scripts/navigator.sh" sync force 2>&1)"
ck "U10: a non-numeric stale-after does not error the reconcile" "${err:-clean}" "clean"
tmux set -gu @claude-tabs-stale-after

# U7: a symlinked settings.json — the shape people who keep dotfiles have.
# Renaming onto the LINK replaced it with a regular file, so the repo copy
# stopped being the one Claude Code reads; and stat reports a symlink's own
# mode (0777 on Linux), which the chmod then applied to the real file.
mkdir -p /tmp/ct-u7-dot
echo '{}' > /tmp/ct-u7-dot/settings.json
chmod 644 /tmp/ct-u7-dot/settings.json
ln -sf /tmp/ct-u7-dot/settings.json /tmp/ct-u7-link.json
"$REPO/hooks/install.sh" --settings /tmp/ct-u7-link.json --quiet >/dev/null 2>&1
ck "U7: the symlink survives the write" "$([ -L /tmp/ct-u7-link.json ] && echo link || echo replaced)" "link"
ck "U7: the real file got the hooks" \
	"$(jq -r '.hooks | length' /tmp/ct-u7-dot/settings.json 2>/dev/null)" "13"
ck "U7: and kept its own mode" \
	"$(stat -c '%a' /tmp/ct-u7-dot/settings.json 2>/dev/null || stat -f '%Lp' /tmp/ct-u7-dot/settings.json 2>/dev/null)" "644"
chmod 666 /tmp/ct-u7-dot/settings.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u7-link.json --uninstall --quiet >/dev/null 2>&1
ck "U7: a world-writable settings.json loses the write bits" \
	"$(stat -c '%a' /tmp/ct-u7-dot/settings.json 2>/dev/null || stat -f '%Lp' /tmp/ct-u7-dot/settings.json 2>/dev/null)" "644"
rm -rf /tmp/ct-u7-dot /tmp/ct-u7-link.json /tmp/ct-u7-dot/settings.json.bak-*

# U7b: the same trap on the tmux.conf side, and the commoner one — ~/.tmux.conf
# is very often a symlink into a dotfiles repo (it is on this machine). The
# uninstall stages a temp file and renames it onto the path, which replaced the
# LINK with a regular file: the git-tracked copy silently stopped being the file
# tmux reads, still holding the plugin line, and the next dotfiles deploy put it
# back.
mkdir -p /tmp/ct-u7b-dot
printf 'set -g mouse on\nrun-shell "/p/claude-tabs.tmux"\n' > /tmp/ct-u7b-dot/tmux.conf
ln -sf /tmp/ct-u7b-dot/tmux.conf /tmp/ct-u7b-link.conf
echo '{}' > /tmp/ct-u7b.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-u7b.json --tmux-conf /tmp/ct-u7b-link.conf \
	--uninstall --quiet >/dev/null 2>&1
ck "U7b: a symlinked tmux.conf is still a symlink after uninstall" \
	"$([ -L /tmp/ct-u7b-link.conf ] && echo link || echo replaced)" "link"
ck "U7b: and the file it points at is the one that got edited" \
	"$(grep -c claude-tabs /tmp/ct-u7b-dot/tmux.conf || true)" "0"
ck "U7b: the user's own line survived" \
	"$(grep -c 'mouse on' /tmp/ct-u7b-dot/tmux.conf)" "1"
rm -rf /tmp/ct-u7b-dot /tmp/ct-u7b-link.conf /tmp/ct-u7b.json*

# U5: a plugin path containing #S must not be format-expanded by run-shell.
# Checked as the property, not as a count of occurrences: counting broke the
# moment a fourth run-shell was added, which is exactly when this needs to
# still work.
ck "no run-shell uses the un-doubled plugin path" \
	"$(grep -c 'run-shell.*\$self_dir/' "$REPO/hooks/claude-tabs.sh" || true)" "0"
# The floor is load-bearing: both counts reaching zero turns the equality below
# into 0 == 0. Measured — pointing every navigator re-arm in the hook at a
# script that does not exist left this pair green with every watcher and
# deferred recompute broken.
nav_total="$(grep -c '/scripts/navigator.sh' "$REPO/hooks/claude-tabs.sh" || true)"
ck "the hook still re-arms the navigator at all" \
	"$([ "$nav_total" -ge 2 ] && echo yes || echo no)" "yes"
ck "every navigator invocation uses the doubled path" \
	"$(grep -c 'self_dir_fmt/scripts/navigator.sh' "$REPO/hooks/claude-tabs.sh")" "$nav_total"

# --- every script must PARSE under stock bash 3.2, not just the hook.
# 3.2 mis-parses a `case` inside $( ) — agents.sh was entirely dead on stock
# macOS while the suite ran only the hook under /bin/bash: the one file
# already fixed for 3.2, i.e. the one least likely to still be broken.
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3'; then
	b32bad=""
	for f in "$REPO"/scripts/*.sh "$REPO"/hooks/*.sh "$REPO"/hooks/install.sh "$REPO"/claude-tabs.tmux; do
		/bin/bash -n "$f" 2>/dev/null || b32bad="$b32bad ${f##*/}"
	done
	ck "every script parses under bash 3.2" "${b32bad:-clean}" "clean"
	# -n is not enough: 3.2 defers command-substitution parsing to execution,
	# so navigator.sh passed -n and then died at runtime. Run the two data
	# paths for real.
	ck "agents.sh RUNS under bash 3.2" \
		"$(/bin/bash "$REPO/scripts/agents.sh" >/dev/null 2>&1 && echo runs || echo dies)" "runs"
	ck "navigator sweep RUNS under bash 3.2" \
		"$(/bin/bash "$REPO/scripts/navigator.sh" sweep >/dev/null 2>&1 && echo runs || echo dies)" "runs"
	ck "navigator poll once RUNS under bash 3.2" \
		"$(/bin/bash "$REPO/scripts/navigator.sh" poll once >/dev/null 2>&1 && echo runs || echo dies)" "runs"
else
	sk "bash 3.2 parse/run checks: no 3.x at /bin/bash"
fi

# --- poll mode: the hookless path. One tick at a time (`poll once`), never
# the daemon — a live poller would repaint fixtures behind the checks' backs.
# With no fresh hook stamp the supervisor's verdict maps directly; the
# conflict arms stay reserved for machines where hooks are actually speaking.
tmux set -gu @claude_tabs_hooks_at
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
tmux set -pu -t "$T" @claude_tabs_at; tmux set -pu -t "$T" @claude_tabs_seen
tmux set -pu -t "$T" @claude_tabs_watch
# Leftover fixtures resolve to the SAME pane and win the per-pane collapse by
# most-active — an old "shell" record was out-voting this block's "idle" and
# painting hourglasses over the states under test.
rm -f /tmp/fakesup/*.json
fixpid; POLPID=$FIXPID
PSTATE="$XDG_DATA_HOME/pollstate"; rm -f "$PSTATE"
psup() { printf '%s' "{\"pid\":$POLPID,\"sessionId\":\"pol1\",\"kind\":\"interactive\",\"status\":\"$1\",\"cwd\":\"/tmp/pl\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"alpha:@1.$T\"}" > "/tmp/fakesup/$POLPID.json"; }
tmux switch-client -c "$client" -t beta 2>/dev/null; sleep 0.2
psup busy
"$REPO/scripts/navigator.sh" poll once "$PSTATE"; sleep 0.3
ck "poll: seeds a busy session as working" "$(st)/$(lb)" "tool/working"
psup waiting
"$REPO/scripts/navigator.sh" poll once "$PSTATE"; sleep 0.3
ck "poll: follows busy -> waiting" "$(st)/$(lb)" "wait/needs you"
ck "poll: the transition notifies when nobody is looking" \
	"$([ -n "$(tmux show -gqv @claude_tabs_notice)" ] && echo yes || echo no)" "yes"
tmux set -gu @claude_tabs_notice; tmux set -gu @claude_tabs_notice_tok
psup idle
"$REPO/scripts/navigator.sh" poll once "$PSTATE"; sleep 0.3
ck "poll: waiting -> idle reads as done" "$(st)/$(lb)" "done/done"
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" poll once "$PSTATE"
ck "poll: a quiet tick reconciles nothing" "$(tmux show -gqv @claude_tabs_synced_at)" ""
psup busy
"$REPO/scripts/navigator.sh" poll once "$PSTATE"; sleep 0.3
ck "poll: a new turn is working, never an hourglass" "$(st)/$(lb)" "tool/working"
# The freshness gate must NOT apply when the poller owns the badges. That rule
# compares the supervisor's statusUpdatedAt against @claude_tabs_seen, which
# only means "a hook observed this session" when hooks exist; with none, the
# poller writes that stamp itself, so the gate had it overruling its own
# output forever. Seen live: a session that moved from waiting to a background
# shell kept "needs you" for twenty minutes, because the record's timestamp
# stayed OLDER than our paint — statusUpdatedAt is not reliably monotonic.
tmux set -pu -t "$T" @claude_tabs_watch
tmux set -p -t "$T" @claude_tabs_state wait
tmux set -p -t "$T" @claude_tabs_glyph 'RED'
tmux set -p -t "$T" @claude_tabs_label 'needs you'
tmux set -p -t "$T" @claude_tabs_seen "$(date +%s)"
tmux set -gu @claude_tabs_hooks_at
printf '%s' "{\"pid\":$POLPID,\"sessionId\":\"pol1\",\"kind\":\"interactive\",\"status\":\"shell\",\"cwd\":\"/tmp/pl\",\"statusUpdatedAt\":$(( ($(date +%s) - 1000) * 1000 )),\"tmux\":\"alpha:@1.$T\"}" > "/tmp/fakesup/$POLPID.json"
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" sync force; sleep 0.3
ck "poll: a stale record still corrects our own badge" "$(st)/$(lb)" "bg/bg shell"

# The discriminator: a fresh hook stamp routes the same contradiction through
# the old conflict arms — done:busy means lost events there, not a new turn.
tmux set -p -t "$T" @claude_tabs_state done; tmux set -w -t "$T" @claude_tabs_state done
tmux set -pu -t "$T" @claude_tabs_at; tmux set -p -t "$T" @claude_tabs_seen 1
tmux set -g @claude_tabs_hooks_at "$(date +%s)"
psup busy
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" sync force; sleep 0.3
ck "poll: a fresh hook stamp keeps the conflict arms" "$(st)" "bg"
tmux set -gu @claude_tabs_hooks_at
tmux set -pu -t "$T" @claude_tabs_watch
# Death between ticks: the session lands in the spool (resumable with no
# SessionEnd hook ever firing) and its badge is cleared even though sweep
# refuses to act when no live session remains.
kill "$POLPID" 2>/dev/null; wait "$POLPID" 2>/dev/null
rm -f "/tmp/fakesup/$POLPID.json"
"$REPO/scripts/navigator.sh" poll once "$PSTATE"; sleep 0.5
ck "poll: an ended session lands in the spool" "$(cut -f2,3 "$SPOOL/pol1" 2>/dev/null)" "pol1	/tmp/pl"
ck "poll: the dead session's badge is cleared" "$(st)" ""
rm -f "$SPOOL/pol1" "$PSTATE"
# The load path: on spawns a daemon and stamps the token; off takes it down.
# sync-on-load off keeps the load from firing its background `sync force`
# into the checks that follow, and with the supervisor dir empty the daemon's
# own ticks reconcile nothing — it just dies on its second tick when the
# token goes away below.
tmux set -g @claude-tabs-sync-on-load off
tmux set -g @claude-tabs-poll on
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "poll: load with poll on stamps the token" \
	"$([ -n "$(tmux show -gqv @claude_tabs_poll_token)" ] && echo yes || echo no)" "yes"
tmux set -g @claude-tabs-poll off
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "poll: load with poll off unsets the token" "$(tmux show -gqv @claude_tabs_poll_token)" ""
tmux set -gu @claude-tabs-sync-on-load
tmux switch-client -c "$client" -t alpha 2>/dev/null; tmux select-window -t alpha:1 2>/dev/null

# --- changing a key option must release the old key, and 'off' must release
# the key at all — including the status-line clicks, which were stolen from
# the user's own bindings with no way back.
tmux set -g @claude-tabs-nav-key 'C-s'
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "changing nav-key unbinds the old key" \
	"$(tmux list-keys -T prefix 2>/dev/null | awk -v r="$REPO" 'index($0,"navigator.sh")&&/ open /{for(i=1;i<NF;i++)if($i=="-T"){print $(i+2);exit}}')" "C-s"
# The click menu is ON by default, and nothing asserted it was ever bound:
# "click-menu off releases the mouse keys" further down is satisfied just as
# well by keys that were never there. Measured — with the whole binding block
# deleted from claude-tabs.tmux, middle-click and double-click doing nothing at
# all, every check in this file stayed green. So assert the default first, on
# the load above (which ran with the option unset), and only then turn it off.
ck "click-menu binds both status-line clicks by default" \
	"$(tmux list-keys -T root 2>/dev/null | grep -c 'MouseDown2Status\|SecondClick1Status')" "2"
ck "...and the menu they open is ours" \
	"$(tmux list-keys -T root 2>/dev/null | grep MouseDown2Status | grep -c 'Clear badge')" "1"
tmux set -g @claude-tabs-click-menu off
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1
# --- our keys must never run in the SERVER. run-shell without -b executes
# inside tmux and blocks every client until it returns; measured at load 33,
# the navigator's row fetch alone is 0.31-1.10s, during which no pane echoes a
# keystroke and the status line does not repaint. (The popup still opens under
# -b: that is how docs/demo.sh photographs it.)
for spec in "navigator.sh. open:navigator" "jump-last:jump" "claude-tabs.tmux. clear:clear"; do
	pat="${spec%%:*}"; name="${spec##*:}"
	ck "the $name key does not block the server" \
		"$(tmux list-keys 2>/dev/null | grep "$pat" | grep -c 'run-shell -b')" "1"
done
# Matches every spelling: run-shell "..", run-shell '..', run-shell -t = "..",
# and a -b dropped from a line-continued call. The old pattern (`run-shell "`)
# matched nothing in either file, so it was 0 == 0 by construction and blind to
# exactly the regression it names.
ck "no synchronous run-shell is left in the plugin" \
	"$(grep -hE "run-shell([[:space:]]+-t[[:space:]]+=)?[[:space:]]+[\"'\\\\]" \
		"$REPO/claude-tabs.tmux" "$REPO/scripts/navigator.sh" |
		grep -vc 'run-shell -b' || true)" "0"

# --- sweep must not clear a badge it merely failed to place. Its rule is
# weaker than agents.sh's, which also resolves a session through its
# controlling tty when the record carries no usable pane (an older Claude
# Code, a record naming another tmux server, the literal "None"). A live
# session badged red for a permission prompt was being erased on that basis,
# and it fires no further hook while the prompt is up, so it did not come back.
rm -f /tmp/fakesup/*.json
SWP=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
tmux set -p -t "$SWP" @claude_tabs_state wait
tmux set -p -t "$SWP" @claude_tabs_glyph 'RED'
# one live record that CAN be placed, one that cannot
fixpid; SWA=$FIXPID
printf '%s' "{\"pid\":$SWA,\"sessionId\":\"sw-ok\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$SWA.json"
fixpid; SWB=$FIXPID
printf '%s' "{\"pid\":$SWB,\"sessionId\":\"sw-none\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"None\"}" > "/tmp/fakesup/$SWB.json"
"$REPO/scripts/navigator.sh" sweep >/dev/null 2>&1
ck "sweep keeps a badge when a live session could not be placed" \
	"$(tmux show -pqv -t "$SWP" @claude_tabs_state)" "wait"
# With every live record placeable, the stale badge is cleared as before.
rm -f "/tmp/fakesup/$SWB.json"
"$REPO/scripts/navigator.sh" sweep >/dev/null 2>&1
ck "sweep still clears a badge with nothing behind it" \
	"$(tmux show -pqv -t "$SWP" @claude_tabs_state)" ""
# ~/.claude/sessions is shared between tmux servers while pane ids are
# per-server, so a record naming another server used to shield whatever
# happened to carry the same number here. It no longer counts as this pane —
# but it does not count as "definitely elsewhere" either, because agents.sh
# falls through to the tty walk on a session-name mismatch and may well place
# it here. So the honest answer is the conservative one: sweep declines. A
# stale badge is recoverable with prefix M-c or the next poll; an erased live
# one is the worst thing this plugin can do.
tmux set -p -t "$SWP" @claude_tabs_state wait
tmux set -p -t "$SWP" @claude_tabs_glyph 'RED'
printf '%s' "{\"pid\":$SWA,\"sessionId\":\"sw-elsewhere\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"otherserver:@9.$SWP\"}" > "/tmp/fakesup/$SWA.json"
"$REPO/scripts/navigator.sh" sweep >/dev/null 2>&1
ck "a foreign record makes sweep decline rather than guess" \
	"$(tmux show -pqv -t "$SWP" @claude_tabs_state)" "wait"
# ...and it does not shield by NUMBER either: with it gone, the same pane is
# cleared, which is what shows the earlier pass was refusal and not shielding.
rm -f "/tmp/fakesup/$SWA.json"
fixpid; SWC=$FIXPID
printf '%s' "{\"pid\":$SWC,\"sessionId\":\"sw-here\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$SWC.json"
"$REPO/scripts/navigator.sh" sweep >/dev/null 2>&1
ck "with every record placeable, the stale badge goes" \
	"$(tmux show -pqv -t "$SWP" @claude_tabs_state)" ""
tmux kill-window -t "$SWP" 2>/dev/null
rm -f /tmp/fakesup/*.json

# --- the poller must survive a session file that reads back empty, and must
# not call the session ended. The pid was derived from the filename one line
# AFTER the empty-read guard used it, so an empty file blamed the previous
# iteration's pid — and on the first file of the glob there was none, so set -u
# killed the daemon outright.
rm -f /tmp/fakesup/*.json
fixpid; EMP=$FIXPID
EMPW=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
printf '%s' "{\"pid\":$EMP,\"sessionId\":\"emptysess\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$EMPW" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$EMP.json"
EMPSTATE="$XDG_DATA_HOME/pollstate-empty"; rm -f "$EMPSTATE"
"$REPO/scripts/navigator.sh" poll once "$EMPSTATE" >/dev/null 2>&1; sleep 0.3
ck "poll: the session is badged first" "$(tmux show -pqv -t "$EMPW" @claude_tabs_state)" "tool"
: > "/tmp/fakesup/$EMP.json"     # the O_TRUNC window of any rewrite
rc=0; "$REPO/scripts/navigator.sh" poll once "$EMPSTATE" >/dev/null 2>&1 || rc=$?
ck "poll: an empty file does not kill the tick" "$rc" "0"
ck "poll: an empty file does not clear a live badge" \
	"$(tmux show -pqv -t "$EMPW" @claude_tabs_state)" "tool"
ck "poll: and does not file the session as ended" \
	"$([ -f "$SPOOL/emptysess" ] && echo filed || echo no)" "no"
# The same file first in the glob order — the shape that killed the daemon.
rm -f /tmp/fakesup/*.json "$EMPSTATE"
: > /tmp/fakesup/1.json
printf '%s' "{\"pid\":$EMP,\"sessionId\":\"emptysess2\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$EMPW" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$EMP.json"
rc=0; "$REPO/scripts/navigator.sh" poll once "$EMPSTATE" >/dev/null 2>&1 || rc=$?
ck "poll: an empty file FIRST in the glob does not kill the tick" "$rc" "0"
tmux kill-window -t "$EMPW" 2>/dev/null; rm -f /tmp/fakesup/*.json "$EMPSTATE" "$SPOOL"/emptysess*

# --- a reconcile that lost the lock must not be recorded as handled, or the
# poller never retries and the badge stays wrong until the session moves again.
SYNCLOCK2="$XDG_DATA_HOME/tmux-claude-tabs/sync.lock"
rm -rf "$SYNCLOCK2"; mkdir -p "$SYNCLOCK2"
tmux set -gu @claude_tabs_synced_at
rc=0; "$REPO/scripts/navigator.sh" sync poll >/dev/null 2>&1 || rc=$?
ck "a skipped reconcile reports it (exit 3)" "$rc" "3"
rmdir "$SYNCLOCK2" 2>/dev/null
# ...while an explicit force waits for the lock rather than doing nothing.
mkdir -p "$SYNCLOCK2"
# A bare `wait` here would block on every fixture sleeper this suite has
# running — one of them for 600 seconds.
( sleep 0.4; rmdir "$SYNCLOCK2" 2>/dev/null ) &
UNLOCKER=$!
tmux set -gu @claude_tabs_synced_at
rc=0; "$REPO/scripts/navigator.sh" sync force >/dev/null 2>&1 || rc=$?
wait "$UNLOCKER" 2>/dev/null
ck "an explicit force waits for the lock instead of skipping" "$rc" "0"
rm -rf "$SYNCLOCK2"

# --- the watcher must never paint done over a session that is blocked on you.
# `waiting` used to fall into the catch-all whose comment says "settled".
fixpid; WWP=$FIXPID
printf '%s' "{\"pid\":$WWP,\"sessionId\":\"wsess\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 ))}" > "/tmp/fakesup/$WWP.json"
tmux set -p -t "$T" @claude_tabs_state bg; tmux set -w -t "$T" @claude_tabs_state bg
"$REPO/scripts/navigator.sh" watch "$T" wsess 1 >/dev/null 2>&1
ck "watch: a waiting session is not painted done" "$(st)" "bg"
rm -f /tmp/fakesup/*.json
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
tmux set -pu -t "$T" @claude_tabs_watch

# --- a large hook payload must not stall the hot path. Bash pattern matching
# over a big string is quadratic; an 80 KB payload took 13 seconds.
big="$(awk 'BEGIN { s = ""; while (length(s) < 60000) s = s "A"; print s }')"
t0=$(date +%s)
printf '%s' "{\"session_id\":\"bigp\",\"blob\":\"$big\",\"tool_name\":\"Bash\"}" |
	TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" tool >/dev/null 2>&1
t1=$(date +%s)
ck "a 60KB payload is handled in seconds, not tens of seconds" \
	"$([ $((t1 - t0)) -le 5 ] && echo fast || echo "slow:$((t1 - t0))s")" "fast"
ck "and the tool name is still read correctly" "$(lb)" "Bash"

# --- a pid is not an identity. kill -0 only says "some process has this
# number": a Claude killed with SIGKILL leaves its file behind, the OS reuses
# the pid, and that file then badged a pane for a session that is gone. The
# record's startedAt is compared against the process's real start.
rm -f /tmp/fakesup/*.json
fixpid; IDP=$FIXPID
IDW=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
mkfix() { # mkfix <startedAt-epoch-seconds>
	printf '%s' "{\"pid\":$IDP,\"sessionId\":\"idsess\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp\",\"startedAt\":$(( $1 * 1000 )),\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$IDW" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$IDP.json"
}
mkfix "$(date +%s)"
idrow() { CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" 2>/dev/null |
	awk -F'\t' -v p="$IDW" '$2 == "live" && $3 == p { n++ } END { print n + 0 }'; }
ck "a record whose startedAt matches the process is live" "$(idrow)" "1"
mkfix "$(( $(date +%s) - 86400 ))"     # same pid, started a day earlier: recycled
ck "a record whose startedAt does not match is dropped" "$(idrow)" "0"
# A record with no startedAt at all must still work — the field is only used
# when it is there.
printf '%s' "{\"pid\":$IDP,\"sessionId\":\"idsess\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$IDW" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$IDP.json"
ck "a record without startedAt is not judged" "$(idrow)" "1"
tmux kill-window -t "$IDW" 2>/dev/null; rm -f /tmp/fakesup/*.json

# --- a session name may contain a space; the pane index must survive it.
SPW=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
tmux rename-session -t alpha 'two words' 2>/dev/null
fixpid; SPP=$FIXPID
printf '%s' "{\"pid\":$SPP,\"sessionId\":\"spacesess\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/tmp/sp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$SPW" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$SPP.json"
ck "a spaced session name still resolves to its pane" \
	"$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' -v p="$SPW" '$2=="live" && $3==p {print $13}')" "waiting"
tmux rename-session -t 'two words' alpha 2>/dev/null
tmux kill-window -t "$SPW" 2>/dev/null; rm -f /tmp/fakesup/*.json

# --- one reconcile at a time. `jump` trips two of the self-heal hooks by
# construction, so two passes started in the same second and each paid for its
# own agents.sh. The lock must also be RELEASED: sync ends in `exec sweep`,
# which replaces the process before any EXIT trap can run.
SYNCLOCK="$XDG_DATA_HOME/tmux-claude-tabs/sync.lock"
rm -rf "$SYNCLOCK"
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" sync force >/dev/null 2>&1
ck "the reconcile lock is released, not leaked" \
	"$([ -d "$SYNCLOCK" ] && echo held || echo free)" "free"
mkdir -p "$SYNCLOCK"
tmux set -gu @claude_tabs_synced_at
tmux set -p -t "$T" @claude_tabs_state thinking; tmux set -p -t "$T" @claude_tabs_at 1
# Through `sync poll`, the throttled path the lock actually exists for, not
# through `force`, which is DEFINED to wait for the lock and then take it
# anyway. With `force` this measured rc=0, the reconcile ran, and the test's own
# lock directory was deleted by the plugin — and the check passed regardless,
# purely because the badge happened to be left at `thinking`. Three assertions,
# because the badge alone cannot tell "did not run" from "ran and changed
# nothing": the exit code says the pass was skipped, and the lock's survival
# says the holder was respected rather than evicted.
syncrc=0; "$REPO/scripts/navigator.sh" sync poll >/dev/null 2>&1 || syncrc=$?
ck "a held lock stops a second reconcile" "$syncrc/$(st)" "3/thinking"
ck "...and the holder's lock is left alone" \
	"$([ -d "$SYNCLOCK" ] && echo held || echo stolen)" "held"
rmdir "$SYNCLOCK" 2>/dev/null
tmux set -pu -t "$T" @claude_tabs_state; tmux set -pu -t "$T" @claude_tabs_at

# --- the state directory holds the path of every project you have run Claude
# in, plus the transcript paths beside them. It must not be world-readable,
# and neither must anything the plugin creates on the way to it.
rm -rf "$XDG_DATA_HOME/tmux-claude-tabs"
env -u TMUX -u TMUX_PANE bash -c 'printf "%s" "{\"session_id\":\"perm1\",\"cwd\":\"/tmp\",\"transcript_path\":\"/tmp/x\"}" | XDG_DATA_HOME='"$XDG_DATA_HOME"' '"$REPO"'/hooks/claude-tabs.sh end'
for d in "$XDG_DATA_HOME/tmux-claude-tabs" "$SPOOL"; do
	ck "private: ${d##*/}" "$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null)" "700"
done
# The turn markers land in the same tree, created from a different code path.
hk prompt >/dev/null 2>&1
ck "private: turns" \
	"$(stat -c '%a' "$XDG_DATA_HOME/tmux-claude-tabs/turns" 2>/dev/null || stat -f '%Lp' "$XDG_DATA_HOME/tmux-claude-tabs/turns" 2>/dev/null)" "700"
# A directory an older version left world-readable is tightened on load.
chmod 755 "$XDG_DATA_HOME/tmux-claude-tabs" "$SPOOL" 2>/dev/null
"$REPO/claude-tabs.tmux" >/dev/null 2>&1
ck "an older, looser state directory is tightened on load" \
	"$(stat -c '%a' "$XDG_DATA_HOME/tmux-claude-tabs" 2>/dev/null || stat -f '%Lp' "$XDG_DATA_HOME/tmux-claude-tabs" 2>/dev/null)" "700"
rm -f "$SPOOL"/perm1
sleep 2   # that load fired a backgrounded sync force; let it land

# --- the settings.json backup is a verbatim snapshot of Claude Code's config,
# so it must never be created more readable than the file it came from.
echo '{"env":{"SECRET":"x"}}' > /tmp/ct-perm-set.json
chmod 600 /tmp/ct-perm-set.json
env -u TMUX "$REPO/hooks/install.sh" --settings /tmp/ct-perm-set.json --quiet >/dev/null 2>&1
bk="$(ls -1 /tmp/ct-perm-set.json.bak-claude-tabs-* 2>/dev/null | head -1)"
ck "the settings backup is not world-readable" \
	"$(stat -c '%a' "$bk" 2>/dev/null || stat -f '%Lp' "$bk" 2>/dev/null)" "600"
rm -f /tmp/ct-perm-set.json /tmp/ct-perm-set.json.bak-claude-tabs-*

# --- a session id is pasted into a shell command, so it must be checked
# rather than trusted. It arrives from the ended-session spool, written from a
# hook payload: a single quote in it broke out of the quoting, and an id
# ending "; <command> ;" ran that command in a new window. Proven against a
# real tmux before this guard existed, so the check below is not theoretical.
# remain-on-exit for the window count, exactly as the resume check below it
# does: the injected command exits the moment it runs, so tmux reaped its
# window before the count was taken and the count could never move. Measured —
# with the id guard removed the injection SUCCEEDED and this check stayed
# green, sampled with no sleep at all.
ct_roe="$(tmux show -gv remain-on-exit 2>/dev/null)"
tmux set -g remain-on-exit on
before_w=$(tmux list-windows -a 2>/dev/null | wc -l | tr -d ' ')
rm -f /tmp/ct-injected
"$REPO/scripts/navigator.sh" resume '' "x' ; touch /tmp/ct-injected ; echo '" /tmp >/dev/null 2>&1
sleep 1
ck "a quoted session id cannot run a command" \
	"$([ -f /tmp/ct-injected ] && echo injected || echo blocked)" "blocked"
ck "and no window is spawned for it" \
	"$(tmux list-windows -a 2>/dev/null | wc -l | tr -d ' ')" "$before_w"
tmux set -g remain-on-exit "${ct_roe:-off}"
rm -f /tmp/ct-injected
# ...while an ordinary session id still resumes. remain-on-exit keeps the
# window after `true` returns, or it is gone before it can be counted.
tmux set -g remain-on-exit on
tmux set -g @claude-tabs-command 'true'
"$REPO/scripts/navigator.sh" resume '' "072abf25-d889-4acd-80bf-b098aaeb6c4d" /tmp >/dev/null 2>&1
sleep 1
ck "a real session id still resumes" \
	"$(tmux list-windows -a -F '#{pane_start_command}' 2>/dev/null | grep -c -- '--resume' || true)" "1"
tmux list-windows -a -F '#{window_id} #{pane_start_command}' 2>/dev/null |
	awk '/--resume/ { print $1 }' | while read -r wid; do tmux kill-window -t "$wid" 2>/dev/null; done
tmux set -gu @claude-tabs-command
tmux set -gu remain-on-exit

# --- a backgrounded command must never exit non-zero: tmux prints the whole
# command back at the user as an error over the status line. The notice
# expiry did exactly that in its ORDINARY case — "[ token matches ] && tmux
# set -gu" fails the test whenever a newer notice has replaced this one, so
# every superseded notification produced a visible "... returned 1".
tmux set -g @claude_tabs_notice_tok live-token
# Was a tautology: the command below is a COPY of the product's, and it ends
# in `|| true`, so $? was 0 whatever the plugin did. What has force is the
# companion check that both real call sites carry the guard; this one now
# asserts the shape it is really about — that the test itself exits 0 — and is
# named for what it does.
ck "the expiry shape used by the product exits 0 when superseded" \
	"$(sh -c '[ "$(tmux -L '"$CLAUDE_TABS_TEST_SOCKET"' show -gqv @claude_tabs_notice_tok)" = stale-token ] && tmux -L '"$CLAUDE_TABS_TEST_SOCKET"' set -gu @claude_tabs_notice \; set -gu @claude_tabs_notice_tok || true' >/dev/null 2>&1; echo $?)" "0"
# The companion had a floor of its own missing, and the pattern it used —
# `set -gu @claude_tabs_notice_tok"`, with the quote hard against the option
# name — matched NEITHER call site on a healthy tree, because both really end
# `… set -gu @claude_tabs_notice_tok || true"`. It scored 0 == 0 by
# construction and only ever fired because a bare-&& mutant happens to put the
# quote exactly where the pattern wanted it. Measured: with the expiry deleted
# from BOTH call sites — the notification then sits on the status line for
# ever, and nothing else here looks at it — all 212 checks stayed green.
# So: count the expiries first, then assert every one of them is guarded.
notice_exp="$(grep -h 'set -gu @claude_tabs_notice_tok' "$REPO/hooks/claude-tabs.sh" "$REPO/scripts/navigator.sh" || true)"
ck "both notice expiries are still armed" \
	"$(printf '%s\n' "$notice_exp" | grep -c 'set -gu @claude_tabs_notice_tok' || true)" "2"
ck "neither call site can regress to a bare &&" \
	"$(printf '%s\n' "$notice_exp" | grep -vc '|| true' || true)" "0"
tmux set -gu @claude_tabs_notice_tok

# --- the notice goes where it does not push the window list along. Measured
# on a 196-column terminal whose list wants 236: on the left it took 30 more
# columns off an already-overflowing list for the four seconds it was up.
# Reads the state the load above already produced — an extra load here fires
# its own backgrounded sync force, which then lands in the middle of the lock
# test further down and rewrote a badge under it.
ck "the notice defaults to the right of the window list" \
	"$(tmux show -gv status-right | grep -c claude_tabs_notice)" "1"
ck "and not to its left" \
	"$(tmux show -gv status-left | grep -c claude_tabs_notice || true)" "0"

ck "click-menu off releases the mouse keys" \
	"$(tmux list-keys 2>/dev/null | grep -c 'MouseDown2Status\|SecondClick1Status' || true)" "0"
tmux set -gu @claude-tabs-nav-key; tmux set -gu @claude-tabs-click-menu
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1

# --- the uninstall verb must take everything back out of the server — but
# first prove there is something to take out, or a load failure would make
# every zero-assertion below pass vacuously.
ck "before uninstall: the format is spliced" \
	"$(tmux show -gv window-status-format 2>/dev/null | grep -o '#{?@claude_tabs_wglyph,' | wc -l | tr -d ' ')" "1"
ck "before uninstall: our bindings exist" \
	"$([ "$(tmux list-keys 2>/dev/null | grep -c claude-tabs)" -ge 1 ] && echo yes || echo no)" "yes"
ck "before uninstall: automatic-rename-format is wrapped once" \
	"$(tmux show -gv automatic-rename-format | grep -o 'claude_tabs_saved_arf' | wc -l | tr -d ' ')" "1"
ck "the saved rename format is the user's, not ours" \
	"$(tmux show -gqv @claude_tabs_saved_arf | grep -c claude_tabs_saved_arf || true)" "0"
ck "a pane not running Claude keeps its usual name" \
	"$(tmux display -p -t "$T" '#{E:automatic-rename-format}')" "$(tmux display -p -t "$T" '#{pane_current_command}')"
# A process tmux sees as `claude`, so the Claude branch of the format is taken.
# A COPY of a sleep binary: tmux names a symlink or a script after its target
# or interpreter. macOS kills a copied /bin/sleep, so coreutils' gsleep first.
mkdir -p /tmp/ct-bin
for src in "$(type -P gsleep)" "$(type -P sleep)"; do
	[ -n "$src" ] && cp "$src" /tmp/ct-bin/claude 2>/dev/null &&
		/tmp/ct-bin/claude 0 2>/dev/null && break
done
CLP=$(tmux new-window -d -P -F '#{pane_id}' 'exec /tmp/ct-bin/claude 200')
sleep 0.5
if [ "$(tmux display -p -t "$CLP" '#{pane_current_command}')" = claude ]; then
	tmux select-pane -t "$CLP" -T '✳ Fix: a.md #[fg=red]x'
	ck "a Claude window is named after its session" \
		"$(tmux display -p -t "$CLP" '#{E:automatic-rename-format}')" "Fix꞉ a․md _[fg=red]x"
	# The pane prints nothing, so only the load itself can apply the name.
	MAN=$(tmux new-window -d -P -F '#{pane_id}' -n mine 'sleep 200')
	bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1
	ck "a load names an idle Claude window at once" \
		"$(tmux display -p -t "$CLP" '#{window_name}')" "Fix꞉ a․md _[fg=red]x"
	ck "...and leaves a hand-named window alone" \
		"$(tmux display -p -t "$MAN" '#{window_name}/#{automatic-rename}')/$(tmux show -wqv -t "$MAN" automatic-rename)" "mine/0/off"
	tmux kill-pane -t "$MAN" 2>/dev/null
	tmux select-pane -t "$CLP" -T 'myhost.local'
	ck "...but not after a title Claude did not set" \
		"$(tmux display -p -t "$CLP" '#{E:automatic-rename-format}')" "claude"
else
	sk "window name: tmux does not see the fixture as claude here"
fi
tmux kill-pane -t "$CLP" 2>/dev/null; rm -rf /tmp/ct-bin
tmux set -g @claude_tabs_poll_token unin-tok
arf_before="$(tmux show -gqv @claude_tabs_saved_arf)"
bash "$REPO/claude-tabs.tmux" uninstall >/dev/null 2>&1
ck "uninstall restores automatic-rename-format" "$(tmux show -gv automatic-rename-format)" "$arf_before"
ck "uninstall strips the spliced formats" \
	"$(tmux show -gv window-status-format 2>/dev/null | grep -c claude_tabs || true)" "0"
ck "uninstall clears the poll token (stops the poller)" \
	"$(tmux show -gqv @claude_tabs_poll_token)" ""
ck "uninstall removes every binding of ours" \
	"$(tmux list-keys 2>/dev/null | grep -c claude-tabs || true)" "0"
ck "uninstall removes the self-heal hooks" \
	"$(tmux show -g after-select-window 2>/dev/null | grep -c claude-tabs || true)" "0"
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1   # restore for anything after

# --- a JSON null must read as "no value", not as a tool called null.
tmux set -pu -t "$T" @claude_tabs_state 2>/dev/null
printf '%s' '{"session_id":"nulltool","tool_name":null}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" tool >/dev/null 2>&1
ck "a null tool_name shows as working, not null" "$(st)/$(lb)" "tool/working"

# --- a malformed notify-duration must not blow up the hook's arithmetic.
tmux set -g @claude-tabs-notify-duration '4s'
err="$(printf '%s' '{"session_id":"durx"}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" stop 2>&1)"
ck "a non-numeric duration does not error the hook" "${err:-clean}" "clean"
tmux set -gu @claude-tabs-notify-duration

# --- losing the aggregation lock defers, never races. Hold the lock, fire a
# hook in a multi-pane window: the window badge must not change while held
# (the pre-fix code aggregated anyway), and the deferred recompute repairs it.
sleep 2   # let the reload's backgrounded sync-force settle first
LKP=$(tmux split-window -d -t "$T" -P -F '#{pane_id}' 'sleep 200')
# The split itself is a layout change, and a layout change now recomputes the
# window aggregate in the background. This fixture hand-sets a stale aggregate
# below and needs it to survive, so wait for the split's own recompute to land
# first — without this the check failed roughly one run in two.
sleep 1.5
# The sibling is set to its FINAL value up front, and the stale aggregate is
# put on the window by hand. Both assertions then hold no matter when the
# deferred recompute fires: while the lock is held the window must still read
# the stale "wait", and once the lock is gone any recompute — early or late —
# must land on "tool". The earlier shape changed the sibling between the two
# checks, which raced the 1s timer and, when the machine hiccuped, let the
# repair run against the old value and never fire again.
tmux set -p -t "$LKP" @claude_tabs_state idle
tmux set -w -t "$T" @claude_tabs_state wait
WID_RAW=$(tmux display -p -t "$T" '#{window_id}'); WID=${WID_RAW#@}
mkdir -p "$XDG_DATA_HOME/tmux-claude-tabs/turns/win-$WID.lock"
printf '%s' '{"session_id":"lk1","tool_name":"Edit"}' | TMUX_PANE=$T "$REPO/hooks/claude-tabs.sh" tool >/dev/null 2>&1
ck "a held lock blocks the inline aggregate" "$(ws)" "wait"
rmdir "$XDG_DATA_HOME/tmux-claude-tabs/turns/win-$WID.lock" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
	[ "$(ws)" = tool ] && break
	sleep 0.5
done
ck "the deferred recompute repairs the aggregate" "$(ws)" "tool"
tmux kill-pane -t "$LKP" 2>/dev/null
for o in @claude_tabs_glyph @claude_tabs_plain @claude_tabs_label @claude_tabs_state; do
	tmux set -pu -t "$T" "$o" 2>/dev/null; tmux set -wu -t "$T" "$o" 2>/dev/null
done

# --- a SIGKILLed Claude leaves a badge in a living pane: no SessionEnd, no
# pane-exited, no live row. Plain sync now sweeps as it goes.
rm -f /tmp/fakesup/*.json
KP=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
tmux set -p -t "$KP" @claude_tabs_state done
sleep 120 & alivepid=$!
printf '%s' "{\"pid\":$alivepid,\"sessionId\":\"sw1\",\"kind\":\"interactive\",\"status\":\"idle\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$T" '#{session_name}:#{window_id}.#{pane_id}')\"}" > "/tmp/fakesup/$alivepid.json"
tmux set -gu @claude_tabs_synced_at
"$REPO/scripts/navigator.sh" sync >/dev/null 2>&1
ck "sync sweeps a badge with no session behind it" \
	"$(tmux show -pqv -t "$KP" @claude_tabs_state)" ""
kill "$alivepid" 2>/dev/null; wait "$alivepid" 2>/dev/null
tmux kill-pane -t "$KP" 2>/dev/null; rm -f /tmp/fakesup/*.json

kill $FIXPIDS 2>/dev/null; wait $FIXPIDS 2>/dev/null

# --- the no-fzf menu is the DEFAULT navigator for anyone without fzf, and it
# leaked seven internal columns into every label: agents.sh emits 14 fields and
# the read bound 8, so the last name swallowed state, src, emoji, colour,
# status and a timestamp. Measured on screen as "~/api<TAB>wait<TAB>h<TAB>..."
rm -f /tmp/fakesup/*.json
# A leftover badge on $T would change the label (src=h reads the pane), and
# with no badge the LEGITIMATE label for a waiting fixture is the word
# "waiting" — so the old grep for that word measured leftover state, not the
# leak. Clear the pane and assert the label's exact shape instead.
tmux set -pu -t "$T" @claude_tabs_state; tmux set -wu -t "$T" @claude_tabs_state
tmux set -pu -t "$T" @claude_tabs_label; tmux set -wu -t "$T" @claude_tabs_label
fixpid; FPMENU=$FIXPID
printf '%s' "{\"pid\":$FPMENU,\"sessionId\":\"menu1\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/home/me/api\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$wsess\"}" > "/tmp/fakesup/$FPMENU.json"
menurow="$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" 2>/dev/null | grep -m1 "	live	")"
# $T in THIS file is the pane id, not a tab — using it as IFS split the row
# on "%" and digits, so whether these two checks passed depended on which
# digits happened to appear in the fixture's pid and timestamp. A literal tab:
menulabel="$(printf '%s\n' "$menurow" | { IFS="$(printf '\t')" read -r _r _k _i _a _c badge where dir _rest; printf '%s  %s  %s' "$badge" "$where" "$dir"; })"
ck "the menu label carries no raw columns" \
	"$(printf '%s' "$menulabel" | tr -dc '\t' | wc -c | tr -d ' ')" "0"

# --- a live session this server cannot place must still be listed. The `tmux`
# field is "None" until Claude Code learns its pane, names a pane that has since
# died, or belongs to another tmux server — and dropping those rows hid exactly
# the session a user opens this list to find. It comes back as its own row kind,
# ranked below every placed session so it cannot push a reachable one down.
fixpid; FPLOST=$FIXPID
printf '%s' "{\"pid\":$FPLOST,\"sessionId\":\"nowhere\",\"kind\":\"interactive\",\"status\":\"busy\",\"cwd\":\"/home/me/lost\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"None\"}" \
	>"/tmp/fakesup/$FPLOST.json"
# A placed session of this block's OWN, resolved here and not minutes ago: the
# ordering assertion below needs one, and borrowing an earlier fixture made it
# report a misordering whenever that fixture had gone stale.
LOSTW=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
fixpid; FPHERE=$FIXPID
printf '%s' "{\"pid\":$FPHERE,\"sessionId\":\"righthere\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/home/me/here\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$LOSTW" '#{session_name}:#{window_id}.#{pane_id}')\"}" \
	>"/tmp/fakesup/$FPHERE.json"
lostrow="$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' '$2 == "lost" { print; exit }')"
ck "an unplaceable live session is listed, not dropped" \
	"$(printf '%s' "$lostrow" | awk -F'\t' '{ print $2 "/" $3 "/" $4 }')" "lost/nowhere/$FPLOST"
ck "...and says where the record claimed it was" \
	"$(printf '%s' "$lostrow" | awk -F'\t' '{ print $7 }' | grep -c '^unplaced None')" "1"
ck "...ranked below every placed session" \
	"$(CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" 2>/dev/null | awk -F'\t' '
		$2 == "live" { live++; if (lost) bad = 1 }
		$2 == "lost" { lost++ }
		END { printf "%s", (live > 0 && lost > 0 && !bad) ? "below" \
			: "live=" live+0 " lost=" lost+0 " misordered=" bad+0 }')" "below"
tmux kill-window -t "$LOSTW" 2>/dev/null
rm -f "/tmp/fakesup/$FPLOST.json" "/tmp/fakesup/$FPHERE.json"
# Columns 6 and 7 are padded to fixed VISIBLE widths so the popup's tab
# delimiter cannot shift a short label a whole tab stop left of a long one.
#
# The fixture is deliberately not ASCII. These three checks used to measure
# "waiting", "idle" and "ended" only, and every one of those has one byte per
# cell — so they were green all the way through the byte-vs-cell padding defect
# and green after its fix, i.e. blind to the entire class. This user works in
# Russian, so a Cyrillic label is the ordinary case here, not an exotic one; a
# CJK one is the other half of the class (two cells per character, where
# Cyrillic is two BYTES per one cell — the two mistakes point opposite ways and
# one fixture catches both).
#
# The supervisor status becomes the label verbatim when no hook has painted the
# pane (agents.sh's fallback arm), which is how a fixture puts arbitrary text in
# column 6 at all.
#
# Asserted as absolute widths, not as "row A equals row B": two equal-but-wrong
# numbers pass an equality, and 19/17 is the contract agents.sh states.
# Three windows of this block's own, so nothing earlier can have killed the
# panes underneath.
AL1=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
AL2=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
AL3=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
for spec in "$AL1 waiting" "$AL2 занято" "$AL3 作業中"; do
	set -- $spec
	fixpid
	printf '%s' "{\"pid\":$FIXPID,\"sessionId\":\"al-$2\",\"kind\":\"interactive\",\"status\":\"$2\",\"cwd\":\"/home/me/al\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$1" '#{session_name}:#{window_id}.#{pane_id}')\"}" \
		>"/tmp/fakesup/$FIXPID.json"
done
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" al-end /home/me/al ended - >"$SPOOL/al-end"
# The measurer first. cells() is this file's own, and a wrong entry in its
# table would agree with a wrong padder and make every check below vacuous —
# so each value the fixture can reach is pinned here against Unicode's
# East_Asian_Width. ⏹ (U+23F9) is the one badge glyph that is a single cell,
# and the ended rows are padded on that assumption.
ck "cells(): ASCII"                    "$(cells 'waiting')" "7"
ck "cells(): Cyrillic is one cell"     "$(cells 'занято')"  "6"
ck "cells(): CJK is two"               "$(cells '作業中')"  "6"
ck "cells(): a badge emoji is two"     "$(cells '🔴')"      "2"
ck "cells(): ⏹ is one"                 "$(cells '⏹')"       "1"
# No python3 anywhere here any more. It is not a dependency of the plugin, only
# ever of this check, and on stock debian:12 — the commonest platform there is
# — its absence skipped all three, leaving the byte-vs-cell class unguarded
# exactly where it is most likely to bite.
alcol() { CLAUDE_TABS_PLAIN=1 "$REPO/scripts/agents.sh" 2>/dev/null |
	awk -F'\t' -v k="$1" -v w="$2" '$2 == k && index($6, w) { print $6 "\t" $7; exit }'; }
alcells() { # alcells <kind> <label> -> "<badge cells>/<where cells>"
	local row badge where
	row="$(alcol "$1" "$2")"
	[ -n "$row" ] || { printf 'no row for %s/%s' "$1" "$2"; return; }
	badge="${row%%	*}"; where="${row#*	}"
	printf '%s/%s' "$(cells "$badge")" "$(cells "$where")"
}
ck "an ASCII label pads to the documented columns" "$(alcells live waiting)" "19/17"
ck "a Cyrillic label lands on the same columns"    "$(alcells live занято)"  "19/17"
ck "a CJK label lands on the same columns"         "$(alcells live 作業中)"  "19/17"
ck "an ended row lines up with the live ones"      "$(alcells hist ended)"   "19/17"
tmux kill-window -t "$AL1" 2>/dev/null; tmux kill-window -t "$AL2" 2>/dev/null
tmux kill-window -t "$AL3" 2>/dev/null
rm -f /tmp/fakesup/*.json "$SPOOL/al-end"
ck "the menu label ends at the directory" \
	"$(case "$menulabel" in *"  /home/me/api") echo clean ;; *) printf '%s' "$menulabel" ;; esac)" "clean"

# --- the no-fzf menu and the fzf popup, DRIVEN. Everything below used to be a
# grep of navigator.sh, and a grep is satisfied by a comment: with the doubling,
# the key alphabet, the overflow hint and the fzf flags all deleted and their
# text preserved in comments, the suite scored its clean 186/0/8.
# 41 rows on purpose — one live session and forty ended ones against an
# alphabet of 34 keys, so the overflow arm has to fire.
rm -f /tmp/fakesup/*.json /tmp/ct-menu-pwn
MW=$(tmux new-window -d -t alpha: -P -F '#{pane_id}' 'sleep 200')
tmux set -p -t "$MW" @claude_tabs_state wait
tmux set -p -t "$MW" @claude_tabs_label '#(touch /tmp/ct-menu-pwn)x'
fixpid; FPMW=$FIXPID
printf '%s' "{\"pid\":$FPMW,\"sessionId\":\"mrow\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/home/me/m\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$MW" '#{session_name}:#{window_id}.#{pane_id}')\"}" \
	>"/tmp/fakesup/$FPMW.json"
mi=0
while [ "$mi" -lt 40 ]; do
	printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "mx$mi" /home/me/m ended - >"$SPOOL/mx$mi"
	mi=$((mi + 1))
done
tmux set -g @claude-tabs-history-shown 40
CT_TMUX_LOG=/tmp/ct-menu-args; : >"$CT_TMUX_LOG"
CT_TMUX_LOG="$CT_TMUX_LOG" PATH="$CT_SHIM:$CT_NOFZF" \
	"$REPO/scripts/navigator.sh" open "$client" /home/me/m >/dev/null 2>&1
# A menu was actually built. Without this floor every count below is 0 == 0.
ck "the no-fzf menu is built at all" \
	"$(grep -c '^display-menu$' "$CT_TMUX_LOG")" "1"
# Item NAMES are format-expanded by tmux, and #(...) in a format runs a shell
# command when the menu opens. The name carries a session label, a cwd and a
# tool name, so every # is doubled on the way in — asserted on the argv the
# code really hands tmux, and then by putting that exact string through tmux's
# own expander, which is what the doubling has to survive.
ck "menu item names are ##-doubled before display-menu" \
	"$(grep -c '##(touch /tmp/ct-menu-pwn)x' "$CT_TMUX_LOG")" "1"
# On a THROWAWAY server, and with `env -u TMUX`. Two separate measurements got
# this check to lie before it was written this way, and both make it say "safe"
# while the name really does carry a live #():
#   - tmux runs no #() job for display-message -p while a CONTROL-MODE client
#     is the current one, which this suite's client always is;
#   - and it runs none when $TMUX names a different server than -L does, which
#     this file exports for the whole run.
# Same format expander either way, with nothing else in it; killed straight
# after.
ct_exp="$CLAUDE_TABS_TEST_SOCKET-expand"
env -u TMUX tmux -L "$ct_exp" kill-server 2>/dev/null
env -u TMUX tmux -L "$ct_exp" -f /dev/null new-session -d 'sleep 30' 2>/dev/null
ct_mname="$(grep -m1 '(touch /tmp/ct-menu-pwn)x' "$CT_TMUX_LOG")"
# tmux runs the job in the BACKGROUND and hands back an empty first expansion
# at once, so wait for the job rather than for the command — and EXPAND AGAIN
# each time round. A third way this said "safe" about a live #(): one single
# expansion, sent while the throwaway server was still coming up, runs no job
# at all. Measured with the doubling deleted, 5 runs: 3 caught it, 2 called it
# safe. Re-expanding is 5/5. A mutant trips it on the first or second pass;
# only the healthy case pays the full budget.
for _i in 1 2 3 4 5 6 7 8 9 10; do
	env -u TMUX tmux -L "$ct_exp" display-message -p "$ct_mname" >/dev/null 2>&1
	[ -f /tmp/ct-menu-pwn ] && break
	sleep 0.3
done
ck "the item name survives tmux's format expander" \
	"$([ -f /tmp/ct-menu-pwn ] && echo pwned || echo safe)" "safe"
env -u TMUX tmux -L "$ct_exp" kill-server 2>/dev/null
# ...and it must not silently hide rows. It stopped at 9 with no hint while the
# default history alone shows 15. Counted as menu entries, not as an alphabet
# in the source: cutting the alphabet back to exactly nine kept the old grep
# green.
ck "the menu offers more than nine shortcuts" \
	"$([ "$(grep -c 'menuact [0-9]' "$CT_TMUX_LOG")" -gt 9 ] && echo yes || echo no)" "yes"
ck "an overflow tells the user rows are hidden" \
	"$(grep -c '^7 more — install fzf for the full list$' "$CT_TMUX_LOG")" "1"
# The popup's fzf gets --tabstop=1 (the shown fields are tab-separated and a
# terminal advances a tab to the next multiple of eight, which undoes the
# padding agents.sh just did) and --reverse. A shim fzf records its argv and
# refuses, so `pick` returns without needing a terminal.
CT_FZF_LOG=/tmp/ct-fzf-args; : >"$CT_FZF_LOG"
CT_FZF_LOG="$CT_FZF_LOG" PATH="$CT_SHIM_FZF:$PATH" \
	"$REPO/scripts/navigator.sh" pick "$client" /home/me/m >/dev/null 2>&1
ck "the popup stops the tab from undoing that" \
	"$(grep -c -e '^--tabstop=1$' -e '^--reverse$' "$CT_FZF_LOG")" "2"
tmux kill-window -t "$MW" 2>/dev/null
tmux set -gu @claude-tabs-history-shown
rm -f "$CT_TMUX_LOG" "$CT_FZF_LOG" /tmp/ct-menu-pwn /tmp/fakesup/*.json "$SPOOL"/mx*

# --- the popup's watch-mode binding must be one fzf actually accepts: fzf
# validates --bind at argument parse time even under --filter, so a renamed
# action or a typo fails here instead of killing the popup at prefix N.
# (Keep in step with the binding built in navigator.sh `pick`.)
if command -v fzf >/dev/null 2>&1; then
	fzv="$(fzf --version 2>/dev/null)"; fzmin="${fzv#*.}"; fzmin="${fzmin%%[!0-9]*}"
	if [ "${fzv%%.*}" -gt 0 ] 2>/dev/null || [ "${fzmin:-0}" -ge 42 ] 2>/dev/null; then
		ck "fzf accepts the popup watch binding" \
			"$(echo x | fzf --track --bind 'load:reload-sync(true)+refresh-preview' --filter x 2>/dev/null)" "x"
		ck "fzf accepts the newdir become binding" \
			"$(echo x | fzf --bind 'alt-n:become(true)' --filter x 2>/dev/null)" "x"
	else
		sk "fzf watch binding: fzf < 0.42"
	fi
else
	sk "fzf watch binding: no fzf installed"
fi

# --- the alt-n directory picker, driven for real: a live fzf in a pane on the
# test server, keys sent with send-keys, the spawned "claude" recording its
# cwd. This is the path the binding checks above cannot see — and it found a
# defect on its first run: a typed /tmp/x with /tmp/x/sub in the list
# fuzzy-matched the row and started Claude in the wrong directory.
if command -v fzf >/dev/null 2>&1; then
	rm -rf /tmp/nd-default /tmp/nd-typed /tmp/nd-out; mkdir -p /tmp/nd-default/sub /tmp/nd-typed
	tmux set -g @claude-tabs-command "sh -c 'pwd >> /tmp/nd-out'"
	nd_wait() { for _ in $(seq 1 60); do tmux capture-pane -p -t "$1" 2>/dev/null | grep -q "new Claude in" && return 0; sleep 0.1; done; return 1; }
	nd_open() { tmux new-window -t alpha -P -F '#{pane_id}' -d "XDG_DATA_HOME=$XDG_DATA_HOME CLAUDE_TABS_SUPERVISOR_DIR=$CLAUDE_TABS_SUPERVISOR_DIR $REPO/scripts/navigator.sh newdir '' $1"; }
	NDP=$(nd_open /tmp/nd-default); nd_wait "$NDP" || echo "picker never appeared"
	tmux send-keys -t "$NDP" Enter; sleep 1.5
	ck "newdir: Enter starts Claude where the popup was opened" "$(tail -1 /tmp/nd-out 2>/dev/null)" "/tmp/nd-default"
	: > /tmp/nd-out
	NDP=$(nd_open /tmp/nd-default); nd_wait "$NDP" || echo "picker never appeared"
	tmux send-keys -t "$NDP" "/tmp/nd-typed" Enter; sleep 1.5
	ck "newdir: a typed path is used verbatim" "$(tail -1 /tmp/nd-out 2>/dev/null)" "/tmp/nd-typed"
	: > /tmp/nd-out
	NDP=$(nd_open /tmp/nd-default); nd_wait "$NDP" || echo "picker never appeared"
	tmux send-keys -t "$NDP" Escape; sleep 1
	ck "newdir: ESC starts nothing" "$(wc -l < /tmp/nd-out | tr -d ' ')" "0"
	NDP=$(nd_open /tmp/nd-default/sub); nd_wait "$NDP" || echo "picker never appeared"
	tmux send-keys -t "$NDP" "/tmp/nd-default" Enter; sleep 1.5
	ck "newdir: a typed existing dir beats a fuzzy list match" "$(tail -1 /tmp/nd-out 2>/dev/null)" "/tmp/nd-default"
	tmux set -gu @claude-tabs-command
	rm -rf /tmp/nd-default /tmp/nd-typed /tmp/nd-out
else
	sk "newdir picker e2e: no fzf installed"
fi
rm -f /tmp/fakesup/*.json

# --- hooks/install.sh promises the settings file keeps its mode. GNU stat reads -f
# as "filesystem" and prints a report to STDOUT while failing, so the BSD-first
# probe captured that instead of a mode and every Linux install narrowed 644
# to mktemp's 0600 while the README claimed otherwise.
echo '{}' > /tmp/ct-mode.json; chmod 640 /tmp/ct-mode.json
"$REPO/hooks/install.sh" --settings /tmp/ct-mode.json --quiet
ck "install keeps the settings file's mode" "$(ls -l /tmp/ct-mode.json | cut -c1-10)" "-rw-r-----"
"$REPO/hooks/install.sh" --uninstall --settings /tmp/ct-mode.json --quiet
ck "uninstall keeps it too" "$(ls -l /tmp/ct-mode.json | cut -c1-10)" "-rw-r-----"
rm -f /tmp/ct-mode.json /tmp/ct-mode.json.bak-*

# --- a dry run reports; it does not create. This wrote settings.json on a
# machine that had never run Claude Code, and said "created" while doing it.
# The directory EXISTS here on purpose. It used to be removed entirely, so the
# unconditional write failed on a missing parent instead of being prevented,
# and the check passed while the guard did nothing. The exit status is checked
# too: that failure was invisible because it was thrown away.
rm -rf /tmp/ct-dryhome; mkdir -p /tmp/ct-dryhome
dry_out="$(env -u TMUX "$REPO/hooks/install.sh" --dry-run --settings /tmp/ct-dryhome/settings.json 2>&1)"
ck "--dry-run exits cleanly" "$?" "0"
ck "--dry-run creates nothing" \
	"$(find /tmp/ct-dryhome -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
ck "--dry-run says what it would do" \
	"$(printf '%s' "$dry_out" | grep -c 'would create')" "1"
# ...and neither does an uninstall with no settings.json at all.
env -u TMUX "$REPO/hooks/install.sh" --uninstall --settings /tmp/ct-dryhome/none.json --quiet >/dev/null 2>&1
ck "uninstall creates no settings.json" \
	"$(find /tmp/ct-dryhome -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf /tmp/ct-dryhome

# --- --uninstall --tmux-conf claimed success whenever the file merely
# mentioned the plugin, but only actually removed the line when our generated
# comment sat immediately above it.
printf '# my own note about claude-tabs.tmux\nset -g mouse on\nrun-shell "%s/claude-tabs.tmux"\nset -g status on\n' "$REPO" > /tmp/ct-uc.tmux
echo '{}' > /tmp/ct-uc.json
"$REPO/hooks/install.sh" --uninstall --settings /tmp/ct-uc.json --tmux-conf /tmp/ct-uc.tmux --quiet
ck "removes the run-shell line without our comment above it" \
	"$(grep -c 'run-shell.*claude-tabs' /tmp/ct-uc.tmux || true)" "0"
ck "and leaves the user's own comment alone" \
	"$(grep -c 'my own note' /tmp/ct-uc.tmux)" "1"
printf 'set -g mouse on\n' > /tmp/ct-uc.tmux
ck "says so when there is no line to remove" \
	"$("$REPO/hooks/install.sh" --uninstall --settings /tmp/ct-uc.json --tmux-conf /tmp/ct-uc.tmux 2>&1 | grep -c 'no tmux-claude-tabs line')" "1"
rm -f /tmp/ct-uc.tmux /tmp/ct-uc.tmux.bak-* /tmp/ct-uc.json*

# --- auto-hooks must not fail silently. Without jq the tmux side installs
# perfectly and no hook is ever written, so no badge can appear — and nothing
# said why.
# Driven, not grepped: with the message reworded and the old text kept in a
# comment the old check stayed green. HOME points at a path no mkdir can
# create, which is what makes hooks/install.sh fail — and, just as important, is what
# keeps this check from writing to a real ~/.claude/settings.json when the
# suite is run on a host rather than in a container.
# The notice is a TRANSIENT: navigator.sh arms a `run-shell -b "sleep N; …"`
# that clears it again, guarded on @claude_tabs_notice_tok — so a clearer armed
# minutes ago will happily wipe this one unless the token is cleared too, and
# the load's own backgrounded sync force can post a notice of its own on top.
# Both were seen once on a loaded machine. Clear the token, and read the option
# straight after the load rather than after a sleep; retry the whole load if it
# lost that race, and print what was actually up when it fails.
tmux set -gu @claude_tabs_notice; tmux set -gu @claude_tabs_notice_tok
tmux set -g @claude-tabs-auto-hooks on
ahnotice=""
for _i in 1 2 3; do
	HOME=/dev/null/nope "$REPO/claude-tabs.tmux" >/dev/null 2>&1
	ahnotice="$(tmux show -gqv @claude_tabs_notice)"
	case "$ahnotice" in *'hooks NOT installed'*) break ;; esac
	tmux set -gu @claude_tabs_notice; tmux set -gu @claude_tabs_notice_tok
	sleep 1
done
ck "auto-hooks reports an installer failure" \
	"$(case "$ahnotice" in
		*'hooks NOT installed'*) echo reported ;;
		*) printf 'notice=[%s]' "$ahnotice" ;;
	esac)" "reported"
tmux set -gu @claude-tabs-auto-hooks; tmux set -gu @claude_tabs_notice
sleep 2   # that load fired a backgrounded sync force; let it land

# The server dies LAST. This line once sat mid-file, and every check added
# after it ran against a dead server: four failed loudly and three passed
# vacuously — a dead server answers "" and 0 to everything, which is exactly
# what those checks expected.

# --- a pane MOVED between windows must take its badge with it. move-pane,
# join-pane and break-pane are ordinary housekeeping, and the badge used to
# stay on the window that no longer holds the Claude while the window that now
# does showed nothing — the tab bar lying in both directions at once, and it
# never repaired itself. Driven, not asserted from source: tmux has no
# after-move-pane, so this also proves the window-layout-changed wiring is
# really installed and really fires. Last in the file on purpose — it creates
# and destroys windows, and an earlier position shifted the layout every later
# check depends on.
MVW=$(tmux new-window -d -P -F '#{window_id}')
MVSRC=$(tmux new-window -d -P -F '#{window_id}')
MVP=$(tmux list-panes -t "$MVSRC" -F '#{pane_id}' | head -1)
# A turn has to be in progress first: `permission` on a pane that never saw a
# prompt is deliberately ignored ("no turn in progress"), so without this the
# badge never appears and the check would measure nothing.
printf '%s' '{"session_id":"mvsess"}' |
	TMUX_PANE=$MVP "$REPO/hooks/claude-tabs.sh" prompt >/dev/null 2>&1
printf '%s' '{"session_id":"mvsess","tool_name":"Write"}' |
	TMUX_PANE=$MVP "$REPO/hooks/claude-tabs.sh" permission >/dev/null 2>&1
ck "move: the source window carries the badge to begin with" \
	"$(tmux show -wqv -t "$MVSRC" @claude_tabs_state 2>/dev/null)" "wait"
tmux move-pane -d -s "$MVP" -t "$MVW" 2>/dev/null
sleep 2
ck "move: the badge leaves the window the pane left" \
	"$(tmux show -wqv -t "$MVSRC" @claude_tabs_state 2>/dev/null)" ""
ck "move: and lands on the window it went to" \
	"$(tmux show -wqv -t "$MVW" @claude_tabs_state 2>/dev/null)" "wait"
# The same hook fires on every resize STEP — measured, one event per step —
# so a drag must leave the badge intact and no process behind. Asserting the
# badge rather than a throttle marker: a throttle was tried here and removed,
# because dropping events cost a window created and given a pane inside one
# second its badge, and the cost it saved was 13% of a fifty-step drag.
MVRP=$(tmux list-panes -t "$MVW" -F '#{pane_id}' | head -1)
# Only this plugin's processes: `ps -e | wc -l` counted the whole machine,
# and on a desktop with other work running it drifted past the threshold by
# itself — a flake that pointed at the plugin.
MVPROC=$(pgrep -f 'navigator.sh' 2>/dev/null | wc -l | tr -d ' ')   # not pgrep -c: on procps it prints 0 AND exits 1
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	tmux resize-pane -t "$MVRP" -y $((10 + _i)) 2>/dev/null
done
sleep 2
ck "move: a resize drag leaves the badge alone" \
	"$(tmux show -wqv -t "$MVW" @claude_tabs_state 2>/dev/null)" "wait"
ck "move: and piles up no processes" \
	"$([ "$(pgrep -f 'navigator.sh' 2>/dev/null | wc -l | tr -d ' ')" -lt $((MVPROC + 5)) ] && echo bounded || echo piling)" "bounded"


# --- the needs-you rescue must sit ABOVE the freshness gate. navigator.sh has
# two arms that paint a waiting supervisor red: an early ungated one, and a
# later one behind `[ "$sup_age" -ge "$seen" ] || continue`. They are not
# redundant — every hook stamps @claude_tabs_seen with its own clock while
# statusUpdatedAt is written only when the status CHANGES, so after any hook
# fires later than the last change the gate suppresses the later arm and a
# session sitting at a permission prompt never turns red. Deleting the early
# arm left this whole file green, which is why this check exists.
fixpid; NRPID=$FIXPID
NRT=$(tmux new-window -d -P -F '#{pane_id}' 'sleep 200')
rm -f /tmp/fakesup/*.json
printf '%s' "{\"pid\":$NRPID,\"sessionId\":\"needsyou\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( ($(date +%s) - 7200) * 1000 )),\"tmux\":\"$(tmux display -p -t "$NRT" '#{session_name}:#{window_id}.#{pane_id}')\"}" \
	> "/tmp/fakesup/$NRPID.json"
# A hook stamps `seen` with NOW — newer than the two-hour-old record. This is
# the ordinary state of any session whose status has not changed recently.
printf '%s' '{"session_id":"needsyou"}' | TMUX_PANE=$NRT "$REPO/hooks/claude-tabs.sh" prompt >/dev/null 2>&1
printf '%s' '{"session_id":"needsyou"}' | TMUX_PANE=$NRT "$REPO/hooks/claude-tabs.sh" stop >/dev/null 2>&1
ck "needs-you: the badge starts settled, and `seen` is newer than the record" \
	"$(tmux show -pqv -t "$NRT" @claude_tabs_state 2>/dev/null)" "done"
tmux set -g @claude-tabs-stale-after '1s'
sleep 2
"$REPO/scripts/navigator.sh" sync force >/dev/null 2>&1
ck "needs-you: a waiting supervisor still turns the tab red" \
	"$(tmux show -pqv -t "$NRT" @claude_tabs_state 2>/dev/null)" "wait"
tmux set -gu @claude-tabs-stale-after
tmux kill-window -t "$NRT" 2>/dev/null; rm -f /tmp/fakesup/*.json

# --- the SessionEnd spool must be newline-safe. A cwd containing a newline
# used to forge extra rows in the history file, and the navigator then offered
# the forged row and previewed whatever file it named. Unix permits such a
# directory name, so this is reachable from a hostile clone or archive.
rm -f "$SPOOL"/* 2>/dev/null
NLT=$(tmux new-window -d -P -F '#{pane_id}' 'sleep 200')
printf '%s' "{\"session_id\":\"nlsess\",\"cwd\":\"/tmp/a\\nB\\tfake\\t/etc/passwd\\tforged\",\"reason\":\"clear\"}" |
	TMUX_PANE=$NLT "$REPO/hooks/claude-tabs.sh" end >/dev/null 2>&1
ck "spool: a newline in cwd cannot forge a second history row" \
	"$(cat "$SPOOL"/* 2>/dev/null | grep -c .)" "1"
ck "spool: and the row still has exactly its six fields" \
	"$(cat "$SPOOL"/* 2>/dev/null | head -1 | awk -F'\t' '{print NF}')" "6"
tmux kill-window -t "$NLT" 2>/dev/null

# --- an unwritable state directory must not silently disable the reconcile.
# Root ignores mode bits, and every container this suite runs in is root, so
# the check has to say it was skipped rather than pass vacuously — a green
# "pass" there would mean nothing at all.
if [ "$(id -u)" = 0 ]; then
	sk "unwritable state dir: root ignores mode bits, cannot be tested here"
else
	UWD="$XDG_DATA_HOME/tmux-claude-tabs"
	fixpid; UWPID=$FIXPID
	UWT=$(tmux new-window -d -P -F '#{pane_id}' 'sleep 200')
	printf '%s' "{\"pid\":$UWPID,\"sessionId\":\"unwrit\",\"kind\":\"interactive\",\"status\":\"waiting\",\"cwd\":\"/tmp\",\"statusUpdatedAt\":$(( $(date +%s) * 1000 )),\"tmux\":\"$(tmux display -p -t "$UWT" '#{session_name}:#{window_id}.#{pane_id}')\"}" \
		> "/tmp/fakesup/$UWPID.json"
	chmod 500 "$UWD" 2>/dev/null
	"$REPO/scripts/navigator.sh" sync force >/dev/null 2>&1
	chmod 700 "$UWD" 2>/dev/null
	ck "an unwritable state dir still reconciles (unlocked), it does not go quiet" \
		"$(tmux show -pqv -t "$UWT" @claude_tabs_state 2>/dev/null)" "wait"
	tmux kill-window -t "$UWT" 2>/dev/null; rm -f /tmp/fakesup/*.json
fi


# --- nothing a hook runs may ever reach the screen. tmux shows a background
# run-shell job's output AND its non-zero exit ("'…' returned 3") to the user:
# one line as a status message that hides the window list for display-time,
# more as a page over the pane that waits for Enter. The hook form of `sync`
# exited 3 whenever a window switch collided with a poll pass holding the sync
# lock — "sometimes the tabs vanish for a few seconds; sometimes a black
# screen with a bash path on it". Measured on tmux 3.3a and 3.7c.
sleep 600 >/dev/null 2>&1 & LKHOLD=$!; FIXPIDS="$FIXPIDS $LKHOLD"
mkdir -p "$XDG_DATA_HOME/tmux-claude-tabs/sync.lock"
printf '%s' "$LKHOLD" > "$XDG_DATA_HOME/tmux-claude-tabs/sync.lock/pid"
# Past the 20s throttle first: with @claude_tabs_synced_at fresh from the
# checks above, `sync` exits 0 before it ever looks at the lock, and these
# three passed on the PRE-fix tree — measured — proving nothing.
tmux set -gu @claude_tabs_synced_at
rc=0; "$REPO/scripts/navigator.sh" sync >/dev/null 2>&1 || rc=$?
ck "hook-form sync exits 0 when another pass holds the lock" "$rc" "0"
rc=0; "$REPO/scripts/navigator.sh" sync poll >/dev/null 2>&1 || rc=$?
ck "...while the poller's form still learns the pass did not run" "$rc" "3"
# The stored hook command, run the way tmux runs it. A fresh window so a page
# it might open lands somewhere this check controls.
SCRW=$(tmux new-window -d -P -F '#{window_id}')
SCRHOOK="$(tmux show-hooks -g after-select-window 2>/dev/null | sed 's/^after-select-window\[[0-9]*\] run-shell -b //; s/^"//; s/"$//')"
tmux set -gu @claude_tabs_synced_at
tmux run-shell -b -t "$SCRW" "$SCRHOOK" 2>/dev/null; sleep 2
ck "...and the hook command puts nothing on the screen" \
	"$(tmux display -p -t "$SCRW" '#{pane_in_mode}' 2>/dev/null)" "0"
[ "$(tmux display -p -t "$SCRW" '#{pane_in_mode}' 2>/dev/null)" = 1 ] && tmux send-keys -t "$SCRW" q 2>/dev/null
rm -rf "$XDG_DATA_HOME/tmux-claude-tabs/sync.lock"; tmux kill-window -t "$SCRW" 2>/dev/null


# --- `hooks/install.sh --uninstall` from a plain terminal must clear the server
# too. It used to require an inside-tmux shell and otherwise stop at "run this
# other command", leaving the badges up. The default server is what `tmux`
# with no -L reaches, so an isolated one is made by pointing TMUX_TMPDIR at a
# private directory — never the machine's real default socket.
UOD="$XDG_DATA_HOME/uo-sock"; mkdir -p "$UOD"; UOS="$XDG_DATA_HOME/uo-settings.json"; printf '{}' > "$UOS"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$UOD" tmux new-session -d -s uo -x 120 -y 30
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$UOD" tmux setw -g window-status-format ' #I:#W '
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$UOD" tmux run-shell "bash '$REPO/claude-tabs.tmux'" >/dev/null 2>&1; sleep 1
ck "outside-tmux uninstall: the isolated default server got the plugin" \
	"$(env -u TMUX TMUX_TMPDIR="$UOD" tmux show -gv window-status-format | grep -c '@claude_tabs_wglyph')" "1"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$UOD" "$REPO/hooks/install.sh" --uninstall --quiet --settings "$UOS" >/dev/null 2>&1 || true
ck "outside-tmux uninstall: formats cleared without an inside-tmux shell" \
	"$(env -u TMUX TMUX_TMPDIR="$UOD" tmux show -gv window-status-format)" " #I:#W "
ck "outside-tmux uninstall: key bindings released too" \
	"$(env -u TMUX TMUX_TMPDIR="$UOD" tmux list-keys 2>/dev/null | grep -c 'navigator.sh')" "0"
env -u TMUX TMUX_TMPDIR="$UOD" tmux kill-server 2>/dev/null

tmux kill-server 2>/dev/null

echo "=== RESULT: pass=$pass fail=$fail skip=$skip ==="
[ "$fail" -eq 0 ]
