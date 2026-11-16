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
