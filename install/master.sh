#!/usr/bin/env bash
# ==========================================================
# IP-Sentinel Panel · 主控一键安装
#
#   bash master.sh --domain panel.example.com [选项]
#
# 选项：
#   --domain <域名>        必填，面板访问域名（需已解析到本机）
#   --tls <模式>           auto | caddy | nginx | selfsigned（默认 auto）
#   --with-agent <y|n>     是否在本机同时安装 Agent（默认 y）
#   --port <端口>          面板本地监听端口（默认 8080）
#   --dry-run              只打印计划，不修改系统
#
# 环境变量：
#   REPO_SLUG              仓库路径，如 someone/ip-sentinel-panel
# ==========================================================
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-jwangb7111/ip-sentinel-panel}"
VERSION="0.1.0"
INSTALL_DIR="/opt/ip-sentinel-panel"
DOMAIN=""; TLS_MODE="auto"; WITH_AGENT="y"; PORT=8080; DRY=0
BRANCH="${BRANCH:-main}"

log()  { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ⚠️  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '2,18p' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)     DOMAIN="${2:-}"; shift 2 ;;
    --tls)        TLS_MODE="${2:-}"; shift 2 ;;
    --with-agent) WITH_AGENT="${2:-}"; shift 2 ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    usage ;;
    *) die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "需要 root"

PUBIP="$( (curl -4 -fsS -m 6 https://api.ip.sb/ip || curl -4 -fsS -m 6 https://ifconfig.me/ip) 2>/dev/null | tr -d '[:space:]')"
if [ -z "$DOMAIN" ]; then
  DEF="${PUBIP:+${PUBIP}.nip.io}"
  echo "未指定 --domain。"
  if [ -n "$DEF" ]; then
    echo "提示：没有域名可以直接用 ${DEF}（nip.io 免费泛解析，指向本机 IP）"
    read -r -p "请输入面板域名（直接回车使用 ${DEF}）: " DOMAIN || true
    DOMAIN="${DOMAIN:-$DEF}"
  else
    read -r -p "请输入面板域名: " DOMAIN || true
  fi
fi
[ -n "$DOMAIN" ] || die "没有可用域名，无法继续"

DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"

if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "输入的是裸 IP。公共 CA 不能为 IP 签证书，自动改用 ${DOMAIN}.nip.io"
  DOMAIN="${DOMAIN}.nip.io"
fi

echo
printf '\033[36m=== IP-Sentinel Panel 主控安装 v%s ===\033[0m\n' "$VERSION"
echo "域名: $DOMAIN | TLS: $TLS_MODE | 本机 Agent: $WITH_AGENT | 端口: $PORT"

# ---------- 预检 ----------
log "系统预检…"
[ -d /run/systemd/system ] || die "需要 systemd 环境"
command -v python3 >/dev/null || die "缺少 python3"
python3 - <<'PY' || die "需要 Python 3.8+"
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY
ok "系统检查通过"

HAVE_NGINX=0; HAVE_CADDY=0
systemctl is-active --quiet nginx 2>/dev/null && HAVE_NGINX=1
command -v caddy >/dev/null 2>&1 && HAVE_CADDY=1
PORT443_FREE=1; PORT80_FREE=1
ss -lnt 2>/dev/null | grep -q ':443 ' && PORT443_FREE=0
ss -lnt 2>/dev/null | grep -q ':80 '  && PORT80_FREE=0
[ "$PORT443_FREE" = "1" ] && ok "443 空闲" || warn "443 已被占用"
[ "$HAVE_NGINX" = "1" ] && ok "检测到运行中的 nginx"

# ---------- TLS 模式决策 ----------
if [ "$TLS_MODE" = "auto" ]; then
  if [ "$PORT443_FREE" = "1" ] && [ "$PORT80_FREE" = "1" ]; then
    TLS_MODE="caddy"
  elif [ "$HAVE_NGINX" = "1" ]; then
    TLS_MODE="nginx"
  elif [ "$HAVE_CADDY" = "1" ]; then
    TLS_MODE="caddy"
  else
    TLS_MODE="caddy"
  fi
