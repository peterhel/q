# q: a project queue for Claude Code sessions

Drop thoughts, bugs and features into a project without interrupting the Claude Code session
working on it. The session picks them up when it finishes its turn, or an orchestrator session
sorts them and starts workers. `q -h` shows everything.

```
q "a thought"                to the project
q bug "corners blink"        with a type: idea | bug | feature
q -s myapp-2 "do X"          to one tmux session (q who lists the sessions working here)
q -p myapp "..."             from any folder (q projects)
q init                       start a queue in a new project, so the phone can reach it
q ls [-a]   q show ID   q take ID   q back ID   q done ID "what was done"   q note ID "..."
```

Python 3 standard library only. `spawn` needs tmux and the `claude` CLI.

## Install

```
./install.sh
```

It symlinks `q` and `qbridge` into `~/.claude/queue/` (where runtime state also lives), `q` into
`~/.local/bin/`, the `/orkestrera` skill into `~/.claude/skills/` and the systemd user unit into
`~/.config/systemd/user/`. Then add the Stop hook to `~/.claude/settings.json`:

```json
"hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "python3 ~/.claude/queue/q hook-stop" } ] } ] }
```

## The queue

- `<project root>/.queue/{new,ready,taken,peter,done}/`, one file per item, moved with rename.
  The project root is the git repo's main checkout, so all worktrees share one queue. `.queue/`
  is added to `.git/info/exclude`. (`peter` holds items waiting for an answer from the human.)
- The Stop hook (`q hook-stop`): items addressed to the session are handed over and the session
  carries on with them. Items for anyone are only mentioned, and while an orchestrator runs they
  go to it alone. Each item once per session. The handover lists everything else open and asks
  for an overlap check. `touch ~/.claude/queue/OFF` turns the hook off.

## Orchestrator and workers

- `/orkestrera` (skill in `skills/orkestrera/`, written in Swedish) in a tmux session: `q orch on`,
  watches `q watch`, sorts (`q merge`, `q ask`, `q ready ID area`), starts workers (`q spawn`),
  reviews and merges by the project's own rules, `q reap`.
- `q spawn ID`: worktree `<root>/.claude/worktrees/q-ID` (inside a trusted folder, so no trust
  dialog), branch `q/ID`, tmux session `<project>-w-<xyz>`, claude with `acceptEdits` and Bash
  in the sandbox (writes only in the worktree, `.queue` and `~/.claude/queue`;
  `allowUnsandboxedCommands: false`). At most one worker per area.
- **Ubuntu 24.04+ and AppArmor:** the profile `bwrap-userns-restrict` keeps processes in bwrap
  from CAP_SYS_ADMIN, and Claude Code's sandbox needs a nested user namespace, so workers lose
  Bash. Check with `bwrap --dev-bind / / unshare -U --map-root-user id -u`: it must print `0`.
  The sandbox fails closed, so a broken sandbox stops workers instead of running them
  unsandboxed.

## The phone

- `qbridge` (systemd user unit `qbridge.service`) listens on an ntfy topic (`Q_IN`) and answers on
  another (`Q_OUT`). Config `~/.config/q/ntfy.env` (mode 600):

  ```
  NTFY_URL=https://ntfy.example.com
  NTFY_TOKEN=tk_...        # read Q_IN, write Q_OUT
  NTFY_REPLY_TOKEN=tk_...  # optional: write-only on Q_IN, carried by notification buttons
  Q_IN=q-in
  Q_OUT=q-out
  ```

  Without the file the service does not start. Use a self-hosted ntfy with access control: the
  topics carry your project names and notes.
- Messages to `Q_IN`: `myapp: text`, `myapp/myapp-2: text`, `bug myapp: text` or `#bug` in the
  text, `ID: answer` to a question, `?` for the list, `undo ID`. The text is data: it is saved
  with q (an argument list, never a shell) and only for registered projects.
- `q ask` and `q tell` put messages in `~/.claude/queue/outbox/`, which qbridge sends.
- **Notification buttons:** a question gets answer buttons, `q ask ID "..." --opt Red --opt Blue`
  (at most 3, default Yes/No), and a button posts `ID: Red` to `Q_IN` straight from the
  notification. "q: added" gets an Undo button while the item is still in `new`. ntfy's app
  cannot take free text: post `ID: text` to `Q_IN` or use the PWA. Without `NTFY_REPLY_TOKEN`
  no buttons are sent.
- PWA in `pwa/`: pick project/session, type, text; shows replies and questions with an Answer
  button. The token is stored only in the phone's localStorage. Host it anywhere static.

Tests: `python3 -m pytest -q tests`.
