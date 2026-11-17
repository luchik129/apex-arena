#!/usr/bin/env python3
"""Activity log for the city feed. Every agent calls it when it starts something, at each main step and when it is done:
    python3 marketing/agency/act.py <role> "<what I am doing, in Russian, one short line>" [done]
Roles: manager, director, analyst, writer, editor, publisher."""
import json, os, sys, time, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("MARKETING_DATA")
if not DATA:
    DATA = "/mnt/project-files/fitness/marketing" if os.path.isdir("/mnt/project-files/fitness/marketing") else os.path.join(HERE, "..", "data")
A = os.path.join(DATA, "agency")
ROLES = {"manager": "strategy", "director": "strategy", "analyst": "analytics", "writer": "creative",
         "editor": "smm", "publisher": "media", "system": ""}

def log(role, text, done=False):
    os.makedirs(A, exist_ok=True)
    role = role if role in ROLES else "manager"
    text = " ".join(str(text).split())[:220]
    now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    with open(os.path.join(A, "activity.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"t": now, "role": role, "dept": ROLES[role], "text": text, "done": bool(done)}, ensure_ascii=False) + "\n")
    p = os.path.join(A, "agents.json")
    try:
        ag = json.load(open(p, encoding="utf-8"))
    except Exception:
        ag = {}
    if role != "system":
        ag[role] = {"doing": "" if done else text, "last": text, "t": now}
    json.dump(ag, open(p, "w", encoding="utf-8"), ensure_ascii=False)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    log(sys.argv[1], sys.argv[2], len(sys.argv) > 3 and sys.argv[3] == "done")

def clear():
    """Called on Stop: nobody is working any more."""
    p = os.path.join(A, "agents.json")
    try:
        ag = json.load(open(p, encoding="utf-8"))
    except Exception:
        return
    for v in ag.values():
        v["doing"] = ""
    json.dump(ag, open(p, "w", encoding="utf-8"), ensure_ascii=False)
