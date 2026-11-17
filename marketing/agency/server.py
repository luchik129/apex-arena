#!/usr/bin/env python3
"""Local control panel: serves the city on http://localhost:8787 with Start / Stop buttons.
Start runs the agency continuously (`claude -p /marketing-work`, no fixed shifts) plus a fast chat responder (`/marketing-reply`) until Stop. Nothing else runs in the background."""
import json, os, signal, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("MARKETING_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data"))
from act import log as act, clear as act_clear
import idea as ideas
import usage
import chat as chatmod
import tasks
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

def claude_cmd(prompt, cfg, tools, max_turns, model):
    return ["claude", "-p", prompt, "--output-format", "json", "--permission-mode", "acceptEdits",
            "--model", model, "--max-turns", str(max_turns)] + (["--chrome"] if HAS_CHROME else []) + ["--add-dir", DATA, "--allowedTools"] + tools + ["--disallowedTools"] + DENY

TOOLS = ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "WebSearch", "mcp__claude-in-chrome__*"]
reply_lock = threading.Lock()

def responder():
    """Answers the owner's chat on its own, in parallel with the workers, so he never waits for them."""
    while state["running"] or chatmod.unread():
        if not chatmod.unread():
            rwake.wait(5)
            rwake.clear()
            continue
        with reply_lock:
            if not chatmod.unread():
                continue
            cfg = json.load(open(os.path.join(A, "config.json"))) if os.path.exists(os.path.join(A, "config.json")) else {}
            out_path = os.path.join(A, "last_reply.out")
            try:
                p = subprocess.Popen(claude_cmd("/marketing-reply", cfg, TOOLS, int(cfg.get("reply_turns", 12)), cfg.get("reply_model", "sonnet")),
                                     cwd=REPO, env=dict(os.environ, MARKETING_DATA=DATA), start_new_session=True,
                                     stdout=open(out_path, "w"), stderr=subprocess.PIPE)
                try:
                    _, err = p.communicate(timeout=240)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGTERM)
                    err = b"timeout"
                text = open(out_path, encoding="utf-8", errors="replace").read()
                info = usage.result_info(text)
                if info["ok"]:
                    usage.add(text, 0)
                if chatmod.unread():  # model did not answer: say so instead of staying silent
                    why = info.get("message") or " ".join((err or b"").decode("utf-8", "replace").split())[-200:] or "нет ответа"
                    chatmod.reply("Не смог ответить как надо (%s). Сообщение получил, передам рабочим, попробуй написать ещё раз через минуту." % why)
            except Exception as e:
                chatmod.reply("Не смог ответить (%s). Сообщение получил." % e)
            export()

rwake = threading.Event()

def work_loop(publish):
    """Continuous work: no fixed shifts. Runs a cycle, takes a short breather, runs the next. Waits only when there is nothing to do."""
    stop_flag = os.path.join(A, "STOP")
    try:
        os.remove(stop_flag)
    except OSError:
        pass
    n = 0
    fails = 0
    last_sig = None
    while state["running"] and not os.path.exists(stop_flag):
        cfg = json.load(open(os.path.join(A, "config.json"))) if os.path.exists(os.path.join(A, "config.json")) else {}
        sig = json.dumps([[t["id"] for t in tasks.open_tasks()], [i["id"] for i in ideas.load() if i.get("status") == "approved"]])
        # nothing new since the last good cycle and today's batch is ready: wait for the owner / new data instead of burning tokens
        vids = os.path.join(DATA, "days", day_today(), "videos")
        batch_done = os.path.isdir(vids) and len([f for f in os.listdir(vids) if f.endswith(".mp4")]) >= 3
        if n and batch_done and sig == last_sig and fails == 0:
            msg = "Ролики готовы, задач нет, жду новую задачу или данные"
            act("system", msg)
            write_state(state="working", step="ждёт: " + msg)
            nap(int(os.environ.get("IDLE_SECONDS", "60")), stop_flag)
            continue
        n += 1
        write_state(state="working", step="работает")
        export()
        env = dict(os.environ, MARKETING_DATA=DATA)
        out_path = os.path.join(A, "last_work.out")
        state["proc"] = subprocess.Popen(claude_cmd("/marketing-work", cfg, TOOLS, int(cfg.get("max_turns", 60)), cfg.get("model", "sonnet")),
                                         cwd=REPO, env=env, start_new_session=True,
                                         stdout=open(out_path, "w"), stderr=open(os.path.join(A, "last_work.err"), "w"))
        state["proc"].wait()
        text = open(out_path, encoding="utf-8", errors="replace").read()
        err = open(os.path.join(A, "last_work.err"), encoding="utf-8", errors="replace").read()[-400:]
        open(os.path.join(A, "last_work.log"), "a").write(text + "\n")
        info = usage.result_info(text)
        if info["ok"]:
            usage.add(text, n)
            act("system", "Цикл работы закончен, потрачено %s токенов" % f"{info['tokens']:,}".replace(",", " "))
            fails = 0
            last_sig = sig
        elif state["running"]:
            fails += 1
            why_failed = info["message"] or " ".join(err.split())[-200:] or "неизвестная ошибка"
            act("system", "Работа оборвалась сразу. Причина: %s" % why_failed)
        export()
        pause = int(os.environ.get("PAUSE_SECONDS") or 20)
        if not info["ok"] and state["running"]:
            # failed at once: most likely the subscription limit; back off further each time instead of spinning
            pause = int(os.environ.get("PAUSE_SECONDS") or min(7200, 1800 * fails))
            act("system", "Жду %d мин и пробую снова (подряд неудач: %d)" % (pause // 60, fails))
            write_state(state="working", step="ждёт лимит %d мин" % (pause // 60))
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
                threading.Thread(target=work_loop, args=(cfg["publish"],), daemon=True).start()
                threading.Thread(target=responder, daemon=True).start()
            elif self.path == "/chat":
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}") if n else {}
                if str(body.get("text", "")).strip():
                    chatmod.add_owner(str(body["text"]))
                    wake.set()
                    rwake.set()
                    if not state["running"]:
                        threading.Thread(target=responder, daemon=True).start()
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
