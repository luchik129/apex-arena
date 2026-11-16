#!/usr/bin/env python3
"""Local control panel: serves the city on http://localhost:8787 with Start / Stop buttons.
Start runs shifts of the agency in a loop (via `claude -p /marketing-shift`) until Stop. Nothing else runs in the background."""
import json, os, signal, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("MARKETING_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data"))
from act import log as act, clear as act_clear
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

def shift_loop(publish):
    stop_flag = os.path.join(A, "STOP")
    try:
        os.remove(stop_flag)
    except OSError:
        pass
    n = 0
    while state["running"] and not os.path.exists(stop_flag):
        n += 1
        write_state(state="working", step="смена %d: старт" % n, shift=n)
        act("system", "Смена %d началась" % n)
        export()
        # headless run: allow file edits and only the commands the pipeline needs; Chrome tools only when publishing was switched on
        tools = ["Bash(node:*)", "Bash(npm:*)", "Bash(python3:*)", "Bash(ffmpeg:*)", "Bash(ffprobe:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(mkdir:*)", "Bash(date:*)"]
        if publish:
            tools.append("mcp__claude-in-chrome__*")
        cmd = ["claude", "-p", "/marketing-shift", "--permission-mode", "acceptEdits", "--allowedTools"] + tools
        env = dict(os.environ, MARKETING_DATA=DATA)
        state["proc"] = subprocess.Popen(cmd, cwd=REPO, env=env, start_new_session=True,
                                         stdout=open(os.path.join(A, "last_shift.log"), "a"), stderr=subprocess.STDOUT)
        state["proc"].wait()
        export()
        # short pause between shifts so the Mac and the accounts are not hammered; leaves quickly on Stop
        for _ in range(900):
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
