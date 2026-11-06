#!/usr/bin/env bash
# ============================================================================
#  BotPanel Installer  -  self-hosted bot hosting panel for your VPS
#  Python / Node.js / JavaScript bots, web UI, file manager, live console,
#  auto-restart and a free random  xxxx-xxxx.trycloudflare.com  URL.
#
#  Usage:   sudo ./install.sh            (install / re-install)
#           sudo ./install.sh --uninstall
#  After install you get a helper command:  botpanel help
# ============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\e[31m✗ Installer failed near line $LINENO. Read the messages above.\e[0m"' ERR

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
APP=/opt/botpanel
SVC_USER=botpanel

say()  { echo -e "${C}➜${N} $*"; }
ok()   { echo -e "${G}✓${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
die()  { echo -e "${R}✗ $*${N}"; trap - ERR; exit 1; }

ask() {            # ask "prompt" "default"  -> $REPLY
  local a=""
  printf '%b' "$1" >/dev/tty 2>/dev/null || true
  read -r a </dev/tty 2>/dev/null || true
  REPLY="${a:-${2:-}}"
}
ask_secret() {     # ask_secret "prompt" -> $REPLY (hidden)
  local a=""
  printf '%b' "$1" >/dev/tty 2>/dev/null || true
  read -rs a </dev/tty 2>/dev/null || true
  printf '\n' >/dev/tty 2>/dev/null || true
  REPLY="$a"
}

[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo ./install.sh"
command -v apt-get >/dev/null 2>&1 || die "This installer supports Debian / Ubuntu only."

# ---------------------------------------------------------------- uninstall
if [ "${1:-}" = "--uninstall" ]; then
  ask "${R}This removes BotPanel AND all bot files in $APP. Type YES to continue: ${N}" ""
  [ "$REPLY" = "YES" ] || die "Cancelled."
  systemctl disable --now botpanel botpanel-tunnel 2>/dev/null || true
  rm -f /etc/systemd/system/botpanel.service /etc/systemd/system/botpanel-tunnel.service
  systemctl daemon-reload
  pkill -u "$SVC_USER" 2>/dev/null || true
  rm -rf "$APP"
  userdel "$SVC_USER" 2>/dev/null || true
  rm -f /usr/local/bin/botpanel /root/botpanel-credentials.txt
  ok "BotPanel removed."
  exit 0
fi

clear 2>/dev/null || true
echo -e "${B}${C}"
cat <<'BANNER'
  ____        _   ____                  _
 | __ )  ___ | |_|  _ \ __ _ _ __   ___| |
 |  _ \ / _ \| __| |_) / _` | '_ \ / _ \ |
 | |_) | (_) | |_|  __/ (_| | | | |  __/ |
 |____/ \___/ \__|_|   \__,_|_| |_|\___|_|
        Bot hosting panel for your VPS
BANNER
echo -e "${N}"

# ---------------------------------------------------------------- questions
echo -e "${B}What kind of bots will you host?${N}"
echo "  1) Python"
echo "  2) Node.js / JavaScript"
echo "  3) Both (recommended)"
ask "Choose [3]: " 3
case "$REPLY" in 1|2|3) RT="$REPLY";; *) RT=3;; esac

echo
echo -e "${B}How should people open the panel?${N}"
echo "  1) Free random URL  (words.trycloudflare.com, HTTPS, no domain needed)"
echo "  2) Direct  http://SERVER-IP:PORT"
ask "Choose [1]: " 1
case "$REPLY" in 2) MODE=direct;; *) MODE=tunnel;; esac

ask "Panel port [8080]: " 8080
PORT="$REPLY"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "Port must be a number from 1024 to 65535."

echo
ask "Admin username [admin]: " admin
ADMIN="$REPLY"
ask_secret "Admin password (leave empty to auto-generate): "
PASS="$REPLY"
echo

# ---------------------------------------------------------------- packages
say "Installing system packages (this can take a minute)..."
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
apt-get update -y -qq
apt-get install -y -qq curl git ca-certificates gnupg unzip openssl build-essential \
  python3 python3-venv python3-pip >/dev/null
ok "Base packages ready"

if [ "$RT" != "1" ]; then
  NODE_MAJOR=0
  command -v node >/dev/null 2>&1 && NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -lt 18 ]; then
    say "Installing Node.js..."
    if curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 \
       && apt-get install -y -qq nodejs >/dev/null; then
      :
    else
      warn "NodeSource failed, using the distro Node.js instead"
      apt-get install -y -qq nodejs npm >/dev/null
    fi
  fi
  ok "Node.js $(node -v) ready"
fi
[ "$RT" != "2" ] && ok "Python $(python3 --version | cut -d' ' -f2) ready"

if [ -z "$PASS" ]; then
  PASS="$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')"
  AUTOPASS=1
else
  AUTOPASS=0
fi

# ---------------------------------------------------------------- user + dirs
id "$SVC_USER" >/dev/null 2>&1 || useradd -r -m -d "$APP/home" -s /bin/bash "$SVC_USER"
mkdir -p "$APP"/{static,data/bots,home}
systemctl stop botpanel botpanel-tunnel 2>/dev/null || true

# ---------------------------------------------------------------- panel backend
say "Writing panel backend..."
cat > "$APP/app.py" <<'PYAPP'
#!/usr/bin/env python3
import os, re, json, time, signal, shutil, subprocess, threading, secrets, zipfile, tempfile
from pathlib import Path
import psutil
from flask import Flask, request, jsonify, session, abort, send_file, send_from_directory
from werkzeug.exceptions import HTTPException
from werkzeug.security import check_password_hash, generate_password_hash

BASE = Path(os.environ.get("BOTPANEL_HOME", "/opt/botpanel"))
DATA = BASE / "data"
BOTS = DATA / "bots"
DB = DATA / "bots.json"
CFG = DATA / "config.json"
BOTS.mkdir(parents=True, exist_ok=True)
cfg = json.loads(CFG.read_text())

app = Flask(__name__, static_folder=None)
app.secret_key = cfg["secret"]
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax",
                  PERMANENT_SESSION_LIFETIME=7 * 86400)

lock = threading.RLock()
procs, pcache, dcache, fails = {}, {}, {}, {}
ID_RE = re.compile(r"^[a-f0-9]{8}$")
ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
TUNNEL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
DEFAULTS = {"python": "python3 main.py", "node": "node index.js", "custom": "bash start.sh"}
STARTERS = {
    "python": ("main.py", 'import time\nprint("Hello from your Python bot!", flush=True)\nwhile True:\n    time.sleep(10)\n    print("still alive", time.strftime("%H:%M:%S"), flush=True)\n'),
    "node": ("index.js", 'console.log("Hello from your Node.js bot!");\nsetInterval(() => console.log("still alive", new Date().toLocaleTimeString()), 10000);\n'),
    "custom": ("start.sh", '#!/bin/bash\necho "Hello from a custom bot!"\nwhile true; do sleep 10; echo "still alive"; done\n'),
}


# ------------------------------------------------------------------ storage
def load():
    try:
        return json.loads(DB.read_text())
    except Exception:
        return {}


def save(d):
    tmp = DB.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, indent=1))
    tmp.replace(DB)


# ------------------------------------------------------------------ processes
def pid_alive(pid):
    try:
        return psutil.Process(pid).status() != psutil.STATUS_ZOMBIE
    except psutil.Error:
        return False


def alive(b):
    pid = b.get("pid")
    if not pid:
        return False
    try:
        p = psutil.Process(pid)
        if p.status() == psutil.STATUS_ZOMBIE:
            return False
        return abs(p.create_time() - b.get("ctime", 0)) < 1.5
    except psutil.Error:
        return False


def bot_env(b, files):
    """Environment for a bot: panel env minus panel-only vars, plus the bot's own variables."""
    env = os.environ.copy()
    for k in ("HOST", "PORT", "BOTPANEL_HOME"):
        env.pop(k, None)          # the panel's own settings must not leak into bots
    env["PYTHONUNBUFFERED"] = "1"
    for k, v in (b.get("env") or {}).items():
        if ENV_KEY.match(str(k)):
            env[str(k)] = str(v)
    venv = files / ".venv"
    if venv.is_dir():
        env["VIRTUAL_ENV"] = str(venv)
        env["PATH"] = f"{venv}/bin:" + env.get("PATH", "")
    return env


def start_bot(bid):
    with lock:
        db = load()
        b = db.get(bid)
        if not b:
            return "Bot not found"
        if alive(b):
            return None
        d = BOTS / bid
        files = d / "files"
        files.mkdir(parents=True, exist_ok=True)
        logp = d / "console.log"
        if logp.exists() and logp.stat().st_size > 5_000_000:
            logp.write_bytes(logp.read_bytes()[-500_000:])
        env = bot_env(b, files)
        with open(logp, "ab") as log:
            log.write(f"\n[panel] $ {b['cmd']}\n".encode())
            try:
                p = subprocess.Popen(b["cmd"], shell=True, executable="/bin/bash", cwd=files, env=env,
                                     stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
            except Exception as e:
                log.write(f"[panel] failed to start: {e}\n".encode())
                return str(e)
        procs[bid] = p
        try:
            ct = psutil.Process(p.pid).create_time()
        except psutil.Error:
            ct = time.time()
        b.update(pid=p.pid, ctime=ct, desired=True, started=time.time())
        save(db)
        return None


def kill_tree(bid, pid):
    try:
        pgid = os.getpgid(pid)
    except ProcessLookupError:
        return

    def sig(s):
        try:
            if pgid == pid:
                os.killpg(pgid, s)
            else:
                os.kill(pid, s)
        except ProcessLookupError:
            pass

    sig(signal.SIGTERM)
    for _ in range(50):
        pr = procs.get(bid)
        if pr:
            pr.poll()
        if not pid_alive(pid):
            return
        time.sleep(0.2)
    sig(signal.SIGKILL)
    pr = procs.get(bid)
    if pr:
        try:
            pr.wait(3)
        except Exception:
            pass


def stop_bot(bid):
    with lock:
        db = load()
        b = db.get(bid)
        if not b:
            return
        b["desired"] = False
        save(db)
    if b.get("pid") and alive(b):
        kill_tree(bid, b["pid"])


def watcher():
    first = True
    while True:
        try:
            for pr in list(procs.values()):
                pr.poll()
            for bid, b in list(load().items()):
                if b.get("desired") and not alive(b):
                    if first or (b.get("autorestart", True) and time.time() - b.get("started", 0) > 5):
                        start_bot(bid)
                    elif not b.get("autorestart", True):
                        with lock:
                            db = load()
                            if bid in db:
                                db[bid]["desired"] = False
                                save(db)
            first = False
        except Exception as e:
            print("watcher error:", e, flush=True)
        time.sleep(3)


def usage(b):
    cpu = mem = 0
    if alive(b):
        try:
            if len(pcache) > 500:
                pcache.clear()
            root = pcache.setdefault(b["pid"], psutil.Process(b["pid"]))
            for p in [root] + root.children(recursive=True):
                pc = pcache.setdefault(p.pid, p)
                cpu += pc.cpu_percent(None)
                mem += pc.memory_info().rss
        except psutil.Error:
            pass
    return round(cpu, 1), mem


def disk(bid):
    t, s = dcache.get(bid, (0, 0))
    if time.time() - t > 60:
        s = 0
        for r, _, fs in os.walk(BOTS / bid / "files"):
            for f in fs:
                try:
                    s += os.lstat(os.path.join(r, f)).st_size
                except OSError:
                    pass
        dcache[bid] = (time.time(), s)
    return s


def view(bid, b):
    cpu, mem = usage(b)
    on = alive(b)
    return dict(id=bid, name=b["name"], runtime=b["runtime"], cmd=b["cmd"],
                autorestart=b.get("autorestart", True),
                status="running" if on else ("restarting" if b.get("desired") else "offline"),
                cpu=cpu, mem=mem, disk=disk(bid),
                uptime=int(time.time() - b.get("started", 0)) if on else 0)


def need(bid):
    if not ID_RE.match(bid) or bid not in load():
        abort(404, "Bot not found")


def safe(bid, rel):
    root = (BOTS / bid / "files").resolve()
    p = (root / str(rel or "").lstrip("/")).resolve()
    if p != root and root not in p.parents:
        abort(400, "Invalid path")
    return root, p


def bash_bg(bid, script, header="running"):
    """Run a shell snippet in the bot folder (with the bot's env), output goes to the console log."""
    files = BOTS / bid / "files"
    files.mkdir(parents=True, exist_ok=True)
    env = bot_env(load().get(bid, {}), files)

    def run():
        try:
            with open(BOTS / bid / "console.log", "ab") as log:
                log.write(f"\n[panel] {header}\n".encode())
                log.flush()
                p = subprocess.Popen(script, shell=True, executable="/bin/bash", cwd=files, env=env,
                                     stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
                try:
                    rc = p.wait(timeout=1800)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    p.wait()
                    log.write(b"[panel] stopped after 30 minutes (timeout).\n")
                    return
                log.write(f"[panel] done (exit code {rc}).\n".encode())
        except Exception as e:
            print("bash_bg error:", e, flush=True)
    threading.Thread(target=run, daemon=True).start()


def tunnel_url():
    try:
        with open(DATA / "tunnel.log", "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 200000))
            txt = f.read().decode("utf-8", "ignore")
        urls = [u for u in TUNNEL_RE.findall(txt) if not u.startswith("https://api.")]
        return urls[-1] if urls else None
    except Exception:
        return None


# ------------------------------------------------------------------ http
@app.errorhandler(HTTPException)
def http_err(e):
    return jsonify(error=e.description), e.code


@app.before_request
def guard():
    if not request.path.startswith("/api/"):
        return None
    if request.method not in ("GET", "HEAD") and request.headers.get("X-Requested-With") != "botpanel":
        return jsonify(error="Bad request"), 400
    if request.path == "/api/login":
        return None
    if not session.get("u"):
        return jsonify(error="Unauthorized"), 401
    return None


@app.get("/")
def index():
    return send_from_directory(BASE / "static", "index.html")


@app.post("/api/login")
def login():
    ip = request.headers.get("CF-Connecting-IP") if request.remote_addr == "127.0.0.1" else request.remote_addr
    now = time.time()
    fl = [t for t in fails.get(ip, []) if now - t < 300]
    if len(fl) >= 6:
        return jsonify(error="Too many attempts. Try again in 5 minutes."), 429
    j = request.get_json(silent=True) or {}
    if j.get("username") == cfg["user"] and check_password_hash(cfg["hash"], str(j.get("password", ""))):
        session.permanent = True
        session["u"] = cfg["user"]
        return jsonify(ok=True)
    fl.append(now)
    fails[ip] = fl
    return jsonify(error="Invalid username or password"), 401


@app.get("/api/me")
def me():
    return jsonify(user=session["u"])


@app.post("/api/logout")
def logout():
    session.clear()
    return jsonify(ok=True)


@app.post("/api/password")
def change_pw():
    j = request.get_json(silent=True) or {}
    if not check_password_hash(cfg["hash"], str(j.get("old", ""))):
        return jsonify(error="Current password is wrong"), 400
    new = str(j.get("new", ""))
    if len(new) < 8:
        return jsonify(error="New password must be at least 8 characters"), 400
    cfg["hash"] = generate_password_hash(new)
    CFG.write_text(json.dumps(cfg))
    return jsonify(ok=True)


@app.get("/api/system")
def system():
    vm = psutil.virtual_memory()
    du = shutil.disk_usage(str(DATA))
    return jsonify(cpu=psutil.cpu_percent(None), cores=psutil.cpu_count(), ram_used=vm.used,
                   ram_total=vm.total, disk_used=du.used, disk_total=du.total, url=tunnel_url(),
                   mode=cfg.get("mode", "tunnel"), uptime=int(time.time() - psutil.boot_time()))


@app.get("/api/bots")
def bots_list():
    return jsonify([view(i, b) for i, b in load().items()])


@app.post("/api/bots")
def bots_create():
    j = request.get_json(silent=True) or {}
    rt = j.get("runtime")
    if rt not in DEFAULTS:
        return jsonify(error="Pick a runtime"), 400
    name = str(j.get("name", "")).strip()[:40] or "My Bot"
    cmd = str(j.get("cmd") or DEFAULTS[rt]).strip()[:500]
    bid = secrets.token_hex(4)
    files = BOTS / bid / "files"
    files.mkdir(parents=True)
    fn, body = STARTERS[rt]
    (files / fn).write_text(body)
    if rt == "python":
        try:
            subprocess.run(["python3", "-m", "venv", ".venv"], cwd=files, timeout=180, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    with lock:
        db = load()
        db[bid] = dict(name=name, runtime=rt, cmd=cmd, autorestart=True, desired=False, created=time.time())
        save(db)
    return jsonify(id=bid)


@app.patch("/api/bots/<bid>")
def bots_patch(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    clean = None
    if "env" in j:
        e = j["env"]
        if not isinstance(e, dict):
            return jsonify(error="Invalid environment variables"), 400
        clean = {}
        for k, v in list(e.items())[:100]:
            k = str(k).strip()
            if not ENV_KEY.match(k):
                return jsonify(error=f"Invalid variable name: {k[:30]}"), 400
            clean[k] = str(v)[:4000]
    with lock:
        db = load()
        b = db[bid]
        if clean is not None:
            b["env"] = clean
        if "name" in j:
            b["name"] = str(j["name"]).strip()[:40] or b["name"]
        if "cmd" in j and str(j["cmd"]).strip():
            b["cmd"] = str(j["cmd"]).strip()[:500]
        if "autorestart" in j:
            b["autorestart"] = bool(j["autorestart"])
        save(db)
    return jsonify(ok=True)


@app.delete("/api/bots/<bid>")
def bots_delete(bid):
    need(bid)
    stop_bot(bid)
    with lock:
        db = load()
        db.pop(bid, None)
        save(db)
    procs.pop(bid, None)
    shutil.rmtree(BOTS / bid, ignore_errors=True)
    return jsonify(ok=True)


@app.post("/api/bots/<bid>/<action>")
def bots_action(bid, action):
    need(bid)
    if action == "start":
        err = start_bot(bid)
        if err:
            return jsonify(error=err), 500
    elif action == "stop":
        stop_bot(bid)
    elif action == "restart":
        stop_bot(bid)
        err = start_bot(bid)
        if err:
            return jsonify(error=err), 500
    elif action == "install":
        rt = load()[bid]["runtime"]
        if rt == "python":
            bash_bg(bid, '[ -d .venv ] || python3 -m venv .venv; . .venv/bin/activate; '
                         'if [ -f requirements.txt ]; then pip install -r requirements.txt; '
                         'else echo "No requirements.txt found"; fi', "installing dependencies...")
        elif rt == "node":
            bash_bg(bid, 'if [ -f package.json ]; then npm install; else echo "No package.json found"; fi',
                    "installing dependencies...")
        else:
            bash_bg(bid, 'echo "Custom bots: install things from your own start.sh"', "install")
    else:
        abort(404)
    return jsonify(ok=True)


@app.get("/api/bots/<bid>/logs")
def bots_logs(bid):
    need(bid)
    p = BOTS / bid / "console.log"
    if not p.exists():
        return jsonify(text="")
    with open(p, "rb") as f:
        f.seek(0, 2)
        sz = f.tell()
        f.seek(max(0, sz - 80000))
        return jsonify(text=f.read().decode("utf-8", "replace"))


@app.post("/api/bots/<bid>/logs/clear")
def bots_logs_clear(bid):
    need(bid)
    (BOTS / bid / "console.log").write_bytes(b"")
    return jsonify(ok=True)


@app.post("/api/bots/<bid>/exec")
def bots_exec(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    cmd = str(j.get("cmd", "")).strip()
    if not cmd:
        return jsonify(error="Type a command first"), 400
    if len(cmd) > 2000:
        return jsonify(error="Command is too long"), 400
    bash_bg(bid, cmd, f"$ {cmd}")
    return jsonify(ok=True)


@app.get("/api/bots/<bid>/env")
def bots_env(bid):
    need(bid)
    return jsonify(env=load()[bid].get("env") or {})


# ------------------------------------------------------------------ files
@app.get("/api/bots/<bid>/files")
def f_list(bid):
    need(bid)
    root, p = safe(bid, request.args.get("path", ""))
    if not p.is_dir():
        abort(404, "Folder not found")
    items = []
    for e in sorted(p.iterdir(), key=lambda e: (not e.is_dir(), e.name.lower())):
        try:
            st = e.stat()
        except OSError:
            continue
        items.append(dict(name=e.name, dir=e.is_dir(), size=st.st_size, mtime=int(st.st_mtime)))
    return jsonify(path="" if p == root else str(p.relative_to(root)), items=items)


@app.get("/api/bots/<bid>/file")
def f_read(bid):
    need(bid)
    _, p = safe(bid, request.args.get("path", ""))
    if not p.is_file():
        abort(404, "File not found")
    if p.stat().st_size > 2_000_000:
        abort(413, "File too large to edit here (download it instead)")
    try:
        return jsonify(content=p.read_bytes().decode("utf-8"))
    except UnicodeDecodeError:
        abort(415, "Binary file - cannot edit")


@app.put("/api/bots/<bid>/file")
def f_write(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    _, p = safe(bid, j.get("path", ""))
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(str(j.get("content", "")), encoding="utf-8")
    dcache.pop(bid, None)
    return jsonify(ok=True)


@app.get("/api/bots/<bid>/download")
def f_download(bid):
    need(bid)
    _, p = safe(bid, request.args.get("path", ""))
    if not p.is_file():
        abort(404, "File not found")
    return send_file(p, as_attachment=True)


@app.post("/api/bots/<bid>/mkdir")
def f_mkdir(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    _, p = safe(bid, j.get("path", ""))
    p.mkdir(parents=True, exist_ok=True)
    return jsonify(ok=True)


@app.post("/api/bots/<bid>/delete")
def f_delete(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    root, p = safe(bid, j.get("path", ""))
    if p == root:
        abort(400, "Cannot delete the root folder")
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    elif p.exists() or p.is_symlink():
        p.unlink()
    dcache.pop(bid, None)
    return jsonify(ok=True)


@app.post("/api/bots/<bid>/upload")
def f_upload(bid):
    need(bid)
    _, d = safe(bid, request.form.get("path", ""))
    d.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in request.files.getlist("files"):
        name = os.path.basename(f.filename or "").strip()
        if name and name not in (".", ".."):
            f.save(d / name)
            n += 1
    dcache.pop(bid, None)
    return jsonify(ok=True, count=n)


@app.post("/api/bots/<bid>/extract")
def f_extract(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    root, z = safe(bid, j.get("path", ""))
    if not z.is_file() or not zipfile.is_zipfile(z):
        abort(400, "Not a valid zip file")
    with zipfile.ZipFile(z) as zf:
        for m in zf.infolist():
            t = (z.parent / m.filename).resolve()
            if t != root and root not in t.parents:
                abort(400, "Unsafe zip file")
        zf.extractall(z.parent)
    dcache.pop(bid, None)
    return jsonify(ok=True)


@app.post("/api/bots/<bid>/rename")
def f_rename(bid):
    need(bid)
    j = request.get_json(silent=True) or {}
    root, src = safe(bid, j.get("path", ""))
    name = str(j.get("name", "")).strip()
    if src == root:
        abort(400, "Cannot rename the root folder")
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        abort(400, "Invalid name")
    if not src.exists() and not src.is_symlink():
        abort(404, "Not found")
    dst = src.parent / name
    if dst.exists() or dst.is_symlink():
        abort(409, "Something with that name already exists")
    src.rename(dst)
    return jsonify(ok=True)


@app.get("/api/bots/<bid>/backup")
def f_backup(bid):
    need(bid)
    root = BOTS / bid / "files"
    tmp = tempfile.TemporaryFile()
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
        for r, dirs, fs in os.walk(root):
            dirs[:] = [d for d in dirs if d not in (".venv", "node_modules", "__pycache__")]
            for f in fs:
                full = os.path.join(r, f)
                if os.path.islink(full):
                    continue
                try:
                    zf.write(full, os.path.relpath(full, root))
                except OSError:
                    pass
    tmp.seek(0)
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", load()[bid]["name"]).strip("_") or "bot"
    return send_file(tmp, as_attachment=True, download_name=f"{name}-backup.zip", mimetype="application/zip")


if __name__ == "__main__":
    threading.Thread(target=watcher, daemon=True).start()
    from waitress import serve
    serve(app, host=os.environ.get("HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8080")),
          threads=24, max_request_body_size=1 << 42)
PYAPP
ok "Backend written"

# ---------------------------------------------------------------- panel frontend
say "Writing panel interface..."
cat > "$APP/static/index.html" <<'HTMLUI'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BotPanel</title>
<style>
:root{--bg:#0a0c16;--card:#12162a;--card2:#181d36;--line:#252c4a;--tx:#e9edfa;--mu:#8791b4;--ac:#7c5cff;--ac2:#22d3ee;--ok:#22c55e;--bad:#ef4444;--warn:#f59e0b}
*{box-sizing:border-box;margin:0}
body{font:15px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:radial-gradient(1200px 600px at 10% -10%,#1b1550 0,transparent 60%),radial-gradient(900px 500px at 100% 0,#0b3a4a 0,transparent 55%),var(--bg);color:var(--tx);min-height:100vh}
.hidden{display:none!important}
.mu{color:var(--mu);font-size:13px}
a{color:var(--ac2);cursor:pointer;text-decoration:none}
header{display:flex;align-items:center;gap:14px;padding:14px 22px;border-bottom:1px solid var(--line);background:rgba(10,12,22,.7);backdrop-filter:blur(10px);position:sticky;top:0;z-index:5;flex-wrap:wrap}
.logo{font-weight:800;font-size:19px;background:linear-gradient(90deg,var(--ac),var(--ac2));-webkit-background-clip:text;background-clip:text;color:transparent}
.chips{display:flex;gap:8px;flex:1;flex-wrap:wrap}
.chip{background:var(--card);border:1px solid var(--line);border-radius:999px;padding:4px 12px;font-size:12.5px;color:var(--mu)}
.chip b{color:var(--tx);font-weight:600}
.chip.url{cursor:pointer;border-color:#35407a}
main{max-width:1100px;margin:0 auto;padding:24px 18px 60px}
.bar{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap}
h2{font-size:20px}
.btn,button{font:inherit;font-size:13.5px;color:var(--tx);background:var(--card2);border:1px solid var(--line);border-radius:10px;padding:8px 14px;cursor:pointer;transition:.15s}
.btn:hover,button:hover{border-color:var(--ac);transform:translateY(-1px)}
.pri{background:linear-gradient(90deg,var(--ac),#5b8cff);border-color:transparent;font-weight:600}
.ok{border-color:#1d6b3b;color:#7ee2a1}.bad,.danger{border-color:#6b1d1d;color:#ff8f8f}
.acts{display:flex;gap:8px;flex-wrap:wrap}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
.card{background:linear-gradient(180deg,var(--card2),var(--card));border:1px solid var(--line);border-radius:16px;padding:16px;cursor:pointer;transition:.2s}
.card:hover{border-color:#3a4580;box-shadow:0 8px 30px rgba(124,92,255,.12)}
.top{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:12px}
.nm{font-weight:700;font-size:16px}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:14px}
.stats div{background:#0d1122;border-radius:10px;padding:8px 10px;font-weight:600;font-size:14px}
.stats span{display:block;color:var(--mu);font-size:11px;font-weight:500;text-transform:uppercase;letter-spacing:.5px}
.badge{font-size:11.5px;font-weight:700;padding:3px 10px;border-radius:999px;text-transform:uppercase;letter-spacing:.4px}
.badge.running{background:#0f2f1c;color:#4ade80}.badge.offline{background:#2a2f45;color:#9aa3c4}.badge.restarting{background:#3a2a0b;color:#fbbf24}
.empty{grid-column:1/-1;text-align:center;color:var(--mu);padding:70px 10px;border:1px dashed var(--line);border-radius:16px}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin:14px 0 16px}
.tabs a{padding:9px 16px;color:var(--mu);border-bottom:2px solid transparent}
.tabs a.on{color:var(--tx);border-color:var(--ac)}
pre#log{background:#070914;border:1px solid var(--line);border-radius:12px;padding:14px;height:56vh;overflow:auto;font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word;margin-bottom:12px}
.list{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.row{display:flex;align-items:center;gap:10px;padding:9px 14px;border-bottom:1px solid var(--line);cursor:pointer}
.row:last-child{border:0}.row:hover{background:var(--card2)}
.row .nm{flex:1;font-weight:500;font-size:14px;word-break:break-all}.row .sz{color:var(--mu);font-size:12px}
.row button{padding:3px 9px;font-size:12px}
.empty2{padding:26px;text-align:center;color:var(--mu)}
textarea#ev{width:100%;height:140px;background:#0d1122;color:#d6defa;border:1px solid var(--line);border-radius:10px;padding:10px 12px;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace;resize:vertical;margin:6px 0}
.cmdrow{display:flex;gap:8px;margin-bottom:12px}.cmdrow input{margin:0;flex:1}
textarea#ta{width:100%;height:58vh;background:#070914;color:#d6defa;border:1px solid var(--line);border-radius:12px;padding:12px;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace;resize:vertical;tab-size:2}
input[type=text],input[type=password],input:not([type]){width:100%;background:#0d1122;border:1px solid var(--line);color:var(--tx);border-radius:10px;padding:10px 12px;font:inherit;margin:6px 0 14px}
input:focus,textarea:focus{outline:none;border-color:var(--ac)}
label{font-size:13px;color:var(--mu)}
.panel{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;max-width:560px}
.center{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.box{background:linear-gradient(180deg,var(--card2),var(--card));border:1px solid var(--line);border-radius:18px;padding:32px;width:100%;max-width:380px;box-shadow:0 20px 60px rgba(0,0,0,.4)}
.box .logo{font-size:26px;margin-bottom:4px}.box .pri{width:100%;padding:11px;margin-top:4px}
.err{color:#ff8f8f;font-size:13px;margin-top:10px;min-height:18px}
.modal{position:fixed;inset:0;background:rgba(5,6,12,.7);backdrop-filter:blur(4px);display:flex;align-items:center;justify-content:center;padding:18px;z-index:20}
.modal .box{max-width:460px}
.rts{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:6px 0 14px}
.rt{padding:12px 6px;text-align:center;border:1px solid var(--line);border-radius:12px;cursor:pointer;font-size:13px;background:#0d1122}
.rt.on{border-color:var(--ac);background:#1b1750}
#toast{position:fixed;bottom:22px;left:50%;transform:translateX(-50%);background:#1b2140;border:1px solid var(--ac);padding:10px 18px;border-radius:12px;z-index:50;opacity:0;pointer-events:none;transition:.25s}
#toast.show{opacity:1}
.crumbs{font-size:14px}
.mini{color:var(--mu);font-size:13px;margin-bottom:10px}
@media(max-width:600px){main{padding:16px 12px}header{padding:12px}}
</style>
</head>
<body>

<div id="login" class="center hidden">
  <form id="lf" class="box">
    <div class="logo">⚡ BotPanel</div>
    <p class="mu" style="margin-bottom:18px">Sign in to manage your bots</p>
    <label>Username</label><input id="lu" autocomplete="username">
    <label>Password</label><input id="lp" type="password" autocomplete="current-password">
    <button class="pri" type="submit">Sign in</button>
    <div class="err" id="le"></div>
  </form>
</div>

<div id="app" class="hidden">
  <header>
    <div class="logo">⚡ BotPanel</div>
    <div class="chips" id="chips"></div>
    <button id="pwb">Password</button>
    <button id="lo">Logout</button>
  </header>

  <main id="home">
    <div class="bar"><h2>Your bots</h2><button class="pri" id="nb">＋ New bot</button></div>
    <div id="bots" class="grid"></div>
  </main>

  <main id="detail" class="hidden">
    <div class="bar">
      <div class="acts" style="align-items:center"><button id="bk">← Back</button><h2 id="dn"></h2><span id="ds" class="badge"></span></div>
      <div class="acts"><button class="ok" data-d="start">▶ Start</button><button data-d="restart">⟳ Restart</button><button class="bad" data-d="stop">■ Stop</button></div>
    </div>
    <div class="tabs" id="tabs"><a data-t="console" class="on">Console</a><a data-t="files">Files</a><a data-t="settings">Settings</a></div>

    <div id="t-console">
      <div class="mini" id="dstats"></div>
      <pre id="log"></pre>
      <div class="cmdrow"><input id="xc" placeholder="Run a command in this bot's folder, e.g.  pip install requests" autocomplete="off" spellcheck="false"><button id="xr">▶ Run</button></div>
      <div class="acts"><button id="inst">📦 Install dependencies</button><button id="clr">Clear console</button></div>
    </div>

    <div id="t-files" class="hidden">
      <div id="fl-view">
        <div class="bar"><div class="crumbs" id="crumbs"></div>
          <div class="acts"><button id="nf">＋ File</button><button id="nd">＋ Folder</button><button id="up">⬆ Upload</button><input type="file" id="upi" multiple hidden></div></div>
        <div class="list" id="fl"></div>
      </div>
      <div id="ed" class="hidden">
        <div class="bar"><b id="edn"></b><div class="acts"><button class="pri" id="sv">Save (Ctrl+S)</button><button id="ec">Close</button></div></div>
        <textarea id="ta" spellcheck="false"></textarea>
      </div>
    </div>

    <div id="t-settings" class="hidden">
      <div class="panel">
        <label>Bot name</label><input id="sn">
        <label>Start command</label><input id="sc">
        <label style="display:flex;gap:8px;align-items:center;margin-bottom:16px"><input type="checkbox" id="sa" style="width:auto;margin:0"> Auto-restart if it crashes</label>
        <label>Environment variables <span class="mu">(one per line: NAME=value - good for tokens)</span></label>
        <textarea id="ev" spellcheck="false" placeholder="BOT_TOKEN=123456:abcdef"></textarea>
        <div class="mu" style="margin-bottom:16px">Restart the bot after changing these.</div>
        <div class="acts"><button class="pri" id="ss">Save settings</button><button id="sb">⬇ Backup (zip)</button><button class="danger" id="sd">Delete bot</button></div>
      </div>
    </div>
  </main>
</div>

<div id="modal" class="modal hidden">
  <div class="box" id="mbox"></div>
</div>
<div id="toast"></div>

<script>
const $=s=>document.querySelector(s);
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=b=>{if(!b)return'0 B';const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1024&&i<4){b/=1024;i++}return b.toFixed(i?1:0)+' '+u[i]};
let bots=[],cur=null,tab='console',cwd='',fileItems=[],editing=null,lastLog='',busy=false;
const RT={python:'🐍 Python',node:'🟩 Node.js',custom:'⚙️ Custom'};
const DEF={python:'python3 main.py',node:'node index.js',custom:'bash start.sh'};

function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('show');clearTimeout(toast.t);toast.t=setTimeout(()=>t.classList.remove('show'),2600)}
async function api(p,o={}){
  o.headers=Object.assign({'X-Requested-With':'botpanel'},o.headers||{});
  if(o.json!==undefined){o.method=o.method||'POST';o.headers['Content-Type']='application/json';o.body=JSON.stringify(o.json)}
  const r=await fetch('/api'+p,o);let d={};try{d=await r.json()}catch(e){}
  if(r.status===401&&p!=='/login'){showLogin();throw new Error('Signed out')}
  if(!r.ok)throw new Error(d.error||('Error '+r.status));
  return d}
const guard=fn=>async(...a)=>{try{return await fn(...a)}catch(e){if(e.message!=='Signed out')toast('⚠ '+e.message)}};

/* ---------- auth ---------- */
function showLogin(){$('#app').classList.add('hidden');$('#login').classList.remove('hidden');$('#lu').focus()}
function showApp(){$('#login').classList.add('hidden');$('#app').classList.remove('hidden');goHome();tick()}
$('#lf').onsubmit=async e=>{e.preventDefault();$('#le').textContent='';
  try{await api('/login',{json:{username:$('#lu').value.trim(),password:$('#lp').value}});$('#lp').value='';showApp()}
  catch(x){$('#le').textContent=x.message}};
$('#lo').onclick=async()=>{await api('/logout',{method:'POST'}).catch(()=>{});showLogin()};
$('#pwb').onclick=()=>{modal(`<div class="logo">Change password</div><p class="mu" style="margin-bottom:14px">Minimum 8 characters</p>
 <label>Current password</label><input id="p1" type="password"><label>New password</label><input id="p2" type="password">
 <div class="acts"><button class="pri" id="pok">Update</button><button id="pno">Cancel</button></div>`);
 $('#pno').onclick=closeModal;
 $('#pok').onclick=guard(async()=>{await api('/password',{json:{old:$('#p1').value,new:$('#p2').value}});closeModal();toast('Password updated')})};

/* ---------- modal ---------- */
function modal(h){$('#mbox').innerHTML=h;$('#modal').classList.remove('hidden')}
function closeModal(){$('#modal').classList.add('hidden')}
$('#modal').onclick=e=>{if(e.target.id==='modal')closeModal()};

$('#nb').onclick=()=>{
  let rt='python',edited=false;
  modal(`<div class="logo">Create a bot</div><p class="mu" style="margin-bottom:14px">Pick a runtime - you can change everything later.</p>
  <label>Name</label><input id="cn" placeholder="My awesome bot">
  <label>Runtime</label><div class="rts"><div class="rt on" data-r="python">🐍<br>Python</div><div class="rt" data-r="node">🟩<br>Node.js / JS</div><div class="rt" data-r="custom">⚙️<br>Custom</div></div>
  <label>Start command</label><input id="cc" value="${DEF.python}">
  <div class="acts"><button class="pri" id="cok">Create</button><button id="cno">Cancel</button></div>`);
  document.querySelectorAll('.rt').forEach(el=>el.onclick=()=>{rt=el.dataset.r;document.querySelectorAll('.rt').forEach(x=>x.classList.toggle('on',x===el));if(!edited)$('#cc').value=DEF[rt]});
  $('#cc').oninput=()=>edited=true;$('#cno').onclick=closeModal;$('#cn').focus();
  $('#cok').onclick=guard(async()=>{const d=await api('/bots',{json:{name:$('#cn').value,runtime:rt,cmd:$('#cc').value}});closeModal();toast('Bot created 🎉');await refresh();openBot(d.id)})};

/* ---------- home ---------- */
function goHome(){cur=null;$('#detail').classList.add('hidden');$('#home').classList.remove('hidden');refresh()}
function renderBots(){
  $('#bots').innerHTML=bots.length?bots.map(b=>`<div class="card" data-id="${b.id}">
   <div class="top"><div><div class="nm">${esc(b.name)}</div><div class="mu">${RT[b.runtime]||''}</div></div><span class="badge ${b.status}">${b.status}</span></div>
   <div class="stats"><div><span>CPU</span>${b.cpu}%</div><div><span>RAM</span>${fmt(b.mem)}</div><div><span>Disk</span>${fmt(b.disk)}</div></div>
   <div class="acts">${b.status==='offline'?'<button class="ok" data-a="start">▶ Start</button>':'<button data-a="restart">⟳</button><button class="bad" data-a="stop">■ Stop</button>'}<button data-a="open">Manage</button></div></div>`).join('')
   :'<div class="empty">No bots yet.<br>Click <b>＋ New bot</b> to launch your first one 🚀</div>'}
$('#bots').onclick=guard(async e=>{const c=e.target.closest('.card');if(!c)return;const a=e.target.closest('button')?.dataset.a||'open';
  if(a==='open')return openBot(c.dataset.id);
  await api(`/bots/${c.dataset.id}/${a}`,{method:'POST'});await refresh()});

/* ---------- system + list refresh ---------- */
async function refresh(){
  const [s,b]=await Promise.all([api('/system'),api('/bots')]);bots=b;
  $('#chips').innerHTML=`<span class="chip">CPU <b>${s.cpu}%</b> · ${s.cores} cores</span><span class="chip">RAM <b>${fmt(s.ram_used)}</b> / ${fmt(s.ram_total)}</span><span class="chip">Disk <b>${fmt(s.disk_used)}</b> / ${fmt(s.disk_total)}</span>`+(s.url?`<span class="chip url" data-u="${esc(s.url)}">🌐 <b>${esc(s.url.replace('https://',''))}</b> (click to copy) · <a href="${esc(s.url)}" target="_blank" rel="noopener">open</a></span>`:(s.mode==='tunnel'?'<span class="chip">🌐 tunnel not ready…</span>':''));
  if(!cur)renderBots();else updateDetail()}
function copyText(t){try{if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t);return true}}catch(e){}
  const x=document.createElement('textarea');x.value=t;x.style.cssText='position:fixed;opacity:0';document.body.appendChild(x);x.select();let ok=false;try{ok=document.execCommand('copy')}catch(e){}x.remove();return ok}
$('#chips').onclick=e=>{if(e.target.closest('a'))return;const u=e.target.closest('.url');if(u)toast(copyText(u.dataset.u)?'URL copied':'Copy failed - select it manually')};

/* ---------- detail ---------- */
function openBot(id){cur=id;$('#home').classList.add('hidden');$('#detail').classList.remove('hidden');lastLog='';$('#log').textContent='';setTab('console');updateDetail();pollLog()}
$('#bk').onclick=goHome;
function updateDetail(){const b=bots.find(x=>x.id===cur);if(!b)return goHome();
  $('#dn').textContent=b.name;const s=$('#ds');s.textContent=b.status;s.className='badge '+b.status;
  const u=b.uptime;$('#dstats').textContent=`${RT[b.runtime]} · CPU ${b.cpu}% · RAM ${fmt(b.mem)} · Disk ${fmt(b.disk)}`+(u?` · up ${u>3600?Math.floor(u/3600)+'h ':''}${Math.floor(u%3600/60)}m`:'')+` · $ ${b.cmd}`}
document.querySelectorAll('[data-d]').forEach(btn=>btn.onclick=guard(async()=>{await api(`/bots/${cur}/${btn.dataset.d}`,{method:'POST'});toast('Done');await refresh();pollLog()}));
function setTab(t){tab=t;document.querySelectorAll('#tabs a').forEach(a=>a.classList.toggle('on',a.dataset.t===t));
  ['console','files','settings'].forEach(x=>$('#t-'+x).classList.toggle('hidden',x!==t));
  if(t==='files'){closeEditor();loadFiles()}
  if(t==='settings'){const b=bots.find(x=>x.id===cur);if(b){$('#sn').value=b.name;$('#sc').value=b.cmd;$('#sa').checked=b.autorestart}loadEnv()}}
$('#tabs').onclick=e=>{const t=e.target.dataset?.t;if(t)setTab(t)};

const stripAnsi=s=>s.replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g,'');
const pollLog=guard(async()=>{if(!cur||tab!=='console')return;const d=await api(`/bots/${cur}/logs`);const t=stripAnsi(d.text);if(t===lastLog)return;lastLog=t;
  const p=$('#log'),near=p.scrollHeight-p.scrollTop-p.clientHeight<80;p.textContent=t||'Console is empty. Press ▶ Start.';if(near||!p.dataset.i){p.scrollTop=p.scrollHeight;p.dataset.i=1}});
$('#inst').onclick=guard(async()=>{await api(`/bots/${cur}/install`,{method:'POST'});toast('Installing... watch the console')});
$('#xr').onclick=guard(async()=>{const c=$('#xc').value.trim();if(!c)return;await api(`/bots/${cur}/exec`,{json:{cmd:c}});$('#xc').value='';toast('Running... watch the console');setTimeout(pollLog,700)});
$('#xc').onkeydown=e=>{if(e.key==='Enter')$('#xr').click()};
$('#clr').onclick=guard(async()=>{await api(`/bots/${cur}/logs/clear`,{method:'POST'});lastLog='';pollLog()});

/* ---------- settings ---------- */
let envLoaded=false;
const loadEnv=guard(async()=>{envLoaded=false;$('#ev').value='';const id=cur;const d=await api(`/bots/${id}/env`);if(id!==cur)return;
  $('#ev').value=Object.entries(d.env||{}).map(([k,v])=>k+'='+v).join('\n');envLoaded=true});
function parseEnv(t){const o={};t.split(/\r?\n/).forEach((raw,i)=>{let l=raw.trim();if(!l||l[0]==='#')return;if(l.startsWith('export '))l=l.slice(7).trim();
  const k=l.indexOf('=');if(k<1)throw new Error('Line '+(i+1)+': use NAME=value');const n=l.slice(0,k).trim();let v=l.slice(k+1).trim();
  if(v.length>1&&(v[0]==='"'||v[0]==="'")&&v[v.length-1]===v[0])v=v.slice(1,-1);
  if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(n))throw new Error('Line '+(i+1)+': bad name "'+n+'"');o[n]=v});return o}
$('#ss').onclick=guard(async()=>{const j={name:$('#sn').value,cmd:$('#sc').value,autorestart:$('#sa').checked};if(envLoaded)j.env=parseEnv($('#ev').value);
  await api(`/bots/${cur}`,{method:'PATCH',json:j});toast('Saved ✔');refresh()});
$('#sb').onclick=()=>{location.href=`/api/bots/${cur}/backup`};
$('#sd').onclick=guard(async()=>{if(!confirm('Delete this bot and ALL its files? This cannot be undone.'))return;await api(`/bots/${cur}`,{method:'DELETE'});toast('Bot deleted');goHome()});

/* ---------- files ---------- */
const join=n=>cwd?cwd+'/'+n:n;
const loadFiles=guard(async()=>{const d=await api(`/bots/${cur}/files?path=${encodeURIComponent(cwd)}`);cwd=d.path;fileItems=d.items;
  let acc='',c='<a data-go="">📁 root</a>';cwd.split('/').filter(Boolean).forEach(p=>{acc+=(acc?'/':'')+p;c+=` / <a data-go="${esc(acc)}">${esc(p)}</a>`});$('#crumbs').innerHTML=c;
  $('#fl').innerHTML=fileItems.length?fileItems.map((f,i)=>`<div class="row" data-i="${i}"><span>${f.dir?'📁':'📄'}</span><span class="nm">${esc(f.name)}</span><span class="sz">${f.dir?'':fmt(f.size)}</span>
   ${!f.dir&&/\.zip$/i.test(f.name)?'<button data-a="unzip">Unzip</button>':''}<button data-a="rn">✎</button>${f.dir?'':'<button data-a="dl">⬇</button>'}<button class="danger" data-a="rm">✕</button></div>`).join(''):'<div class="empty2">This folder is empty. Upload files or create one.</div>'});
$('#crumbs').onclick=e=>{const g=e.target.dataset?.go;if(g!==undefined){cwd=g;loadFiles()}};
$('#fl').onclick=guard(async e=>{const r=e.target.closest('.row');if(!r)return;const f=fileItems[+r.dataset.i],a=e.target.closest('button')?.dataset.a,p=join(f.name);
  if(a==='rm'){if(!confirm(`Delete ${f.name}?`))return;await api(`/bots/${cur}/delete`,{json:{path:p}});return loadFiles()}
  if(a==='rn'){const n=prompt('Rename to:',f.name);if(!n||n===f.name||/[\/\\]/.test(n))return;await api(`/bots/${cur}/rename`,{json:{path:p,name:n}});return loadFiles()}
  if(a==='dl'){location.href=`/api/bots/${cur}/download?path=${encodeURIComponent(p)}`;return}
  if(a==='unzip'){await api(`/bots/${cur}/extract`,{json:{path:p}});toast('Extracted ✔');return loadFiles()}
  if(f.dir){cwd=p;return loadFiles()}
  const d=await api(`/bots/${cur}/file?path=${encodeURIComponent(p)}`);editing=p;$('#edn').textContent='✏️ '+p;$('#ta').value=d.content;$('#fl-view').classList.add('hidden');$('#ed').classList.remove('hidden')});
function closeEditor(){editing=null;$('#ed').classList.add('hidden');$('#fl-view').classList.remove('hidden')}
$('#ec').onclick=closeEditor;
const saveFile=guard(async()=>{if(!editing)return;await api(`/bots/${cur}/file`,{method:'PUT',json:{path:editing,content:$('#ta').value}});toast('Saved ✔')});
$('#sv').onclick=saveFile;
$('#ta').onkeydown=e=>{if((e.ctrlKey||e.metaKey)&&e.key==='s'){e.preventDefault();saveFile()}
  if(e.key==='Tab'){e.preventDefault();const t=e.target,s=t.selectionStart;t.setRangeText('  ',s,t.selectionEnd,'end')}};
$('#nf').onclick=guard(async()=>{const n=prompt('New file name:');if(!n||/[\/\\]/.test(n))return;await api(`/bots/${cur}/file`,{method:'PUT',json:{path:join(n),content:''}});loadFiles()});
$('#nd').onclick=guard(async()=>{const n=prompt('New folder name:');if(!n||/[\/\\]/.test(n))return;await api(`/bots/${cur}/mkdir`,{json:{path:join(n)}});loadFiles()});
$('#up').onclick=()=>$('#upi').click();
$('#upi').onchange=guard(async e=>{const fs=[...e.target.files];if(!fs.length)return;const fd=new FormData();fd.append('path',cwd);fs.forEach(f=>fd.append('files',f));
  toast('Uploading '+fs.length+' file(s)...');await api(`/bots/${cur}/upload`,{method:'POST',body:fd});e.target.value='';toast('Upload complete ✔');loadFiles()});

/* ---------- loops ---------- */
async function tick(){if($('#app').classList.contains('hidden')||busy)return;busy=true;try{await refresh()}catch(e){}busy=false}
setInterval(tick,3000);setInterval(pollLog,2000);
api('/me').then(showApp).catch(showLogin);
</script>
</body>
</html>
HTMLUI
ok "Interface written"

# ---------------------------------------------------------------- python env + config
say "Setting up Python environment..."
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install -q --upgrade pip
"$APP/venv/bin/pip" install -q flask psutil waitress
ok "Dependencies installed"

BP_USER="$ADMIN" BP_PASS="$PASS" BP_MODE="$MODE" BP_DATA="$APP/data" "$APP/venv/bin/python" - <<'PYCFG'
import os, json, secrets
from werkzeug.security import generate_password_hash
data = os.environ["BP_DATA"]
cfg = {"user": os.environ["BP_USER"], "hash": generate_password_hash(os.environ["BP_PASS"]), "secret": secrets.token_hex(32), "mode": os.environ["BP_MODE"]}
open(os.path.join(data, "config.json"), "w").write(json.dumps(cfg))
PYCFG
chmod 600 "$APP/data/config.json"
chown -R "$SVC_USER:$SVC_USER" "$APP"

# ---------------------------------------------------------------- services
if [ "$MODE" = "tunnel" ]; then HOSTADDR=127.0.0.1; else HOSTADDR=0.0.0.0; fi

cat > /etc/systemd/system/botpanel.service <<EOF
[Unit]
Description=BotPanel web panel
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
WorkingDirectory=$APP
Environment=HOST=$HOSTADDR
Environment=PORT=$PORT
ExecStart=$APP/venv/bin/python $APP/app.py
Restart=always
RestartSec=3
# keep bots running when the panel itself is restarted
KillMode=process
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now botpanel >/dev/null 2>&1
sleep 2
systemctl is-active --quiet botpanel || { journalctl -u botpanel -n 20 --no-pager; die "Panel failed to start"; }
ok "Panel service running on port $PORT"

# ---------------------------------------------------------------- helper command
cat > /usr/local/bin/botpanel <<'CLIEOF'
#!/usr/bin/env bash
# BotPanel helper command
APP=/opt/botpanel
UNIT=/etc/systemd/system/botpanel.service
TUNIT=/etc/systemd/system/botpanel-tunnel.service
CRED=/root/botpanel-credentials.txt

tunnel_url() { grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$APP/data/tunnel.log" 2>/dev/null | grep -v '^https://api\.' | tail -1; }
unit_val()   { sed -n "s/^Environment=$1=//p" "$UNIT" 2>/dev/null | head -1; }
need_root()  { [ "$(id -u)" -eq 0 ] || { echo "Please run:  sudo botpanel $1"; exit 1; }; }

show_urls() {
  local t host port ip
  t="$(tunnel_url)"; host="$(unit_val HOST)"; port="$(unit_val PORT)"
  if [ -f "$TUNIT" ]; then
    if [ -n "$t" ]; then echo "Tunnel URL : $t"; else echo "Tunnel URL : not ready (try: sudo botpanel tunnel)"; fi
  fi
  if [ "$host" = "0.0.0.0" ]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    echo "Direct URL : http://$ip:$port"
  fi
}

case "${1:-help}" in
  url)
    show_urls ;;
  status)
    systemctl status botpanel --no-pager -n 5
    [ -f "$TUNIT" ] && { echo; systemctl status botpanel-tunnel --no-pager -n 5; }
    echo; show_urls ;;
  restart)
    need_root restart
    systemctl restart botpanel && echo "Panel restarted (your bots keep running)." ;;
  tunnel)
    need_root tunnel
    [ -f "$TUNIT" ] || { echo "No tunnel installed - the panel is in direct mode."; exit 1; }
    systemctl restart botpanel-tunnel
    echo "Waiting for a new public URL (up to 60s)..."
    u=""
    for _ in $(seq 1 60); do u="$(tunnel_url)"; [ -n "$u" ] && break; sleep 1; done
    if [ -n "$u" ]; then
      echo "Tunnel URL : $u"
      [ -f "$CRED" ] && sed -i "s|^URL: .*|URL:      $u|" "$CRED"
    else
      echo "Still not ready. Check:  journalctl -u botpanel-tunnel -n 30 --no-pager"
      exit 1
    fi ;;
  logs)
    journalctl -u botpanel -f ;;
  passwd)
    need_root passwd
    read -rsp "New admin password (min 8 characters): " p1; echo
    read -rsp "Repeat password: " p2; echo
    [ "${#p1}" -ge 8 ] || { echo "Too short."; exit 1; }
    [ "$p1" = "$p2" ] || { echo "Passwords do not match."; exit 1; }
    BP_PASS="$p1" BP_CFG="$APP/data/config.json" "$APP/venv/bin/python" - <<'PY' || exit 1
import os, json, secrets
from werkzeug.security import generate_password_hash
p = os.environ["BP_CFG"]
c = json.load(open(p))
c["hash"] = generate_password_hash(os.environ["BP_PASS"])
c["secret"] = secrets.token_hex(32)      # signs everybody out
open(p, "w").write(json.dumps(c))
PY
    [ -f "$CRED" ] && sed -i 's|^Password: .*|Password: (changed - not stored)|' "$CRED"
    systemctl restart botpanel && echo "Password changed. All sessions were signed out." ;;
  uninstall)
    need_root uninstall
    read -rp "This removes BotPanel AND all bot files in $APP. Type YES to continue: " a
    [ "$a" = "YES" ] || { echo "Cancelled."; exit 1; }
    systemctl disable --now botpanel botpanel-tunnel 2>/dev/null
    rm -f "$UNIT" "$TUNIT"
    systemctl daemon-reload
    pkill -u botpanel 2>/dev/null
    rm -rf "$APP" "$CRED"
    userdel botpanel 2>/dev/null
    rm -f /usr/local/bin/botpanel
    echo "BotPanel removed."
    exit 0 ;;
  *)
    cat <<'HLP'
BotPanel helper

  botpanel url          show the panel address(es)
  botpanel status       service status + address(es)
  sudo botpanel restart       restart the panel (bots keep running)
  sudo botpanel tunnel        restart the Cloudflare tunnel and show the NEW url
  sudo botpanel passwd        change the admin password
  botpanel logs         follow the panel log
  sudo botpanel uninstall     remove everything
HLP
    ;;
esac
CLIEOF
chmod 755 /usr/local/bin/botpanel

# ---------------------------------------------------------------- tunnel / direct access
URL=""          # public trycloudflare URL
DIRECT_URL=""   # http://IP:PORT

tunnel_url() {
  grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$APP/data/tunnel.log" 2>/dev/null \
    | grep -v '^https://api\.' | tail -1 || true
}

get_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "$ip"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
    ok "Firewall: opened port $PORT"
  fi
}

install_cloudflared() {
  local deb=/tmp/cloudflared.deb raw="$ARCH"
  local base=https://github.com/cloudflare/cloudflared/releases/latest/download
  if curl -fsSL --retry 3 --retry-delay 2 -o "$deb" "$base/cloudflared-linux-${ARCH}.deb" \
     && dpkg -i "$deb" >/dev/null 2>&1; then
    :
  else
    warn "Package install failed - trying the standalone binary..."
    [ "$raw" = "armhf" ] && raw=arm
    curl -fsSL --retry 3 --retry-delay 2 -o /usr/local/bin/cloudflared "$base/cloudflared-linux-${raw}" || return 1
    chmod 755 /usr/local/bin/cloudflared
  fi
  rm -f "$deb"
  command -v cloudflared >/dev/null 2>&1 && cloudflared --version >/dev/null 2>&1
}

wait_url() {   # wait_url SECONDS  -> sets URL
  local i u
  for ((i = 0; i < $1; i++)); do
    u="$(tunnel_url)"
    if [ -n "$u" ]; then URL="$u"; return 0; fi
    sleep 1
  done
  return 1
}

diagnose_tunnel() {
  local code
  echo
  warn "The tunnel did not produce a public URL. Details:"
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://api.trycloudflare.com 2>/dev/null || true)"
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    echo "   - This VPS cannot reach api.trycloudflare.com (network / DNS / firewall)."
  else
    echo "   - api.trycloudflare.com is reachable (HTTP $code), so Cloudflare may be rate-limiting this IP."
  fi
  echo "   - Tunnel service state: $(systemctl is-active botpanel-tunnel 2>/dev/null || true)"
  echo "   - Last tunnel log lines:"
  tail -n 8 "$APP/data/tunnel.log" 2>/dev/null | sed 's/^/       /' || true
  echo "   - Last service messages:"
  journalctl -u botpanel-tunnel -n 6 --no-pager 2>/dev/null | sed 's/^/       /' || true
  echo
}

TUNNEL_OK=1
if [ "$MODE" = "tunnel" ]; then
  say "Installing Cloudflare Tunnel..."
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64|arm64|armhf) ;;
    *) TUNNEL_OK=0; warn "cloudflared is not available for CPU architecture: $ARCH" ;;
  esac
  if [ "$TUNNEL_OK" = 1 ] && ! install_cloudflared; then
    TUNNEL_OK=0
    warn "Could not install cloudflared (is github.com reachable from this VPS?)"
  fi

  if [ "$TUNNEL_OK" = 1 ]; then
    CF_BIN="$(command -v cloudflared)"
    cat > /etc/systemd/system/botpanel-tunnel.service <<EOF
[Unit]
Description=BotPanel Cloudflare quick tunnel
After=botpanel.service network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
# '+' = run as root, so the log file always belongs to the service user
ExecStartPre=+/bin/sh -c ': > $APP/data/tunnel.log && chown $SVC_USER:$SVC_USER $APP/data/tunnel.log && chmod 644 $APP/data/tunnel.log'
ExecStart=$CF_BIN tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$PORT
StandardOutput=append:$APP/data/tunnel.log
StandardError=append:$APP/data/tunnel.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable botpanel-tunnel >/dev/null 2>&1
    systemctl restart botpanel-tunnel
    say "Waiting for your random public URL (up to 90 seconds)..."
    for attempt in 1 2 3; do
      if wait_url 30; then break; fi
      if [ "$attempt" -lt 3 ]; then
        warn "No URL yet (try $attempt of 3) - restarting the tunnel..."
        systemctl restart botpanel-tunnel || true
      fi
    done
    if [ -n "$URL" ]; then ok "Tunnel is up"; else diagnose_tunnel; fi
  fi
else
  # direct mode: make sure no old tunnel from a previous install keeps running
  systemctl disable --now botpanel-tunnel >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/botpanel-tunnel.service
  systemctl daemon-reload
  open_firewall
  DIRECT_URL="http://$(get_ip):$PORT"
fi

# tunnel failed -> offer the direct address so the panel is never unreachable
if [ "$MODE" = "tunnel" ] && [ -z "$URL" ]; then
  warn "You can still open the panel directly on this server's IP address (plain HTTP)."
  ask "Open the panel on http://SERVER-IP:$PORT too? [Y/n]: " Y
  case "$REPLY" in
    n|N|no|NO|No) ;;
    *)
      sed -i 's/^Environment=HOST=.*/Environment=HOST=0.0.0.0/' /etc/systemd/system/botpanel.service
      systemctl daemon-reload
      systemctl restart botpanel
      sleep 2
      systemctl is-active --quiet botpanel || { journalctl -u botpanel -n 20 --no-pager; die "Panel failed to restart"; }
      open_firewall
      DIRECT_URL="http://$(get_ip):$PORT"
      ok "Panel reachable on $DIRECT_URL"
      ;;
  esac
fi

# ---------------------------------------------------------------- done
PRIMARY="${URL:-$DIRECT_URL}"
CRED=/root/botpanel-credentials.txt
{
  echo "BotPanel"
  echo "URL:      ${PRIMARY:-pending}"
  if [ -n "$URL" ] && [ -n "$DIRECT_URL" ]; then echo "Direct:   $DIRECT_URL"; fi
  echo "Username: $ADMIN"
  echo "Password: $PASS"
} > "$CRED"
chmod 600 "$CRED"
trap - ERR

echo
echo -e "${G}${B}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}${B}║            ✅  BotPanel is installed!                ║${N}"
echo -e "${G}${B}╚══════════════════════════════════════════════════════╝${N}"
echo -e "  ${B}Open panel :${N} ${C}${PRIMARY:-not ready yet}${N}"
if [ -n "$URL" ] && [ -n "$DIRECT_URL" ]; then echo -e "  ${B}Also direct:${N} ${C}${DIRECT_URL}${N}"; fi
echo -e "  ${B}Username   :${N} $ADMIN"
if [ "$AUTOPASS" = "1" ]; then echo -e "  ${B}Password   :${N} $PASS  ${Y}(auto-generated)${N}"; else echo -e "  ${B}Password   :${N} (the one you entered)"; fi
echo -e "  ${B}Saved to   :${N} $CRED"
echo
echo -e "  Storage: bots can use all free disk space on this VPS (no quotas)."
if [ "$MODE" = "tunnel" ]; then
  echo -e "  ${Y}Note:${N} free trycloudflare URLs change if the tunnel restarts or the VPS reboots."
  echo -e "        Get the current address any time with:  ${B}botpanel url${N}"
  if [ -z "$URL" ]; then
    echo -e "  ${Y}Tunnel not ready:${N} retry with  ${B}sudo botpanel tunnel${N}  (it prints the new URL)."
  fi
fi
echo -e "  Helper:  ${B}botpanel help${N}   |   Remove:  sudo botpanel uninstall"
echo