fi
ok "TLS 方案: $TLS_MODE"

if [ "$DRY" = "1" ]; then
  cat <<EOF

=== DRY RUN ===
安装目录   : $INSTALL_DIR
面板端口   : $PORT
TLS 方案   : $TLS_MODE
本机 Agent : $WITH_AGENT
仓库       : $REPO_SLUG@$BRANCH
EOF
  exit 0
fi

# ---------- 依赖 ----------
log "安装基础依赖…"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 curl jq openssl ca-certificates tar >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y -q python3 curl jq openssl tar >/dev/null
else
  die "仅支持 apt / dnf 系统"
fi
ok "依赖就绪"

# ---------- 部署面板 ----------
log "拉取面板代码…"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TARBALL="https://github.com/${REPO_SLUG}/archive/refs/heads/${BRANCH}.tar.gz"
curl -fsSL --max-time 60 "$TARBALL" -o "$TMP/src.tar.gz" || die "下载失败：$TARBALL"
tar xzf "$TMP/src.tar.gz" -C "$TMP" || die "解包失败"
SRC="$(find "$TMP" -maxdepth 2 -type d -name panel | head -1)"
[ -n "$SRC" ] || die "包内未找到 panel 目录"

mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/static"
if [ -f "$INSTALL_DIR/config.json" ]; then
  cp -a "$INSTALL_DIR/config.json" "$INSTALL_DIR/config.json.bak.$(date +%s)"
fi
if [ -f "$INSTALL_DIR/data/panel.db" ]; then
  cp -a "$INSTALL_DIR/data/panel.db" "$INSTALL_DIR/data/panel.db.bak.$(date +%s)"
fi
cp -a "$SRC/." "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/src"
cp -a "$TMP"/*/install "$INSTALL_DIR/src/" 2>/dev/null || true
cp -a "$TMP"/*/version.txt "$INSTALL_DIR/src/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/app.py"
cp -f "$INSTALL_DIR/src/install/agent.sh" "$INSTALL_DIR/static/agent.sh" 2>/dev/null || true
ok "代码已部署到 $INSTALL_DIR"

# ---------- systemd ----------
log "配置服务…"
cat > /etc/systemd/system/ipsentinel-panel.service <<UNIT
[Unit]
Description=IP-Sentinel Panel
After=network.target

[Service]
WorkingDirectory=${INSTALL_DIR}
Environment=PANEL_PORT=${PORT}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable ipsentinel-panel.service >/dev/null 2>&1
systemctl restart ipsentinel-panel.service
sleep 2
systemctl is-active --quiet ipsentinel-panel.service || die "面板启动失败：journalctl -u ipsentinel-panel -n 40"
ok "面板进程已启动"

for i in 1 2 3 4 5; do
  C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
  [ "$C" = "200" ] && break
  sleep 1
done
[ "$C" = "200" ] || die "本地健康检查失败（HTTP $C）"
ok "本地健康检查 200"

# ---------- TLS ----------
setup_nginx_site() {
  local cert="$1" key="$2"
  local conf="/etc/nginx/sites-available/ipsentinel-${DOMAIN}.conf"
  cat > "$conf" <<NGINX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 4m;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
NGINX
  ln -sf "$conf" "/etc/nginx/sites-enabled/ipsentinel-${DOMAIN}.conf"
  nginx -t || die "nginx 配置校验失败，已保留配置文件：$conf"
  systemctl reload nginx
}

