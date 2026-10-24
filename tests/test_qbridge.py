import importlib.machinery
import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "qbridge"


def load(monkeypatch, home):
    monkeypatch.setenv("Q_HOME", str(home))
    monkeypatch.setenv("Q_SESSIONS", "{}")
    monkeypatch.setenv("Q_SESSION", "")
    loader = importlib.machinery.SourceFileLoader("qbridge", str(SRC))
    spec = importlib.util.spec_from_loader("qbridge", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class FakeNtfy:
    def __init__(self):
        self.sent = []

    def reply(self, label, body):
        return (label, body)

    def publish(self, text, title=None, tags=None, priority=None, actions=None):
        self.sent.append({"text": text, "title": title, "tags": tags, "priority": priority,
                          "actions": actions})
        return True


@pytest.fixture
def b(monkeypatch, tmp_path):
    return load(monkeypatch, tmp_path / "home")


def test_parse(b):
    assert b.parse_message("myapp: dark map") == ("add", "myapp", None, "idea", "dark map")
    assert b.parse_message("bug myapp/mx-11: corners blink") == \
        ("add", "myapp", "mx-11", "bug", "corners blink")
    assert b.parse_message("myapp: corners blink #bug") == \
        ("add", "myapp", None, "bug", "corners blink")
    assert b.parse_message("261023-0948-qos: red") == ("answer", "261023-0948-qos", "red")
    assert b.parse_message("?") == ("who",)
    assert b.parse_message("undo 261023-0948-qos") == ("undo", "261023-0948-qos")
    assert b.parse_message("ångra 261023-0948-qos") == ("undo", "261023-0948-qos")
    assert b.parse_message("just text")[0] == "error"
    assert b.parse_message("")[0] == "error"
    assert b.parse_message("x: " + "a" * 9000)[0] == "error"
    # text is never a path or a flag
    assert b.parse_message("../etc: x")[0] == "add"      # rejected later: not a registered project


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "proj"
    subprocess.run(["git", "init", "-q", "-b", "main", str(root)], check=True)
    return root


def test_handle_adds_to_a_registered_project_only(b, repo, tmp_path, monkeypatch):
    monkeypatch.chdir(repo)
    subprocess.run([b.Q, "init"], check=True, capture_output=True)
    n = FakeNtfy()
    b.handle(n, "proj: dark map #feature")
    [item] = list((repo / ".queue" / "new").glob("*.md"))
    text = item.read_text()
    assert "type: feature" in text and "from: phone" in text and "dark map" in text
    assert n.sent[-1]["title"] == "q: added"
    b.handle(n, "nope: x")
    assert n.sent[-1]["title"] == "q: not added" and "no project" in n.sent[-1]["text"]
    b.handle(n, "proj/ghost: x")
    assert n.sent[-1]["title"] == "q: not added"
    b.handle(n, "proj: -s evil --force")             # flags in the text stay text
    items = [f.read_text() for f in (repo / ".queue" / "new").glob("*.md")]
    assert len(items) == 2 and any("-s evil --force" in t and "to:" not in t for t in items)


def test_answer_finds_the_project(b, repo, monkeypatch):
    monkeypatch.chdir(repo)
    out = subprocess.run([b.Q, "x"], capture_output=True, text=True, check=True).stdout
    i = out.split()[0]
    subprocess.run([b.Q, "ask", i, "which colour?"], check=True, capture_output=True)
    n = FakeNtfy()
    b.drain_outbox(n)
    assert "which colour?" in n.sent[0]["text"] and i in n.sent[0]["title"]
    assert not list((b.HOME / "outbox").glob("*.json"))
    b.handle(n, f"{i}: red")
    assert (repo / ".queue" / "new" / f"{i}.md").exists()
    b.handle(n, "261023-0000-aaa: x")
    assert n.sent[-1]["title"] == "q: not found"


def test_sessions_only_on_change(b, repo, monkeypatch):
    monkeypatch.chdir(repo)
    subprocess.run([b.Q, "x"], check=True, capture_output=True)
    n = FakeNtfy()
    b.publish_sessions(n)
    b.publish_sessions(n)
    assert len(n.sent) == 1 and json.loads(n.sent[0]["text"]) == {"proj": {"sessions": [],
                                                                          "orch": None}}
    assert n.sent[0]["tags"] == "sessions"


def test_reply_buttons(b, monkeypatch):
    conf = {"NTFY_URL": "https://n.example", "NTFY_TOKEN": "tk_box", "Q_IN": "q-in", "Q_OUT": "q-out"}
    assert b.Ntfy(conf).reply("Yes", "x: Yes") is None          # no reply token, no buttons
    n = b.Ntfy({**conf, "NTFY_REPLY_TOKEN": "tk_reply"})
    a = n.reply("Yes", "261023-0948-qos: Yes")
    assert a == ("http, Yes, https://n.example/q-in, method=POST, "
                 "headers.Authorization=Bearer tk_reply, body=261023-0948-qos: Yes, clear=true")
    sent = {}

    def urlopen(req, timeout):
        sent.update(req.headers)
        return type("R", (), {"read": lambda self: b""})()
    monkeypatch.setattr(b.urllib.request, "urlopen", urlopen)
    assert n.publish("q", actions=[a, None, a, a, a])
    assert sent["Actions"].count("http, ") == 3                 # ntfy's limit
    assert "Bearer tk_box" in sent["Authorization"]


def test_ask_buttons_answer_and_add_can_be_undone(b, repo, monkeypatch):
    monkeypatch.chdir(repo)
    i = subprocess.run([b.Q, "x"], capture_output=True, text=True, check=True).stdout.split()[0]
    subprocess.run([b.Q, "ask", i, "which colour?", "--opt", "Red", "--opt", "Blå"], check=True,
                   capture_output=True)
    j = subprocess.run([b.Q, "y"], capture_output=True, text=True, check=True).stdout.split()[0]
    subprocess.run([b.Q, "ask", j, "ok?"], check=True, capture_output=True)
    bad = subprocess.run([b.Q, "ask", j, "ok?", "--opt", "a,b"], capture_output=True, text=True)
    assert bad.returncode != 0
    n = FakeNtfy()
    b.drain_outbox(n)
    by_item = {s["title"].split("(")[1][:-1]: s["actions"] for s in n.sent}
    assert by_item[i] == [("Red", f"{i}: Red"), ("Blå", f"{i}: Blå")]
    assert by_item[j] == [("Yes", f"{j}: Yes"), ("No", f"{j}: No")]
    b.handle(n, by_item[i][1][1])                   # the button's body, as ntfy posts it
    assert "Peter" in (repo / ".queue" / "new" / f"{i}.md").read_text()

    b.handle(n, "proj: never mind")
    [(label, body)] = n.sent[-1]["actions"]
    k = body.split()[1]
    assert label == "Undo" and (repo / ".queue" / "new" / f"{k}.md").exists()
    subprocess.run([b.Q, "take", k], check=True, capture_output=True)
    b.handle(n, body)
    assert n.sent[-1]["title"] == "q: not undone"   # already taken: leave it to the worker
    subprocess.run([b.Q, "back", k], check=True, capture_output=True)
    b.handle(n, body)
    assert (repo / ".queue" / "done" / f"{k}.md").exists()
