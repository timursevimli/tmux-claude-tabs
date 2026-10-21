# Tests

`contract.sh` checks the REAL `~/.claude/sessions` files on this machine
against the fast path's format assumptions — run it after a Claude Code
update. The plugin also self-detects drift at runtime (falls back to the
documented `claude agents --json` and shows a one-line notice, once a day).

`regression.sh` is a self-contained regression (it prints its own pass/fail/
skip counts; a skipped check is counted as neither) over the hook state
machine, notifications, spool history, the session-file fast path, background
tasks resolved through the process tree, the watcher, the poller (seed,
transitions, quiet ticks, the hooks-fresh discriminator, death-to-history,
daemon token lifecycle), window aggregation,
sweep, navigator sort order, the jump key's walk, badge injection, key
(un)binding, the tmux-side uninstall, hook surgery, migration and hooks/install.sh.
On a machine whose /bin/bash is 3.2 it also parses every script and runs the
two data paths under it — the navigator was once dead on stock macOS while
only the hook was being tested there.
It needs bash, tmux, jq, fzf (the picker checks skip without it) and python3 (one fixture spawns a process with no
controlling terminal), and never touches your real tmux server or
`~/.claude` (supervisor and data dirs are overridden via env).

Run it on Linux in a container, with the repo mounted at `/repo`:

```sh
docker run --rm -v "$PWD":/repo:ro -v "$PWD/tests/regression.sh":/test.sh:ro \
  ubuntu:24.04 bash -c 'apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux jq fzf procps locales && \
    locale-gen en_US.UTF-8; LANG=en_US.UTF-8 bash /test.sh'
```

Verified green on: macOS (BSD userland, tmux 3.7; every script parse-checked
and the two data paths run under stock /bin/bash 3.2), Debian 12 (tmux 3.3a,
mawk 1.3.4-2020 — the oldest stack in the matrix), Ubuntu 24.04 (mawk,
tmux 3.4), Fedora 44 (tmux 3.7c), Arch.

It is safe on the host too: every tmux call goes to a dedicated socket
(`-L claude-tabs-test`, override with `CLAUDE_TABS_TEST_SOCKET`), which the
suite creates and kills itself, and `TMUX_TMPDIR` is pointed at
`/tmp/ct-tmuxdir`, so even the checks that call plain `tmux` (the uninstall
ones) never reach the server you run it from. Set `REPO=$PWD` when running
outside a container.
