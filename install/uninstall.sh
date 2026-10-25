#!/usr/bin/env bash
# ==========================================================
# IP-Sentinel Panel · 主控卸载
#
#   bash uninstall.sh           # 停止并移除程序，保留数据库
#   bash uninstall.sh --purge   # 连同数据库与配置一起删除
# ==========================================================
set -euo pipefail

INSTALL_DIR="/opt/ip-sentinel-panel"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ✅ %s\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { echo "需要 root"; exit 1; }

echo "即将卸载 IP-Sentinel Panel"
[ "$PURGE" = "1" ] && echo "⚠️  --purge：数据库和配置也会被删除" || echo "（数据库会保留，加 --purge 可一并删除）"
read -r -p "确认继续？(y/N) " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

log "停止服务…"
systemctl disable --now ipsentinel-panel.service 2>/dev/null || true
rm -f /etc/systemd/system/ipsentinel-panel.service
systemctl daemon-reload
ok "服务已移除"

log "清理反向代理配置…"
for f in /etc/nginx/sites-enabled/ipsentinel-*.conf; do
  [ -e "$f" ] || continue
  rm -f "$f" "/etc/nginx/sites-available/$(basename "$f")"
  ok "已删除 nginx 站点 $(basename "$f")"
done
if command -v nginx >/dev/null 2>&1; then nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; fi

if [ -f /etc/caddy/Caddyfile ] && grep -q "127.0.0.1:8080" /etc/caddy/Caddyfile 2>/dev/null; then
  echo "  ℹ️  Caddyfile 里仍有面板配置，请手动删除对应 site 块：/etc/caddy/Caddyfile"
fi

log "清理文件…"
if [ "$PURGE" = "1" ]; then
  rm -rf "$INSTALL_DIR" /root/.ips_panel_pw
  ok "程序、数据库、口令文件已删除"
else
  rm -rf "$INSTALL_DIR/static" "$INSTALL_DIR/app.py" "$INSTALL_DIR/src"
  ok "程序已删除，数据库保留在 $INSTALL_DIR/data"
fi

echo
echo "完成。"
