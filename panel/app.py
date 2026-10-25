#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IP-Sentinel 面板（P1 骨架）
纯 Python 标准库：http.server + sqlite3 + hmac
监听 127.0.0.1:8080，由 nginx/Caddy 反代到公网
"""
import base64
import concurrent.futures as futures
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import sqlite3
import ssl
import subprocess
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE, "data", "panel.db")
STATIC_DIR = os.path.join(BASE, "static")
CONF_PATH = os.path.join(BASE, "config.json")
AGENT_CONF = "/opt/ip_sentinel/config.conf"
LOCAL_LOG = "/opt/ip_sentinel/logs/sentinel.log"
PW_FILE = "/root/.ips_panel_pw"

SESSIONS = {}
ATTEMPTS = {}
LOCK = threading.Lock()
SEM = threading.Semaphore(8)
SESSION_TTL = 7 * 24 * 3600


# ---------------------------------------------------------------- 数据库
def connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with connect() as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS nodes (
              id TEXT PRIMARY KEY, ip TEXT, port INTEGER, psk TEXT,
              region TEXT, alias TEXT, is_local INTEGER DEFAULT 0,
              enable_google INTEGER DEFAULT 1, enable_trust INTEGER DEFAULT 1,
              last_seen TEXT, last_status TEXT, created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS commands (
              id INTEGER PRIMARY KEY AUTOINCREMENT, node_id TEXT, action TEXT,
              status TEXT, http_code INTEGER, output TEXT,
              created_at TEXT, finished_at TEXT
            );
            CREATE TABLE IF NOT EXISTS reports (
              id INTEGER PRIMARY KEY AUTOINCREMENT, node_id TEXT, kind TEXT,
              raw TEXT, created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS trend (
              id INTEGER PRIMARY KEY AUTOINCREMENT, node_id TEXT, score INTEGER,
              google TEXT, netflix TEXT, gpt TEXT, created_at TEXT
            );
            """
        )
        try:
            c.execute("ALTER TABLE commands ADD COLUMN batch_id TEXT")
        except sqlite3.OperationalError:
            pass
        for stmt in (
            "ALTER TABLE nodes ADD COLUMN status TEXT DEFAULT 'active'",
            "ALTER TABLE nodes ADD COLUMN reachable INTEGER",
            "ALTER TABLE nodes ADD COLUMN agent_version TEXT",
        ):
            try:
                c.execute(stmt)
            except sqlite3.OperationalError:
                pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


# ---------------------------------------------------------------- 本地 Agent 配置
def read_agent_conf():
    conf = {}
    try:
        with open(AGENT_CONF, "r") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return conf


def seed_local_node():
    conf = read_agent_conf()
    if not conf.get("CHAT_ID"):
        return
    host = os.uname().nodename
    nid = host.lower()
    with connect() as c:
        row = c.execute("SELECT id FROM nodes WHERE is_local=1").fetchone()
        if row:
            c.execute(
                "UPDATE nodes SET psk=?, region=?, port=? WHERE id=?",
                (conf["CHAT_ID"], conf.get("REGION_NAME", ""), int(conf.get("AGENT_PORT", 9527)), row["id"]),
            )
        else:
            c.execute(
                "INSERT INTO nodes (id, ip, port, psk, region, alias, is_local, created_at) "
                "VALUES (?,?,?,?,?,?,1,?)",
                (nid, "127.0.0.1", int(conf.get("AGENT_PORT", 9527)), conf["CHAT_ID"],
                 conf.get("REGION_NAME", ""), "本机主控 · " + conf.get("REGION_NAME", ""), now()),
            )


# ---------------------------------------------------------------- 口令与会话
def load_conf():
    if os.path.exists(CONF_PATH):
        with open(CONF_PATH) as f:
            return json.load(f)
    pw = "".join(secrets.choice("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789") for _ in range(16))
    salt = secrets.token_hex(16)
    conf = {"salt": salt, "pw_hash": hash_pw(pw, salt), "created": now()}
    with open(CONF_PATH, "w") as f:
        json.dump(conf, f)
    os.chmod(CONF_PATH, 0o600)
    with open(PW_FILE, "w") as f:
        f.write(pw + "\n")
    os.chmod(PW_FILE, 0o600)
    print(f"[init] 初始口令已生成，见 {PW_FILE}", flush=True)
    return conf


