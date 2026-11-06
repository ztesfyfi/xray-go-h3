#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

BASE=/opt/xray-go
UNIT=/etc/systemd/system/xray-go.service
LOGROTATE=/etc/logrotate.d/xray-go
SVC_USER=xray-go
MARKER=.xray-go-managed
XRAY_VERSION=v26.10.31
TEST_SNI=www.bing.com

say(){ printf '\033[1;32m%s\033[0m\n' "$*"; }
die(){ printf '错误：%s\n' "$*" >&2; exit 1; }
show_logs(){ echo "最近的 Xray 错误日志："; if [[ -s "$BASE/logs/error.log" ]]; then tail -n 30 "$BASE/logs/error.log" || true; else echo "尚无 error.log 内容"; fi; }

[[ $EUID -eq 0 ]] || die "请使用 root 运行"
[[ -d /run/systemd/system ]] || die "仅支持 systemd 系统"
for c in curl unzip openssl systemctl ss awk grep groupadd useradd userdel groupdel id getent install mktemp cat chmod chown rm sleep base64 tr uname sha256sum tail cmp; do
  command -v "$c" >/dev/null 2>&1 || die "缺少依赖 $c；脚本不会自动安装依赖"
done

[[ ! -e "$BASE" && ! -L "$BASE" && ! -e "$UNIT" && ! -L "$UNIT" ]] || die "项目目录或服务文件已存在，为避免覆盖已停止"
if id "$SVC_USER" >/dev/null 2>&1 || getent group "$SVC_USER" >/dev/null 2>&1; then
  die "系统账户或组 xray-go 已存在，为避免冲突已停止"
fi
if command -v logrotate >/dev/null 2>&1; then
  [[ ! -e "$LOGROTATE" && ! -L "$LOGROTATE" ]] || die "$LOGROTATE 已存在，为避免覆盖已停止"
fi

# 随机选择未被本机 UDP socket 占用的高位端口；安装后固定，不会在重启时变化。
PORT=
for ((attempt=1; attempt<=100; attempt++)); do
  candidate=$((20000 + RANDOM % 41000))
  SOCKETS=$(ss -H -lun "sport = :$candidate" 2>/dev/null) || die "无法检查 UDP 端口占用状态"
  if [[ -z "$SOCKETS" ]]; then PORT=$candidate; break; fi
done
[[ -n "$PORT" ]] || die "随机尝试 100 次仍未找到空闲 UDP 高位端口"

case "$(uname -m)" in
  x86_64|amd64) A=64 ;;
  aarch64|arm64) A=arm64-v8a ;;
  armv7l|armv7) A=arm32-v7a ;;
  *) die "不支持的 CPU 架构" ;;
esac

