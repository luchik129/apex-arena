#!/usr/bin/env python3
"""Local control panel: serves the city on http://localhost:8787 with Start / Stop buttons.
Start runs shifts of the agency in a loop (via `claude -p /marketing-shift`) until Stop. Nothing else runs in the background."""
import json, os, signal, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("MARKETING_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data"))
from act import log as act, clear as act_clear
import idea as ideas
import usage
HAS_CHROME = "--chrome" in subprocess.run(["claude", "--help"], capture_output=True, text=True).stdout if __import__("shutil").which("claude") else False
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DATA = os.environ.get("MARKETING_DATA") or os.path.join(REPO, "marketing", "data")
A = os.path.join(DATA, "agency")
CITY = os.path.join(HERE, "city.html")
PORT = int(os.environ.get("PORT", "8787"))
state = {"proc": None, "caff": None, "running": False}
lock = threading.Lock()

def write_state(**kw):
    p = os.path.join(A, "state.json")
    try:
        s = json.load(open(p, encoding="utf-8"))
    except Exception:
        s = {}
    s.update(kw)
    json.dump(s, open(p, "w", encoding="utf-8"), ensure_ascii=False)

def export():
    subprocess.run([sys.executable, os.path.join(HERE, "export_city.py")], env=dict(os.environ, MARKETING_DATA=DATA), cwd=REPO)

def day_today():
    return __import__("datetime").date.today().isoformat()

def idle_reason(cfg):
    """Decides without calling Claude whether a shift is worth running."""
    u = usage.load()["days"].get(day_today(), {})
    if u.get("shifts", 0) >= int(cfg.get("max_shifts_per_day", 3)):
        return "Лимит смен на сегодня (%s) выполнен, агентство отдыхает до завтра" % cfg.get("max_shifts_per_day", 3)
    vids = os.path.join(DATA, "days", day_today(), "videos")
    batch_done = os.path.isdir(vids) and len([f for f in os.listdir(vids) if f.endswith(".mp4")]) >= 3
    if not batch_done:
        return None
    sig = []
    for d in ("stats",):
        p = os.path.join(DATA, d)
        if os.path.isdir(p):
            sig += sorted(os.listdir(p))
    approved = [i for i in ideas.load() if i.get("status") == "approved"]
    try:
        sig.append(os.path.getmtime(os.path.join(DATA, "log.json")))
    except OSError:
        pass
    key = json.dumps([sig, [i["id"] for i in approved]])
    last = state.get("last_sig")
    state["last_sig"] = key
    if last == key and not approved:
        return "Ролики на сегодня готовы, новых данных нет, жду (токены не тратятся)"
    return None

