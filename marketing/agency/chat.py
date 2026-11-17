#!/usr/bin/env python3
"""Chat between the owner and the agency (manager). Stored in data/agency/chat.jsonl.
    python3 marketing/agency/chat.py unread                 -> owner messages the manager has not handled yet (JSON)
    python3 marketing/agency/chat.py reply "<text>"         -> the manager answers the owner (also marks everything read)
    python3 marketing/agency/chat.py post "<text>"          -> manager message that does not touch unread state
    python3 marketing/agency/chat.py done <id> ["<note>"]   -> mark one owner message as handled (without a long reply)"""
import json, os, sys, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from act import A, log

P = os.path.join(A, "chat.jsonl")

def load():
    out = []
    try:
        for l in open(P, encoding="utf-8").read().splitlines():
            try:
                out.append(json.loads(l))
            except Exception:
                pass
    except OSError:
        pass
    return out

def _write(items):
    os.makedirs(A, exist_ok=True)
    with open(P, "w", encoding="utf-8") as f:
        for i in items:
            f.write(json.dumps(i, ensure_ascii=False) + "\n")

def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")

def add_owner(text):
    items = load()
    n = 1 + max([int(i.get("id", 0)) for i in items] or [0])
    items.append({"id": str(n), "t": now(), "from": "owner", "text": " ".join(text.split())[:1500], "handled": False})
    _write(items)
    log("system", "Владелец написал управляющему: " + text.strip()[:120])
    return n

def unread():
    return [i for i in load() if i["from"] == "owner" and not i.get("handled")]

def reply(text):
    items = load()
    n = 1 + max([int(i.get("id", 0)) for i in items] or [0])
    for i in items:
        if i["from"] == "owner":
            i["handled"] = True
    items.append({"id": str(n), "t": now(), "from": "manager", "text": text.strip()[:1500], "handled": True})
    _write(items)
    log("manager", "Ответил владельцу в чате")

def post(text):
    """Manager message to the owner that does not touch unread state (used by workers when a task is finished)."""
    items = load()
    n = 1 + max([int(i.get("id", 0)) for i in items] or [0])
    items.append({"id": str(n), "t": now(), "from": "manager", "text": text.strip()[:1500], "handled": True})
    _write(items)
    log("manager", "Написал владельцу в чат")

def done(mid, note=""):
    items = load()
    for i in items:
        if i["id"] == str(mid):
            i["handled"] = True
    _write(items)
    if note:
        reply(note)

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["unread"]:
        print(json.dumps(unread(), ensure_ascii=False, indent=1))
    elif a[:1] == ["reply"] and len(a) > 1:
        reply(a[1])
    elif a[:1] == ["post"] and len(a) > 1:
        post(a[1])
    elif a[:1] == ["done"] and len(a) > 1:
        done(a[1], a[2] if len(a) > 2 else "")
    else:
        sys.exit(__doc__)
