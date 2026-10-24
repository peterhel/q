#!/usr/bin/env python3
"""q: a per-project queue of thoughts, bugs and features, fed without disturbing a working session.

Anyone (Peter, from a terminal or the phone):
  q TEXT...                    add an item for the project (the orchestrator sorts it)
  q bug|idea|feature TEXT...   the same with a type
  q -s SESSION TEXT...         addressed to one tmux session (see `q who`)
  q -p PROJECT ...             act on a registered project from anywhere (see `q projects`)
  q ls [-a]   q show ID   q note ID TEXT...   q who [--all]   q projects
  q init                       start a queue here, so the phone can reach the project

Sessions:
  q take ID   q back ID   q done ID [NOTE...]
  q ask ID QUESTION... [--opt ANSWER]...
                               park the item for Peter and send him the question; each --opt
                               (max 3) is a reply button in the notification, default Yes/No
  q answer ID TEXT...          Peter's answer; the item goes back to new

The orchestrator (skill /orkestrera):
  q orch on|off                this session orchestrates the project
  q ready ID [AREA]            sorted and ready to be worked; AREA = what it touches
  q merge ID INTO              ID is the same as INTO: folded in, closed
  q spawn ID                   a worker: worktree .claude/worktrees/q-ID, branch q/ID, tmux
  q reap ID                    remove a finished worker's tmux session and worktree
  q watch                      one line per change in the queue (for the Monitor tool)
  q tell TEXT...               a short message to Peter's phone

Items live in <root>/.queue/<state>/<id>.md, states new → ready → taken → done, plus peter (waiting
for an answer). One file per item, moved with rename, so two sessions can never take the same one.
The project root is the main checkout of a git repo (all its worktrees share one queue), else the
nearest folder holding .queue, else the current folder. q never writes outside <root>/.queue,
~/.claude/queue and, for spawn, the worker's worktree beside the root.

`q hook-stop` is the Claude Code Stop hook: a session ending a turn is told, once, about new items
addressed to it (and carries on with them). Items for anyone go to the orchestrator when one is on,
otherwise every session in the project hears of them. ~/.claude/queue/OFF turns the hook off.
"""
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("Q_HOME", Path.home() / ".claude" / "queue"))
STATES = ("new", "ready", "taken", "peter", "done")
OPEN = ("new", "ready", "taken", "peter")
TYPES = ("idea", "bug", "feature")
ID_RE = re.compile(r"^\d{6}-\d{4}-[a-z2-7]{3}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.\-åäöÅÄÖ]{1,64}$")
MAX_TEXT = 8000


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def die(msg):
    sys.exit(f"q: {msg}")


# ── where ─────────────────────────────────────────────────────────────────────────────────────

def _git(cwd, *args):
    try:
        r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def project_root(cwd):
    cwd = Path(cwd).resolve()
    common = _git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common:
        c = Path(common)
        if c.name == ".git":
            return c.parent
        top = _git(cwd, "rev-parse", "--show-toplevel")
        if top:
            return Path(top)
    for d in (cwd, *cwd.parents):
        if (d / ".queue").is_dir():
            return d
    return cwd


def qdir(root, create=False):
    q = root / ".queue"
    if create:
        for s in (*STATES, "tmp"):
            (q / s).mkdir(parents=True, exist_ok=True)
        _exclude_from_git(root)
        register(root)
    return q


def _exclude_from_git(root, entry=".queue/"):
    """Keep .queue (and workers' worktrees) out of git without touching the tracked .gitignore."""
    ex = root / ".git" / "info" / "exclude"
    if not ex.parent.is_dir():
        return
    lines = ex.read_text().splitlines() if ex.exists() else []
    if entry not in lines:
        with ex.open("a") as f:
            f.write(("\n" if lines and lines[-1] else "") + entry + "\n")


# ── projects ──────────────────────────────────────────────────────────────────────────────────

def _registry():
    p = HOME / "projects.json"
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return {}


def register(root):
    """Name a project by its folder; on a clash, by parent-folder."""
    reg = _registry()
    if str(root) in reg.values():
        return
    name = root.name
    if name in reg:
        name = f"{root.parent.name}-{root.name}"
    reg[name] = str(root)
    HOME.mkdir(parents=True, exist_ok=True)
    tmp = HOME / "projects.json.tmp"
    tmp.write_text(json.dumps(reg, indent=1, ensure_ascii=False))
    os.rename(tmp, HOME / "projects.json")