def shift_loop(publish):
    stop_flag = os.path.join(A, "STOP")
    try:
        os.remove(stop_flag)
    except OSError:
        pass
    n = 0
    last_idle = None
    while state["running"] and not os.path.exists(stop_flag):
        # headless run: allow file edits and only the commands the pipeline needs
        tools = ["Bash(git pull:*)", "Bash(node:*)", "Bash(npm:*)", "Bash(python3:*)", "Bash(ffmpeg:*)", "Bash(ffprobe:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(mkdir:*)", "Bash(date:*)"]
        # Chrome is always on: agents read stats there; posting itself is gated by config.json "publish" in the shift rules
        tools.append("mcp__claude-in-chrome__*")
        cfg = json.load(open(os.path.join(A, "config.json"))) if os.path.exists(os.path.join(A, "config.json")) else {}
        budget = int(cfg.get("daily_tokens", 0))
        why = None
        idle_for = int(os.environ.get("IDLE_SECONDS", "1800"))
        win = usage.window(float(cfg.get("window_hours", 5)), int(cfg.get("window_tokens", 0)))
        if budget and usage.summary(budget)["left"] == 0:
            why = "Дневной лимит токенов (%s) исчерпан, агентство ждёт завтра" % f"{budget:,}".replace(",", " ")
        elif win["limit"] and win["wait"] > 0:
            why = "Лимит на %g ч почти выбран, следующая смена примерно через %d мин" % (win["hours"], win["wait"] // 60 + 1)
            idle_for = min(idle_for, win["wait"]) if not os.environ.get("IDLE_SECONDS") else idle_for
        else:
            why = idle_reason(cfg)  # free pre-check: 0 tokens when there is nothing new to do
        if why:
            if why != last_idle:
                act("system", why)
                write_state(state="working", step="ждёт: " + why)
            last_idle = why
            for _ in range(idle_for):
                if not state["running"] or os.path.exists(stop_flag):
                    break
                time.sleep(1)
            continue
        last_idle = None
        n += 1
        write_state(state="working", step="смена %d: старт" % n, shift=n)
        act("system", "Смена %d началась" % n)
        export()
        cmd = ["claude", "-p", "/marketing-shift", "--output-format", "json", "--permission-mode", "acceptEdits",
               "--model", cfg.get("model", "sonnet"), "--max-turns", str(cfg.get("max_turns", 60))] + (["--chrome"] if HAS_CHROME else []) + ["--allowedTools"] + tools
        env = dict(os.environ, MARKETING_DATA=DATA)
        out_path = os.path.join(A, "last_shift.out")
        state["proc"] = subprocess.Popen(cmd, cwd=REPO, env=env, start_new_session=True,
                                         stdout=open(out_path, "w"), stderr=open(os.path.join(A, "last_shift.log"), "a"))
        state["proc"].wait()
        text = open(out_path, encoding="utf-8", errors="replace").read()
        open(os.path.join(A, "last_shift.log"), "a").write(text + "\n")
        tok = usage.add(text, n)
        if tok is not None:
            act("system", "Смена %d закончилась, потрачено %s токенов" % (n, f"{tok:,}".replace(",", " ")))
        elif state["running"]:
            act("system", "Смена %d закончилась с ошибкой, подробности в last_shift.log" % n)
        export()
        # short pause between shifts so the Mac and the accounts are not hammered; leaves quickly on Stop
        win = usage.window(float(cfg.get("window_hours", 5)), int(cfg.get("window_tokens", 0)))
        pause = int(os.environ.get("PAUSE_SECONDS") or (win["pause"] if win["limit"] else 300))
        if tok is None and state["running"]:
            # most likely the real subscription limit was hit (or the CLI failed): wait and try again, do not spin
            pause = int(os.environ.get("PAUSE_SECONDS") or 1800)
            act("system", "Смена не завершилась, вероятно упёрлись в лимит подписки. Жду %d мин и пробую снова" % (pause // 60))
        if state["running"]:
            act("system", "Следующая смена через %d мин" % (pause // 60))
            write_state(state="working", step="перерыв %d мин" % (pause // 60))
        for _ in range(pause):
            if not state["running"] or os.path.exists(stop_flag):
                break
            time.sleep(1)
    state["running"] = False
    write_state(state="sleeping", step="")
    act_clear()
    act("system", "Агентство остановлено, все ушли домой")
    export()
    if state.get("caff"):
        try:
            state["caff"].terminate()
        except Exception:
            pass

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/agency.json"):
            export()
            return self.send(200, open(os.path.join(A, "agency.json"), encoding="utf-8").read())
        if self.path == "/" or self.path.startswith("/index"):
            export()
            data = open(os.path.join(A, "agency.json"), encoding="utf-8").read().replace("</", "<\\/")
            html = open(CITY, encoding="utf-8").read().replace("<!--AGENCY-->", "<script>window.AGENCY=%s;window.AGENCY.control=true;</script>" % data)
            return self.send(200, html, "text/html")
        self.send(404, "{}")
    def do_POST(self):
        with lock:
            if self.path == "/start" and not state["running"]:
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}") if n else {}
                cfgp = os.path.join(A, "config.json")
                cfg = json.load(open(cfgp)) if os.path.exists(cfgp) else {}
                cfg["publish"] = bool(body.get("publish"))
                json.dump(cfg, open(cfgp, "w"))
                state["running"] = True
                try:
                    state["caff"] = subprocess.Popen(["caffeinate", "-i"])  # keeps the Mac awake while the agency works
                except Exception:
                    state["caff"] = None
                act("system", "Нажат Старт" + (" (публикация разрешена)" if cfg["publish"] else " (только подготовка, без публикации)"))
                threading.Thread(target=shift_loop, args=(cfg["publish"],), daemon=True).start()
            elif self.path == "/idea":
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}") if n else {}
                if body.get("verdict") in ("approved", "rejected"):
                    ideas.verdict(body.get("id"), body["verdict"], body.get("note", ""))
                    export()
            elif self.path == "/stop":
                state["running"] = False
                open(os.path.join(A, "STOP"), "w").close()
                p = state.get("proc")
                if p and p.poll() is None:
                    try:
                        os.killpg(p.pid, signal.SIGTERM)
                    except Exception:
                        pass
                write_state(state="sleeping", step="")
                act_clear()
                act("system", "Нажат Стоп")
        self.send(200, json.dumps({"running": state["running"]}))

if __name__ == "__main__":
    os.makedirs(A, exist_ok=True)
    write_state(state="sleeping", step="")
    print("Flexo Agency panel: http://localhost:%d  (Ctrl+C to quit)" % PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
