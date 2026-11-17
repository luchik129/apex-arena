#!/usr/bin/env python3
"""Ideas and HR department: agents propose, the owner approves or rejects in the city panel.
    python3 marketing/agency/idea.py add <role> <kind> "<title>" "<why, with evidence>"
kind: idea | hire | fire | experiment
    python3 marketing/agency/idea.py list [pending|approved|rejected]   (agents read the owner's verdicts here)
    python3 marketing/agency/idea.py applied <id>                        (after an approved item was carried out)"""
import json, os, sys, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from act import A, log

P = os.path.join(A, "ideas.json")

def load():
    try:
        return json.load(open(P, encoding="utf-8"))
    except Exception:
        return []

def save(items):
    os.makedirs(A, exist_ok=True)
    json.dump(items, open(P, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")

def add(role, kind, title, why):
    items = load()
    if any(i["title"] == title and i["status"] == "pending" for i in items):
        return None
    n = 1 + max([int(i["id"]) for i in items] or [0])
    items.insert(0, {"id": str(n), "t": now(), "from": role, "kind": kind if kind in ("idea", "hire", "fire", "experiment") else "idea",
                     "title": title[:160], "why": why[:600], "status": "pending"})
    save(items)
    log(role, "Предложил владельцу: " + title)
    return n

def verdict(iid, status, note=""):
    items = load()
    for i in items:
        if i["id"] == str(iid) and i["status"] == "pending":
            i["status"] = status
            i["decided"] = now()
            if note:
                i["note"] = note[:300]
            save(items)
            log("system", ("Владелец одобрил: " if status == "approved" else "Владелец отклонил: ") + i["title"])
            return True
    return False

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["add"] and len(a) >= 5:
        print(add(a[1], a[2], a[3], a[4]))
    elif a[:1] == ["list"]:
        st = a[1] if len(a) > 1 else None
        print(json.dumps([i for i in load() if not st or i["status"] == st], ensure_ascii=False, indent=1))
    elif a[:1] == ["applied"] and len(a) > 1:
        items = load()
        for i in items:
            if i["id"] == a[1] and i["status"] == "approved":
                i["status"] = "done"
                i["done"] = now()
        save(items)
    else:
        sys.exit(__doc__)
