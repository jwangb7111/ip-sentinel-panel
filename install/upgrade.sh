#!/usr/bin/env bash
# ==========================================================
# IP-Sentinel Panel · 主控升级（保留数据）
#   bash upgrade.sh
# ==========================================================
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-jwangb7111/ip-sentinel-panel}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="/opt/ip-sentinel-panel"
SERVICE="ipsentinel-panel"

log() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ✅ %s\033[0m\n' "$*"; }
die() { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "需要 root"
[ -d "$INSTALL_DIR" ] || die "未安装：$INSTALL_DIR 不存在"

log "备份当前版本…"
TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/ip-sentinel-backup-$TS"
mkdir -p "$BK"
cp -a "$INSTALL_DIR/app.py" "$BK/" 2>/dev/null || true
cp -a "$INSTALL_DIR/static" "$BK/" 2>/dev/null || true
cp -a "$INSTALL_DIR/config.json" "$BK/" 2>/dev/null || true
cp -a "$INSTALL_DIR/data/panel.db" "$BK/" 2>/dev/null || true
ok "已备份到 $BK"

log "下载新版本…"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL --max-time 60 "https://github.com/${REPO_SLUG}/archive/refs/heads/${BRANCH}.tar.gz" -o "$TMP/src.tar.gz" || die "下载失败"
tar xzf "$TMP/src.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 2 -type d -name panel | head -1)"
[ -n "$SRC" ] || die "包内未找到 panel 目录"

log "覆盖程序文件（保留 data/ 与 config.json）…"
cp -a "$SRC/." "$INSTALL_DIR/"
rm -rf "$INSTALL_DIR/src"
mkdir -p "$INSTALL_DIR/src"
cp -a "$TMP"/*/install "$INSTALL_DIR/src/" 2>/dev/null || true
cp -a "$TMP"/*/version.txt "$INSTALL_DIR/src/" 2>/dev/null || true
DOMAIN="$(grep -o 'server_name [^;]*' /etc/nginx/sites-enabled/* 2>/dev/null | grep -v '_' | head -1 | awk '{print $2}')"
if [ -n "$DOMAIN" ] && [ -f "$INSTALL_DIR/src/install/agent.sh" ]; then
  {
    echo '#!/usr/bin/env bash'
    printf 'DEFAULT_MASTER="%s"\n' "$DOMAIN"
    tail -n +2 "$INSTALL_DIR/src/install/agent.sh"
  } > "$INSTALL_DIR/static/agent.sh"
  chmod 755 "$INSTALL_DIR/static/agent.sh"
fi

log "重启服务…"
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE" || die "启动失败，回滚：cp -a $BK/* $INSTALL_DIR/ && systemctl restart $SERVICE"

C="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)"
[ "$C" = "200" ] || die "健康检查失败（HTTP $C），备份在 $BK"

VER="$(cat "$INSTALL_DIR/src/version.txt" 2>/dev/null || echo unknown)"
echo
echo "✅ 升级完成，当前版本 $VER"
echo "   备份保留在 $BK"