def project_by_name(name):
    reg = _registry()
    if name not in reg:
        die(f"no project {name!r} (known: {', '.join(sorted(reg)) or 'none'})")
    return Path(reg[name])


def project_name(root):
    for k, v in _registry().items():
        if v == str(root):
            return k
    return root.name


# ── who ───────────────────────────────────────────────────────────────────────────────────────

def my_session():
    """This tmux session's name, or None outside tmux. Q_SESSION overrides (tests)."""
    if "Q_SESSION" in os.environ:
        return os.environ["Q_SESSION"] or None
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return None
    try:
        r = subprocess.run(["tmux", "display", "-p", "-t", pane, "#S"],
                           capture_output=True, text=True, timeout=3)
        return (r.stdout.strip() or None) if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _claude_panes():
    if "Q_SESSIONS" in os.environ:
        return [(n, Path(p)) for n, p in json.loads(os.environ["Q_SESSIONS"]).items()]
    try:
        r = subprocess.run(["tmux", "list-panes", "-a", "-F",
                            "#S\t#{pane_current_path}\t#{pane_current_command}"],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[2] == "claude":
            out.append((parts[0], Path(parts[1])))
    return out


def sessions_in(root):
    """{tmux session: path} for panes running claude under root (worktrees included)."""
    return {n: str(p) for n, p in _claude_panes() if project_root(p) == root}


def orchestrator(root):
    """The orchestrator's session name, if it is on and still running."""
    f = qdir(root) / "orch"
    try:
        name = f.read_text().strip()
    except OSError:
        return None
    return name if name in sessions_in(root) else None


# ── items ─────────────────────────────────────────────────────────────────────────────────────

def new_id():
    alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    return time.strftime("%y%m%d-%H%M") + "-" + "".join(secrets.choice(alphabet) for _ in range(3))


FIELDS = ("id", "type", "to", "from", "created", "area", "taken_by", "taken", "worktree",
          "branch", "done")


def parse(path):
    text = path.read_text()
    meta, body = {}, text
    if text.startswith("---\n"):
        head, _, body = text[4:].partition("\n---\n")
        for line in head.splitlines():
            k, _, v = line.partition(":")
            meta[k.strip()] = v.strip()
    meta["body"] = body.strip()
    meta["state"] = path.parent.name
    meta.setdefault("id", path.stem)
    return meta


def render(meta):
    head = "\n".join(f"{k}: {meta[k]}" for k in FIELDS if meta.get(k))
    return f"---\n{head}\n---\n{meta['body'].strip()}\n"


def _write(q, path, meta):
    tmp = q / "tmp" / path.name
    tmp.write_text(render(meta))
    os.rename(tmp, path)


def find(q, item_id):
    if not ID_RE.match(item_id or ""):
        die(f"no such id {item_id!r}")
    for s in STATES:
        p = q / s / f"{item_id}.md"
        if p.exists():
            return p
    die(f"no item {item_id}")


def items(q, states=OPEN):
    out = []
    for s in states:
        d = q / s
        if d.is_dir():
            out += [parse(p) for p in sorted(d.glob("*.md"))]
    return out


def title(meta, width=70):
    line = meta["body"].splitlines()[0] if meta["body"] else ""
    return line if len(line) <= width else line[:width - 1] + "…"


def _move(root, item_id, to_state, expect=None, **updates):
    q = qdir(root, create=True)
    src = find(q, item_id)
    if expect and src.parent.name not in expect:
        die(f"{item_id} is {src.parent.name}, not {'/'.join(expect)}")
    dst = q / to_state / src.name
    try:
        os.rename(src, dst)            # atomic: of two sessions, only one wins
    except FileNotFoundError:
        die(f"{item_id} was moved by someone else")
    meta = parse(dst)
    for k, v in updates.items():
        if v is None:
            meta.pop(k, None)
        else:
            meta[k] = v
    _write(q, dst, meta)
    return meta, dst


def _note(meta, who, text):
    meta["body"] += f"\n\nNote ({who}, {time.strftime('%Y-%m-%d %H:%M')}): {text}"


# ── phone ─────────────────────────────────────────────────────────────────────────────────────

def to_phone(kind, root, text, item=None, options=None):
    """Drop a message for the bridge (qbridge) to send. Never fails the caller."""
    try:
        out = HOME / "outbox"
        out.mkdir(parents=True, exist_ok=True)
        msg = {"kind": kind, "project": project_name(root), "item": item,
               "from": my_session() or "terminal", "text": text[:MAX_TEXT], "at": now()}
        if options:
            msg["options"] = options
        name = f"{time.time_ns()}-{secrets.token_hex(2)}.json"
        (out / f".{name}").write_text(json.dumps(msg, ensure_ascii=False))
        os.rename(out / f".{name}", out / name)
    except OSError:
        pass


# ── commands: anyone ──────────────────────────────────────────────────────────────────────────

def cmd_add(root, args):
    to, force, kind = None, False, "idea"
    while args and args[0].startswith("-") and args[0] != "-":
        a = args.pop(0)
        if a in ("-s", "--to"):
            to = args.pop(0) if args else die("-s needs a session")
        elif a in ("-f", "--force"):
            force = True
        else:
            die(f"unknown flag {a}")
    if args and args[0] in TYPES:
        kind = args.pop(0)
    text = sys.stdin.read() if args == ["-"] else " ".join(args)
    if not text.strip():
        die("nothing to add")
    if len(text) > MAX_TEXT:
        die(f"longer than {MAX_TEXT} characters")
    if to in ("orch", "orchestrator"):
        to = orchestrator(root) or die("no orchestrator is on in this project")
    if to and not force:
        here = sessions_in(root)
        if to not in here:
            die(f"no Claude session {to!r} in {root} (here: {', '.join(sorted(here)) or 'none'})."
                " -f to add anyway.")
    q = qdir(root, create=True)
    meta = {"id": new_id(), "type": kind, "to": to or "", "from": os.environ.get("Q_FROM")
            or my_session() or "terminal", "created": now(), "body": text}
    _write(q, q / "new" / f"{meta['id']}.md", meta)
    print(f"{meta['id']}  {kind}" + (f" → {to}" if to else "") + f"  ({project_name(root)})")


def cmd_ls(root, args):
    q = qdir(root)
    rows = items(q, STATES if "-a" in args else OPEN)
    if "--json" in args:
        print(json.dumps([{k: m.get(k) for k in ("id", "state", "type", "to", "area", "taken_by")}
                          | {"title": title(m, 120)} for m in rows], ensure_ascii=False))
        return
    if not rows:
        print(f"queue empty ({project_name(root)})")
        return
    for m in rows:
        who = m.get("to") or "*"
        extra = f" [{m.get('taken_by', '?')}]" if m["state"] == "taken" else ""
        area = f" ({m['area']})" if m.get("area") else ""
        print(f"{m['id']}  {m['state']:5}  {m.get('type', ''):7} → {who:12}{extra}{area}  {title(m)}")


def cmd_show(root, args):
    print(find(qdir(root), args[0] if args else die("show ID")).read_text())


def cmd_note(root, args):
    if len(args) < 2:
        die("note ID TEXT")
    q = qdir(root, create=True)
    p = find(q, args[0])
    m = parse(p)
    _note(m, my_session() or "terminal", " ".join(args[1:]))
    _write(q, p, m)
    print(f"noted {args[0]}")


def cmd_who(root, args):
    if "--all" in args:
        out = {}
        for name, path in _registry().items():
            out[name] = {"sessions": sorted(sessions_in(Path(path))),
                         "orch": orchestrator(Path(path))}
        print(json.dumps(out, ensure_ascii=False) if "--json" in args else
              "\n".join(f"{n:20} {', '.join(v['sessions']) or '-'}" for n, v in sorted(out.items())))
        return
    here = sessions_in(root)
    orch = orchestrator(root)
    if not here:
        print(f"no Claude sessions in {root}")
    for name, path in sorted(here.items()):
        print(f"{name:20} {path}" + ("   (orchestrator)" if name == orch else ""))


def cmd_init(root, args):
    qdir(root, create=True)
    print(f"{project_name(root)}: queue in {root / '.queue'}")


def cmd_projects(root, args):
    for name, path in sorted(_registry().items()):
        print(f"{name:20} {path}")


# ── commands: sessions ────────────────────────────────────────────────────────────────────────

def cmd_take(root, args):
    i = args[0] if args else die("take ID")
    _move(root, i, "taken", expect=("new", "ready"), taken_by=my_session() or "terminal", taken=now())
    print(f"taken {i}")


def cmd_back(root, args):
    i = args[0] if args else die("back ID")
    _move(root, i, "new", taken_by=None, taken=None)
    print(f"back {i}")


def cmd_done(root, args):
    i = args[0] if args else die("done ID [NOTE]")
    note = " ".join(args[1:]).strip()
    m, p = _move(root, i, "done", done=now())
    if note:
        m["body"] += f"\n\nDone: {note}"
        _write(qdir(root), p, m)
    print(f"done {i}")


def cmd_ask(root, args):
    options, rest = [], []
    it = iter(args)
    for a in it:
        if a in ("-o", "--opt"):
            options.append(next(it, "") or die("--opt needs a value"))
        else:
            rest.append(a)
    if len(options) > 3:
        die("at most 3 --opt (ntfy shows 3 buttons)")
    if any(len(o) > 40 or re.search(r"[,;=\"'\n]", o) for o in options):
        die("an --opt is a short button label without , ; = or quotes")
    args = rest
    if len(args) < 2:
        die("ask ID QUESTION [--opt ANSWER]...")
    question = " ".join(args[1:])
    m, p = _move(root, args[0], "peter")
    _note(m, my_session() or "terminal", f"Question for Peter: {question}")
    _write(qdir(root), p, m)
    to_phone("ask", root, f"{title(m, 80)}\n\n{question}", item=args[0], options=options)
    print(f"asked {args[0]}")


def cmd_answer(root, args):
    if len(args) < 2:
        die("answer ID TEXT")
    m, p = _move(root, args[0], "new", expect=("peter", "new", "ready", "taken"))
    _note(m, "Peter", " ".join(args[1:]))
    _write(qdir(root), p, m)
    print(f"answered {args[0]}")


# ── commands: orchestrator ────────────────────────────────────────────────────────────────────

def cmd_orch(root, args):
    q = qdir(root, create=True)
    if args[:1] == ["off"]:
        (q / "orch").unlink(missing_ok=True)
        print("orchestrator off")
        return
    me = my_session() or die("the orchestrator must run in tmux")
    cur = orchestrator(root)
    if cur and cur != me:
        die(f"{cur} already orchestrates {project_name(root)}")
    (q / "orch").write_text(me + "\n")
    print(f"{me} orchestrates {project_name(root)}")


def cmd_ready(root, args):
    i = args[0] if args else die("ready ID [AREA]")
    area = " ".join(args[1:]).strip() or None
    _move(root, i, "ready", expect=("new", "ready"), area=area)
    print(f"ready {i}" + (f" ({area})" if area else ""))


def cmd_merge(root, args):
    if len(args) != 2 or args[0] == args[1]:
        die("merge ID INTO")
    q = qdir(root, create=True)
    into = find(q, args[1])
    if into.parent.name == "done":
        die(f"{args[1]} is done")
    m, _ = _move(root, args[0], "done", done=now())
    t = parse(into)
    t["body"] += f"\n\nMerged in {args[0]} ({m.get('type', '')}): {m['body']}"
    _write(q, into, t)
    m["body"] += f"\n\nDone: merged into {args[1]}"
    _write(q, q / "done" / f"{args[0]}.md", m)
    print(f"merged {args[0]} into {args[1]}")


def worker_settings(root):
    """Bash runs in the sandbox: it writes only in the worktree, the repo's .git (commits), the
    queue and q's own folder (so `q done` and `q ask` work)."""
    return {"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True,
                        "allowUnsandboxedCommands": False,     # a sandbox failure stops, never escapes
                        "filesystem": {"allowWrite": [str(root / ".queue"), str(HOME)]}}}


