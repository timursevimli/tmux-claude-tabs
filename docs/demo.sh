#!/usr/bin/env bash
# Renders the README's pictures: docs/tabs.png (the status line) and
# docs/navigator.png (the popup).
#
# Everything here is invented: five windows named after projects that do not
# exist, on a tmux server of its own (-L claude-tabs-demo), with a supervisor
# directory of its own. It never reads ~/.claude and never touches the tmux
# server you are using. The badges are painted by the real hooks/claude-tabs.sh
# from fake payloads, so what ends up in the picture is the plugin's own
# output, not a mockup of it.
#
#   ./docs/demo.sh           write docs/tabs.png (needs chrome for the PNG)
#   ./docs/demo.sh --popup   write docs/navigator.png instead
#   ./docs/demo.sh --text    print the status line as ANSI and stop
#   ./docs/demo.sh --shot    photograph a REAL terminal window instead of
#                              rendering the capture (macOS; needs Screen
#                              Recording for the terminal app). Combine with
#                              --popup for the navigator shot.
#   ./docs/demo.sh --keep    leave the demo server up to poke at:
#                              tmux -L claude-tabs-demo attach -t demo
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK=claude-tabs-demo
SUP="$(mktemp -d "${TMPDIR:-/tmp}/ct-demo-sup.XXXXXX")"
DATA="$(mktemp -d "${TMPDIR:-/tmp}/ct-demo-data.XXXXXX")"
PIDS=""
tmux() { command tmux -L "$SOCK" "$@"; }

KEEP=0 SHOT=0
for a in "$@"; do
	[ "$a" = --keep ] && KEEP=1
	[ "$a" = --shot ] && SHOT=1
done
cleanup() {
	if [ "$KEEP" = 1 ]; then
		echo "demo: server left up — tmux -L $SOCK attach -t demo" >&2
		echo "demo: supervisor=$SUP data=$DATA" >&2
		return
	fi
	tmux kill-server 2>/dev/null
	[ -n "$PIDS" ] && kill $PIDS 2>/dev/null
	rm -rf "$SUP" "$DATA"
}
trap cleanup EXIT INT TERM

command -v tmux >/dev/null || { echo "demo: tmux is required" >&2; exit 1; }

# render_png <html> <out.png> — <html>.size carries the canvas the page needs.
# Existing is not the same as working: Homebrew leaves a `chromium` shim in
# PATH that execs an app it did not install, so each candidate is RUN, not
# merely tested for.
render_png() {
	local html="$1" out="$2" c chrome=""
	for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
		chromium chromium-browser google-chrome google-chrome-stable \
		"$HOME/Library/Caches/ms-playwright"/chromium_headless_shell-*/chrome-mac/headless_shell; do
		[ -n "$c" ] || continue
		"$c" --version >/dev/null 2>&1 || continue
		chrome="$c"
		break
	done
	if [ -z "$chrome" ]; then
		cp "$html" "${out%.png}.html"
		echo "demo: no chrome found — HTML left at ${out%.png}.html" >&2
		return 1
	fi
	"$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
		--force-device-scale-factor=2 --default-background-color=00000000 \
		--screenshot="$out" --window-size="$(tr ' ' ',' <"$html.size")" \
		"file://$html" >/dev/null 2>&1
	[ -s "$out" ] || { echo "demo: chrome produced nothing" >&2; return 1; }
	return 0
}


export CLAUDE_TABS_SUPERVISOR_DIR="$SUP"
export XDG_DATA_HOME="$DATA"

# --- a server of our own, five windows, none of them yours --------------------
tmux kill-server 2>/dev/null
sleep 0.2
POPUP=0
for a in "$@"; do [ "$a" = --popup ] && POPUP=1; done
# The popup shot needs a taller screen than the status-line strip does.
if [ "$POPUP" = 1 ]; then COLS=112 ROWS=30
elif [ "$SHOT" = 1 ]; then COLS=118 ROWS=6   # a strip: a few lines and the bar
else COLS=118 ROWS=12
fi

