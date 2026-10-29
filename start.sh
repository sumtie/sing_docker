#!/usr/bin/env bash
set -euo pipefail

# ==================== 基础路径 ====================
APP_CONF=/app/config.json
SB_CONF=/etc/sing-box/config.json
CF_DIR=/etc/cloudflared
CF_CONF=${CF_DIR}/config.yml
LOG_DIR=/var/log/argo

mkdir -p /etc/sing-box "$CF_DIR" "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ==================== 环境变量 ====================
UUID="${UUID:-}"
VLESS_PORT="${VLESS_PORT:-${PORT:-8001}}"
VMESS_PORT="${VMESS_PORT:-$((VLESS_PORT + 1))}"
VLESS_WS_PATH="${VLESS_WS_PATH:-/vless-ws}"
VMESS_WS_PATH="${VMESS_WS_PATH:-/vmess-ws}"
ARGO_AUTH="${ARGO_AUTH:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"

SB_PID=""
CF_PID=""

cleanup() {
  log "收到退出信号，正在关闭..."
  [ -n "$SB_PID" ] && kill "$SB_PID" 2>/dev/null || true
  [ -n "$CF_PID" ] && kill "$CF_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ==================== UUID ====================
if [ -z "$UUID" ]; then
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  log "未提供 UUID，已随机生成：$UUID"
fi
UUID="$(printf '%s' "$UUID" | tr 'A-Z' 'a-z')"

# 域名清洗（去掉协议头 / 路径 / 末尾斜杠）
ARGO_DOMAIN="$(printf '%s' "$ARGO_DOMAIN" | sed -e 's#^https\?://##' -e 's#/.*$##' -e 's#/*$##')"

# ==================== 生成 sing-box 配置 ====================
jq --arg uuid "$UUID" \
   --arg vpath "$VLESS_WS_PATH" \
   --arg mpath "$VMESS_WS_PATH" \
   --argjson vport "$VLESS_PORT" \
   --argjson mport "$VMESS_PORT" \
   '
     (.inbounds[] | select(.tag == "vless-ws") | .listen_port) = $vport
   | (.inbounds[] | select(.tag == "vmess-ws") | .listen_port) = $mport
   | (.inbounds[] | select(.tag == "vless-ws") | .transport.path) = $vpath
   | (.inbounds[] | select(.tag == "vmess-ws") | .transport.path) = $mpath
   | (.inbounds[] | .users[0].uuid) = $uuid
   ' "$APP_CONF" > "$SB_CONF"

if ! sing-box check -c "$SB_CONF" > "$LOG_DIR/check.log" 2>&1; then
  log "sing-box 配置校验失败："
  cat "$LOG_DIR/check.log"
  exit 1
fi
log "sing-box 配置校验通过"

# ==================== 启动 sing-box ====================
log "启动 sing-box（VLESS:${VLESS_PORT}${VLESS_WS_PATH}  VMess:${VMESS_PORT}${VMESS_WS_PATH}）"
sing-box run -c "$SB_CONF" > "$LOG_DIR/sing-box.log" 2>&1 &
SB_PID=$!

sleep 2
if ! kill -0 "$SB_PID" 2>/dev/null; then
  log "sing-box 启动失败："
  cat "$LOG_DIR/sing-box.log"
  exit 1
fi

# ==================== 链接输出工具 ====================
share_links() {
  local host="$1"
  local venc menc vmess_json
  venc="$(jq -rn --arg p "$VLESS_WS_PATH" '$p|@uri')"
  menc="$(jq -rn --arg p "$VMESS_WS_PATH" '$p|@uri')"

  echo ""
  echo "================================================================"
  echo " VLESS + WS  (TLS 443)"
  echo "================================================================"
  echo "vless://${UUID}@${host}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${venc}#vless-ws"

  vmess_json="$(jq -cn \
    --arg h "$host" --arg id "$UUID" --arg p "$VMESS_WS_PATH" \
    '{v:"2",ps:("vmess-ws-"+$h),add:$h,port:"443",id:$id,aid:"0",scy:"auto",
      net:"ws",type:"none",host:$h,path:$p,tls:"tls",sni:$h,alpn:"",fp:"chrome"}')"

  echo ""
  echo "================================================================"
  echo " VMess + WS  (TLS 443)"
  echo "================================================================"
  echo "vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
  echo "================================================================"
  echo ""
}