CLAUDE_JSON = Path(os.environ.get("Q_CLAUDE_JSON", Path.home() / ".claude.json"))


def trust_folder(wt):
    """Mark the worktree trusted in ~/.claude.json, so the worker never stops at the trust dialog
    (inheriting trust from the root raced when two workers started in the same second)."""
    try:
        d = json.loads(CLAUDE_JSON.read_text())
        proj = d.setdefault("projects", {}).setdefault(str(wt), {})
        if proj.get("hasTrustDialogAccepted"):
            return
        proj["hasTrustDialogAccepted"] = True
        tmp = CLAUDE_JSON.with_name(CLAUDE_JSON.name + ".q-tmp")
        tmp.write_text(json.dumps(d, indent=2))
        os.rename(tmp, CLAUDE_JSON)
    except (OSError, ValueError):
        pass  # the dialog is a nuisance, not a danger: spawn anyway


def worker_prompt(root, m, wt, branch):
    return (f"You are a worker for queue item {m['id']} in project {project_name(root)}.\n"
            f"Read it first: `q show {m['id']}`. Your worktree is {wt}, branch {branch}; work only "
            "here. The project's CLAUDE.md and rules apply in full.\n"
            "Do the item, with tests where the project has them, in small commits on your branch. "
            "Never merge, push or deploy: the orchestrator does that.\n"
            f"If you need Peter: `q ask {m['id']} \"the question\"` and stop until the answer comes.\n"
            f"When done: `q done {m['id']} \"what changed, commits, tests run and their result, "
            "anything left open\"`, then stop.")