# Each window runs a short invented transcript and then idles, so the
# navigator's preview (a live capture-pane of the session) is not a blank box.
# The preview follows the bottom of the pane, the way it does for a real
# session whose output has filled the screen. A short transcript printed at
# the top would leave the preview looking at blank rows, so pad it down.
fake_session() { # fake_session <transcript>
	# Pad so the LAST line of the transcript sits on the last row of the pane.
	# The preview follows the bottom, the way it does for a real session whose
	# output has filled the screen, so a transcript printed at the top would
	# leave the preview looking at blank rows — and the window behind the
	# popup would be mostly empty too.
	local pad="" i=0 n have
	have=$(printf '%s' "$1" | awk '{ n = gsub(/\\\\n/, "&"); print n }')
	n=$(( ROWS - 1 - have ))
	[ "$n" -lt 0 ] && n=0
	while [ "$i" -lt "$n" ]; do pad="$pad\\n"; i=$((i + 1)); done
	printf 'printf %s; sleep 900' "$(printf '%q' "$pad$1")"
}
tmux -f /dev/null new-session -d -s demo -x "$COLS" -y "$ROWS" -n zsh 'sleep 900'
tmux new-window -t demo -n web   -d "$(fake_session '\n> add the retry path to the client\n\n  Read  src/client.ts\n  Edit  src/client.ts  +18 -2\n  Bash  npm test\n    ✓ 41 passed (2.1s)\n\n Retries now back off 200ms → 1.6s over four\n attempts, and a 429 is retried where a 400\n is not.\n\n> ')"
tmux new-window -t demo -n api   -d "$(fake_session '\n> drop the legacy /v1 routes\n\n  Grep  "/v1/" (14 files)\n\n Fourteen files still reference them; two are\n in the public SDK.\n\n  Bash  git rm -r src/routes/v1\n\n Allow this command? \n   1. Yes\n   2. No, tell Claude what to do differently\n\n ❯ ')"
tmux new-window -t demo -n docs  -d "$(fake_session '\n> rewrite the install section\n\n  Edit  README.md  +31 -47\n\n Cut to one line plus the reload, with the\n settings.json edit disclosed above the\n snippet that turns it on.\n\n> ')"
tmux new-window -t demo -n infra -d "$(fake_session '\n> deploy staging and watch it land\n\n  Bash  terraform apply -auto-approve\n        (running in the background)\n\n Applying. I will report when it settles.\n\n> ')"
# docs holds three Claudes: two more panes, so the badge can carry its count
tmux split-window -d -t demo:3 'sleep 300'
tmux split-window -d -t demo:3 'sleep 300'

# A real theme, not tmux's bare default: the gruvbox powerline look, with the
# same colours and the same U+E0B0 separator a themed setup actually produces.
# The point of the picture is that the badge splices into someone else's
# status line, so the status line has to look like someone else's.
SEP=$'\ue0b0'
BG=#3c3836 DIM=#504945 CUR=#fabd2f FG=#ebdbb2 MUT=#bdae93 SL=#665c54
tmux set -g status-style "bg=$BG,fg=$FG"
tmux set -g status-position bottom
tmux set -g status-justify left
tmux set -g status-right ''
tmux set -g status-left "#[bg=$SL,fg=$MUT] #S #[bg=$BG,fg=$SL,nobold,noitalics,nounderscore]$SEP"
tmux setw -g window-status-separator ''
tmux setw -g window-status-format \
	"#[bg=$DIM,fg=$BG,noitalics]$SEP#[bg=$DIM,fg=$FG] #I #[bg=$DIM,fg=$FG] #W #[bg=$BG,fg=$DIM,noitalics]$SEP"
tmux setw -g window-status-current-format \
	"#[bg=$CUR,fg=$BG,nobold,noitalics,nounderscore]$SEP#[bg=$CUR,fg=$DIM] #I #[bg=$CUR,fg=$DIM,bold] #W #[bg=$BG,fg=$CUR,nobold,noitalics,nounderscore]$SEP"

# --- the plugin itself --------------------------------------------------------
# $TMUX must be exported BEFORE anything of ours runs. Every script here calls
# plain `tmux`, which without it connects to the DEFAULT socket — i.e. the
# server you are actually using. Getting this wrong once spliced this demo's
# formats, bindings and self-heal hooks into a live session; the hooks even
# doubled up, because removal matches by the plugin's own path and this copy
# sits somewhere else. Set it first, and every command below is confined to
# the demo server.
export TMUX="$(tmux display -p '#{socket_path}'),$(tmux display -p '#{pid}'),0"

