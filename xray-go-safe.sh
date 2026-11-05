#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
BASE=/opt/xray-go
UNIT=/etc/systemd/system/xray-go.service
SVC_USER=xray-go
SNI=www.bing.com
say(){ printf '\033[1;32m%s\033[0m\n' "$*"; }
die(){ printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "请使用 root 运行"
[[ -d /run/systemd/system ]] || die "仅支持 systemd 系统"
for c in curl unzip openssl systemctl ss awk; do command -v "$c" >/dev/null 2>&1 || die "缺少依赖 $c；脚本不会自动安装依赖"; done
[[ ! -e "$BASE" && ! -e "$UNIT" ]] || die "项目目录或服务文件已存在，为避免覆盖已停止"
if id "$SVC_USER" >/dev/null 2>&1 || getent group "$SVC_USER" >/dev/null 2>&1; then die "系统账户或组 xray-go 已存在，为避免冲突已停止"; fi
read -r -p "H3 UDP 端口 [8443]: " PORT
if [[ -z "$PORT" ]]; then PORT=8443; fi
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || die "端口无效"
ss -H -lun "sport = :$PORT" 2>/dev/null | grep -q . && die "UDP/$PORT 已被占用"
case "$(uname -m)" in
 x86_64|amd64) A=64 ;;
 aarch64|arm64) A=arm64-v8a ;;
 armv7l|armv7) A=arm32-v7a ;;
 *) die "不支持的 CPU 架构" ;;
esac
TMP=$(mktemp -d)
MADE_USER=0; MADE_DIR=0; MADE_UNIT=0
rollback(){
 rc=$?
 if (( rc != 0 )); then
   echo "安装失败，回滚本脚本创建的资源" >&2
   if (( MADE_UNIT )); then rm -f "$UNIT"; systemctl daemon-reload >/dev/null 2>&1 || true; fi
   if (( MADE_DIR )); then rm -rf "$BASE"; fi
   if (( MADE_USER )); then userdel "$SVC_USER" >/dev/null 2>&1 || true; fi
 fi
 rm -rf "$TMP"
 exit "$rc"
}
trap rollback EXIT
say "下载 Xray-core 官方发行包"
curl --fail --location --retry 2 --connect-timeout 10 --max-time 180 "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$A.zip" -o "$TMP/xray.zip"
unzip -tq "$TMP/xray.zip" >/dev/null || die "发行包校验失败"
mkdir "$TMP/unpack"; unzip -q "$TMP/xray.zip" -d "$TMP/unpack"
[[ -s "$TMP/unpack/xray" ]] || die "发行包中未找到 xray"
groupadd --system "$SVC_USER"
useradd --system --gid "$SVC_USER" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SVC_USER"
MADE_USER=1
install -d -o root -g "$SVC_USER" -m 0750 "$BASE" "$BASE/bin" "$BASE/config" "$BASE/cert"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 "$BASE/logs"
MADE_DIR=1
install -o root -g "$SVC_USER" -m 0750 "$TMP/unpack/xray" "$BASE/bin/xray"
UUID=$(cat /proc/sys/kernel/random/uuid)
PATH_ID=$(openssl rand -hex 16)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 825 -nodes -keyout "$BASE/cert/server.key" -out "$BASE/cert/server.crt" -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1
chown root:"$SVC_USER" "$BASE/cert/server.key" "$BASE/cert/server.crt"; chmod 0640 "$BASE/cert/server.key" "$BASE/cert/server.crt"
cat > "$BASE/config/config.json" <<EOF
{
 "log":{"loglevel":"warning","error":"$BASE/logs/error.log"},
 "inbounds":[{
  "tag":"vless-xhttp-h3","listen":"::","port":$PORT,"protocol":"vless",
  "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
  "streamSettings":{
   "network":"xhttp","security":"tls",
   "xhttpSettings":{"path":"/$PATH_ID"},
   "tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":"$BASE/cert/server.crt","keyFile":"$BASE/cert/server.key"}]}
  }
 }],
 "outbounds":[{"tag":"direct","protocol":"freedom"}]
}
EOF
chown root:"$SVC_USER" "$BASE/config/config.json"; chmod 0640 "$BASE/config/config.json"
say "执行 Xray 配置测试"
"$BASE/bin/xray" run -test -config "$BASE/config/config.json"
cat > "$UNIT" <<EOF
[Unit]
Description=Xray-go isolated VLESS XHTTP H3
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$BASE
ExecStart=$BASE/bin/xray run -config $BASE/config/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$BASE/logs
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$UNIT"; MADE_UNIT=1
systemctl daemon-reload
systemctl enable --now xray-go.service
sleep 2
systemctl is-active --quiet xray-go.service || { systemctl --no-pager --full status xray-go.service || true; die "服务启动失败，请检查 journalctl -u xray-go"; }
IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
if [[ -z "$IP" ]]; then IP=$(curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true); fi
if [[ -z "$IP" ]]; then IP="请手动填写 VPS 公网 IP"; fi
if [[ "$IP" == *:* ]]; then ADDR="[$IP]"; else ADDR="$IP"; fi
URI="vless://$UUID@$ADDR:$PORT?encryption=none&security=tls&sni=$SNI&alpn=h3&type=xhttp&path=%2F$PATH_ID&mode=auto&allowInsecure=1#Xray-go-H3"
printf '%s\n' "$URI" > "$BASE/node.txt"
chown root:"$SVC_USER" "$BASE/node.txt"; chmod 0640 "$BASE/node.txt"
B64=$(printf '%s' "$URI" | base64 | tr -d '\r\n')
trap - EXIT; rm -rf "$TMP"
say "安装完成；服务 xray-go.service；目录 $BASE；监听 UDP/$PORT"
printf '\n节点 URI:\n%s\n\nBase64:\n%s\n' "$URI" "$B64"
echo "注意：本脚本不修改防火墙。请在云安全组及系统防火墙放行 UDP/$PORT。"
echo "注意：使用自签名证书并设置 allowInsecure=1，客户端不会验证服务端证书身份。"
echo "注意：H3 仅使用 QUIC/UDP，没有 TCP/H2 回退；网络屏蔽 UDP 时将无法连接。"
