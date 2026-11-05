# Xboard-Node-Script

`Xboard-Node-Script` 是一个专注于 Xboard-Node 日常管理的菜单式命令脚本，主命令为 `xns`。

命名含义：

```text
x = Xboard
n = Node
s = Script
```

脚本只处理 Xboard-Node 自身的安装、升级、服务控制和状态检查，不修改其他服务的配置。

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
14. 更新管理脚本            xns update-script
15. 退出
```

## 开发测试

```bash
bash -n Xboard-Node-Script.sh
bash -n install.sh
bash tests/test.sh
```