# Full width on purpose: at 96% a two-column sliver of the window underneath
# showed through as single stray letters, which reads as a broken render
# rather than as "a popup over your work".
tmux set -g @claude-tabs-popup-width 100%
tmux set -g @claude-tabs-popup-height 88%
# A quiet border and the same ground as the terminal: the default is a bright
# line that draws the eye away from what the picture is about.
tmux set -g popup-border-style 'fg=#504945'
tmux set -g popup-style 'bg=#282828'
tmux set -g popup-border-lines rounded
tmux set -g @claude-tabs-poll off        # the picture is a still; no daemon needed
tmux set -g @claude-tabs-notify off      # no clients here, so every state would notify
tmux set -g @claude-tabs-watch-ticks 0   # no background watchers outliving the run
tmux set -g @claude-tabs-sync-on-load off
bash "$REPO/claude-tabs.tmux" >/dev/null 2>&1

# --- fake sessions, real hook -------------------------------------------------
# hook <pane> <event> <json>
hook() {
	local p="$1" ev="$2" js="$3"
	TMUX_PANE="$p" bash "$REPO/hooks/claude-tabs.sh" "$ev" <<<"$js" >/dev/null 2>&1
}
pane() { tmux list-panes -t "demo:$1" -F '#{pane_id}' | sed -n "${2:-1}p"; }

W=$(pane 1); A=$(pane 2); D1=$(pane 3 1); D2=$(pane 3 2); D3=$(pane 3 3); I=$(pane 4)

# web — mid-turn, running a tool (the current window, so it shows its label)
hook "$W" prompt '{"session_id":"d-web"}'
hook "$W" tool '{"session_id":"d-web","tool_name":"Bash"}'
# api — blocked on a permission prompt
hook "$A" prompt '{"session_id":"d-api"}'
hook "$A" permission '{"session_id":"d-api","tool_name":"Edit"}'
# docs — three sessions, all finished
hook "$D1" prompt '{"session_id":"d-docs1"}'; hook "$D1" stop '{"session_id":"d-docs1"}'
hook "$D2" prompt '{"session_id":"d-docs2"}'; hook "$D2" stop '{"session_id":"d-docs2"}'
hook "$D3" prompt '{"session_id":"d-docs3"}'; hook "$D3" stop '{"session_id":"d-docs3"}'
# infra — the turn ended, a background job did not
hook "$I" prompt '{"session_id":"d-infra"}'
hook "$I" tool '{"session_id":"d-infra","tool_name":"Bash","tool_input":{"run_in_background":true}}'
hook "$I" stop '{"session_id":"d-infra","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"terraform apply"}]}'

# The navigator lists what the supervisor reports, not what the badges say, so
# the popup shot needs session files too — one per window, plus two sessions
# that ended earlier and are still resumable.
if [ "$POPUP" = 1 ]; then
	i=0
	for w in 1 2 3 4; do
		i=$((i + 1))
		p="$(pane "$w")"
		sleep 900 >/dev/null 2>&1 &
		PIDS="$PIDS $!"
		case $w in
		1) st=busy    dir=/home/you/web ;;
		2) st=waiting dir=/home/you/api ;;
		3) st=idle    dir=/home/you/docs ;;
		4) st=shell   dir=/home/you/infra ;;
		esac
		printf '%s' "{\"pid\":$!,\"sessionId\":\"demo-s$i\",\"kind\":\"interactive\",\"status\":\"$st\",\"cwd\":\"$dir\",\"statusUpdatedAt\":$(( ($(date +%s) - i * 70) * 1000 )),\"tmux\":\"demo:@$w.$p\"}" \
			>"$SUP/$!.json"
	done
	spool="$DATA/tmux-claude-tabs/ended"
	mkdir -p "$spool"
	printf '%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 8100 ))" demo-e1 /home/you/scraper prompt_input_exit - >"$spool/demo-e1"
	printf '%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 1500 ))" demo-e2 /home/you/notes clear - >"$spool/demo-e2"
fi

tmux select-window -t demo:1     # "web" is the window you are looking at
sleep 0.4

