---
title: "第一次提交：把「行动现场」搬上桌面"
date: 2026-07-23
type: update
cover: images/cover.jpg
tags: [milestone, quickshell, hyprland, actiondesk]
author: "vimalinx"
---

VimaArchConfig 的第一个 commit 落地了 🎉

commit 信息原文：`init: Action Desk quickshell config (three-column todo + terminal worksite)`

这个仓库是我的 Arch / Hyprland 桌面配置。核心就一件事：**Action Desk** —— 整台电脑唯一的「行动与工作现场」层。

里面有什么：

- **三栏 Todo**：今天 / 本周 / 本月 + 长期，按时段分桶
- **终端工作现场**：同一个面板里的第二个标签页，管理终端组合
- `Super+T` 或三指下滑唤出，不用的时候整个 shell 直接退出

代码规模（真实行数）：

- `ActionDesk.qml` 1822 行 —— 三栏 Todo 面板
- `ActionDeskTerminals.qml` 956 行 —— 终端工作现场
- `shell.qml` 主入口，模块化开关：`enableOverview` / `enableActionDesk` / `enableStatusPanel` / `enableTerminalsPanel`，关掉的模块根本不加载，不占内存

依赖：QuickShell + Hyprland，Todo 数据的唯一真相是 `vimalinx-todo` CLI（SQLite 存储）。

个人配置，仅供参考。先发出来，边用边改 ✍️
