#!/usr/bin/env python3
"""Token accounting for the agency. After each shift the panel parses the JSON result of `claude -p --output-format json`
and adds it to data/agency/usage.json. "Tokens" = input + output + cache writes (cheap cache reads are shown separately)."""
import json, os, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
import sys; sys.path.insert(0, HERE)
from act import A

P = os.path.join(A, "usage.json")

def today():
    return datetime.date.today().isoformat()

def load():
    try:
        return json.load(open(P, encoding="utf-8"))
    except Exception:
        return {"days": {}, "shifts": []}

def parse(text):
    """Returns (tokens, cache_read, cost_usd) from the CLI's JSON result, or None."""
    res = None
    for line in reversed(text.strip().splitlines()):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("type") == "result":
            res = d
            break
    if res is None:
        try:
            d = json.loads(text)
            res = d if isinstance(d, dict) else None
        except Exception:
            return None
    if not res:
        return None
    tok = cr = 0
    mu = res.get("modelUsage") or {}
    if mu:  # includes subagents
        for m in mu.values():
            tok += int(m.get("inputTokens", 0)) + int(m.get("outputTokens", 0)) + int(m.get("cacheCreationInputTokens", 0))
            cr += int(m.get("cacheReadInputTokens", 0))
    else:
        u = res.get("usage") or {}
        tok = int(u.get("input_tokens", 0)) + int(u.get("output_tokens", 0)) + int(u.get("cache_creation_input_tokens", 0))
        cr = int(u.get("cache_read_input_tokens", 0))
    return tok, cr, float(res.get("total_cost_usd") or 0)

def add(text, shift_no):
    r = parse(text)
    if not r:
        return None
    tok, cr, cost = r
    u = load()
    d = u["days"].setdefault(today(), {"tokens": 0, "cache_read": 0, "cost_usd": 0.0, "shifts": 0})
    d["tokens"] += tok; d["cache_read"] += cr; d["cost_usd"] = round(d["cost_usd"] + cost, 4); d["shifts"] += 1
    u["shifts"] = ([{"t": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "shift": shift_no,
                     "tokens": tok, "cache_read": cr, "cost_usd": round(cost, 4)}] + u.get("shifts", []))[:50]
    json.dump(u, open(P, "w", encoding="utf-8"), indent=1)
    return tok

def summary(budget):
    u = load()
    d = u["days"].get(today(), {"tokens": 0, "cache_read": 0, "cost_usd": 0.0, "shifts": 0})
    total = sum(v["tokens"] for v in u["days"].values())
    return {"today": d, "total_tokens": total, "budget": budget, "left": max(0, budget - d["tokens"]) if budget else None,
            "last": (u.get("shifts") or [None])[0]}

def window(hours, limit):
    """Tokens spent in the last `hours` hours and pacing for the next shift, so a limit is spread over the whole window."""
    now = datetime.datetime.now().astimezone()
    sh = load().get("shifts", [])
    recent = []
    for s in sh:
        try:
            t = datetime.datetime.fromisoformat(s["t"])
        except Exception:
            continue
        if (now - t).total_seconds() < hours * 3600:
            recent.append((t, s["tokens"]))
    used = sum(x[1] for x in recent)
    last5 = [s["tokens"] for s in sh[:5] if s.get("tokens")]
    avg = int(sum(last5) / len(last5)) if last5 else 300000
    per_window = max(1, limit // max(1, avg)) if limit else 0
    pause = int(hours * 3600 / per_window) if limit else 0  # even spacing across the window
    wait = 0
    if limit and used + avg > limit and recent:
        # wait until enough old shifts leave the window
        need = used + avg - limit
        for t, tok in sorted(recent):
            need -= tok
            wait = int(hours * 3600 - (now - t).total_seconds()) + 60
            if need <= 0:
                break
    return {"hours": hours, "limit": limit, "used": used, "left": max(0, limit - used) if limit else None,
            "avg_shift": avg, "pause": pause, "wait": max(0, wait)}


def result_info(text):
    """The final result of a headless run: {"ok": bool, "tokens": int, "message": str}. A run that ended at once with an error (for example
    the subscription limit) is NOT a finished shift."""
    res = None
    for line in reversed(text.strip().splitlines()):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("type") == "result":
            res = d
            break
    if res is None:
        try:
            d = json.loads(text)
            res = d if isinstance(d, dict) else None
        except Exception:
            res = None
    r = parse(text)
    tokens = r[0] if r else 0
    msg = ""
    if res:
        msg = str(res.get("result") or res.get("error") or res.get("subtype") or "")
    else:
        msg = " ".join(text.split())[:200] or "нет ответа от claude"
    ok = bool(res) and not res.get("is_error") and tokens > 0
    return {"ok": ok, "tokens": tokens, "message": " ".join(msg.split())[:200]}