def cmd_spawn(root, args):
    i = args[0] if args else die("spawn ID")
    q = qdir(root, create=True)
    p = find(q, i)
    if p.parent.name != "ready":
        die(f"{i} is {p.parent.name}; only ready items are spawned")
    m = parse(p)
    area = m.get("area")
    if area:
        busy = [t["id"] for t in items(q, ("taken",)) if t.get("area") == area]
        if busy:
            die(f"area {area!r} is busy with {', '.join(busy)}")
    if not (root / ".git").exists():
        die("spawn needs a git repo")
    branch = f"q/{i}"
    # Inside the root, like `claude --worktree`: a folder Peter already trusts, so the worker
    # starts without the trust dialog.
    wt = root / ".claude" / "worktrees" / f"q-{i}"
    _exclude_from_git(root, ".claude/worktrees/")
    base = _git(root, "rev-parse", "--abbrev-ref", "HEAD") or die("no HEAD")
    if not wt.exists():
        r = subprocess.run(["git", "-C", str(root), "worktree", "add", "-q", "-b", branch, str(wt),
                            base], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"worktree: {r.stderr.strip()}")
    session = f"{project_name(root)[:12]}-w-{i[-3:]}"
    _move(root, i, "taken", expect=("ready",), taken_by=session, taken=now(), worktree=str(wt),
          branch=branch)
    # The worker runs the user's hooks like every other session.
    trust_folder(wt)
    claude =os.environ.get("Q_CLAUDE", "claude")
    cmd = " ".join([shlex.quote(claude), "-n", shlex.quote(session),
                    "--settings", shlex.quote(json.dumps(worker_settings(root))),
                    "--permission-mode", "acceptEdits",
                    shlex.quote(worker_prompt(root, m, wt, branch))])
    r = subprocess.run(["tmux", "new-session", "-d", "-s", session, "-c", str(wt), cmd],
                       capture_output=True, text=True)
    if r.returncode != 0:
        _move(root, i, "ready", taken_by=None, taken=None)
        die(f"tmux: {r.stderr.strip()}")
    print(f"spawned {i}: session {session}, worktree {wt}, branch {branch} from {base}")