# shoot <out.png> [pre-capture command...] — photograph a REAL terminal window.
# Everything the HTML path can only approximate (font shaping, hinting, the
# terminal's own colour handling) is simply correct here, because it IS a
# terminal. Only the demo window is captured, by its window id — never the
# screen, and never any other window.
#
# The capture cannot run from this script. A tmux server is a daemon
# reparented to launchd, so macOS attributes anything started here to tmux,
# while screen-recording rights belong to the terminal app; confirmed in the
# TCC log, which named the terminal as the responsible process. So a second,
# throwaway terminal window runs the capture as a child of that app.
SHOT_TITLE=claude-tabs-demo-shot
shoot() {
	local out="$1"; shift
	local drv="$DATA/shoot.sh" res="$DATA/shoot.res" cl i
	rm -f "$out" "$res"

	tmux set -g set-titles off      # let the terminal keep the title we gave it
	open -na Ghostty --args --title="$SHOT_TITLE" \
		--window-width="$COLS" --window-height="$ROWS" \
		--background=#282828 --foreground=#ebdbb2 --window-decoration=false \
		--background-image= --background-opacity=1 --font-size=26 \
		--window-padding-x=12 --window-padding-y=10 \
		-e tmux -L "$SOCK" attach -t demo >/dev/null 2>&1

	for i in $(seq 1 40); do
		cl="$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -1)"
		[ -n "$cl" ] && break
		sleep 0.25
	done
	[ -n "$cl" ] || { echo "demo: no terminal attached" >&2; return 1; }
	sleep 1.2                        # first paint

	if [ "$#" -gt 0 ]; then
		CLIENT="$cl" "$@"
		sleep 2.5                    # let fzf draw and its preview land
	fi

	cat >"$drv" <<-DRIVER
		#!/bin/bash
		# The window id comes back as the script's RESULT, not through
		# console.log — in JXA that writes to stderr, and the id vanished.
		id=\$(osascript -l JavaScript <<'JS' 2>/dev/null
		(function () {
		  ObjC.import("CoreGraphics"); ObjC.import("Foundation");
		  const arr = ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(1 | 16, 0));
		  for (let i = 0; i < arr.count; i++) {
		    const w = arr.objectAtIndex(i);
		    const nm = w.objectForKey("kCGWindowName");
		    if (nm && ObjC.unwrap(nm).indexOf("$SHOT_TITLE") >= 0) {
		      return String(ObjC.unwrap(w.objectForKey("kCGWindowNumber")));
		    }
		  }
		  return "";
		})()
		JS
		)
		[ -n "\$id" ] && screencapture -x -o -l "\$id" "$out" 2>/dev/null
		[ -s "$out" ] && echo ok >"$res" || echo "no-window" >"$res"
	DRIVER
	chmod +x "$drv"
	open -na Ghostty --args --window-width=40 --window-height=3 -e "$drv" >/dev/null 2>&1
	for i in $(seq 1 60); do [ -f "$res" ] && break; sleep 0.5; done

	tmux detach-client -a 2>/dev/null   # ends the attach, so the window closes
	tmux detach-client 2>/dev/null
	[ -s "$out" ]
}

# --- the popup, photographed through a nested client --------------------------
# A tmux popup is drawn over the client's screen, so capture-pane on the demo
# server cannot see it. Attaching the demo server inside ANOTHER tmux makes its
# whole screen — popup included — the contents of one ordinary pane, which
# capture-pane -e then hands over with its colours intact.
if [ "$POPUP" = 1 ] && [ "$SHOT" = 1 ]; then
	open_nav() { tmux run-shell -b "'$REPO/scripts/navigator.sh' open '$CLIENT' /home/you/web"; }
	shoot "$REPO/docs/navigator.png" open_nav || { echo "demo: capture failed" >&2; exit 1; }
	echo "demo: wrote $REPO/docs/navigator.png"
	exit 0
fi
if [ "$SHOT" = 1 ]; then
	shoot "$REPO/docs/tabs.png" || { echo "demo: capture failed" >&2; exit 1; }
	echo "demo: wrote $REPO/docs/tabs.png"
	exit 0
fi
if [ "$POPUP" = 1 ]; then
	OUTER=claude-tabs-demo-outer
	outer() { command tmux -L "$OUTER" "$@"; }
	outer kill-server 2>/dev/null
	sleep 0.2
	outer -f /dev/null new-session -d -x "$COLS" -y "$ROWS" \
		"tmux -L $SOCK attach -t demo"
	outer set -g status off
	sleep 1.5
	cl="$(tmux list-clients -F '#{client_name}' | head -1)"
	[ -n "$cl" ] || { echo "demo: no client attached" >&2; exit 1; }
	tmux run-shell -b "'$REPO/scripts/navigator.sh' open '$cl' /home/you/web"
	sleep 4                     # fzf draws, then the preview capture lands
	outer capture-pane -p -e >"$DATA/screen.ansi"
	outer kill-server 2>/dev/null
	python3 - "$DATA/screen.ansi" "$DATA/popup.html" <<'PYX'
import html, re, sys, unicodedata

# xterm-256 -> hex, enough of it for what tmux and fzf emit here.
# gruvbox dark, so the popup shot and the status-line shot are the same world
BASE = ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286",
        "#689d6a", "#a89984", "#928374", "#fb4934", "#b8bb26", "#fabd2f",
        "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]
