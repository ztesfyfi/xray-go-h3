#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/opt/xray-go
UNIT=/etc/systemd/system/xray-go.service
SVC_USER=xray-go
MARKER=.xray-go-managed
EXPECTED_EXEC="ExecStart=$BASE/bin/xray run -config $BASE/config/config.json"

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行" >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo "仅支持 systemd 系统" >&2; exit 1; }
for c in systemctl grep awk getent id rm userdel groupdel; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖 $c，未作任何修改" >&2; exit 1; }
done

[[ -f "$UNIT" && ! -L "$UNIT" ]] || { echo "未找到可信的 xray-go.service，未作任何修改" >&2; exit 1; }
[[ -d "$BASE" && ! -L "$BASE" ]] || { echo "$BASE 不存在或不是普通目录，拒绝卸载" >&2; exit 1; }
[[ -f "$BASE/$MARKER" && ! -L "$BASE/$MARKER" ]] || { echo "缺少项目归属标记，拒绝卸载" >&2; exit 1; }
grep -Fqx '# Xray-go-managed: v1' "$UNIT" || { echo "服务文件缺少项目标记，拒绝卸载" >&2; exit 1; }
grep -Fqx "$EXPECTED_EXEC" "$UNIT" || { echo "服务文件 ExecStart 与本项目不符，拒绝卸载" >&2; exit 1; }

FORMAT=$(awk -F= '$1=="format"{print $2}' "$BASE/$MARKER")
EXPECTED_UID=$(awk -F= '$1=="uid"{print $2}' "$BASE/$MARKER")
EXPECTED_GID=$(awk -F= '$1=="gid"{print $2}' "$BASE/$MARKER")
[[ "$FORMAT" == "xray-go-h3-managed-v1" && "$EXPECTED_UID" =~ ^[0-9]+$ && "$EXPECTED_GID" =~ ^[0-9]+$ ]] || {
  echo "项目归属标记内容异常，拒绝卸载" >&2
  exit 1
}

REMOVE_USER=0
REMOVE_GROUP=0
if USER_ENTRY=$(getent passwd "$SVC_USER"); then
  IFS=: read -r _ _ CURRENT_UID CURRENT_GID _ CURRENT_HOME CURRENT_SHELL <<< "$USER_ENTRY"
  if [[ "$CURRENT_UID" == "$EXPECTED_UID" && "$CURRENT_GID" == "$EXPECTED_GID" && "$CURRENT_HOME" == "/nonexistent" && "$CURRENT_SHELL" == "/usr/sbin/nologin" ]]; then
    REMOVE_USER=1
  else
    echo "警告：xray-go 账户身份与安装记录不符，卸载时将保留该账户。" >&2
  fi
fi
if GROUP_ENTRY=$(getent group "$SVC_USER"); then
  IFS=: read -r _ _ CURRENT_GROUP_GID _ <<< "$GROUP_ENTRY"
  if [[ "$CURRENT_GROUP_GID" == "$EXPECTED_GID" ]]; then
    REMOVE_GROUP=1
  else
    echo "警告：xray-go 组身份与安装记录不符，卸载时将保留该组。" >&2
  fi
fi

echo "即将卸载本项目："
echo "  服务：$UNIT"
echo "  目录：$BASE"
echo "  账户/组：仅在身份与安装记录匹配时删除"
echo "不会处理其他 xray、x-ui、cloudflared、/etc/xray 或防火墙规则。"
read -r -p "输入 YES 确认卸载: " ANSWER
[[ "$ANSWER" == YES ]] || { echo "已取消，未作任何修改"; exit 0; }

systemctl disable --now xray-go.service
rm -f -- "$UNIT"
systemctl daemon-reload
systemctl reset-failed xray-go.service >/dev/null 2>&1 || true
rm -rf -- "$BASE"

if (( REMOVE_USER )); then
  userdel "$SVC_USER" || echo "警告：删除 xray-go 账户失败，账户已保留。" >&2
fi
if (( REMOVE_GROUP )); then
  groupdel "$SVC_USER" 2>/dev/null || echo "警告：删除 xray-go 组失败，组已保留。" >&2
fi
echo "卸载完成。其他服务、配置和防火墙规则未主动触碰。"