def cmd_reap(root, args):
    i = args[0] if args else die("reap ID")
    m = parse(find(qdir(root), i))
    if m["state"] != "done":
        die(f"{i} is {m['state']}; reap only finished workers")
    if m.get("taken_by"):
        subprocess.run(["tmux", "kill-session", "-t", m["taken_by"]], capture_output=True)
    wt = m.get("worktree")
    if wt and Path(wt).exists():
        r = subprocess.run(["git", "-C", str(root), "worktree", "remove", wt],
                           capture_output=True, text=True)
        if r.returncode != 0:
            die(f"worktree kept (uncommitted work?): {r.stderr.strip()}")
    print(f"reaped {i}" + (f"; branch {m['branch']} kept" if m.get("branch") else ""))


def _snapshot(q):
    return {p.stem: p.parent.name for s in STATES for p in (q / s).glob("*.md")} if q.is_dir() else {}


def cmd_watch(root, args):
    """One line per change: `<state> <id> <title>`. Polls once a second; ends never."""
    q = qdir(root, create=True)
    seen = _snapshot(q)
    while True:
        time.sleep(float(os.environ.get("Q_WATCH_INTERVAL", "1")))
        cur = _snapshot(q)
        for i, s in sorted(cur.items()):
            if seen.get(i) != s:
                try:
                    t = title(parse(q / s / f"{i}.md"), 100)
                except OSError:
                    t = ""
                print(f"{s} {i} {t}", flush=True)
        seen = cur