def xterm(n):
    if n < 16:
        return BASE[n]
    if n < 232:
        n -= 16
        r, g, b = n // 36, (n % 36) // 6, n % 6
        f = lambda v: 0 if v == 0 else 55 + 40 * v
        return "#%02x%02x%02x" % (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)

FG, BG = "#ebdbb2", "#282828"
src, out = sys.argv[1], sys.argv[2]
rows = open(src, encoding="utf-8", errors="replace").read().split("\n")
# Trim blank rows at both ends. A terminal screenshot is judged on density,
# and rows of nothing above the popup are what made the first attempts look
# like an empty desk with a window on it.
def blank(r):
    return not re.sub(r"\x1b\[[0-9;]*m", "", r).strip()
while rows and blank(rows[-1]):
    rows.pop()
while rows and blank(rows[0]):
    rows.pop(0)

WIDTH = max(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1
                for c in re.sub(r"\x1b\[[0-9;]*m", "", r)) for r in rows)
lines = []
for row in rows:
    fg = bg = None; bold = rev = False; buf = []
    for part in re.split(r"(\x1b\[[0-9;]*m)", row):
        if not part:
            continue
        if part.startswith("\x1b["):
            codes = [c for c in part[2:-1].split(";") if c != ""] or ["0"]
            i = 0
            while i < len(codes):
                c = int(codes[i])
                if c == 0: fg = bg = None; bold = rev = False
                elif c == 1: bold = True
                elif c == 22: bold = False
                elif c == 7: rev = True
                elif c == 27: rev = False
                elif 30 <= c <= 37: fg = xterm(c - 30)
                elif 90 <= c <= 97: fg = xterm(c - 90 + 8)
                elif 40 <= c <= 47: bg = xterm(c - 40)
                elif 100 <= c <= 107: bg = xterm(c - 100 + 8)
                elif c == 39: fg = None
                elif c == 49: bg = None
                elif c in (38, 48) and i + 2 < len(codes) and codes[i + 1] == "5":
                    v = xterm(int(codes[i + 2]))
                    if c == 38: fg = v
                    else: bg = v
                    i += 2
                elif c in (38, 48) and i + 4 < len(codes) and codes[i + 1] == "2":
                    # Truecolor. A themed status line is full of it, and
                    # without this branch the r/g/b arrived as three separate
                    # SGR codes: "2" reset nothing, then 60 and 60 fell
                    # through, and the bar rendered as one solid block.
                    v = "#%02x%02x%02x" % tuple(int(codes[i + 2 + k]) for k in range(3))
                    if c == 38: fg = v
                    else: bg = v
                    i += 4
                i += 1
            continue
        f, b = fg or FG, bg or BG
        if rev: f, b = b, f
        st = f"color:{f};background:{b}" + (";font-weight:700" if bold else "")
        # A wide character is two terminal cells but not two monospace
        # advances, so pin it to 2ch or every column after it drifts. Which
        # characters those are is decided by East_Asian_Width, not by a
        # codepoint range: "⏹" sits among the emoji and is ONE cell, and
        # boxing it like the rest pushed the ended rows a column right.
        for chunk in re.split(r"([\U00002190-\U0001FAFF])", part):
            if not chunk:
                continue
            if len(chunk) == 1 and unicodedata.east_asian_width(chunk) in "WF":
                buf.append(f'<span style="{st};display:inline-block;width:2ch;'
                           f'text-align:center">{html.escape(chunk)}</span>')
            else:
                buf.append(f'<span style="{st}">{html.escape(chunk)}</span>')
    # capture-pane trims trailing blanks, which cuts the status line off where
    # its text ends — a real one spans the terminal. Pad back to full width;
    # the SGR state at the end of the row is the bar's own background, so the
    # padding continues it exactly.
    w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1
            for c in re.sub(r"\x1b\[[0-9;]*m", "", row))
    if w < WIDTH:
        f, b = fg or FG, bg or BG
        if rev: f, b = b, f
        buf.append(f'<span style="color:{f};background:{b}">{"&nbsp;" * (WIDTH - w)}</span>')
    lines.append("".join(buf) or "&nbsp;")

