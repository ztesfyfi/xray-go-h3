# Xray-go H3 隔离版

基于 [eishare/Xray-go](https://github.com/eishare/Xray-go) 原脚本思路整理的独立 H3 直连版本。仅部署 VLESS + XHTTP + TLS + HTTP/3（QUIC），不部署 REALITY、Argo 或 cloudflared。

> **自用项目，请先审阅脚本再运行。项目按现状提供，不对使用造成的任何损失承担责任。**

## 隔离设计

- 程序、配置、证书、日志和节点信息统一放在独立目录 `/opt/xray-go`。
- 使用独立 Xray 二进制，不替换系统已有的 xray 可执行文件。
- 使用独立 systemd 服务 `xray-go.service` 和无登录系统账户 `xray-go`。
- 安装前检查项目目录、服务文件、账户/组；发现同名资源即停止，不覆盖。
- 安装时在 UDP 20000–60999 范围内随机抽取端口，检查本机 UDP 监听占用；最多尝试 100 次。选定端口写入配置，重启不会重新随机。
- 配置写入后先执行 Xray 配置测试，再启动服务；启动后检查 systemd 活动状态和 UDP 监听。
- 安装失败时，仅回滚本安装器已创建的服务文件、日志轮转配置、项目目录和账户/组。
- 卸载不对项目目录执行递归强制删除，只删除已知的项目文件；未知文件会导致目录和账户/组保留。
- 卸载前校验服务文件标记、ExecStart 和项目目录归属标记；账户/组只有在身份信息与安装记录匹配、且没有其他用户依赖该组时才尝试删除。
- 不运行 apt update，不自动安装或升级系统软件。
- 不修改 UFW、iptables、nftables、系统路由、DNS 或云平台安全组。
- 不停止、覆盖或强杀其他 xray、x-ui、cloudflared。
- 不读写 `/etc/xray`。

> 说明：随机端口的“检查空闲”和进程真正绑定端口之间存在极短竞争窗口；服务启动后仍应确认监听状态。独立目录、进程、账户和端口可以避免常见的配置/文件/监听冲突，但 CPU、内存、磁盘、内核网络栈等系统资源仍由所有程序共享，不能称为硬件级或内核级完全隔离。

## 系统要求

Linux + systemd；root；x86_64、ARM64 或 ARMv7。
预先安装 curl、unzip、openssl、systemctl、ss、awk、grep、sha256sum、tail，以及账户管理和基础文件工具。脚本不会自动安装依赖。
如果系统安装了 logrotate，安装器会创建独立的 `/etc/logrotate.d/xray-go`；未安装 logrotate 时不会自动安装，也不会创建该配置。

## Xray 版本与下载校验

当前脚本固定使用 Xray-core `v26.10.31`，不会自动追随 `latest`。安装器从 Xray 官方 GitHub Release 下载对应架构 ZIP 和同版本 `.dgst` 文件，解析其中的 SHA256 并使用 `sha256sum` 比对；校验缺失、格式异常或不匹配时立即终止，不解压、不安装。
升级版本时需要维护者同步更新版本号并检查官方校验文件格式和各架构资产，再进行静态及生命周期测试。SHA256 校验可检测下载文件与校验文件不一致，但由于二者来自同一发布渠道，本身不等同于独立的发布者签名验证。

## 安装

下载并审阅 `xray-go-safe.sh`，然后运行：

~~~bash
bash xray-go-safe.sh
~~~

脚本会自动随机分配 UDP 高位端口，并询问证书模式：

- **自有域名模式：** 输入域名，再提供与域名匹配的证书文件（建议 fullchain.pem）和私钥文件。脚本检查证书域名、有效期及证书/私钥公钥是否匹配；节点 URI 不添加 `allowInsecure=1`。请确保证书链完整、证书可被客户端信任，并自行负责续期。
- **测试模式：** 域名留空时生成以 `www.bing.com` 为名称的自签名证书，并在节点 URI 中使用 `allowInsecure=1`。这会关闭客户端对服务端证书身份的正常验证，只适合临时测试，不建议用于敏感通信或长期生产使用。

证书和私钥会复制到项目专属目录 `/opt/xray-go/cert`，不会修改用户提供的源文件。节点 URI 保存于 `/opt/xray-go/node.txt`。

查看服务：

~~~bash
systemctl status xray-go --no-pager
journalctl -u xray-go -e --no-pager
ss -lunp
tail -n 50 /opt/xray-go/logs/error.log
~~~

安装器启动后会检查服务状态和 UDP 监听；检查失败时会显示服务状态及最近错误日志，并触发回滚。这是启动层面的健康检查，不代表公网端到端 H3 测试已经成功。

## 日志轮转

检测到系统已有 logrotate 时，安装器创建独立的 `/etc/logrotate.d/xray-go`，每日轮转并保留 7 份，使用 copytruncate，作用范围仅为 `/opt/xray-go/logs/*.log`。如果系统没有 logrotate，脚本不会安装它，日志轮转需要管理员另行安排。

## 防火墙

本项目刻意不自动改防火墙。需在云厂商安全组及 VPS 系统防火墙允许安装时选定端口的 **UDP 入站**。仅开放 TCP 不够。

## H3 兼容性

TLS ALPN 仅设置 h3，Xray 将使用 QUIC/UDP 监听。此配置没有 H2/TCP 回退；网络、运营商或中间防火墙屏蔽 UDP/QUIC 时连接会失败。请在目标网络实测。

## 卸载

下载并审阅 `xray-go-safe-uninstall.sh`，然后运行：

~~~bash
bash xray-go-safe-uninstall.sh
~~~

输入 YES 才会继续。卸载脚本会验证项目标记和服务定义，先停止并移除本项目 systemd 服务。它只删除明确属于本项目的程序、配置、证书、节点文件和 error.log 编号备份，不使用 `rm -rf /opt/xray-go`。如果目录内存在未知文件、额外日志或其他内容，会保留剩余目录及账户/组，避免误删用户数据。若 logrotate 配置被人工修改，也会保留并提示检查。

不会处理普通 xray.service、x-ui、cloudflared、`/etc/xray` 或防火墙规则。

## 当前验证状态

本次更新只提交到 `isolation-hardening` 分支及其草稿 PR，不会连接 VPS，也不会执行部署。上传 GitHub 不代表已经通过 Bash 语法、安装/卸载生命周期或真实公网 H3 测试；合并前仍需在隔离测试环境完成这些验证。