wait_for_url() {
  local file="$1" tries=0 url=""
  while [ "$tries" -lt 90 ]; do
    url="$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$file" 2>/dev/null | head -n1 || true)"
    if [ -n "$url" ]; then printf '%s' "$url"; return 0; fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}

start_quick_tunnel() {
  local port="$1" name="$2"
  cloudflared tunnel --no-autoupdate --edge-ip-version auto \
      --url "http://127.0.0.1:${port}" \
      > "$LOG_DIR/cloudflared-${name}.log" 2>&1 &
  echo $!
}

# ==================== 启动 cloudflared ====================
if [ -n "$ARGO_AUTH" ]; then
  # ---------- 固定隧道 ----------
  if [ -z "$ARGO_DOMAIN" ]; then
    log "错误：检测到 ARGO_AUTH，固定隧道必须同时设置 ARGO_DOMAIN"
    exit 1
  fi

  if printf '%s' "$ARGO_AUTH" | grep -q '^eyJ'; then
    log "模式：固定隧道（Tunnel Token）→ ${ARGO_DOMAIN}"
    TOKEN_LINE="token: ${ARGO_AUTH}"
    RUN_ARGS=(--token "${ARGO_AUTH}")
  else
    log "模式：固定隧道（凭据 JSON）→ ${ARGO_DOMAIN}"
    printf '%s' "$ARGO_AUTH" > "${CF_DIR}/creds.json"
    TUNNEL_ID="$(jq -r '.TunnelID' "${CF_DIR}/creds.json")"
    TOKEN_LINE="tunnel: ${TUNNEL_ID}
credentials-file: ${CF_DIR}/creds.json"
    RUN_ARGS=()
  fi

  cat > "$CF_CONF" <<EOF
${TOKEN_LINE}
no-autoupdate: true
edge-ip-version: auto
ingress:
  - hostname: ${ARGO_DOMAIN}
    path: ${VLESS_WS_PATH}
    service: http://127.0.0.1:${VLESS_PORT}
  - hostname: ${ARGO_DOMAIN}
    path: ${VMESS_WS_PATH}
    service: http://127.0.0.1:${VMESS_PORT}
  - service: http_status:404
EOF

  cloudflared tunnel --config "$CF_CONF" "${RUN_ARGS[@]}" run \
      > "$LOG_DIR/cloudflared.log" 2>&1 &
  CF_PID=$!

  sleep 12
  if ! kill -0 "$CF_PID" 2>/dev/null; then
    log "固定隧道连接失败，回退到临时隧道。日志："
    tail -n 20 "$LOG_DIR/cloudflared.log" || true
    CF_PID=""
  else
    share_links "$ARGO_DOMAIN"
    echo "提示：固定隧道请在 Cloudflare Zero Trust 后台确认该隧道的 Public Hostname 已配置"
    echo "      ${ARGO_DOMAIN}  path=${VLESS_WS_PATH}  → http://localhost:${VLESS_PORT}"
    echo "      ${ARGO_DOMAIN}  path=${VMESS_WS_PATH}  → http://localhost:${VMESS_PORT}"
    echo ""
  fi
fi

if [ -z "$CF_PID" ]; then
  # ---------- 临时隧道 ----------
  log "模式：临时隧道（trycloudflare）"
  VLESS_CF_PID="$(start_quick_tunnel "$VLESS_PORT" vless)"
  VMESS_CF_PID="$(start_quick_tunnel "$VMESS_PORT" vmess)"

  VLESS_URL="$(wait_for_url "$LOG_DIR/cloudflared-vless.log" || true)"
  VMESS_URL="$(wait_for_url "$LOG_DIR/cloudflared-vmess.log" || true)"

  [ -n "$VLESS_URL" ] && log "VLESS 临时域名：$VLESS_URL"
  [ -n "$VMESS_URL" ] && log "VMess 临时域名：$VMESS_URL"

  printf '%s\n%s\n' "$VLESS_URL" "$VMESS_URL" > "$LOG_DIR/urls.txt"

  if [ -n "$VLESS_URL" ]; then share_links "${VLESS_URL#https://}"; fi
  if [ -z "$VLESS_URL" ] && [ -z "$VMESS_URL" ]; then
    log "临时隧道获取失败，日志："
    tail -n 20 "$LOG_DIR/cloudflared-vless.log" || true
  fi

  # 记录子进程用于退出清理
  CF_PID="$VLESS_CF_PID"
  echo "$VMESS_CF_PID" >> "$LOG_DIR/urls.txt"
fi

log "启动完成，容器持续运行中…"
wait