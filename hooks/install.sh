#!/usr/bin/env bash
# tmux-claude-tabs — wires hooks/claude-tabs.sh into Claude Code's settings.
#
# Optional: the plugin's default install runs on the per-server poller and
# never touches settings.json — these hooks are the instant-updates upgrade.
#
# The edit is append-only and idempotent: entries pointing at this repo's hook
# are replaced, and nothing else in settings.json — hooks other tools installed
# included — changes in meaning. The file is rewritten by jq, so its LAYOUT is
# jq's from the first change on: a UTF-8 BOM is dropped, CRLF becomes LF, hand
# formatting is reflowed. A run that would change nothing but the layout writes
# nothing at all, so an --uninstall on a settings.json this never wired into
# leaves it byte for byte as it was. A timestamped backup — the only copy of
# the original formatting — is written before the first change.
#
#   ./hooks/install.sh                 wire the hooks in
#   ./hooks/install.sh --uninstall     take them back out
#   ./hooks/install.sh --dry-run       show the resulting diff, change nothing
#   ./hooks/install.sh --print         print just the hooks block and exit
#   ./hooks/install.sh --settings P    operate on P instead of ~/.claude/settings.json
#   ./hooks/install.sh --tmux-conf P   also append the run-shell line to P
#   ./hooks/install.sh --quiet         say nothing except errors

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # this file lives in hooks/
hook="$repo/hooks/claude-tabs.sh"
settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mode=install
dry=0
quiet=0
tmux_conf=""

while [ $# -gt 0 ]; do
	case "$1" in
	--uninstall) mode=uninstall ;;
	--dry-run) dry=1 ;;
	--print) mode=print ;;
	--quiet) quiet=1 ;;
	--settings)
		[ "$#" -ge 2 ] || { echo "--settings needs a path" >&2; exit 2; }
		settings="$2"
		shift
		;;
	--tmux-conf)
		[ "$#" -ge 2 ] || { echo "--tmux-conf needs a path" >&2; exit 2; }
		tmux_conf="$2"
		shift
		;;
	-h | --help)
		# The whole leading comment block, wherever it ends — a hardcoded
		# line range printed shell source the moment the block grew.
		awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "unknown option: $1" >&2
		exit 2
		;;
	esac
	shift
done

say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ -x "$hook" ] || die "hook script not found or not executable: $hook"
# --print writes nothing, so it must not demand the tool used for writing.
# It used to fail this check and then advise running itself, which is a loop.
if [ "$mode" != print ]; then
	command -v jq >/dev/null 2>&1 || die "jq is required to edit $settings (brew install jq / apt install jq).
Run './hooks/install.sh --print' to get the JSON and paste it in by hand."
fi

# event → label passed to the hook script → optional matcher
specs='[
  {"event":"SessionStart",      "label":"start",      "matcher":null},
  {"event":"UserPromptSubmit",  "label":"prompt",     "matcher":null},
  {"event":"PreToolUse",        "label":"tool",       "matcher":".*"},
  {"event":"PostToolUse",       "label":"post",       "matcher":".*"},
  {"event":"PostToolUseFailure","label":"post",       "matcher":".*"},
  {"event":"PermissionRequest", "label":"permission", "matcher":".*"},
  {"event":"Notification",      "label":"notify",     "matcher":null},
  {"event":"SubagentStart",     "label":"subagent",   "matcher":null},
  {"event":"SubagentStop",      "label":"subagent-done",       "matcher":null},
  {"event":"PreCompact",        "label":"compact",    "matcher":null},
  {"event":"Stop",              "label":"stop",       "matcher":null},
  {"event":"StopFailure",       "label":"error",      "matcher":null},
  {"event":"SessionEnd",        "label":"end",        "matcher":null}
]'

