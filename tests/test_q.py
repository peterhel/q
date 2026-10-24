import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

Q = str(Path(__file__).resolve().parent.parent / "q")


def run(cwd, *args, stdin=None, session="", sessions=None, home=None, check=True):
    env = {**os.environ, "Q_SESSION": session, "Q_SESSIONS": json.dumps(sessions or {}),
           "Q_HOME": str(home or Path(cwd).parent / "qhome"), "Q_WATCH_INTERVAL": "0.05"}
    r = subprocess.run([sys.executable, Q, *args], cwd=cwd, input=stdin, env=env,
                       capture_output=True, text=True)
    if check:
        assert r.returncode == 0, r.stderr
    return r


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "proj"
    root.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "-c", "user.email=x@y", "-c", "user.name=x",
                    "commit", "-q", "--allow-empty", "-m", "init"], check=True)
    (root / "sub").mkdir()
    return root


def ids(root, state):
    return sorted(p.stem for p in (root / ".queue" / state).glob("*.md"))


def test_add_lands_in_new_and_stays_out_of_git(repo):
    out = run(repo, "bug", "corners", "blink").stdout
    [i] = ids(repo, "new")
    assert out.startswith(i)
    text = (repo / ".queue" / "new" / f"{i}.md").read_text()
    assert "type: bug" in text and "corners blink" in text
    assert ".queue/" in (repo / ".git" / "info" / "exclude").read_text()
    assert subprocess.run(["git", "-C", str(repo), "status", "--porcelain"],
                          capture_output=True, text=True).stdout == ""


def test_subfolder_and_worktree_share_the_main_queue(repo, tmp_path):
    wt = tmp_path / "proj-wt"
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "x", str(wt)], check=True)
    run(repo / "sub", "from sub")
    run(wt, "from worktree")
    assert len(ids(repo, "new")) == 2
    assert not (wt / ".queue").exists()


def test_outside_git_uses_nearest_queue_folder(tmp_path):
    (tmp_path / ".queue").mkdir()
    (tmp_path / "a" / "b").mkdir(parents=True)
    run(tmp_path / "a" / "b", "x")
    assert len(ids(tmp_path, "new")) == 1


def test_addressing_a_session_must_name_one_working_here(repo):
    r = run(repo, "-s", "ghost", "hi", sessions={"real": str(repo)}, check=False)
    assert r.returncode != 0 and "real" in r.stderr
    run(repo, "-s", "real", "hi", sessions={"real": str(repo)})
    run(repo, "-s", "ghost", "-f", "hi")
    assert len(ids(repo, "new")) == 2


def test_take_is_exclusive_and_done_keeps_the_note(repo):
    run(repo, "x")
    [i] = ids(repo, "new")
    run(repo, "take", i, session="a")
    r = run(repo, "take", i, session="b", check=False)
    assert r.returncode != 0
    assert "taken_by: a" in (repo / ".queue" / "taken" / f"{i}.md").read_text()
    run(repo, "done", i, "fixed", "it")
    assert "Done: fixed it" in (repo / ".queue" / "done" / f"{i}.md").read_text()
    assert ids(repo, "taken") == []


def test_back_returns_an_item_untaken(repo):
    run(repo, "x")
    [i] = ids(repo, "new")
    run(repo, "take", i, session="a")
    run(repo, "back", i)
    assert ids(repo, "new") == [i]
    assert "taken_by" not in (repo / ".queue" / "new" / f"{i}.md").read_text()


def test_ids_cannot_escape_the_queue(repo):
    r = run(repo, "show", "../../etc/passwd", check=False)
    assert r.returncode != 0


def hook(repo, home, session):
    payload = json.dumps({"session_id": "sid-1", "cwd": str(repo / "sub")})
    out = run(repo, "hook-stop", stdin=payload, session=session, home=home).stdout
    return json.loads(out) if out.strip() else None


def test_hook_is_silent_without_a_queue(repo, tmp_path):
    assert hook(repo, tmp_path / "home", "me") is None
    assert not (repo / ".queue").exists()


