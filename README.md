# Xboard-Node-Script

`Xboard-Node-Script` 是 Xboard-Node 的菜单式管理脚本，主命令为 `xns`。

命名含义：

```text
x = Xboard
n = Node
s = Script
```

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
14. 编辑 config.yml         xns config
15. 编辑 sing_origin.json   xns dns
16. 从 V2bX 一键迁移        xns migrate
17. 回滚到 V2bX             xns rollback
18. 更新管理脚本            xns update-script
19. 退出
```

## 一键迁移

迁移固定使用 Machine mode，只要求输入：

1. 面板地址
2. Machine Token
3. Machine ID

运行：

```bash
sudo xns migrate
```

脚本会执行：

1. 记录 V2bX 当前状态
2. 备份 V2bX 配置
3. 执行 Xboard-Node 官方 Machine mode 安装
4. 如果存在 `/etc/V2bX/sing_origin.json`，复制到 `/etc/xboard-node/sing_origin.json`
5. 在 `config.yml` 中启用 `kernel.custom_config`
6. 停止并禁用 V2bX
7. 启动 Xboard-Node 并做健康检查

迁移不会解析 `/etc/V2bX/config.json` 中的协议、节点或内核。节点由面板分配给 Machine。

V2bX 的程序和配置不会删除。需要恢复时运行：

```bash
sudo xns rollback
```

非交互迁移：

```bash
sudo xns migrate \
  --panel https://import.example.com \
  --token MACHINE_TOKEN \
  --machine-id 4 \
  --health-port 65530 \
  --yes
```

指定其他 sing-box 配置文件：

```bash
--custom-config /path/to/sing_origin.json
```

## 从 V2bX-script 借鉴的功能

- 短命令和数字菜单
- 菜单项对应直接命令
- 启动、停止、重启、状态、日志、开机自启
- 安装、升级、卸载
- 配置修改后自动重启
- 管理脚本原子更新
- 版本显示
- 安装前系统和架构检查

未加入：

- 一键 BBR
- 关闭或清空防火墙
- x25519 密钥生成
- V2bX 配置解析

## 安全说明

- 迁移前备份到 `/etc/xboard-node/backups/migrations/`
- Machine Token 不会写入迁移状态文件
- 非交互命令的 Token 可能留在 shell 历史中，建议优先使用交互模式

## 开发测试

```bash
bash -n Xboard-Node-Script.sh
bash -n install.sh
bash tests/test.sh
```
