# Xboard-Node-Script

`Xboard-Node-Script` 是一个专注于 Xboard-Node 日常管理的菜单式命令脚本，主命令为 `xns`。

命名含义：

```text
x = Xboard
n = Node
s = Script
```

脚本负责 Xboard-Node 的安装、升级、服务控制和状态检查，并提供可选的 SS2022 中转落地安装与更新流程。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/ChampagneA7/Xboard-Node-Script/main/install.sh | sudo bash
```

安装后运行：

```bash
xns
```

也可以使用完整名称：

```bash
Xboard-Node-Script
```

## 菜单

```text
1.  启动 Xboard-Node        xns start
2.  停止 Xboard-Node        xns stop
3.  重启 Xboard-Node        xns restart
4.  查看状态                xns status
5.  查看日志                xns log
6.  安装/重新配置           xns install
7.  升级 Xboard-Node        xns update
8.  卸载 Xboard-Node        xns uninstall
9.  设置开机自启            xns enable
10. 取消开机自启            xns disable
11. 查看版本                xns version
12. 健康检查                xns health
13. 实例列表                xns list
14. 搭建 SS2022 落地       xns relay landing
15. 验证中转并生成配置     xns relay transit
16. 更新 SS2022            xns relay update
17. 更新管理脚本            xns update-script
18. TCP 调优               xns tcp
19. 端口白/黑名单          xns firewall
20. 退出
```

菜单编号也可以直接作为命令使用，例如 `xns 18`、`xns 19`。

## TCP 调优

```bash
xns tcp
```

脚本会下载并校验 `Kylin010/tcpfit` 的 `tcpfit.sh`，随后进入其交互式调优菜单。上游脚本可执行检测、调优、限速、状态查看和回滚；TCP 参数修改前，请先确认机器用途和现有网络策略。

上游地址可通过环境变量覆盖：

```bash
export XBOARD_TCPFIT_URL="https://example.com/tcpfit.sh"
```

## 端口白名单和黑名单

```bash
xns firewall
```

端口策略会自动适配当前系统防火墙，支持 UFW、firewalld、nftables 和 iptables。默认优先使用已启用的 UFW/firewalld，再回退到 nftables/iptables。

- UFW：写入 `before.rules` / `before6.rules` 的独立高优先级链，并随 UFW 原生持久化。
- firewalld：使用高优先级 rich rule，并随 firewalld 原生持久化（需要 firewalld 0.9 及以上）。
- nftables：使用独立的 `inet xns_ports` 表，附带开机 systemd 服务。
- iptables：使用独立的 `XNS_PORTS` 链，附带开机 systemd 服务。

该功能只增加自己的策略，不会删除现有放行规则。

常用命令：

```bash
xns firewall status
xns firewall list
xns firewall whitelist --ports 80,443
xns firewall blacklist --ports 52
xns firewall clear
```

菜单中的 `1` 可以直接查看当前白名单或黑名单列表，也可以随时运行 `xns firewall list`。

数字操作流程：

```text
xns 19
→ 1 查看列表
→ 2 设置白名单
→ 3 设置黑名单
→ 4 清除策略
→ 0 返回主菜单
```

需要强制指定后端时：

```bash
xns firewall whitelist --ports 80,443 --backend ufw --yes
xns firewall blacklist --ports 52 --backend iptables --yes
```

可用后端为 `auto`、`ufw`、`firewalld`、`nftables`、`iptables`。

端口写法：

```text
80,443          TCP 和 UDP 都生效
80/tcp,53/udp   指定协议
1000-2000/tcp   端口范围
```

白名单只放行列出的端口，并自动保留 `22/TCP` 和当前 SSH 端口，避免远程连接被锁死。黑名单禁止列出的端口，且不允许包含 `22/TCP` 或当前 SSH 端口。清除策略后会删除独立规则并恢复原有 UFW/firewalld 行为。

UFW 和 firewalld 使用其原生持久化机制；nftables 和 iptables 使用 `xns-firewall.service` 在开机时恢复。

## SS2022 中转

适合“中转机 + 落地机”结构，例如：

```text
客户端 -> 香港中转机（VLESS + Reality） -> 新加坡落地机（SS2022） -> 目标网站
```

落地机负责安装 SS2022、自动生成密钥和限制来源 IP。中转机负责校验落地端口、输出 Xboard 面板 JSON，并在用户确认已保存后重启 Xboard-Node。当前输出面向 sing-box 内核。

### 落地机

```bash
xns relay landing
```

脚本会：

1. 调用上游 SS2022 安装器的无交互模式，不需要再次进入它的菜单。
2. 只需要输入中转机公网 IPv4，端口自动使用默认值 `8388`。
3. 根据 CPU 自动选择 AES-128-GCM 或 ChaCha20-Poly1305，并自动生成密钥。
4. 首次安装 SS2022；重复执行时自动应用现有配置。
5. 若使用 UFW，自动放行 SSH 并只允许中转机 IP 访问 SS2022 的 TCP/UDP 端口。
6. 若使用 firewalld，自动创建同等来源限制规则。
7. 输出一个 `XNS1:` 开头的落地配对码，供中转机使用。

交互流程只有：

```text
xns
→ 14
→ 输入中转机公网 IPv4
→ 等待安装完成并复制配对码
```

默认 Outbound tag 为中性的 `landing-ss2022`。

云厂商安全组仍需放行：来源为中转机公网 IP，目标为落地机的 SS2022 TCP/UDP 端口。

### 中转机

在中转机运行：

```bash
xns relay transit
```

粘贴落地机输出的 `XNS1:` 配对码后，脚本会：

1. 检查落地机端口是否可达。
2. 保存中转配置。
3. 输出“自定义 Outbounds”和“自定义 Routes”JSON。
4. 询问是否已经在 Xboard 面板保存并提交。
5. 输入 `y` 后自动重启 Xboard-Node，并检查服务健康状态。

也可以直接指定配对码：

```bash
xns relay transit --pair XNS1:...
```

查看之前保存的配置：

```bash
xns relay show
```

### 更新 SS2022

更新 `shadowsocks-rust`，保留端口、密钥和防火墙配置：

```bash
xns relay update
```

更新会从官方 release 下载对应架构的新版本，校验 SHA-256，并在新版本无法启动时自动恢复旧二进制。

配置保存在 `/etc/xboard-node/relay/`，权限为 `600`。面板 JSON 含 SS2022 密钥，不要公开分享。

SS2022 安装复用上游 GPLv3 项目的无交互安装器，本脚本以外部命令方式调用它，不内嵌其源码。上游地址可通过环境变量覆盖：

```bash
export XBOARD_SS2022_INSTALL_URL="https://example.com/install.sh"
```

## 开发测试

```bash
bash -n Xboard-Node-Script.sh
bash -n install.sh
bash tests/test.sh
```