# Strip our entries wherever they appear, then (unless uninstalling) append the
# current ones. Groups that still hold someone else's hooks survive untouched.
filter='
# Only an entry whose COMMAND IS our hook script — not one that merely mentions
# it. The old test matched any command containing the path, so another tool
# invoking `othertool --ignore .../hooks/claude-tabs.sh` was silently deleted,
# while the header of this file promises other tools are left exactly alone.
# Take the first shell word, honouring the quoting @sh writes, and require THAT
# to be our script.
def ours:
  (.command // "")
  | if startswith("'\''") then (.[1:] | split("'\''")[0])
    elif startswith("\"") then (.[1:] | split("\"")[0])
    else (split(" ")[0]) end
  # `// ""`: jq splits the EMPTY string into [], so a hook object carrying no
  # .command at all — legal for a hook that is not of type "command" — reached
  # endswith() as null and killed the whole run with a raw type error, exit 5.
  | (. // "")
  | endswith("/hooks/claude-tabs.sh");

def strip($e):
  .hooks[$e] = (((.hooks[$e] // [])
    # An entry without a .hooks key is left exactly as it is: not rewritten,
    # not given an empty array, not removed. Only one that HAD hooks and lost
    # all of them to us is dropped. Testing "is it empty now" also deleted a
    # matcher-only stanza belonging to another tool, which is legal to write
    # and is another persons data vanishing out of settings.json.
    | map(if has("hooks")
          then (.hooks | length) as $before
               | .hooks = (.hooks | map(select(ours | not)))
               | if (.hooks | length) == 0 and $before > 0
                 then .__drop = true else . end
          else . end)
    | map(select(.__drop != true))));

# @sh quotes the path, so a repo cloned under "My Projects" still works when
# Claude Code hands the command to sh -c.
def entry($s):
  (if $s.matcher == null then {} else {matcher: $s.matcher} end)
  + {hooks: [{type: "command", command: (($hook | @sh) + " " + $s.label), timeout: 5}]};

# $orig so the cleanup below can tell an entry WE emptied from one that was
# already empty when we arrived. Without it, a settings.json carrying
# "hooks": {} — exactly what one looks like after someone removes their own
# hooks — had that key deleted, and a "Stop": [] lost its key, so a run that
# should have changed nothing reflowed the whole file and made a backup.
. as $orig
| reduce ($specs | .[]) as $s (
  (. // {}) | .hooks = (.hooks // {});
  strip($s.event)
  | if $install then .hooks[$s.event] += [entry($s)] else . end
)
| .hooks |= with_entries(. as $e | select(
    ($e.value | length) > 0
    or ((($orig.hooks // {}) | has($e.key))
        and ((($orig.hooks // {})[$e.key] | length) == 0))))
# Drop the key unless it was ALREADY empty when we arrived. Three cases:
# it was absent and we created it -> drop; it held hooks and we emptied it ->
# drop, which is what leaves an uninstall looking like the file before the
# install; it was already {} -> keep, because those bytes are not ours.
# (No apostrophes in here: this whole filter is one single-quoted shell
# string, and one of them ends it in the middle of a jq expression.)
| if (.hooks | length) == 0
    and (($orig | has("hooks")) and (($orig.hooks | length) == 0) | not)
  then del(.hooks) else . end
'

if [ "$mode" = print ]; then
	# This is the escape hatch for a machine without jq, so it must not need
	# jq. It used to, and the error message it produced advised running the
	# very command that had just failed. Both paths read the same $specs, so
	# they cannot drift.
	if command -v jq >/dev/null 2>&1; then
		jq -n --arg hook "$hook" --argjson specs "$specs" --argjson install true "$filter"
	else
		# The path goes into a JSON string, so escape it the way jq would.
		# Without this a clone under a directory containing a quote or a
		# backslash emitted invalid JSON — and this branch exists precisely
		# for machines that cannot run jq to check.
		# Through the environment, NOT `awk -v hook=…`: POSIX has -v run escape
		# processing over the value, so a clone under a directory holding "\s"
		# reached the script as plain "s" and --print named a path that does not
		# exist. mawk happens not to do it, gawk and the BSD awk macOS ships do,
		# which is how it survived a Linux-only test. ENVIRON is untouched.
		printf '%s\n' "$specs" | CLAUDE_TABS_HOOK="$hook" awk '
			BEGIN { hook = ENVIRON["CLAUDE_TABS_HOOK"] }
			/"event"/ {
				ev = $0; sub(/.*"event":"/, "", ev); sub(/".*/, "", ev)
				lb = $0; sub(/.*"label":"/, "", lb); sub(/".*/, "", lb)
				mt = $0; sub(/.*"matcher":/, "", mt); sub(/[ ,}].*/, "", mt)
				n++; e[n] = ev; l[n] = lb; m[n] = mt
			}
			# Character by character, because awk treats backslashes in a gsub
			# REPLACEMENT specially: gsub(/\\/, "\\\\", v) substitutes one backslash
			# for one backslash and doubles nothing, so a path containing a
			# backslash came out as invalid JSON (\\o is not an escape).
			# `k`, not `n`: n is the global event counter this same program
			# uses for e[]/l[]/m[], and shadowing it here would read as a bug.
			function jesc(v,   out, i, c, k) {
				# A control character inside a JSON string is invalid JSON, and
				# leaving it raw made a clone under a path holding a tab emit a
				# file no parser accepts — on the branch that exists precisely
				# for machines with no jq to check it with. awk has no ord(), so
				# the map is built once from the characters themselves; the five
				# short forms and the lowercase \u00xx are what jq itself writes,
				# which is what keeps the two branches byte-identical.
				if (!ctlinit) {
					for (k = 1; k < 32; k++) ctl[sprintf("%c", k)] = sprintf("\\u%04x", k)
					ctl[sprintf("%c", 8)] = "\\b"; ctl[sprintf("%c", 9)] = "\\t"
					ctl[sprintf("%c", 10)] = "\\n"; ctl[sprintf("%c", 12)] = "\\f"
					ctl[sprintf("%c", 13)] = "\\r"; ctl[sprintf("%c", 127)] = "\\u007f"
					ctlinit = 1
				}
				out = ""
				for (i = 1; i <= length(v); i++) {
					c = substr(v, i, 1)
					if (c == "\\") out = out "\\\\"
					else if (c == "\"") out = out "\\\""
					else if (c in ctl) out = out ctl[c]
					else out = out c
				}
				return out
			}
			# What jq @sh does on the other path: wrap in single quotes, writing an
			# embedded quote as the four characters quote-backslash-quote-quote.
			# Without it a path like /home/o brien with an apostrophe closed the
			# quoting and Claude Code ran the remainder of the path as a command.
			# 39 is the apostrophe: spelling it out keeps one out of this source,
			# which is itself inside a single-quoted shell string.
			function shq(v,   q, out, i, c) {
				q = sprintf("%c", 39)
				out = q
				for (i = 1; i <= length(v); i++) {
					c = substr(v, i, 1)
					if (c == q) out = out q "\\" q q
					else out = out c
				}
				return out q
			}
			END {
				print "{"
				print "  \"hooks\": {"
				for (i = 1; i <= n; i++) {
					printf "    \"%s\": [\n      {\n", e[i]
					if (m[i] != "null") printf "        \"matcher\": %s,\n", m[i]
					print "        \"hooks\": ["
					print "          {"
					print "            \"type\": \"command\","
					printf "            \"command\": \"%s %s\",\n", jesc(shq(hook)), l[i]
					print "            \"timeout\": 5"
					print "          }"
					print "        ]"
					printf "      }\n    ]%s\n", (i < n ? "," : "")
				}
				print "  }"
				print "}"
			}'
	fi
	exit 0
fi

if [ ! -f "$settings" ] && [ "$mode" = uninstall ]; then
	say "no $settings — nothing to uninstall"
	skip_settings=1
fi
[ -f "$settings" ] || [ "${skip_settings:-0}" = 1 ] || {
	# A dry run reports, it does not create. This wrote ~/.claude/settings.json
	# on a machine that had never run Claude Code, and said "created" as part
	# of its own preview.
	if [ "$dry" -eq 1 ]; then
		if [ "$mode" = uninstall ]; then
			say "no $settings — nothing to uninstall"
		else
			say "would create $settings"
			say "--- would wire 13 hook entries into a new $settings ---"
		fi
		# Do not exit: --tmux-conf was asked for too, and its preview lives
		# further down. Skip only the settings work.
		skip_settings=1
	fi
	# The dry-run guard has to cover the WRITE, not only the mkdir. It guarded
	# just the mkdir, so `--dry-run` printed "would create" and then created
	# the file for real — the exact behaviour the comment above says was
	# fixed — and `--uninstall` left behind a settings.json that had never
	# existed. When the parent directory was missing too, the write simply
	# failed and the run exited non-zero with a raw shell error.
	if [ "${skip_settings:-0}" != 1 ]; then
		mkdir -p "$(dirname "$settings")" 2>/dev/null ||
			die "cannot create $(dirname "$settings") — check its permissions"
		# 0600: a settings.json can carry environment values and API
		# configuration, and one we create ourselves should not start out
		# world-readable.
		# The `||` matters: on a directory we cannot traverse this failed with a
		# raw "line 202: Permission denied" from bash, which reads like a bug in
		# the installer rather than a thing the user can fix.
		(umask 077; echo '{}' >"$settings") 2>/dev/null ||
			die "cannot create $settings — check the permissions on $(dirname "$settings")"
		say "created $settings"
	fi
}

# Follow a symlinked settings.json to the file it actually is. Plenty of people
# keep theirs in a dotfiles repo and link it into ~/.claude, and renaming onto
# the LINK replaced it with a regular file — their repo copy silently stopped
# being the one Claude Code reads. Worse, `stat` reports a symlink's OWN mode,
# 0777 on Linux, and the chmod below faithfully applied it: measured in a
# container, a 0600 settings.json came out world-WRITABLE, holding commands
# Claude Code runs. Resolve first and everything downstream works on the file.
resolve_link() { # resolve_link <path>
	local p="$1" n=0 l
	while [ -L "$p" ] && [ "$n" -lt 16 ]; do
		l="$(readlink "$p")" || break
		case "$l" in
		/*) p="$l" ;;
		*) p="$(dirname "$p")/$l" ;;
		esac
		n=$((n + 1))
	done
	printf '%s' "$p"
}
if [ "${skip_settings:-0}" = 1 ]; then
	settings_real="$settings"
else
settings_real="$(resolve_link "$settings")"
[ "$settings_real" = "$settings" ] || say "following $settings -> $settings_real"
# jq 1.6 — Debian 12, Ubuntu 22.04, RHEL 9 — exits 0 on a file holding no JSON
# at all. So a zero-byte settings.json passed this check, the filter produced
# nothing, and the empty result compared equal to the empty original: install
# reported "already up to date" and wired nothing. Treat it as {}.
if [ ! -s "$settings_real" ] || [ -z "$(tr -d '[:space:]' <"$settings_real" 2>/dev/null || true)" ]; then
	settings_empty=1
	say "$settings_real holds no JSON — starting from {}"
else
	settings_empty=0
jq -e . "$settings" >/dev/null 2>&1 || die "$settings is not valid JSON — fix it first"
# Shape, not just syntax. The filter indexes .hooks by event name and maps each
# event to a list; a hand-edited file where .hooks is an array, or an event
# holds an object, made jq fail with a raw type error and no idea what to do.
#
# The top level first: `has("hooks")` and `.hooks|type` both ERROR on a JSON
# array, string or number, so a settings.json holding one fell through to the
# message below and printed "has .hooks as  —" with an empty type, naming the
# wrong problem.
jq -e 'type == "object"' "$settings" >/dev/null 2>&1 ||
	die "$settings holds a JSON $(jq -r 'type' "$settings" 2>/dev/null) at the top level — Claude Code expects an object, { … }"
jq -e 'if has("hooks") then (.hooks | type) == "object" else true end' "$settings" >/dev/null 2>&1 ||
	die "$settings has .hooks as $(jq -r '.hooks | type' "$settings" 2>/dev/null) — Claude Code expects an object keyed by event name"
jq -e 'if has("hooks") then ([.hooks[] | type] | all(. == "array")) else true end' "$settings" >/dev/null 2>&1 ||
	die "$settings has an event under .hooks that is not a list — expected e.g. \"Stop\": [ … ]"
# One level deeper, because the two checks above are not enough: an event list
# holding a string, an entry whose .hooks is not a list, a .command that is a
# number — each reached the filter and killed jq with a raw type error and exit
# 5. Under `@claude-tabs-auto-hooks on` that text is painted into the tmux
# status line at every server start, where it cannot be acted on.
# Only the events this installer actually rewrites are checked: an oddly shaped
# entry under some event we never touch passes through jq untouched, and
# refusing to install over it would be a new failure, not a fixed one.
bad_events="$(jq -r --argjson specs "$specs" '
	def readable:
		type == "object"
		and (if has("hooks")
			then (.hooks | type) == "array"
				and all(.hooks[];
					type == "object"
					and (.command == null or (.command | type) == "string"))
			else true end);
	[$specs[].event] as $ours
	| (.hooks // {})
	| to_entries[]
	# `.key as $k` first: an argument to any/index is evaluated against THAT
	# filter input, so a bare `any(. == .key)` reads .key off $ours and errors.
	| select(.key as $k | $ours | any(. == $k))
	| select([.value[] | readable] | all | not)
	| .key' "$settings" 2>/dev/null | tr '\n' ' ')" || bad_events="?"
bad_events="${bad_events% }"
[ -z "$bad_events" ] ||
	die "$settings has a hook entry under $bad_events that this installer cannot read.
An entry must be an object; its optional .hooks must be a list of objects whose
.command, when present, is a string. Fix those entries, or move them to an event
this plugin does not manage."
fi

install_flag=true
[ "$mode" = uninstall ] && install_flag=false

# Staged in the target's own directory rather than $TMPDIR: a rename is atomic
# only within one filesystem, and mktemp's default lands on another often
# enough (a tmpfs /tmp, a separate /home) to matter for a file Claude Code
# reads at every launch.
# One writer at a time. Two tmux servers starting together, or a manual run
# racing an auto-hooks load, both read the file, both compute a new version,
# and the second rename wins — silently dropping whatever the first added,
# including another tool's hooks. mkdir is the atomic primitive a shell has.
lockdir="$settings_real.claude-tabs.lock"
release_lock() { [ "${lock_held:-0}" = 1 ] && { rm -f "$lockdir/pid"; rmdir "$lockdir"; } 2>/dev/null; }

if [ -d "$lockdir" ]; then
	# `|| true`: a lock directory with no pid file is the ordinary result of a
	# Ctrl-C, and under `set -e` the failing `cat` killed the installer right
	# here — silently, rc=1 and no output — which also made every line of the
	# recovery below it unreachable. The one case this block exists for was the
	# one case it could not handle.
	holder="$(cat "$lockdir/pid" 2>/dev/null || true)"
	case "$holder" in
	'' | *[!0-9]*)
		# A pid file that is empty, truncated or garbage still SITS IN the
		# directory, so rmdir cannot succeed while it is there — and an
		# unguarded rmdir failure under `set -Eeuo pipefail` killed the
		# installer with rc=1 and no output at all. Permanently, too: the lock
		# it failed to clear was still there for the next run to die on. The
		# same silent death this block exists to prevent, one line further on.
		if [ -n "$(find "$lockdir" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
			rm -f "$lockdir/pid" 2>/dev/null || true
			rmdir "$lockdir" 2>/dev/null || true
		fi
		;;
	*)
		if ! kill -0 "$holder" 2>/dev/null; then
			rm -f "$lockdir/pid" 2>/dev/null || true
			rmdir "$lockdir" 2>/dev/null || true
		fi
		;;
	esac
fi
lock_held=0
for _try in 1 2 3 4 5 6 7 8 9 10; do
	if mkdir "$lockdir" 2>/dev/null; then
		printf '%s' "$$" >"$lockdir/pid" 2>/dev/null
		lock_held=1
		# Before anything else can fail. The main trap is installed further down,
		# and a Ctrl-C in the gap left a lock directory that nothing cleared.
		trap release_lock EXIT INT TERM
		break
	fi
	sleep 0.3
done
# Say which of the three things actually blocked us. "Another install is
# writing" sent people hunting for a concurrent process that was never there,
# when the real cause was almost always a directory they could not write.
if [ "$lock_held" != 1 ]; then
	settings_dir="$(dirname "$settings_real")"
	if [ ! -d "$settings_dir" ]; then
		die "$settings_dir does not exist"
	elif [ ! -w "$settings_dir" ] || [ ! -x "$settings_dir" ]; then
		die "cannot write in $settings_dir — check its permissions"
	elif [ -e "$lockdir" ] && [ ! -d "$lockdir" ]; then
		die "$lockdir exists and is not a directory — remove it"
	elif [ -d "$lockdir" ]; then
		# Name the thing to delete. "Try again" is useless advice for a lock
		# nothing is holding, and an orphaned one never clears itself under two
		# minutes old.
		die "another install is writing $settings_real — if nothing else is running, remove $lockdir and re-run"
	else
		die "another install is writing $settings_real — try again"
	fi
fi

tmpfile="$(mktemp "$(dirname "$settings_real")/.claude-tabs.XXXXXX")" ||
	die "cannot write next to $settings_real"
conf_tmp=""
trap 'rm -f "$tmpfile" ${conf_tmp:+"$conf_tmp"}; release_lock' EXIT
if [ "${settings_empty:-0}" = 1 ]; then
	printf '{}' | jq --arg hook "$hook" --argjson specs "$specs" --argjson install "$install_flag" "$filter" >"$tmpfile"
else
	jq --arg hook "$hook" --argjson specs "$specs" --argjson install "$install_flag" "$filter" "$settings_real" >"$tmpfile"
fi

same_file() {
	# Minimal Fedora/RHEL images ship no diffutils; cksum is POSIX coreutils.
	if command -v cmp >/dev/null 2>&1; then
		cmp -s "$1" "$2"
	else
		[ "$(cksum <"$1")" = "$(cksum <"$2")" ]
	fi
}
# Byte-equal is the cheap case; MEANING-equal is the one that matters. jq is
# the only writer here, so a settings.json it did not produce comes back
# reformatted even when this installer changed nothing in it: a one-line
# "env" object exploded over three lines, a BOM deleted, CRLF rewritten to LF.
# That landed as a large spurious diff in the user's own version control, and
# the backup was then the only copy of their formatting. When the two files
# say the same thing, leave the original exactly as it is.
same_json() {
	# Both sides must actually parse: an unreadable file yields "" from jq on
	# each side, and two empty strings would compare equal and skip a real write.
	[ -n "$2" ] && [ "$1" = "$2" ]
}
if same_file "$settings_real" "$tmpfile"; then
	say "settings.json already up to date ($mode)"
elif same_json "$(jq -S -c . "$settings_real" 2>/dev/null)" "$(jq -S -c . "$tmpfile" 2>/dev/null)"; then
	say "settings.json already up to date ($mode) — left its formatting alone"
else
	if [ "$dry" -eq 1 ]; then
		say "--- would change $settings_real ---"
		diff -u "$settings_real" "$tmpfile" || true
	else
		backup="$settings_real.bak-claude-tabs-$(date +%Y%m%d-%H%M%S)-$$"
		# 0600, whatever the umask says. This copy is a verbatim snapshot of
		# your Claude Code settings, so it must not land more readable than
		# the file it came from.
		(umask 077; cp "$settings_real" "$backup")
		# mktemp creates 0600 and mv carries that over, silently narrowing a
		# 644 settings.json. Keep whatever mode the file had.
		#
		# GNU first, and each attempt's STDOUT discarded on failure: `-f` means
		# "filesystem" to GNU stat, so the BSD spelling does not merely fail
		# there — it prints a filesystem report to stdout, which the capture
		# then swallowed. The guard below saw non-digits and skipped the chmod,
		# so every Linux install narrowed 644 to 600 while claiming otherwise.
		old_mode="$(stat -c '%a' "$settings_real" 2>/dev/null)" ||
			old_mode="$(stat -f '%Lp' "$settings_real" 2>/dev/null)" || old_mode=""
		mv "$tmpfile" "$settings_real"
		case "$old_mode" in *[!0-9]* | '') ;; *) chmod "$old_mode" "$settings_real" 2>/dev/null || true ;; esac
		# Restore what the file had, then drop any write bit for group or
		# other. Readable by others is the owner's business and 0644 comes
		# back as 0644; WRITABLE by others is not, because every byte in here
		# is a command Claude Code will run as them.
		chmod go-w "$settings_real" 2>/dev/null || true
		say "$mode done: $settings_real (backup: $backup)"
		# With auto-hooks on this runs at every tmux start, so the copies add
		# up. Keep the five newest and drop the rest — they are snapshots of a
		# file that is itself under the user's own version control more often
		# than not.
		ls -1t "$settings_real".bak-claude-tabs-* 2>/dev/null | tail -n +6 |
			while IFS= read -r old_bak; do rm -f "$old_bak" 2>/dev/null; done
	fi
fi
fi   # skip_settings: nothing to read, write or back up

# Removing the hooks is only half of an uninstall: the spliced formats, key
# bindings and self-heal hooks live in the tmux server. Take those down too
# when we can reach a server; otherwise say what remains.
if [ "$mode" = uninstall ] && [ "$dry" -eq 0 ]; then
	# Inside tmux this is the current server. Outside, it is the DEFAULT server
	# (the one `tmux` with no -L talks to; TMUX_TMPDIR honoured) — which is the
	# only one most people have. Requiring an inside-tmux shell here left the
	# uninstall half done for anyone who ran it from a plain terminal, with the
	# badges still up and a message telling them to go run a second command.
	if command -v tmux >/dev/null 2>&1 && { [ -n "${TMUX:-}" ] || tmux list-sessions >/dev/null 2>&1; }; then
		"$repo/claude-tabs.tmux" uninstall 2>/dev/null || true
		say "tmux side cleared: formats, key bindings, hooks, badge options${TMUX:+} (${TMUX:+this server}${TMUX:-default server})"
	else
		say "no tmux server running — formats and bindings are already gone with it; a server on another socket needs '$repo/claude-tabs.tmux uninstall' from inside it"
	fi
fi

# Two parsers see this line: tmux strips its quoting layer, then run-shell
# hands the rest to sh -c — so the path needs sh quotes INSIDE tmux quotes,
# and any # doubled (run-shell format-expands its argument).
repo_fmt="${repo//"#"/"##"}"
line="run-shell \"'$repo_fmt/claude-tabs.tmux'\""

# A commented-out line is not a reference. `grep -qF claude-tabs.tmux` counted
# one, so someone who disabled the plugin by commenting the line out and then
# re-ran the installer was told "tmux.conf already references this clone" —
# and nothing was wired.
conf_mentions() { # conf_mentions <file> [literal]
	grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qF "${2:-claude-tabs.tmux}"
}
# The same trap resolve_link() was written for on the settings.json side, and
# the commoner one: ~/.tmux.conf is very often a symlink into a dotfiles repo.
# The uninstall below stages a temp file and renames it onto $tmux_conf, so it
# replaced the LINK with a regular file — the git-tracked copy silently stopped
# being the file tmux reads, still holding the plugin line, and the next
# dotfiles deploy quietly put it back. Resolve first and both branches operate
# on the file itself. A plain path comes back unchanged, so this is a no-op
# whenever --tmux-conf is not a link.
if [ -n "$tmux_conf" ]; then
	tmux_conf_given="$tmux_conf"
	tmux_conf="$(resolve_link "$tmux_conf")"
	[ "$tmux_conf" = "$tmux_conf_given" ] || say "following $tmux_conf_given -> $tmux_conf"
fi
if [ -n "$tmux_conf" ] && [ "$mode" = uninstall ]; then
	# Symmetry: --uninstall --tmux-conf removes the block it added instead of
	# appending one during an uninstall.
	if conf_mentions "$tmux_conf"; then
		if [ "$dry" -eq 1 ]; then
			say "--- would remove the tmux-claude-tabs block from $tmux_conf ---"
		else
			# Only a line that is NOTHING BUT our run-shell invocation may be
			# deleted. The old filter dropped any line mentioning the path
			# next to "run", which quietly ate the user's own command: an
			# if-shell wrapping our line lost its else branch with it, and a
			# backslash-continued if-shell lost its body and left a dangling
			# continuation that breaks the next config load. When the mention
			# is part of something larger, say where it is and change nothing.
			#
			# The awk also runs inside an `if` now. As a bare command its exit
			# 1 (nothing found) tripped `set -e` and killed the script, so the
			# "left it alone" branch below was unreachable and an uninstall
			# ended in a silent failure with two stray files behind it.
			conf_tmp="$tmux_conf.tmp.$$"
			# Create the temp file BEFORE awk runs, so a directory we cannot
			# write is reported as one. Both used to arrive as the same non-zero
			# status: the shell printed a raw "Permission denied" with a line
			# number, the failure was then read as awk's "found nothing", and an
			# uninstall on a root-owned /etc/tmux.conf said "no line found — left
			# it alone" and exited 0 with the line still in the file.
			# `2>` first: the shell reports a failed redirection on fd 2, so fd 2
			# has to be closed off before the one that fails, or the raw message
			# with a line number in it goes to the terminal anyway.
			: 2>/dev/null >"$conf_tmp" ||
				die "cannot write next to $tmux_conf — check the permissions on $(dirname "$tmux_conf")"
			if awk '
				function only_ours(l,   t, SQ) {
					SQ = sprintf("%c", 39)
					t = l
					sub(/\r$/, "", t); sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
					if (t !~ /^run(-shell)?[ \t]/) return 0
					sub(/^run(-shell)?[ \t]+/, "", t)
					gsub(/"/, "", t); gsub(SQ, "", t)
					sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
					return (t ~ /claude-tabs\.tmux$/)
				}
				# Lines that MIGHT belong to the block install wrote are parked
				# in pend[] instead of printed, so they can be dropped together
				# with it. Everything still pending goes out ahead of the next
				# line we keep, and at EOF.
				function flush(   i) {
					for (i = 1; i <= np; i++) print pend[i]
					np = 0; ourcomment = 0
				}
				/^[[:space:]]*$/ { pend[++np] = $0; prev = $0; next }
				/^[[:space:]]*#[[:space:]]*tmux-claude-tabs \(must come after/ {
					pend[++np] = $0; ourcomment = np; prev = $0; next
				}
				{
					if (index($0, "claude-tabs.tmux") > 0) {
						if (only_ours($0) && prev !~ /\\[[:space:]]*$/) {
							# Install writes "\n# comment\nrun-shell …", and only
							# the last two lines were ever removed — so every
							# install/uninstall cycle left one more blank line
							# behind and a one-line tmux.conf grew to six after
							# five rounds. Drop the separator too, but only when
							# our own comment is sitting above it (that is the
							# block install wrote) and only the one empty line it
							# actually added: blanks the user typed survive.
							if (ourcomment > 0) {
								np = ourcomment - 1
								if (np > 0 && pend[np] == "") np--
								ourcomment = 0
							}
							removed = 1; prev = $0; next
						}
						blocked = NR
					}
					flush()
					print
					prev = $0
				}
				END {
					flush()
					exit(removed ? 0 : (blocked ? 2 : 1))
				}' "$tmux_conf" >"$conf_tmp"; then
				cp "$tmux_conf" "$tmux_conf.bak-claude-tabs-$(date +%Y%m%d-%H%M%S)"
				mv "$conf_tmp" "$tmux_conf"
				conf_tmp=""
				say "removed the plugin line from $tmux_conf"
			else
				rc=$?
				rm -f "$conf_tmp"
				conf_tmp=""
				if [ "$rc" -eq 2 ]; then
					say "$tmux_conf mentions claude-tabs.tmux inside a larger command — left it alone, remove it by hand:"
					grep -n 'claude-tabs\.tmux' "$tmux_conf" | head -3 | while IFS= read -r l; do say "  $l"; done
				else
					say "no tmux-claude-tabs run-shell line found in $tmux_conf — left it alone"
				fi
			fi
		fi
	else
		say "$tmux_conf has no tmux-claude-tabs line"
	fi
elif [ -n "$tmux_conf" ]; then
	if conf_mentions "$tmux_conf"; then
		# "Already references" is not the same as "references THIS clone". A
		# config left pointing at a clone that has since moved loads nothing,
		# and saying only that it is referenced sends the user looking
		# elsewhere.
		if conf_mentions "$tmux_conf" "$repo/claude-tabs.tmux"; then
			say "tmux.conf already references this clone"
		else
			say "tmux.conf references a DIFFERENT claude-tabs.tmux than this one:"
			grep -n 'claude-tabs\.tmux' "$tmux_conf" | head -3 | while IFS= read -r l; do say "  $l"; done
			say "this clone is at $repo — update the line, or run --uninstall --tmux-conf first"
		fi
	elif [ "$dry" -eq 1 ]; then
		say "--- would append to $tmux_conf ---"
		say "$line"
	else
		# A typo in the path, or a tmux.conf the user cannot write, used to come
		# out as a raw "hooks/install.sh: line 513: …: No such file or directory" and
		# rc=1 — which reads like a bug in the installer. It also lands AFTER the
		# settings.json half has already been written and said "install done", so
		# the message has to say what is done and what is not. `2>` first: the
		# shell reports a failed redirection on fd 2, so fd 2 must already be
		# closed off for the raw message to go with it.
		printf '\n# tmux-claude-tabs (must come after your theme plugin sets its formats)\n%s\n' "$line" 2>/dev/null >>"$tmux_conf" ||
			die "cannot append to $tmux_conf — check that it exists and is writable.
The hooks in $settings are already wired; only the tmux.conf line is missing:
  $line"
		say "appended to $tmux_conf"
	fi
elif [ "$mode" = install ]; then
	say ""
	say "Now add this to your tmux.conf, AFTER the line that runs tpm/your theme:"
	say "  $line"
	say "then reload tmux (prefix r) or run: tmux run-shell '$repo/claude-tabs.tmux'"
fi