def cmd_tell(root, args):
    text = " ".join(args).strip() or die("tell TEXT")
    to_phone("tell", root, text)
    print("told")


# ── the Stop hook ─────────────────────────────────────────────────────────────────────────────

def hook_stop():
    """Never fails and never blocks twice on the same item."""
    try:
        if (HOME / "OFF").exists():
            return
        payload = json.loads(sys.stdin.read() or "{}")
        sid, cwd = payload.get("session_id"), payload.get("cwd")
        if not sid or not cwd:
            return
        root = project_root(cwd)
        q = qdir(root)
        if not (q / "new").is_dir():
            return
        me = my_session()
        orch = orchestrator(root)
        if orch and me == orch:
            return          # the orchestrator is woken by `q watch`, not by turns ending
        seen_file = HOME / "state" / f"{re.sub(r'[^A-Za-z0-9_-]', '', sid)}.seen"
        seen = set(seen_file.read_text().split()) if seen_file.exists() else set()
        fresh = [m for m in items(q, ("new",)) if m["id"] not in seen]
        mine = [m for m in fresh if me and m.get("to") == me]
        general = [] if orch else [m for m in fresh if not m.get("to")]
        if not mine and not general:
            return
        seen_file.parent.mkdir(parents=True, exist_ok=True)
        with seen_file.open("a") as f:
            f.write("".join(m["id"] + "\n" for m in mine + general))
        lines = []
        if mine:
            lines.append("Peter put items in the queue for this session while you worked:")
            lines += [f"  {m['id']}  {m.get('type', '')}: {title(m, 100)}" for m in mine]
        if general:
            lines.append(f"{len(general)} new item(s) in the project queue, for anyone:")
            lines += [f"  {m['id']}  {m.get('type', '')}: {title(m, 100)}" for m in general]
        handed = {m["id"] for m in mine + general}
        others = [m for m in items(q, OPEN) if m["id"] not in handed]
        if others:
            lines.append("Also open in this project (check against these):")
            lines += [f"  {m['id']}  {m['state']}"
                      + (f" by {m.get('taken_by')}" if m["state"] == "taken" else "")
                      + f": {title(m, 100)}" for m in others[:15]]
            if len(others) > 15:
                lines.append(f"  ... and {len(others) - 15} more (`q ls`)")
        lines.append("Before starting anything, look for overlap: between these items, with work "
                     "taken by other sessions, with what you are doing, and with recently done "
                     "items (`q ls -a`). The same idea twice becomes one; ideas that pull in "
                     "different directions or touch the same code are never both done blindly. "
                     "Merge them, order them, or ask Peter in one line when they contradict. Write "
                     "what you decided on the items with `q note ID ...`.")
        if mine:
            lines.append("Then, for your items: `q take ID`, do it, `q done ID \"what was done\"`. "
                         "If one needs Peter or does not belong here, say so in one line and leave it.")
        if general:
            lines.append("Items for anyone: do not start them unless Peter asks; mention them in one "
                         "line, with any overlap you found.")
        print(json.dumps({"decision": "block", "reason": "\n".join(lines)}))
    except Exception:                                          # noqa: BLE001
        return


COMMANDS = {"ls": cmd_ls, "show": cmd_show, "note": cmd_note, "who": cmd_who,
            "projects": cmd_projects, "init": cmd_init, "take": cmd_take, "back": cmd_back, "done": cmd_done,
            "ask": cmd_ask, "answer": cmd_answer, "orch": cmd_orch, "ready": cmd_ready,
            "merge": cmd_merge, "spawn": cmd_spawn, "reap": cmd_reap, "watch": cmd_watch,
            "tell": cmd_tell}


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["hook-stop"]:
        return hook_stop()
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return
    if argv[0] in ("-p", "--project"):
        if len(argv) < 2:
            die("-p needs a project")
        root = project_by_name(argv[1])
        argv = argv[2:]
        if not argv:
            die("-p PROJECT needs a command or text")
    else:
        root = project_root(os.getcwd())
    if argv[0] in COMMANDS:
        return COMMANDS[argv[0]](root, argv[1:])
    return cmd_add(root, argv)


if __name__ == "__main__":
    main()
