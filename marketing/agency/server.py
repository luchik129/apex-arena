#!/usr/bin/env python3
"""Local control panel: serves the city on http://localhost:8787 with Start / Stop buttons.
Start runs shifts of the agency in a loop (via `claude -p /marketing-shift`) until Stop. Nothing else runs in the background."""
import json, os, signal, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("MARKETING_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data"))
from act import log as act, clear as act_clear
import idea as ideas
import usage
import chat as chatmod
HAS_CHROME = "--chrome" in subprocess.run(["claude", "--help"], capture_output=True, text=True).stdout if __import__("shutil").which("claude") else False
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DATA = os.environ.get("MARKETING_DATA") or os.path.join(REPO, "marketing", "data")
A = os.path.join(DATA, "agency")
CITY = os.path.join(HERE, "city.html")
PORT = int(os.environ.get("PORT", "8787"))
# Everything is allowed for the agents except commands that can wreck the machine and that no marketing task needs.
DENY = ["Bash(sudo:*)", "Bash(rm -rf /:*)", "Bash(rm -rf ~:*)", "Bash(rm -fr /:*)", "Bash(rm -fr ~:*)", "Bash(mkfs:*)", "Bash(diskutil:*)",
        "Bash(shutdown:*)", "Bash(reboot:*)", "Bash(pmset:*)", "Bash(launchctl:*)", "Bash(chown:*)", "Bash(git push --force:*)"]
state = {"proc": None, "caff": None, "running": False}
wake = threading.Event()  # set when the owner writes in the chat: ends any waiting at once

def nap(seconds, stop_flag):
    """Waits up to `seconds`, returns early on Stop or when the owner wrote something."""
    end = time.time() + seconds
    while time.time() < end and state["running"] and not os.path.exists(stop_flag):
        if wake.wait(1):
            wake.clear()
            return
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
    if chatmod.unread():
        return None
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
    fails = 0
    last_idle = None
    while state["running"] and not os.path.exists(stop_flag):
        # headless run: allow file edits and only the commands the pipeline needs
        # The editor runs compound commands (cd ... && OUT_DIR=... node render.js, ffprobe, python3), which prefix rules like Bash(node:*) never match.
        # So Bash is allowed as a whole and the dangerous things are denied explicitly below.
        tools = ["Bash"]
        tools.append("mcp__claude-in-chrome__*")
        cfg = json.load(open(os.path.join(A, "config.json"))) if os.path.exists(os.path.join(A, "config.json")) else {}
        budget = int(cfg.get("daily_tokens", 0))
        owner_wants = bool(chatmod.unread())
        why = None
        idle_for = int(os.environ.get("IDLE_SECONDS", "1800"))
        win = usage.window(float(cfg.get("window_hours", 5)), int(cfg.get("window_tokens", 0)))
        if owner_wants:
            why = None
        elif budget and usage.summary(budget)["left"] == 0:
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
            nap(idle_for, stop_flag)
            continue
        last_idle = None
        n += 1
        write_state(state="working", step="смена %d: старт" % n, shift=n)
        act("system", "Смена %d началась" % n)
        export()
        cmd = ["claude", "-p", "/marketing-shift", "--output-format", "json", "--permission-mode", "acceptEdits",
               "--model", cfg.get("model", "sonnet"), "--max-turns", str(cfg.get("max_turns", 60))] + (["--chrome"] if HAS_CHROME else []) + ["--allowedTools"] + tools + ["--disallowedTools"] + DENY
        env = dict(os.environ, MARKETING_DATA=DATA)
        out_path = os.path.join(A, "last_shift.out")
        state["proc"] = subprocess.Popen(cmd, cwd=REPO, env=env, start_new_session=True,
                                         stdout=open(out_path, "w"), stderr=open(os.path.join(A, "last_shift.err"), "w"))
        state["proc"].wait()
        text = open(out_path, encoding="utf-8", errors="replace").read()
        err = open(os.path.join(A, "last_shift.err"), encoding="utf-8", errors="replace").read()[-400:] if os.path.exists(os.path.join(A, "last_shift.err")) else ""
        open(os.path.join(A, "last_shift.log"), "a").write(text + "\n")
        info = usage.result_info(text)
        tok = None
        if info["ok"]:
            tok = usage.add(text, n)
            act("system", "Смена %d закончилась, потрачено %s токенов" % (n, f"{info['tokens']:,}".replace(",", " ")))
            fails = 0
        elif state["running"]:
            fails += 1
            why_failed = info["message"] or " ".join(err.split())[-200:] or "неизвестная ошибка"
            act("system", "Смена %d оборвалась сразу, это не конец работы. Причина: %s" % (n, why_failed))
        export()
        # short pause between shifts so the Mac and the accounts are not hammered; leaves quickly on Stop
        win = usage.window(float(cfg.get("window_hours", 5)), int(cfg.get("window_tokens", 0)))
        pause = int(os.environ.get("PAUSE_SECONDS") or (win["pause"] if win["limit"] else 300))
        if tok is None and state["running"]:
            # failed at once: most likely the subscription limit; back off further each time instead of spinning
            pause = int(os.environ.get("PAUSE_SECONDS") or min(7200, 1800 * fails))
            act("system", "Жду %d мин и пробую снова (подряд неудач: %d)" % (pause // 60, fails))
        if state["running"]:
            act("system", "Следующая смена через %d мин" % (pause // 60))
            write_state(state="working", step="перерыв %d мин" % (pause // 60))
        nap(pause, stop_flag)
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
            elif self.path == "/chat":
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}") if n else {}
                if str(body.get("text", "")).strip():
                    chatmod.add_owner(str(body["text"]))
                    wake.set()
                    export()
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