def test_hook_hands_my_items_over_once(repo, tmp_path):
    home = tmp_path / "home"
    run(repo, "-s", "me", "-f", "do this")
    run(repo, "-s", "other", "-f", "not mine")
    out = hook(repo, home, "me")
    assert out["decision"] == "block" and "do this" in out["reason"]
    handed, _, also = out["reason"].partition("Also open")
    assert "not mine" not in handed and "not mine" in also     # listed for the overlap check only
    assert hook(repo, home, "me") is None          # never twice: no loop
    run(repo, "-s", "me", "-f", "and this")
    out = hook(repo, home, "me")
    handed = out["reason"].partition("Also open")[0]
    assert "and this" in handed and "do this" not in handed


def test_hook_only_mentions_items_for_anyone(repo, tmp_path):
    run(repo, "an idea")
    out = hook(repo, tmp_path / "home", "me")
    assert "an idea" in out["reason"] and "do not start them" in out["reason"]


def test_hook_off_switch(repo, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / "OFF").touch()
    run(repo, "x")
    assert hook(repo, home, "me") is None


def test_hook_never_fails_on_garbage(repo, tmp_path):
    r = run(repo, "hook-stop", stdin="not json", home=tmp_path)
    assert r.returncode == 0 and r.stdout == ""


def test_note_appends_to_the_item(repo):
    run(repo, "x")
    [i] = ids(repo, "new")
    run(repo, "note", i, "overlaps", "with", "y", session="me")
    assert "Note (me, " in (repo / ".queue" / "new" / f"{i}.md").read_text()
    assert "overlaps with y" in (repo / ".queue" / "new" / f"{i}.md").read_text()


def test_hook_shows_other_open_work_and_asks_for_an_overlap_check(repo, tmp_path):
    run(repo, "-s", "other", "-f", "dark mode for the map")
    [taken] = ids(repo, "new")
    run(repo, "take", taken, session="other")
    run(repo, "-s", "me", "-f", "map colours in dark mode")
    out = hook(repo, tmp_path / "home", "me")
    assert "map colours in dark mode" in out["reason"]
    assert f"{taken}  taken by other: dark mode for the map" in out["reason"]
    assert "overlap" in out["reason"] and "q note" in out["reason"]


# ── phase 2 ──────────────────────────────────────────────────────────────────────────────────

def one(repo, *args, **kw):
    return run(repo, *args, **kw).stdout.split()[0]


def test_ready_sets_area_and_take_accepts_ready(repo):
    i = one(repo, "x")
    run(repo, "ready", i, "android-map")
    assert ids(repo, "ready") == [i]
    assert "area: android-map" in (repo / ".queue" / "ready" / f"{i}.md").read_text()
    run(repo, "take", i, session="w")
    assert ids(repo, "taken") == [i]


def test_merge_folds_a_duplicate_in(repo):
    a = one(repo, "dark map")
    b = one(repo, "map in dark mode")
    run(repo, "merge", b, a)
    assert ids(repo, "done") == [b]
    assert "Merged in" in (repo / ".queue" / "new" / f"{a}.md").read_text()
    assert f"merged into {a}" in (repo / ".queue" / "done" / f"{b}.md").read_text()
    assert run(repo, "merge", a, a, check=False).returncode != 0


def test_ask_parks_for_peter_and_answer_returns_it(repo, tmp_path):
    home = tmp_path / "home"
    i = one(repo, "x")
    run(repo, "ask", i, "which", "colour?", home=home, session="w")
    assert ids(repo, "peter") == [i]
    [msg] = list((home / "outbox").glob("*.json"))
    m = json.loads(msg.read_text())
    assert m["kind"] == "ask" and m["item"] == i and "which colour?" in m["text"]
    assert m["project"] == "proj"
    run(repo, "answer", i, "red", home=home)
    assert ids(repo, "new") == [i]
    assert "Note (Peter, " in (repo / ".queue" / "new" / f"{i}.md").read_text()


