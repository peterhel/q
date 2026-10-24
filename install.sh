#!/bin/sh
# Symlink q into the places Claude Code, the shell and systemd look. Runtime state (outbox,
# state, projects.json) stays in ~/.claude/queue; the code is read from this checkout.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
link() {
    mkdir -p "$(dirname "$2")"
    # A real file or folder from an earlier copy is kept beside it, never overwritten.
    if [ -e "$2" ] && [ ! -L "$2" ]; then mv "$2" "$2.orig"; echo "kept $2.orig"; fi
    ln -sfn "$1" "$2"; echo "$2 -> $1"
}
link "$here/q" "$HOME/.claude/queue/q"
link "$here/qbridge" "$HOME/.claude/queue/qbridge"
link "$here/pwa" "$HOME/.claude/queue/pwa"
link "$HOME/.claude/queue/q" "$HOME/.local/bin/q"
link "$here/skills/orkestrera" "$HOME/.claude/skills/orkestrera"
link "$here/systemd/qbridge.service" "$HOME/.config/systemd/user/qbridge.service"
echo "Add the Stop hook (see README), then: systemctl --user daemon-reload"