def hash_pw(pw, salt):
    return hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 120000).hex()


def check_pw(pw):
    conf = load_conf()
    return hmac.compare_digest(hash_pw(pw, conf["salt"]), conf["pw_hash"])


def save_password(pw):
    conf = load_conf()
    salt = secrets.token_hex(16)
    conf["salt"] = salt
    conf["pw_hash"] = hash_pw(pw, salt)
    conf["updated"] = now()
    with open(CONF_PATH, "w") as f:
        json.dump(conf, f)
    os.chmod(CONF_PATH, 0o600)
    try:
        os.remove(PW_FILE)
    except OSError:
        pass


def new_session():
    sid = secrets.token_urlsafe(32)
    with LOCK:
        SESSIONS[sid] = time.time() + SESSION_TTL
    return sid


def valid_session(sid):
    if not sid:
        return False
    with LOCK:
        exp = SESSIONS.get(sid)
        if not exp:
            return False
        if exp < time.time():
            SESSIONS.pop(sid, None)
            return False
    return True


# ---------------------------------------------------------------- 与 Agent 通讯
def signed_url(node, path, extra=""):
    ts = str(int(time.time()))
    payload = path + (("?" + extra) if extra else "") + ":" + ts
    sig = hmac.new(node["psk"].encode(), payload.encode(), hashlib.sha256).hexdigest()
    url = "https://%s:%d%s?t=%s&sign=%s" % (node["ip"], node["port"], path, ts, sig)
    if extra:
        url += "&" + extra
    return url


def call_agent(node, path, extra="", timeout=30):
    url = signed_url(node, path, extra)
    try:
        r = subprocess.run(
            ["curl", "-sk", "--max-time", str(timeout), url],
            capture_output=True, text=True, timeout=timeout + 5,
        )
        return r.returncode, (r.stdout or "").strip()[:4000]
    except Exception as e:  # noqa: BLE001
        return -1, str(e)[:500]


def run_command(cmd_id, node, action):
    paths = {
        "run": "/trigger_run", "google": "/trigger_google",
        "trust": "/trigger_trust", "report": "/trigger_report",
        "log": "/trigger_log", "quality": "/trigger_quality",
        "ota": "/trigger_ota",
    }
    path = paths.get(action)
    if not path:
        return
    with SEM:
        c = connect()
        c.execute("UPDATE commands SET status='running' WHERE id=?", (cmd_id,))
        c.commit()
        code, out = call_agent(node, path)
        c.execute(
            "UPDATE commands SET status=?, http_code=?, output=?, finished_at=? WHERE id=?",
            ("done" if code == 0 else "failed", code, out, now(), cmd_id),
        )
        c.execute("UPDATE nodes SET last_seen=?, last_status=? WHERE id=?",
                  (now(), "ok" if code == 0 else "fail", node["id"]))
        c.commit()
        c.close()


# ---------------------------------------------------------------- 存活探测
def probe_reachable(ip, port):
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((ip, int(port)), timeout=3) as sock:
            with ctx.wrap_socket(sock, server_hostname="ip-sentinel") as tls:
                tls.settimeout(3)
        return True
    except Exception:  # noqa: BLE001
        return False


def probe_node(node):
    ok = False
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((node["ip"], int(node["port"])), timeout=3) as sock:
            with ctx.wrap_socket(sock, server_hostname="ip-sentinel") as tls:
                tls.settimeout(3)
        ok = True
    except Exception:  # noqa: BLE001
        ok = False
    try:
        with connect() as c:
            if ok:
                c.execute("UPDATE nodes SET last_seen=?, last_status='ok', reachable=1 WHERE id=?", (now(), node["id"]))
            else:
                c.execute("UPDATE nodes SET last_status='fail', reachable=0 WHERE id=?", (node["id"],))
    except Exception:  # noqa: BLE001
        pass


def probe_loop():
    while True:
        try:
            with connect() as c:
                nodes = [dict(r) for r in c.execute("SELECT id, ip, port FROM nodes")]
            for n in nodes:
                t = threading.Thread(target=probe_node, args=(n,), daemon=True)
                t.start()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(90)


def run_batch(cmds, action):
    with futures.ThreadPoolExecutor(max_workers=8) as ex:
        for node, cid in cmds:
            ex.submit(run_command, cid, node, action)


