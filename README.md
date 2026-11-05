# Xray-go H3 隔离版

基于 [eishare/Xray-go](https://github.com/eishare/Xray-go) 原脚本思路整理的独立 H3 直连版本。仅部署 VLESS + XHTTP + TLS + HTTP/3（QUIC），不部署 REALITY、Argo 或 cloudflared。

> **自用项目，请先审阅脚本再运行。项目按现状提供，不对使用造成的任何损失承担责任。**

## 隔离设计

- 程序、配置、证书和节点信息统一放在 /opt/xray-go
- 独立 systemd 服务 xray-go.service
- 独立无登录系统账户 xray-go
- 安装前检查目录、服务、账户和 UDP 端口冲突
- 配置写入后先执行 Xray 配置测试，再启用服务
- 不运行 apt update，不自动安装或升级系统软件
- 不修改 UFW、iptables、nftables 或云平台安全组
- 不停止、覆盖或强杀其他 xray、x-ui、cloudflared
- 不读写 /etc/xray

## 系统要求

Linux + systemd；root；x86_64、ARM64 或 ARMv7。
预先安装 curl、unzip、openssl、systemctl、ss、awk、grep。脚本不会自动安装依赖。

## 安装

下载并审阅 xray-go-safe.sh，然后运行：

~~~bash
bash xray-go-safe.sh
~~~

按提示输入 H3 UDP 端口，默认 8443。节点 URI 保存于 /opt/xray-go/node.txt。

查看服务：

~~~bash
systemctl status xray-go --no-pager
journalctl -u xray-go -e --no-pager
~~~

## 防火墙

本项目刻意不自动改防火墙。需在云厂商安全组及 VPS 系统防火墙允许所选端口的 **UDP 入站**。仅开放 TCP 不够。

## TLS 与安全提醒

当前版本生成以 www.bing.com 为名称的自签名证书，节点 URI 使用 allowInsecure=1，以便没有域名和可信证书时进行测试连接。这会关闭客户端对服务端证书身份的正常验证，存在中间人攻击风险，不建议用于敏感通信或长期生产使用。更安全的后续版本应使用自有域名和可信 CA 证书，并移除 allowInsecure=1。

## H3 兼容性

TLS ALPN 仅设置 h3，Xray 将使用 QUIC/UDP 监听。此配置没有 H2/TCP 回退；网络、运营商或中间防火墙屏蔽 UDP/QUIC 时连接会失败。请在目标网络实测。

## 卸载

下载并审阅 xray-go-safe-uninstall.sh，然后运行：

~~~bash
bash xray-go-safe-uninstall.sh
~~~

输入 YES 才会继续。卸载只处理 xray-go.service、/opt/xray-go 和本安装器创建的同名账户/组。不会处理普通 xray.service、x-ui、cloudflared、/etc/xray 或防火墙规则。
