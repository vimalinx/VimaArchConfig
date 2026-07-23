# VimaArchConfig

Vimalinx 的 Arch/Hyprland 桌面配置。当前包含 **Action Desk** —— 整台电脑唯一的"行动与工作现场"层：三栏 Todo（今天 / 本周 / 本月 + 长期）+ 终端工作现场，三指下滑或 `Super+T` 唤出。

## 内容

```
quickshell/
├── shell.qml                    # QuickShell 主入口
├── GlobalStates.qml             # 全局面板开关状态（Singleton）
├── config.json                  # UI 主题/缩放配置
├── modules/
│   ├── actiondesk/
│   │   ├── ActionDesk.qml       # 三栏 Todo 面板（行动标签）
│   │   └── ActionDeskTerminals.qml  # 终端工作现场（终端标签）
│   └── common/                  # 共享组件：Appearance/ConfigOptions/Directories + functions/widgets
└── scripts/
    └── qs-on-demand.sh          # 面板按需启停 IPC 入口
```

## 依赖

- [QuickShell](https://quickshell.org/) + Hyprland
- `vimalinx-todo` CLI（Todo 源真相，SQLite）
- `qs` / `quickshell` 命令行

## 安装

```bash
# 1. 复制到 QuickShell 配置目录
cp -r quickshell/* ~/.config/quickshell/

# 2. 确保 shell.qml 中启用 ActionDesk
#    property bool enableActionDesk: true
#    Loader { active: enableActionDesk; sourceComponent: ActionDesk {} }

# 3. 绑定 Super+T / 三指下滑到 qs-on-demand.sh action-toggle
```

## 操作

- `hjkl` / 方向键移动焦点；`g`/`G` 跳栏顶/底
- `Ctrl+hjkl` 调序或换桶；`m` + `t/w/m/l` 指定时段
- `Space` 展开/折叠子任务；`Tab` 建子项；`i` 输入新任务
- `Enter`/`x` 完成；`dd` 删除；`yt` 复制标题

## 许可

个人配置，仅供参考。