def test_projects_registry_and_dash_p(repo, tmp_path):
    home = tmp_path / "home"
    run(repo, "x", home=home)
    assert "proj" in run(tmp_path, "projects", home=home).stdout
    run(tmp_path, "-p", "proj", "from elsewhere", home=home)
    assert len(ids(repo, "new")) == 2
    assert run(tmp_path, "-p", "nope", "x", home=home, check=False).returncode != 0


def test_with_an_orchestrator_items_for_anyone_go_to_it_only(repo, tmp_path):
    home = tmp_path / "home"
    here = {"orc": str(repo), "me": str(repo / "sub")}
    run(repo, "orch", "on", session="orc", sessions=here, home=home)
    run(repo, "an idea", home=home)
    payload = json.dumps({"session_id": "s", "cwd": str(repo)})
    r = run(repo, "hook-stop", stdin=payload, session="me", sessions=here, home=home)
    assert r.stdout == ""                       # the worker is not distracted
    r = run(repo, "hook-stop", stdin=payload, session="orc", sessions=here, home=home)
    assert r.stdout == ""                       # the orchestrator learns via `q watch`
    i = one(repo, "-s", "orch", "for the boss", sessions=here, home=home)
    assert "to: orc" in (repo / ".queue" / "new" / f"{i}.md").read_text()
    # a dead orchestrator does not swallow items
    r = run(repo, "hook-stop", stdin=json.dumps({"session_id": "s2", "cwd": str(repo)}),
            session="me", sessions={"me": str(repo)}, home=home)
    assert "an idea" in r.stdout


def test_second_orchestrator_is_refused(repo, tmp_path):
    here = {"a": str(repo), "b": str(repo)}
    run(repo, "orch", "on", session="a", sessions=here)
    assert run(repo, "orch", "on", session="b", sessions=here, check=False).returncode != 0


def test_watch_prints_state_changes(repo):
    i = one(repo, "x")
    env = {**os.environ, "Q_HOME": str(repo.parent / "qhome"), "Q_WATCH_INTERVAL": "0.05",
           "Q_SESSION": "", "Q_SESSIONS": "{}"}
    p = subprocess.Popen([sys.executable, Q, "watch"], cwd=repo, env=env, stdout=subprocess.PIPE,
                         text=True)
    try:
        import time
        time.sleep(0.3)
        run(repo, "ready", i)
        line = p.stdout.readline()
        assert line.startswith(f"ready {i} x")
    finally:
        p.kill()


def test_spawn_only_ready_items_and_one_worker_per_area(repo, tmp_path):
    import shutil
    if not shutil.which("tmux"):
        pytest.skip("no tmux")
    home = tmp_path / "home"
    a = one(repo, "first", home=home)
    b = one(repo, "second", home=home)
    assert run(repo, "spawn", a, home=home, check=False).returncode != 0      # not ready
    run(repo, "ready", a, "map", home=home)
    run(repo, "ready", b, "map", home=home)
    os.environ["Q_CLAUDE"] = "true"
    try:
        out = run(repo, "spawn", a, home=home).stdout
        wt = repo / ".claude" / "worktrees" / f"q-{a}"
        assert wt.is_dir() and f"branch q/{a}" in out
        meta = (repo / ".queue" / "taken" / f"{a}.md").read_text()
        assert f"worktree: {wt}" in meta and "taken_by: proj-w-" in meta
        r = run(repo, "spawn", b, home=home, check=False)
        assert r.returncode != 0 and "busy" in r.stderr
        assert run(repo, "reap", a, home=home, check=False).returncode != 0    # not done yet
        run(repo, "done", a, "ok", home=home)
        run(repo, "reap", a, home=home)
        assert not wt.exists()
        assert subprocess.run(["git", "-C", str(repo), "status", "--porcelain"],
                              capture_output=True, text=True).stdout == ""
        assert "q/" + a in subprocess.run(["git", "-C", str(repo), "branch"], capture_output=True,
                                          text=True).stdout                  # branch kept
    finally:
        os.environ.pop("Q_CLAUDE")
