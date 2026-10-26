#!/usr/bin/env bash
# ==========================================================
# IP-Sentinel Agent 一键安装（非交互）
#
#   bash install-agent.sh --master <面板域名> [选项]
#
# 选项：
#   --master <域名>      必填，面板地址，如 panel.example.com
#   --region <CC/SS/CITY> 可选，覆盖自动识别，如 US/VA/Ashburn
#   --node-id <id>       可选，默认 <hostname>-<国家码>
#   --port <端口>        可选，默认 9527
#   --enroll <注册码>     可选，面板开启注册码模式时必填
#   --dry-run            只打印识别结果，不安装
#   --version <x.y.z>    可选，上游版本，默认 4.3.5
# ==========================================================
set -euo pipefail

MASTER=""; REGION_OVERRIDE=""; NODE_ID=""; AGENT_PORT=9527; ENROLL=""
VERSION="4.3.5"; DRY=0
REPO="https://raw.githubusercontent.com/hotyue/IP-Sentinel"
INSTALL_DIR="/opt/ip_sentinel"

log()  { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ⚠️  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --master)   [ $# -ge 2 ] || die "--master 后面需要跟主控域名"; MASTER="$2"; shift 2 ;;
    --region)   [ $# -ge 2 ] || die "--region 后面需要跟 CC/SS/CITY"; REGION_OVERRIDE="$2"; shift 2 ;;
    --node-id)  [ $# -ge 2 ] || die "--node-id 后面需要跟节点 ID"; NODE_ID="$2"; shift 2 ;;
    --port)     [ $# -ge 2 ] || die "--port 后面需要跟端口号"; AGENT_PORT="$2"; shift 2 ;;
    --enroll)   [ $# -ge 2 ] || die "--enroll 后面需要跟注册码"; ENROLL="$2"; shift 2 ;;
    --version)  [ $# -ge 2 ] || die "--version 后面需要跟版本号"; VERSION="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# 优先使用内置主控地址（面板分发版才有），交互时允许改
if [ -z "${MASTER:-}" ] && [ -n "${DEFAULT_MASTER:-}" ]; then
  if [ -t 0 ]; then
    read -r -p "本脚本已内置主控地址，直接回车使用，或输入其它主控域名: " _ans || true
    MASTER="${_ans:-$DEFAULT_MASTER}"
  else
    MASTER="$DEFAULT_MASTER"
  fi
fi
if [ -z "${MASTER:-}" ] && [ -t 0 ]; then
  read -r -p "请输入主控域名（例如 panel.example.com）: " MASTER || true
fi
[ -n "${MASTER:-}" ] || die "缺少主控域名：请用 --master <域名>，或在交互终端下按提示输入"
[ "$(id -u)" = "0" ] || die "需要 root"

MASTER="${MASTER#http://}"; MASTER="${MASTER#https://}"; MASTER="${MASTER%%/*}"
PANEL="https://${MASTER}"

# 先验证域名可解析，避免后面 curl 报含糊的 could not resolve host
if ! getent hosts "$MASTER" >/dev/null 2>&1; then
  die "无法解析域名 $MASTER。请检查节点 DNS/拼写，或改用主控公网 IP"
fi
printf '\033[36m\n=== IP-Sentinel Agent 安装器 ===\033[0m\n'
echo "面板: $PANEL"

# ---------- 依赖 ----------
if ! command -v curl >/dev/null || ! command -v jq >/dev/null || ! command -v openssl >/dev/null; then
  log "安装基础依赖…"
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl jq openssl ca-certificates >/dev/null
  elif command -v dnf >/dev/null; then
    dnf install -y -q curl jq openssl >/dev/null
  elif command -v apk >/dev/null; then
    apk add --no-cache curl jq openssl >/dev/null
  else
    die "无法识别包管理器，请手动安装 curl / jq / openssl"
  fi
fi

# ---------- 公网 IP ----------
log "探测公网出口…"
PUBLIC_IP="$( (curl -4 -fsS -m 6 https://api.ip.sb/ip || curl -4 -fsS -m 6 https://ifconfig.me/ip) 2>/dev/null | tr -d '[:space:]')"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法探测公网 IPv4，请检查网络"
ok "出口 IP: $PUBLIC_IP"

# ---------- 区域识别 ----------
log "拉取战区拓扑…"
MAP="$(mktemp)"
curl -fsSL -m 20 "${REPO}/main/data/map.json" -o "$MAP" || die "拉取 map.json 失败（检查到 GitHub 的连通性）"

if [ -n "$REGION_OVERRIDE" ]; then
  CC="${REGION_OVERRIDE%%/*}"; REST="${REGION_OVERRIDE#*/}"
  SS="${REST%%/*}"; CITY="${REST#*/}"
  log "使用指定区域: $CC / $SS / $CITY"
else
  log "根据 IP 自动识别位置…"
  GEO="$(curl -fsS -m 8 "https://ipinfo.io/${PUBLIC_IP}/json" 2>/dev/null || echo '{}')"
  CC="$(jq -r '.country // empty' <<<"$GEO")"
  CITY="$(jq -r '.city // empty' <<<"$GEO")"
  STATE_NAME="$(jq -r '.region // empty' <<<"$GEO")"
  [ -n "$CC" ] || die "无法识别国家，请用 --region CC/SS/CITY 手动指定"
  ok "识别结果: ${CC} / ${STATE_NAME:-?} / ${CITY:-?}"

  # 国家
  jq -e --arg cc "$CC" '.continents[].countries[] | select(.id==$cc)' "$MAP" >/dev/null \
    || die "map.json 中没有国家 $CC，请用 --region 手动指定"

  # 州/省
  SS="$(jq -r --arg cc "$CC" --arg s "$STATE_NAME" '
    [.continents[].countries[] | select(.id==$cc) | .states[]
     | select(($s|ascii_downcase) as $q | ((.name|ascii_downcase)|contains($q)) or ((.id|ascii_downcase)==$q))]
    | if length>0 then .[0].id else empty end' "$MAP")"
  [ -n "$SS" ] || SS="$(jq -r --arg cc "$CC" '.continents[].countries[] | select(.id==$cc) | .states[0].id' "$MAP")"

  # 城市
  CITY_ID="$(jq -r --arg cc "$CC" --arg ss "$SS" --arg c "$CITY" '
    [.continents[].countries[] | select(.id==$cc) | .states[] | select(.id==$ss) | .cities[]
     | select(($c|ascii_downcase) as $q | ((.name|ascii_downcase)|contains($q)) or ((.id|ascii_downcase)==$q))]
    | if length>0 then .[0].id else empty end' "$MAP")"
  [ -n "$CITY_ID" ] || CITY_ID="$(jq -r --arg cc "$CC" --arg ss "$SS" '.continents[].countries[] | select(.id==$cc) | .states[] | select(.id==$ss) | .cities[0].id' "$MAP")"
  CITY="$CITY_ID"
fi

[ -n "${SS:-}" ] && [ -n "${CITY:-}" ] || die "区域解析失败，请用 --region CC/SS/CITY 指定"

REGION_JSON_URL="${REPO}/main/data/regions/${CC}/${SS}/${CITY}.json"
REGION_NAME="$(curl -fsSL -m 15 "$REGION_JSON_URL" | jq -r '.region_name // empty' || true)"
[ -n "$REGION_NAME" ] || die "拉取区域配置失败: $REGION_JSON_URL"

BASE_LAT="$(curl -fsSL -m 15 "$REGION_JSON_URL" | jq -r '.google_module.base_lat')"
BASE_LON="$(curl -fsSL -m 15 "$REGION_JSON_URL" | jq -r '.google_module.base_lon')"
LANG_PARAMS="$(curl -fsSL -m 15 "$REGION_JSON_URL" | jq -r '.google_module.lang_params')"
VALID_URL_SUFFIX="$(curl -fsSL -m 15 "$REGION_JSON_URL" | jq -r '.google_module.valid_url_suffix')"
KEYWORD_FILE="$(jq -r --arg cc "$CC" '.continents[].countries[] | select(.id==$cc) | .keyword_file' "$MAP")"
ok "战区: $REGION_NAME"
ok "坐标: $BASE_LAT, $BASE_LON · 语言: $LANG_PARAMS"

PSK="$(openssl rand -hex 16)"
if [ -z "$NODE_ID" ]; then
  HOSTP="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c1-10 | tr 'A-Z' 'a-z')"
  NODE_ID="${HOSTP}-$(echo "$CC" | tr 'A-Z' 'a-z')"
fi
NODE_ID="${NODE_ID:0:24}"

if [ "$DRY" = "1" ]; then
  cat <<EOF

=== DRY RUN ===
面板      : $PANEL
节点 ID   : $NODE_ID
出口 IP   : $PUBLIC_IP
端口      : $AGENT_PORT
战区      : $REGION_NAME  ($CC/$SS/$CITY)
词库      : $KEYWORD_FILE
PSK       : $PSK
EOF
  rm -f "$MAP"; exit 0
fi

# ---------- 部署文件 ----------
log "创建目录与核心文件…"
mkdir -p "$INSTALL_DIR"/{core,data/keywords,data/regions/$CC/$SS,logs,data/cookies}

CORE_FILES="runner.sh agent_daemon.sh mod_google.sh mod_trust.sh mod_quality.sh tg_report.sh updater.sh uninstall.sh"
for f in $CORE_FILES; do
  curl -fsSL -m 20 "${REPO}/main/core/$f" -o "$INSTALL_DIR/core/$f" || die "下载 core/$f 失败"
done
chmod +x "$INSTALL_DIR"/core/*.sh

curl -fsSL -m 30 "${REPO}/main/data/user_agents.txt" -o "$INSTALL_DIR/data/user_agents.txt" || die "下载 UA 指纹池失败"
curl -fsSL -m 30 "${REPO}/main/data/keywords/${KEYWORD_FILE}" -o "$INSTALL_DIR/data/keywords/${KEYWORD_FILE}" || die "下载词库失败"
curl -fsSL -m 30 "$REGION_JSON_URL" -o "$INSTALL_DIR/data/regions/$CC/$SS/$CITY.json" || die "下载区域配置失败"
ok "文件就绪"

# ---------- 配置 ----------
log "写入配置…"
cat > "$INSTALL_DIR/config.conf" <<CONF
# IP-Sentinel 本地配置（由面板安装器生成: $(date -u '+%Y-%m-%d %H:%M:%S UTC')）
AGENT_VERSION="$VERSION"
REGION_CODE="$CC"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

ENABLE_GOOGLE="true"
ENABLE_TRUST="true"

TG_TOKEN="PANEL_MODE"
TG_API_URL="${PANEL}/api/agent/tgshim/botPANEL/sendMessage"
CHAT_ID="$PSK"
AGENT_PORT="$AGENT_PORT"
INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="$INSTALL_DIR/logs/sentinel.log"

IP_PREF="4"
PUBLIC_IP="$PUBLIC_IP"
BIND_IP="$PUBLIC_IP"
COMM_IP="$PUBLIC_IP"
CONF
chmod 600 "$INSTALL_DIR/config.conf"

# ---------- 证书 ----------
if [ ! -f "$INSTALL_DIR/core/cert.pem" ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$INSTALL_DIR/core/key.pem" -out "$INSTALL_DIR/core/cert.pem" \
    -subj "/C=US/O=IP-Sentinel/CN=Agent-Sec" >/dev/null 2>&1
fi
echo "$PUBLIC_IP" > "$INSTALL_DIR/core/.last_ip"

# ---------- systemd ----------
log "部署守护进程与定时器…"
cat > /etc/systemd/system/ip-sentinel-agent-daemon.service <<'UNIT'
[Unit]
Description=IP-Sentinel Agent Daemon
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Type=simple
ExecStart=/bin/bash /opt/ip_sentinel/core/agent_daemon.sh
Restart=always
RestartSec=5
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/ip-sentinel-runner.service <<'UNIT'
[Unit]
Description=IP-Sentinel Runner
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/ip_sentinel/core/runner.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
UNIT

cat > /etc/systemd/system/ip-sentinel-runner.timer <<'UNIT'
[Unit]
Description=Timer for IP-Sentinel Runner
[Timer]
OnCalendar=*:0/20
RandomizedDelaySec=180
Persistent=true
Unit=ip-sentinel-runner.service
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable ip-sentinel-agent-daemon.service >/dev/null 2>&1
systemctl restart ip-sentinel-agent-daemon.service
systemctl enable --now ip-sentinel-runner.timer >/dev/null 2>&1
sleep 2
systemctl is-active --quiet ip-sentinel-agent-daemon.service || die "守护进程启动失败：journalctl -u ip-sentinel-agent-daemon -n 30"
ok "守护进程运行中"

# ---------- 自测 ----------
TS="$(date +%s)"
SIG="$(printf '%s' "/trigger_log:$TS" | openssl dgst -sha256 -hmac "$PSK" | awk '{print $NF}')"
RESP="$(curl -sk --max-time 8 "https://127.0.0.1:${AGENT_PORT}/trigger_log?t=$TS&sign=$SIG" || true)"
case "$RESP" in
  *"Action Accepted"*) ok "本地签名自测通过" ;;
  *) warn "本地自测返回异常: $RESP" ;;
esac

# ---------- 注册 ----------
log "向面板提交注册…"
REG_BODY="$(jq -nc --arg id "$NODE_ID" --arg ip "$PUBLIC_IP" --argjson port "$AGENT_PORT" \
  --arg psk "$PSK" --arg region "$REGION_NAME" --arg ver "$VERSION" --arg enroll "$ENROLL" \
  '{node_id:$id, ip:$ip, port:$port, psk:$psk, region:$region, version:$ver}
   + (if $enroll != "" then {enroll:$enroll} else {} end)')"
REG_BODY_FILE="$(mktemp)"
REG_CODE="$(curl -sS -m 20 -o "$REG_BODY_FILE" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -d "$REG_BODY" "${PANEL}/api/agent/register" 2>/dev/null || echo 000)"
REG_RESP="$(cat "$REG_BODY_FILE" 2>/dev/null || echo '{}')"
rm -f "$REG_BODY_FILE"

rm -f "$MAP"

echo
echo "============================================================"
if [ "$REG_CODE" = "200" ] && jq -e '.ok == true' >/dev/null 2>&1 <<<"$REG_RESP"; then
  STATUS="$(jq -r '.status // "pending"' <<<"$REG_RESP")"
  if [ "$STATUS" = "active" ]; then
    ok "节点已注册（已处于激活状态）"
  else
    ok "已提交注册，等待面板审批"
  fi
  echo
  echo "  节点 ID : $NODE_ID"
  echo "  战区    : $REGION_NAME"
  echo "  地址    : $PUBLIC_IP:$AGENT_PORT"
  echo
  echo "  下一步：打开 $PANEL → 舰队 → 待审批，点「通过」"
elif [ "$REG_CODE" = "409" ]; then
  warn "$(jq -r '.error // "节点已存在"' <<<"$REG_RESP")"
  echo "  重装场景：先在面板删除该节点再重跑，或直接把面板里的 PSK 改成：$PSK"
elif [ "$REG_CODE" = "000" ]; then
  warn "无法连接面板 $PANEL（检查域名解析与 443 可达性）"
  echo "  本地已装好，可稍后手动添加："
  echo "  节点 ID : $NODE_ID / 公网 IP : $PUBLIC_IP / 端口 : $AGENT_PORT / PSK : $PSK"
else
  warn "注册失败（HTTP $REG_CODE）：$REG_RESP"
  echo "  节点 ID : $NODE_ID / 公网 IP : $PUBLIC_IP / 端口 : $AGENT_PORT / PSK : $PSK"
fi
echo
echo "  防火墙建议（只放行面板出口 IP 访问 ${AGENT_PORT}）："
echo "  ufw allow from <面板出口IP> to any port $AGENT_PORT proto tcp"
echo "============================================================"
