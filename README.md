# USB Drive Monitor

轻量 macOS 菜单栏监控工具。启动后不弹窗口，只在顶部状态栏出现；点击状态栏项目才打开面板。默认 Eco 模式开启，只读取系统 I/O 统计、USB 挂载事件和系统错误日志，不对 USB 磁盘执行测试读写。

完整需求与验收项见 [REQUIREMENTS.md](REQUIREMENTS.md)。

## 构建

```bash
./build_app.sh
```

产物为 `USBDriveMonitor.app`。构建脚本只负责生成应用包；安装和启动由部署流程单独执行。