# 域名模式要求用户提供与域名匹配的可信证书及私钥；留空则进入仅供测试的自签名模式。
read -r -p "自有证书域名（留空使用仅供测试的 $TEST_SNI 自签名证书）: " SNI
CERT_MODE= selfsigned
if [[ -n "$SNI" ]]; then
  [[ "$SNI" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "域名格式不正确"
  CERT_MODE=custom
  read -r -p "证书文件路径（建议 fullchain.pem）: " CERT_SOURCE
  read -r -p "私钥文件路径: " KEY_SOURCE
  [[ -n "$CERT_SOURCE" && -f "$CERT_SOURCE" && ! -L "$CERT_SOURCE" ]] || die "证书文件不存在或不是普通文件"
  [[ -n "$KEY_SOURCE" && -f "$KEY_SOURCE" && ! -L "$KEY_SOURCE" ]] || die "私钥文件不存在或不是普通文件"
else
  SNI=$TEST_SNI
fi

TMP=$(mktemp -d)
MADE_USER=0
MADE_GROUP=0
MADE_DIR=0
MADE_UNIT=0
MADE_LOGROTATE=0

rollback(){
  rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo "安装失败，回滚本脚本创建的资源" >&2
    if (( MADE_UNIT )); then
      systemctl disable --now xray-go.service >/dev/null 2>&1 || true
      rm -f -- "$UNIT"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if (( MADE_LOGROTATE )); then rm -f -- "$LOGROTATE"; fi
    if (( MADE_DIR )); then rm -rf -- "$BASE"; fi
    if (( MADE_USER )); then userdel "$SVC_USER" >/dev/null 2>&1 || true; fi
    if (( MADE_GROUP )); then groupdel "$SVC_USER" >/dev/null 2>&1 || true; fi
  fi
  rm -rf -- "$TMP"
  exit "$rc"
}
trap rollback EXIT

say "下载 Xray-core $XRAY_VERSION 官方发行包"
URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-$A.zip"
curl --fail --location --retry 2 --connect-timeout 10 --max-time 180 "$URL" -o "$TMP/xray.zip"
curl --fail --location --retry 2 --connect-timeout 10 --max-time 60 "$URL.dgst" -o "$TMP/xray.zip.dgst"
CHECKSUM=$(awk -F '= ' '/256=/ {print $2; exit}' "$TMP/xray.zip.dgst" | tr -d '\r\n')
[[ "$CHECKSUM" =~ ^[a-fA-F0-9]{64}$ ]] || die "官方 .dgst 中未找到有效 SHA256，拒绝安装"
LOCALSUM=$(sha256sum "$TMP/xray.zip" | awk '{print $1}')
[[ "$LOCALSUM" == "$CHECKSUM" ]] || die "Xray ZIP SHA256 校验失败，拒绝解压和安装"
unzip -tq "$TMP/xray.zip" >/dev/null || die "ZIP 结构校验失败"
mkdir "$TMP/unpack"
unzip -q "$TMP/xray.zip" -d "$TMP/unpack"
[[ -s "$TMP/unpack/xray" ]] || die "发行包中未找到 xray"

if [[ "$CERT_MODE" == custom ]]; then
  openssl x509 -in "$CERT_SOURCE" -noout -checkhost "$SNI" >/dev/null 2>&1 || die "证书 SAN/CN 与输入域名不匹配"
  openssl x509 -in "$CERT_SOURCE" -noout -checkend 0 >/dev/null 2>&1 || die "证书已过期"
  CERT_PUB=$(openssl x509 -in "$CERT_SOURCE" -pubkey -noout) || die "无法读取证书公钥"
  KEY_PUB=$(openssl pkey -in "$KEY_SOURCE" -pubout 2>/dev/null) || die "无法读取私钥或私钥格式不受支持"
  [[ "$CERT_PUB" == "$KEY_PUB" ]] || die "证书与私钥不匹配"
fi

groupadd --system "$SVC_USER"
MADE_GROUP=1
useradd --system --gid "$SVC_USER" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SVC_USER"
MADE_USER=1

MADE_DIR=1
install -d -o root -g "$SVC_USER" -m 0750 "$BASE" "$BASE/bin" "$BASE/config" "$BASE/cert"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 "$BASE/logs"
printf 'format=xray-go-h3-managed-v1\nuid=%s\ngid=%s\n' "$(id -u "$SVC_USER")" "$(id -g "$SVC_USER")" > "$BASE/$MARKER"
chown root:root "$BASE/$MARKER"
chmod 0600 "$BASE/$MARKER"

install -o root -g "$SVC_USER" -m 0750 "$TMP/unpack/xray" "$BASE/bin/xray"
UUID=$(cat /proc/sys/kernel/random/uuid)
PATH_ID=$(openssl rand -hex 16)
if [[ "$CERT_MODE" == custom ]]; then
  install -o root -g "$SVC_USER" -m 0640 "$CERT_SOURCE" "$BASE/cert/server.crt"
  install -o root -g "$SVC_USER" -m 0640 "$KEY_SOURCE" "$BASE/cert/server.key"
  ALLOW_INSECURE=
else
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 825 -nodes \
    -keyout "$BASE/cert/server.key" -out "$BASE/cert/server.crt" \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1
  chown root:"$SVC_USER" "$BASE/cert/server.key" "$BASE/cert/server.crt"
  chmod 0640 "$BASE/cert/server.key" "$BASE/cert/server.crt"
  ALLOW_INSECURE='&allowInsecure=1'
fi

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
chown root:"$SVC_USER" "$BASE/config/config.json"
chmod 0640 "$BASE/config/config.json"

say "执行 Xray 配置测试"
"$BASE/bin/xray" run -test -config "$BASE/config/config.json"

MADE_UNIT=1
cat > "$UNIT" <<EOF
[Unit]
Description=Xray-go isolated VLESS XHTTP H3
# Xray-go-managed: v1
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
chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable --now xray-go.service
sleep 2
if ! systemctl is-active --quiet xray-go.service; then
  systemctl --no-pager --full status xray-go.service || true
  show_logs
  die "服务启动失败；已请求自动回滚"
fi
if [[ -z "$(ss -H -lun "sport = :$PORT" 2>/dev/null)" ]]; then
  systemctl --no-pager --full status xray-go.service || true
  show_logs
  die "服务进程已启动但未发现 UDP/$PORT 监听；已请求自动回滚"
fi

if command -v logrotate >/dev/null 2>&1 && [[ -d /etc/logrotate.d ]]; then
  MADE_LOGROTATE=1
  cat > "$LOGROTATE" <<EOF
# Xray-go-managed: v1
$BASE/logs/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su $SVC_USER $SVC_USER
}
EOF
  chmod 0644 "$LOGROTATE"
fi

IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
if [[ -z "$IP" ]]; then IP=$(curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true); fi
if [[ -z "$IP" ]]; then IP="请手动填写 VPS 公网 IP"; fi
if [[ "$IP" == *:* ]]; then ADDR="[$IP]"; else ADDR="$IP"; fi
URI="vless://$UUID@$ADDR:$PORT?encryption=none&security=tls&sni=$SNI&alpn=h3&type=xhttp&path=%2F$PATH_ID&mode=auto$ALLOW_INSECURE#Xray-go-H3"
printf '%s\n' "$URI" > "$BASE/node.txt"
chown root:"$SVC_USER" "$BASE/node.txt"
chmod 0640 "$BASE/node.txt"
B64=$(printf '%s' "$URI" | base64 | tr -d '\r\n')

trap - EXIT
rm -rf -- "$TMP"
say "安装完成；Xray $XRAY_VERSION；服务 xray-go.service；目录 $BASE；监听 UDP/$PORT"
printf '\n节点 URI:\n%s\n\nBase64:\n%s\n' "$URI" "$B64"
echo "注意：本脚本不修改防火墙。请在云安全组及系统防火墙放行 UDP/$PORT。"
if [[ "$CERT_MODE" == selfsigned ]]; then
  echo "警告：当前使用自签名证书并设置 allowInsecure=1，仅供测试；客户端不会验证服务端身份。"
else
  echo "TLS：使用用户提供的证书；已检查域名匹配、有效期及证书/私钥匹配。"
fi
if (( MADE_LOGROTATE )); then echo "日志轮转：已写入 $LOGROTATE（每日轮转，保留 7 份）。"; else echo "日志轮转：未配置（系统未检测到 logrotate）。"; fi
echo "H3 仅使用 QUIC/UDP，没有 TCP/H2 回退；网络屏蔽 UDP 时将无法连接。"
echo "注意：端口检查与实际绑定之间仍存在极短竞争窗口；安装后已检查 UDP 监听。"
