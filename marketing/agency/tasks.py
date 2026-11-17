#!/usr/bin/env python3
"""Owner tasks for the workers. Stored in data/agency/tasks.json.
    python3 marketing/agency/tasks.py add "<task text>"   -> new open task (the manager does this when the owner asks for work)
    python3 marketing/agency/tasks.py list                -> open tasks (JSON)
    python3 marketing/agency/tasks.py done <id> ["<result>"]"""
import json, os, sys, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from act import A, log
P = os.path.join(A, "tasks.json")

def load():
    try:
        return json.load(open(P, encoding="utf-8"))
    except Exception:
        return []

def save(t):
    os.makedirs(A, exist_ok=True)
    json.dump(t, open(P, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

def open_tasks():
    return [t for t in load() if t.get("status") == "open"]

def add(text):
    t = load()
    n = 1 + max([int(x["id"]) for x in t] or [0])
    t.append({"id": str(n), "text": " ".join(text.split())[:800], "status": "open",
              "t": datetime.datetime.now().astimezone().isoformat(timespec="seconds")})
    save(t)
    log("manager", "Новая задача от владельца #%d: %s" % (n, text.strip()[:100]))
    return n

def done(tid, result=""):
    t = load()
    for x in t:
        if x["id"] == str(tid):
            x["status"] = "done"
            x["result"] = result[:500]
    save(t)
    log("manager", "Задача #%s выполнена" % tid)

if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "add":
        print(add(a[1]))
    elif a and a[0] == "done":
        done(a[1], a[2] if len(a) > 2 else "")
    else:
        print(json.dumps(open_tasks(), ensure_ascii=False))
