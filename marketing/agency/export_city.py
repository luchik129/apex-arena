#!/usr/bin/env python3
"""Builds agency.json (real numbers, roster, decisions, shift state) for the city page from marketing/data."""
import json, os, glob, sys
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("MARKETING_DATA") or os.path.join(HERE, "..", "data")
if os.path.isdir("/mnt/project-files/fitness/marketing") and not os.environ.get("MARKETING_DATA"):
    DATA = "/mnt/project-files/fitness/marketing"
A = os.path.join(DATA, "agency")

def load(p, d):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return d

def build():
    log = load(os.path.join(DATA, "log.json"), [])
    made = [v for v in log if v.get("video") or v.get("status") in ("ready", "posted")]
    posted = [v for v in log if v.get("status") == "posted"]
    stats = [v for v in log if v.get("metrics")]
    plats = set()
    posts = 0
    for v in posted:
        pl = v.get("platforms") or list((v.get("links") or {}).keys())
        posts += len(pl) or 1
        plats.update(pl)
    views = sum(int((v.get("metrics") or {}).get("views", 0) or 0) for v in log)
    hits = sum(1 for v in log if int((v.get("metrics") or {}).get("views", 0) or 0) >= 10000)
    inst = load(os.path.join(A, "installs.json"), {})  # {"installs": N, "asOf": "..."} written from App Store Connect numbers
    m = {
        "videosMade": len(made), "videosPosted": len(posted), "videosWithStats": len(stats),
        "views": views, "posts": posts, "hits": hits, "platforms": len(plats),
        "reports": len(glob.glob(os.path.join(DATA, "reports", "*.md"))),
        "days": len(glob.glob(os.path.join(DATA, "days", "*"))),
        "installs": inst.get("installs"),
    }
    return {
        "asOf": os.environ.get("TODAY") or __import__("datetime").date.today().isoformat(),
        "metrics": m,
        "levels": load(os.path.join(HERE, "levels.json"), None),
        "roster": load(os.path.join(A, "roster.json"), []),
        "decisions": load(os.path.join(A, "decisions.json"), []),
        "experiment": load(os.path.join(A, "state.json"), {}).get("experiment"),
        "status": load(os.path.join(A, "state.json"), {"state": "sleeping"}),
        "publish": load(os.path.join(A, "config.json"), {}).get("publish", False),
        "agents": load(os.path.join(A, "agents.json"), {}),
        "activity": activity(),
    }

def activity(n=80):
    p = os.path.join(A, "activity.jsonl")
    try:
        lines = open(p, encoding="utf-8").read().splitlines()[-n:]
    except Exception:
        return []
    out = []
    for l in reversed(lines):
        try:
            out.append(json.loads(l))
        except Exception:
            pass
    return out

if __name__ == "__main__":
    out = build()
    os.makedirs(A, exist_ok=True)
    json.dump(out, open(os.path.join(A, "agency.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("agency.json written:", out["metrics"])
