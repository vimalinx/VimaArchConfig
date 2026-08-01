---
title: "面板按需启停：不用时 QuickShell 直接退出"
date: 2026-07-31
type: photo
cover: images/cover.jpg
tags: [quickshell, ipc, hyprland, 架构]
author: "vimalinx"
---

很多人跑桌面 shell 是常驻内存的。Action Desk 选了另一条路：**按需启停**。

封面是按 `qs-on-demand.sh` 的真实逻辑画的流程图。

**唤起时**（`Super+T` / 三指下滑 → `action-toggle`）：

1. 先试试 `qs ipc call actionDesk toggle` —— 如果实例活着，直接响应
2. 没活着就 `qs --daemonize` 拉起，然后每 0.1s 重试一次 IPC，最多 40 次，每 5 次失败再补拉一次
3. 40 次还没就绪才报错退出

**关闭时**（Esc）：

1. 面板关掉，发起一个延迟 1.8s 的 `quit` 请求
2. 延迟期间如果又打开了别的面板，这次退出作废（重新检查共享 UI 状态）
3. 确认 `shellIdle` 为 true，才 `qs kill` 完全退出

也就是说：不用的时候，QuickShell 进程根本不存在，内存归零。

面板本身通过 IPC 暴露了一组接口：`toggle` / `open` / `close` / `openTerminals` / `toggleTerminals`，终端工作现场（由 `TerminalCombos.py` 驱动，保存/恢复终端组合）和行动清单共用同一个窗口，只是不同标签页。

`shell.qml` 里的注释写得很直白：关掉的模块 "not loaded at all, so rest assured no unnecessary stuff will take up memory" 😌