# ---------------------------------------------------------------- 上报解析
SCORE_RE = re.compile(r"(?i)scamalytics[^\d]{0,40}(\d{1,3})")
STATUS_RE = re.compile(r"(?i)(google|netflix|gpt|chatgpt)[^:\n]{0,20}[:：]\s*([^\n|]{1,24})")


def ingest_report(node_id, raw):
    score = None
    m = SCORE_RE.search(raw)
    if m:
        v = int(m.group(1))
        if 0 <= v <= 100:
            score = v
    statuses = {}
    for k, v in STATUS_RE.findall(raw):
        statuses[k.lower()] = v.strip()[:20]
    with connect() as c:
        c.execute("INSERT INTO reports (node_id, kind, raw, created_at) VALUES (?,?,?,?)",
                  (node_id, "agent", raw[:8000], now()))
        if score is not None or statuses:
            c.execute(
                "INSERT INTO trend (node_id, score, google, netflix, gpt, created_at) VALUES (?,?,?,?,?,?)",
                (node_id, score, statuses.get("google"), statuses.get("netflix"),
                 statuses.get("gpt") or statuses.get("chatgpt"), now()),
            )


# ---------------------------------------------------------------- HTTP
CTYPES = {
    ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml",
    ".png": "image/png", ".ico": "image/x-icon", ".json": "application/json",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "IPSPanel/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # -- helpers
    def _send(self, code, body=b"", ctype="application/json; charset=utf-8", headers=None, head=False):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body and not head:
            self.wfile.write(body)

    def _json(self, obj, code=200, headers=None):
        self._send(code, json.dumps(obj, ensure_ascii=False), headers=headers)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
        ctype = (self.headers.get("Content-Type") or "").lower()
        try:
            if "application/json" in ctype:
                return json.loads(raw.decode("utf-8", "replace"))
            return {k: v[0] for k, v in urllib.parse.parse_qs(raw.decode("utf-8", "replace")).items()}
        except Exception:  # noqa: BLE001
            return {}

    def _cookie(self):
        raw = self.headers.get("Cookie") or ""
        for part in raw.split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                if k.strip() == "ips_session":
                    return v.strip()
        return None

    def _authed(self):
        return valid_session(self._cookie())

    def _host(self):
        return (self.headers.get("Host") or "").split(":")[0]

    def _cookie_header(self, sid=None):
        secure = "" if self._host() in ("127.0.0.1", "localhost") else "; Secure"
        if sid is None:
            return "ips_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" + secure
        return "ips_session=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Strict%s" % (sid, SESSION_TTL, secure)

    # -- routes
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/"):
            return self.api_get(path)
        return self.static(path)

    def do_HEAD(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/"):
            return self._send(405, b"", head=True)
        return self.static(path, head=True)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/agent/tgshim/"):
            return self.tgshim()
        if path == "/api/agent/register":
            return self.register_agent()
        return self.api_post(path)

    def do_PATCH(self):
        self.api_post(urllib.parse.urlparse(self.path).path, method="PATCH")

    def do_DELETE(self):
        self.api_post(urllib.parse.urlparse(self.path).path, method="DELETE")

    # -- static
    def static(self, path, head=False):
        if path in ("/", ""):
            path = "/index.html"
        safe = os.path.normpath(path).lstrip("/")
        full = os.path.join(STATIC_DIR, safe)
        if not os.path.abspath(full).startswith(STATIC_DIR) or not os.path.isfile(full):
            full = os.path.join(STATIC_DIR, "index.html")
        ext = os.path.splitext(full)[1].lower()
        # 版本更新后立即生效：HTML 不缓存，资源每次回源校验
        cache = "no-store" if ext == ".html" else "no-cache, must-revalidate"
        with open(full, "rb") as f:
            data = f.read()
        self._send(200, data, CTYPES.get(ext, "application/octet-stream"),
                   headers={"Cache-Control": cache}, head=head)

    # -- api GET
    def api_get(self, path):
        if path == "/api/me":
            return self._json({"ok": True} if self._authed() else {"ok": False}, 200 if self._authed() else 401)
        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)

        if path == "/api/nodes":
            with connect() as c:
                rows = [dict(r) for r in c.execute(
                    "SELECT id, ip, port, region, alias, is_local, enable_google, enable_trust, "
                    "last_seen, last_status, created_at, status, reachable, agent_version "
                    "FROM nodes ORDER BY is_local DESC, created_at")]
            return self._json({"nodes": rows})

        if path == "/api/stats":
            with connect() as c:
                total = c.execute("SELECT COUNT(*) n FROM nodes").fetchone()["n"]
                cmds = c.execute("SELECT COUNT(*) n FROM commands WHERE created_at >= date('now','-1 day')").fetchone()["n"]
                reps = c.execute("SELECT COUNT(*) n FROM reports WHERE created_at >= date('now','-1 day')").fetchone()["n"]
            return self._json({"nodes": total, "commands_24h": cmds, "reports_24h": reps})

        if path == "/api/commands":
            with connect() as c:
                rows = [dict(r) for r in c.execute(
                    "SELECT * FROM commands ORDER BY id DESC LIMIT 60")]
            return self._json({"commands": rows})

        m = re.match(r"^/api/nodes/([^/]+)/log$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            with connect() as c:
                node = c.execute("SELECT * FROM nodes WHERE id=?", (nid,)).fetchone()
            if not node:
                return self._json({"error": "not found"}, 404)
            node = dict(node)
            if node["is_local"]:
                text = ""
                if os.path.exists(LOCAL_LOG):
                    text = subprocess.run(["tail", "-n", "200", LOCAL_LOG],
                                          capture_output=True, text=True).stdout
                return self._json({"log": text or "（暂无日志，等待下一轮养护）"})
            code, out = call_agent(node, "/trigger_log")
            return self._json({"log": "已下发日志回传指令（code=%s）\n%s" % (code, out)})

        m = re.match(r"^/api/nodes/([^/]+)/trend$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            with connect() as c:
                rows = [dict(r) for r in c.execute(
                    "SELECT * FROM trend WHERE node_id=? ORDER BY id DESC LIMIT 40", (nid,))]
            rows.reverse()
            return self._json({"trend": rows})

        m = re.match(r"^/api/nodes/([^/]+)/reports$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            with connect() as c:
                rows = [dict(r) for r in c.execute(
                    "SELECT * FROM reports WHERE node_id=? ORDER BY id DESC LIMIT 20", (nid,))]
            return self._json({"reports": rows})

        return self._json({"error": "not found"}, 404)

    # -- api POST / PATCH / DELETE
    def api_post(self, path, method="POST"):
        if path == "/api/login":
            ip = self.client_address[0]
            with LOCK:
                hits = [t for t in ATTEMPTS.get(ip, []) if t > time.time() - 300]
                if len(hits) >= 5:
                    return self._json({"error": "尝试过多，请 5 分钟后再试"}, 429)
                ATTEMPTS[ip] = hits + [time.time()]
            body = self._body()
            if not check_pw(str(body.get("password", ""))):
                return self._json({"error": "口令错误"}, 401)
            sid = new_session()
            return self._json({"ok": True}, headers={"Set-Cookie": self._cookie_header(sid)})

        if path == "/api/logout":
            sid = self._cookie()
            if sid:
                with LOCK:
                    SESSIONS.pop(sid, None)
            return self._json({"ok": True}, headers={"Set-Cookie": self._cookie_header(None)})

        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)

        if path == "/api/password":
            b = self._body()
            old = str(b.get("old") or "")
            new = str(b.get("new") or "")
            if not check_pw(old):
                return self._json({"error": "原口令不正确"}, 401)
            if len(new) < 10:
                return self._json({"error": "新口令至少 10 位"}, 400)
            if new == old:
                return self._json({"error": "新口令不能与原口令相同"}, 400)
            save_password(new)
            cur = self._cookie()
            with LOCK:
                for k in list(SESSIONS):
                    if k != cur:
                        SESSIONS.pop(k, None)
            return self._json({"ok": True})

        if path == "/api/nodes" and method == "POST":
            b = self._body()
            nid = (b.get("id") or "").strip()
            ip = (b.get("ip") or "").strip()
            psk = (b.get("psk") or "").strip()
            if not nid or not ip or not psk:
                return self._json({"error": "id / ip / psk 必填"}, 400)
            with connect() as c:
                c.execute(
                    "INSERT OR REPLACE INTO nodes (id, ip, port, psk, region, alias, is_local, created_at) "
                    "VALUES (?,?,?,?,?,?,0,?)",
                    (nid, ip, int(b.get("port") or 9527), psk, b.get("region", ""),
                     b.get("alias") or nid, now()),
                )
            return self._json({"ok": True})

        m = re.match(r"^/api/nodes/([^/]+)$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            with connect() as c:
                if method == "DELETE":
                    c.execute("DELETE FROM nodes WHERE id=?", (nid,))
                    return self._json({"ok": True})
                b = self._body()
                sets, vals = [], []
                for k in ("alias", "region", "enable_google", "enable_trust"):
                    if k in b:
                        sets.append("%s=?" % k)
                        vals.append(int(b[k]) if k.startswith("enable") else b[k])
                if sets:
                    vals.append(nid)
                    c.execute("UPDATE nodes SET %s WHERE id=?" % ", ".join(sets), vals)
            return self._json({"ok": True})

        if path == "/api/batch" and method == "POST":
            b = self._body()
            action = str(b.get("action") or "")
            if action not in ("run", "google", "trust", "quality", "report", "log", "ota"):
                return self._json({"error": "unknown action"}, 400)
            with connect() as c:
                rows = [dict(r) for r in c.execute("SELECT * FROM nodes")]
            ids = b.get("ids")
            if ids:
                keep = set(ids)
                rows = [r for r in rows if r["id"] in keep]
            if not rows:
                return self._json({"error": "没有可执行的节点"}, 400)
            batch_id = secrets.token_hex(6)
            cmds = []
            with connect() as c:
                for n in rows:
                    cur = c.execute(
                        "INSERT INTO commands (node_id, action, status, created_at, batch_id) "
                        "VALUES (?,?,?,?,?)", (n["id"], action, "queued", now(), batch_id))
                    cmds.append((n, cur.lastrowid))
            threading.Thread(target=run_batch, args=(cmds, action), daemon=True).start()
            return self._json({"ok": True, "batch_id": batch_id, "total": len(cmds)})

        m = re.match(r"^/api/batch/([^/]+)$", path)
        if m and method == "GET":
            bid = m.group(1)
            with connect() as c:
                rows = [dict(r) for r in c.execute(
                    "SELECT node_id, action, status, http_code, output FROM commands "
                    "WHERE batch_id=? ORDER BY id", (bid,))]
            count = {}
            for r in rows:
                count[r["status"]] = count.get(r["status"], 0) + 1
            return self._json({"total": len(rows), "counts": count, "items": rows})

        m = re.match(r"^/api/nodes/([^/]+)/action$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            action = str((self._body() or {}).get("action") or "")
            if action not in ("run", "google", "trust", "report", "log", "quality", "ota"):
                return self._json({"error": "unknown action"}, 400)
            with connect() as c:
                node = c.execute("SELECT * FROM nodes WHERE id=?", (nid,)).fetchone()
                if not node:
                    return self._json({"error": "not found"}, 404)
                cur = c.execute("INSERT INTO commands (node_id, action, status, created_at) VALUES (?,?,?,?)",
                                (nid, action, "queued", now()))
                cmd_id = cur.lastrowid
            threading.Thread(target=run_command, args=(cmd_id, dict(node), action), daemon=True).start()
            return self._json({"ok": True, "command_id": cmd_id})

        m = re.match(r"^/api/nodes/([^/]+)/(approve|reject)$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            act = m.group(2)
            with connect() as c:
                if act == "approve":
                    c.execute("UPDATE nodes SET status='active' WHERE id=?", (nid,))
                else:
                    c.execute("DELETE FROM nodes WHERE id=?", (nid,))
            return self._json({"ok": True})

        m = re.match(r"^/api/nodes/([^/]+)/toggle$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            b = self._body()
            mod = str(b.get("mod") or "")
            state = bool(b.get("state"))
            if mod not in ("google", "trust"):
                return self._json({"error": "unknown module"}, 400)
            with connect() as c:
                row = c.execute("SELECT * FROM nodes WHERE id=?", (nid,)).fetchone()
            if not row:
                return self._json({"error": "not found"}, 404)
            code, out = call_agent(dict(row), "/trigger_toggle",
                                   "mod=%s&state=%s" % (mod, "true" if state else "false"))
            if not (code == 0 and "Action Accepted" in out):
                return self._json({"error": "Agent 拒绝：%s" % (out or code)}, 502)
            with connect() as c:
                c.execute("UPDATE nodes SET enable_%s=? WHERE id=?" % mod, (1 if state else 0, nid))
            return self._json({"ok": True})

        m = re.match(r"^/api/nodes/([^/]+)/rename$", path)
        if m:
            nid = urllib.parse.unquote(m.group(1))
            alias = str((self._body() or {}).get("alias") or "").strip()
            if not alias or len(alias) > 20:
                return self._json({"error": "别名需 1~20 个字符"}, 400)
            with connect() as c:
                row = c.execute("SELECT * FROM nodes WHERE id=?", (nid,)).fetchone()
            if not row:
                return self._json({"error": "not found"}, 404)
            b64 = base64.urlsafe_b64encode(alias.encode()).decode().rstrip("=")
            code, out = call_agent(dict(row), "/trigger_rename", "b64=" + b64)
            with connect() as c:
                c.execute("UPDATE nodes SET alias=? WHERE id=?", (alias, nid))
            return self._json({"ok": True, "agent": out[:160]})

        return self._json({"error": "not found"}, 404)

    # -- Agent 主动注册（公开接口，需审批）
    def register_agent(self):
        ip = self.client_address[0]
        with LOCK:
            key = "reg:" + ip
            hits = [t for t in ATTEMPTS.get(key, []) if t > time.time() - 3600]
            if len(hits) >= 10:
                return self._json({"error": "注册过于频繁，请稍后再试"}, 429)
            ATTEMPTS[key] = hits + [time.time()]

        b = self._body()
        nid = re.sub(r"[^a-zA-Z0-9_-]", "", str(b.get("node_id") or ""))[:32]
        node_ip = str(b.get("ip") or "").strip()[:64]
        psk = str(b.get("psk") or "").strip()
        region = str(b.get("region") or "")[:80]
        ver = str(b.get("version") or "")[:16]
        try:
            port = int(b.get("port") or 9527)
        except (TypeError, ValueError):
            port = 9527
        if not nid or not node_ip or len(psk) < 16:
            return self._json({"error": "node_id / ip / psk 不完整"}, 400)

        reachable = probe_reachable(node_ip, port)
        with connect() as c:
            exist = c.execute("SELECT status FROM nodes WHERE id=?", (nid,)).fetchone()
            if exist:
                if exist["status"] == "active":
                    return self._json({
                        "error": "节点已存在且已激活。重装请先在面板删除该节点，或使用注册码模式"
                    }, 409)
                c.execute(
                    "UPDATE nodes SET ip=?, port=?, psk=?, region=?, reachable=?, agent_version=?, "
                    "last_seen=?, last_status=? WHERE id=?",
                    (node_ip, port, psk, region, 1 if reachable else 0, ver,
                     now() if reachable else None, "ok" if reachable else "fail", nid),
                )
                return self._json({"ok": True, "status": "pending", "note": "已更新待审批信息"})
            c.execute(
                "INSERT INTO nodes (id, ip, port, psk, region, alias, is_local, enable_google, "
                "enable_trust, last_seen, last_status, created_at, status, reachable, agent_version) "
                "VALUES (?,?,?,?,?,?,0,1,1,?,?,?,'pending',?,?)",
                (nid, node_ip, port, psk, region, nid,
                 now() if reachable else None, "ok" if reachable else "fail", now(),
                 1 if reachable else 0, ver),
            )
        return self._json({"ok": True, "status": "pending"})

    # -- Telegram 垫片
    def tgshim(self):
        body = self._body()
        text = body.get("text") or body.get("message") or ""
        chat_id = str(body.get("chat_id") or "")
        node_id = None
        with connect() as c:
            row = c.execute("SELECT id FROM nodes WHERE psk=?", (chat_id,)).fetchone()
            if row:
                node_id = row["id"]
            else:
                row = c.execute("SELECT id FROM nodes ORDER BY is_local DESC LIMIT 1").fetchone()
                node_id = row["id"] if row else "unknown"
        if text:
            ingest_report(node_id, text)
        return self._json({"ok": True, "result": {"message_id": int(time.time())}})


def main():
    init_db()
    seed_local_node()
    load_conf()
    threading.Thread(target=probe_loop, daemon=True).start()
    port = int(os.environ.get("PANEL_PORT", "8080"))
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    print(f"[panel] listening on 127.0.0.1:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