case "$TLS_MODE" in
  caddy)
    if ! command -v caddy >/dev/null 2>&1; then
      log "安装 Caddy…"
      if command -v apt-get >/dev/null; then
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1 || true
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
          | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
          > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
        apt-get update -qq && apt-get install -y -qq caddy >/dev/null || die "Caddy 安装失败，请改用 --tls nginx 或手动配置"
      else
        die "非 apt 系统请手动安装 Caddy，或改用 --tls nginx"
      fi
    fi
    CADDYFILE="/etc/caddy/Caddyfile"
    touch "$CADDYFILE"
    if ! grep -q "^\s*${DOMAIN}\s*{" "$CADDYFILE" 2>/dev/null; then
      cat >> "$CADDYFILE" <<CADDY

${DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT}
    encode gzip
}
CADDY
    fi
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 || die "Caddyfile 校验失败：$CADDYFILE"
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
    ok "Caddy 已接管 $DOMAIN"
    ;;
  nginx)
    [ "$HAVE_NGINX" = "1" ] || die "未检测到运行中的 nginx，请改用 --tls caddy"
    CERT=""; KEY=""
    for pair in "/root/cert/ssl.pem:/root/cert/ssl.key" \
                "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem:/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
                "/etc/ssl/ipsentinel/fullchain.pem:/etc/ssl/ipsentinel/privkey.pem"; do
      c="${pair%%:*}"; k="${pair##*:}"
      if [ -f "$c" ] && [ -f "$k" ]; then CERT="$c"; KEY="$k"; break; fi
    done
    if [ -z "$CERT" ]; then
      warn "没找到可用证书，生成自签证书（浏览器会提示不安全）"
      mkdir -p /etc/ssl/ipsentinel
      openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/ipsentinel/privkey.pem -out /etc/ssl/ipsentinel/fullchain.pem \
        -subj "/CN=${DOMAIN}" >/dev/null 2>&1
      CERT="/etc/ssl/ipsentinel/fullchain.pem"; KEY="/etc/ssl/ipsentinel/privkey.pem"
    fi
    setup_nginx_site "$CERT" "$KEY"
    ok "nginx 已挂载 $DOMAIN（证书: $CERT）"
    ;;
  selfsigned)
    die "selfsigned 模式需要已有 nginx，请改用 --tls nginx"
    ;;
  none)
    warn "跳过 TLS，仅本地 http://127.0.0.1:${PORT}"
    ;;
  *)
    die "未知的 --tls 值: $TLS_MODE"
    ;;
esac

# ---------- 本机 Agent ----------
if [ "$WITH_AGENT" = "y" ]; then
  log "安装本机 Agent…"
  AGENT_SH="$INSTALL_DIR/src/install/agent.sh"
  if [ -f "$AGENT_SH" ]; then
    bash "$AGENT_SH" --master "$DOMAIN" --node-id master 2>&1 | sed 's/^/    /' || warn "Agent 安装失败，可稍后手动执行"
    sqlite3 "$INSTALL_DIR/data/panel.db" "UPDATE nodes SET status='active' WHERE status='pending';" 2>/dev/null || true
  else
    warn "未找到 agent.sh，跳过"
  fi
else
  warn "按要求跳过本机 Agent"
fi

# ---------- 收尾 ----------
PW=""
[ -f /root/.ips_panel_pw ] && PW="$(cat /root/.ips_panel_pw)"

echo
echo "============================================================"
echo "✅ 主控部署完成"
echo "============================================================"
echo "  面板地址 : https://${DOMAIN}"
echo "  本地监听 : 127.0.0.1:${PORT}"
if [ -n "$PW" ]; then
  echo "  初始口令 : $PW"
  echo "  （同时保存在 /root/.ips_panel_pw，登录后请到「设置」修改）"
else
  echo "  口令     : 已存在旧配置，沿用原口令"
fi
echo
echo "  常用命令："
echo "    systemctl status ipsentinel-panel"
echo "    journalctl -u ipsentinel-panel -f"
echo
echo "  添加节点：在节点上执行"
echo "    bash <(curl -fsSL https://${DOMAIN}/agent.sh) --master ${DOMAIN}"
echo "============================================================"