open(out + ".size", "w").write("%d %d" % (int(WIDTH * 9.06) + 34, len(lines) * 20 + 34))
open(out, "w", encoding="utf-8").write(
    "<!doctype html><meta charset=utf-8><style>"
    "html,body{margin:0;background:%s;overflow:hidden}"
    ".s{padding:14px;white-space:pre;color:%s;"
    "font:15px/1.27 'JetBrainsMono Nerd Font','JetBrainsMono NF',"
    "'Hack Nerd Font','SF Mono',Menlo,monospace;"
    "-webkit-font-smoothing:antialiased}" % (BG, FG) +
    "</style><div class=s>" + "\n".join(lines) + "</div>")
PYX
	png="$REPO/docs/navigator.png"
	render_png "$DATA/popup.html" "$png" || exit 1
	echo "demo: wrote $png"
	exit 0
fi

# --- pull the rendered line out -----------------------------------------------
line="$(tmux display-message -p -t demo:1 \
	'#{T:status-left}#{W:#{E:window-status-format},#{E:window-status-current-format}}')"

if [ "${1:-}" = --text ]; then
	printf '%s\n' "$line" |
		sed -e 's/#\[fg=colour\([0-9]*\),bold\]/\\033[1;38;5;\1m/g' \
			-e 's/#\[fg=colour\([0-9]*\),bg=colour\([0-9]*\),bold\]/\\033[1;38;5;\1;48;5;\2m/g' \
			-e 's/#\[fg=colour\([0-9]*\)\]/\\033[38;5;\1m/g' \
			-e 's/#\[nobold\]/\\033[22m/g' \
			-e 's/#\[default\]/\\033[0m/g' |
		xargs -0 printf '%b\n'
	exit 0
fi

# --- tmux style tags -> HTML -> PNG -------------------------------------------
printf '%s' "$line" >"$DATA/line.txt"
python3 - "$DATA/line.txt" "$DATA/tabs.html" <<'PYT'
import html, re, sys

GRUV = {236: "#32302f", 238: "#3c3836", 245: "#928374", 223: "#ebdbb2",
        108: "#8ec07c", 109: "#83a598", 142: "#b8bb26", 167: "#fb4934",
        175: "#d3869b", 214: "#fabd2f", 32: "#83a598", 31: "#fb4934",
        35: "#d3869b", 34: "#b8bb26", 90: "#928374", 33: "#fabd2f"}
BG, FG = "#3c3836", "#ebdbb2"
src, out = sys.argv[1], sys.argv[2]
line = open(src, encoding="utf-8").read()

def colour(tok):
    v = tok.split("=", 1)[1]
    if v.startswith("#"):
        return v
    if v.startswith("colour"):
        return GRUV.get(int(v[6:]), FG)
    return {"default": None}.get(v, v)

spans, fg, bg, bold = [], None, None, False
for part in re.split(r"(#\[[^\]]*\])", line):
    if not part:
        continue
    if part.startswith("#["):
        for tok in part[2:-1].split(","):
            if tok in ("default",):
                fg = bg = None; bold = False
            elif tok == "bold":
                bold = True
            elif tok in ("nobold", "noitalics", "nounderscore"):
                if tok == "nobold":
                    bold = False
            elif tok.startswith("fg="):
                fg = colour(tok)
            elif tok.startswith("bg="):
                bg = colour(tok)
        continue
    st = f"color:{fg or FG};background:{bg or BG}" + (";font-weight:700" if bold else "")
    spans.append(f'<span style="{st}">{html.escape(part)}</span>')

plain = re.sub(r"#\[[^\]]*\]", "", line)
wide = sum(1 for ch in plain if 0x1F000 <= ord(ch) <= 0x1FAFF or 0x2600 <= ord(ch) <= 0x27BF)
cols = len(plain) - wide + wide * 2
# A real status line spans the terminal, so trailing background is not
# padding to be trimmed — it is what the bar looks like. Overshoot a little
# rather than clip the last window off the right.
open(out + ".size", "w").write("%d %d" % (int(cols * 9.06) + 40, 30))
open(out, "w", encoding="utf-8").write(
    "<!doctype html><meta charset=utf-8><style>"
    "html,body{margin:0;background:%s;overflow:hidden}"
    ".bar{color:%s;background:%s;white-space:pre;"
    "font:15px/1.85 'JetBrainsMono Nerd Font','JetBrainsMono NF',"
    "'Hack Nerd Font','SF Mono',Menlo,monospace;"
    "-webkit-font-smoothing:antialiased}"
    "</style><div class=bar>" % (BG, FG, BG) + "".join(spans) + "</div>")
PYT

render_png "$DATA/tabs.html" "$REPO/docs/tabs.png" || exit 1
echo "demo: wrote $REPO/docs/tabs.png"
