#!/usr/bin/env bash
set -Eeuo pipefail
BASE=/opt/xray-go
UNIT=/etc/systemd/system/xray-go.service
SVC_USER=xray-go
[[ $EUID -eq 0 ]] || { echo "请使用 root 运行" >&2; exit 1; }
[[ -f "$UNIT" ]] || { echo "未找到 xray-go.service，未作任何修改"; exit 1; }
grep -Fq "ExecStart=$BASE/bin/xray run -config $BASE/config/config.json" "$UNIT" || { echo "服务文件与本项目预期不符，拒绝卸载"; exit 1; }
[[ ! -e "$BASE" || -d "$BASE" ]] || { echo "$BASE 不是目录，拒绝删除"; exit 1; }
echo "只会删除 xray-go.service、/opt/xray-go 和本项目创建的 xray-go 用户/组。"
echo "不会处理 xray、x-ui、cloudflared、/etc/xray 或防火墙规则。"
read -r -p "输入 YES 确认卸载: " ANSWER
[[ "$ANSWER" == YES ]] || { echo "已取消"; exit 0; }
systemctl disable --now xray-go.service
rm -f "$UNIT"
systemctl daemon-reload
systemctl reset-failed xray-go.service >/dev/null 2>&1 || true
rm -rf -- "$BASE"
if id "$SVC_USER" >/dev/null 2>&1; then
  if [[ "$(id -gn "$SVC_USER")" == "$SVC_USER" ]]; then userdel "$SVC_USER"; else echo "账户主组不符，保留账户以避免误删" >&2; fi
fi
if getent group "$SVC_USER" >/dev/null 2>&1; then groupdel "$SVC_USER" 2>/dev/null || true; fi
echo "卸载完成。其他服务和 /etc/xray 未触碰。"
