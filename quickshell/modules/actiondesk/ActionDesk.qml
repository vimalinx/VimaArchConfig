import "root:/"
import "root:/modules/common"
import "root:/modules/common/functions/string_utils.js" as StringUtils
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

// The three-finger layer: durable actions and the terminal worksite share one
// surface. Launching apps, managing windows, notifications and agent monitoring
// deliberately live elsewhere.
Scope {
    id: desk

    readonly property string cli: "/home/vimalinx/.local/bin/vimalinx-todo"
    readonly property string uiFont: "Noto Sans CJK SC"
    readonly property string monoFont: "JetBrains Mono"

    readonly property color canvas: "#090b0e"
    readonly property color paper: "#11151a"
    readonly property color paperRaised: "#171c22"
    readonly property color paperHover: "#1d232a"
    readonly property color line: "#29313a"
    readonly property color lineStrong: "#3a444f"
    readonly property color ink: "#f4f0e8"
    readonly property color inkSoft: "#c4c1bb"
    readonly property color inkMute: "#7d858e"
    readonly property color accent: "#e6b85c"
    readonly property color accentSoft: "#3a3020"
    readonly property color positive: "#78b9a7"
    readonly property color danger: "#d78f86"

    property var state: ({
        "revision": 0,
        "tasks": [],
        "recent_done": [],
        "counts": {"today": 0, "week": 0, "month": 0, "later": 0, "open": 0, "done": 0},
        "latest_plan": null,
        "ai": {"model": "deepseek-v4-flash", "config": "~/.omp/agent/models.yml", "configured": false}
    })
    property date now: new Date()
    property string notice: ""
    property string noticeTone: "neutral"
    property string pendingAction: ""
    property bool loading: false
    property string activeTab: "actions"

    // list = hjkl navigation; insert = capture field
    property string navMode: "list"
    property int focusColumn: 0
    property int focusIndex: 0
    property int focusScrollNonce: 0
    property string insertParentId: ""
    property string insertParentTitle: ""
    property var expandedParents: ({})
    property string pendingFocusId: ""
    property string chord: ""
    property var lastRepeat: null
    property string fadingTaskId: ""
    property double lastSpaceAt: 0

    readonly property bool listReady: GlobalStates.actionDeskOpen && activeTab === "actions" && navMode === "list"
    readonly property bool listFree: listReady && chord.length === 0

    readonly property var columnDefs: [
        {"key": "today", "title": "今天", "subtitle": "今日承诺推进"},
        {"key": "week", "title": "本周", "subtitle": "本周内做完"},
        {"key": "month", "title": "本月", "subtitle": "本月 + 长期"}
    ]

    function tasksForBucket(bucket) {
        const source = state.tasks || []
        const result = []
        for (let i = 0; i < source.length; i++) {
            const task = source[i]
            if (task?.parent_id) continue
            if (String(task?.bucket || "today") === bucket) result.push(task)
        }
        return result
    }

    function columnTasks(column) {
        if (column === 0) return tasksForBucket("today")
        if (column === 1) return tasksForBucket("week")
        return tasksForBucket("month").concat(tasksForBucket("later"))
    }

    // Flat focus list: root, then children only when that parent is expanded
    function columnNavItems(column) {
        const roots = columnTasks(column)
        const items = []
        for (let r = 0; r < roots.length; r++) {
            const root = roots[r]
            items.push({"task": root, "depth": 0})
            if (!isExpanded(String(root.id || ""))) continue
            const kids = root.children || []
            for (let c = 0; c < kids.length; c++) {
                items.push({"task": kids[c], "depth": 1})
            }
        }
        return items
    }

    function isExpanded(taskId) {
        const id = String(taskId || "")
        if (!id) return false
        return !!(expandedParents && expandedParents[id])
    }

    function setExpanded(taskId, value) {
        const id = String(taskId || "")
        if (!id) return
        const next = Object.assign({}, expandedParents || {})
        if (value) next[id] = true
        else delete next[id]
        expandedParents = next
    }

    function toggleExpanded(taskId) {
        setExpanded(taskId, !isExpanded(taskId))
    }

    function monthSectionCount() {
        return tasksForBucket("month").length
    }

    function bucketName(bucket) {
        if (bucket === "week") return "本周"
        if (bucket === "month") return "本月"
        if (bucket === "later") return "长期"
        return "今天"
    }

    function nextBucket(bucket) {
        if (bucket === "today") return "week"
        if (bucket === "week") return "month"
        if (bucket === "month") return "later"
        return "today"
    }

    function prevBucket(bucket) {
        if (bucket === "week") return "today"
        if (bucket === "month") return "week"
        if (bucket === "later") return "month"
        return "later"
    }

    function taskMeta(task) {
        const parts = []
        const kids = task?.children || []
        if (kids.length > 0) {
            const openKids = kids.filter(c => String(c?.status || "open") === "open").length
            const mark = isExpanded(String(task?.id || "")) ? "▾" : "▸"
            parts.push(`${mark} 子项 ${openKids}/${kids.length}`)
        }
        if (task?.project_ref) parts.push(String(task.project_ref))
        if (task?.due_at) parts.push(`截止 ${String(task.due_at)}`)
        if (task?.estimate_minutes) parts.push(`${Number(task.estimate_minutes)} 分钟`)
        if (String(task?.priority || "normal") === "urgent") parts.push("紧急")
        else if (String(task?.priority || "normal") === "high") parts.push("高优先")
        return parts.join("  ·  ")
    }

    function focusedAddBucket() {
        if (focusColumn === 0) return "today"
        if (focusColumn === 1) return "week"
        const task = focusedTask()
        if (task) {
            const bucket = String(task.bucket || "month")
            if (bucket === "later" || bucket === "month") return bucket
        }
        return "month"
    }

    function setNotice(message, tone) {
        notice = String(message || "")
        noticeTone = tone || "neutral"
    }

    function refresh() {
        if (snapshotProcess.running) return
        loading = true
        snapshotProcess.command = [cli, "snapshot"]
        snapshotProcess.running = true
    }

    function runAction(args, action, busyMessage) {
        if (actionProcess.running || !args || args.length === 0) return
        pendingAction = action
        setNotice(busyMessage || "处理中…", "neutral")
        actionProcess.command = [cli].concat(args)
        actionProcess.running = true
    }

    function addTask(title) {
        const clean = String(title || "").trim()
        if (!clean) return
        const args = ["add", clean, "--source", "quickshell"]
        if (desk.insertParentId.length > 0) {
            const similar = findSimilarTitle(clean, null, desk.insertParentId)
            if (similar)
                setNotice(`注意：父项下已有相似「${similar}」`, "neutral")
            args.push("--parent", desk.insertParentId)
            setExpanded(desk.insertParentId, true)
            runAction(args, "add", "正在记下子项…")
        } else {
            const bucket = focusedAddBucket()
            const similar = findSimilarTitle(clean, bucket, null)
            if (similar)
                setNotice(`注意：${bucketName(bucket)}已有相似「${similar}」`, "neutral")
            args.push("--bucket", bucket)
            runAction(args, "add", `正在记下到“${bucketName(bucket)}”…`)
        }
    }

    function findSimilarTitle(title, bucket, parentId) {
        const needle = String(title || "").trim().toLowerCase()
        if (!needle) return ""
        if (parentId) {
            const roots = state.tasks || []
            for (let i = 0; i < roots.length; i++) {
                if (String(roots[i]?.id || "") !== String(parentId)) continue
                const kids = roots[i].children || []
                for (let c = 0; c < kids.length; c++) {
                    const other = String(kids[c]?.title || "").trim()
                    if (other.toLowerCase() === needle) return other
                }
            }
            return ""
        }
        const roots = tasksForBucket(bucket)
        for (let i = 0; i < roots.length; i++) {
            const other = String(roots[i]?.title || "").trim()
            if (other.toLowerCase() === needle) return other
        }
        return ""
    }

    function completeTask(taskId) {
        runAction(["complete", String(taskId)], "complete", "正在完成…")
    }

    function reopenTask(taskId) {
        runAction(["reopen", String(taskId)], "reopen", "正在恢复…")
    }

    function toggleTask(taskId) {
        runAction(["toggle", String(taskId)], "toggle", "切换完成状态…")
    }

    function deleteTask(taskId) {
        runAction(["delete", String(taskId)], "delete", "正在删除…")
    }

    function moveTask(taskId, bucket) {
        runAction(["bucket", String(taskId), String(bucket)], "bucket", `移到“${bucketName(bucket)}”…`)
    }

    function reorderTask(taskId, direction) {
        runAction(["reorder", String(taskId), String(direction)], "reorder", direction === "up" ? "上移…" : "下移…")
    }

    function rememberRepeat(kind, payload) {
        lastRepeat = {"kind": kind, "payload": payload || {}}
    }

    function clearChord() {
        chord = ""
        chordTimer.stop()
    }

    function armChord(next) {
        chord = String(next || "")
        if (chord.length === 0) {
            chordTimer.stop()
            return
        }
        chordTimer.restart()
        if (chord === "d") setNotice("再按 d 删除 · Esc 取消", "neutral")
        else if (chord === "y") setNotice("再按 t 复制标题 · Esc 取消", "neutral")
        else if (chord === "m") setNotice("t今天 w本周 m本月 l长期 · Esc 取消", "neutral")
    }

    function focusedNavItem() {
        const items = columnNavItems(focusColumn)
        if (focusIndex < 0 || focusIndex >= items.length) return null
        return items[focusIndex]
    }

    function focusedTask() {
        return focusedNavItem()?.task || null
    }

    function clampFocus() {
        const items = columnNavItems(focusColumn)
        if (items.length === 0) {
            focusIndex = 0
            return
        }
        if (focusIndex < 0) focusIndex = 0
        if (focusIndex >= items.length) focusIndex = items.length - 1
    }

    function ensureDefaultFocus() {
        // Always prefer today column
        focusColumn = 0
        focusIndex = 0
        clampFocus()
    }

    function focusTaskById(taskId) {
        const target = String(taskId || "")
        if (!target) return false
        for (let col = 0; col < 3; col++) {
            const items = columnNavItems(col)
            for (let i = 0; i < items.length; i++) {
                if (String(items[i]?.task?.id || "") === target) {
                    focusColumn = col
                    focusIndex = i
                    focusScrollNonce += 1
                    return true
                }
            }
        }
        return false
    }

    function jumpFocusEdge(toEnd) {
        clearChord()
        const items = columnNavItems(focusColumn)
        if (items.length === 0) {
            focusIndex = 0
            return
        }
        focusIndex = toEnd ? items.length - 1 : 0
        focusScrollNonce += 1
    }

    function collapseColumn(column) {
        const roots = columnTasks(column)
        const next = Object.assign({}, expandedParents || {})
        let changed = false
        for (let i = 0; i < roots.length; i++) {
            const id = String(roots[i]?.id || "")
            if (id && next[id]) {
                delete next[id]
                changed = true
            }
        }
        if (changed) expandedParents = next
        clampFocus()
        focusScrollNonce += 1
        setNotice("已折叠本栏子项", "neutral")
    }

    function columnProgress(column) {
        const completed = state.counts?.completed_today || {}
        if (column === 0) {
            const openN = Number(state.counts?.today || 0)
            const doneN = Number(completed.today || 0)
            return {"done": doneN, "open": openN, "total": doneN + openN}
        }
        if (column === 1) {
            const openN = Number(state.counts?.week || 0)
            const doneN = Number(completed.week || 0)
            return {"done": doneN, "open": openN, "total": doneN + openN}
        }
        const openN = Number(state.counts?.month || 0) + Number(state.counts?.later || 0)
        const doneN = Number(completed.month || 0) + Number(completed.later || 0)
        return {"done": doneN, "open": openN, "total": doneN + openN}
    }

    function enterListMode() {
        navMode = "list"
        insertParentId = ""
        insertParentTitle = ""
        clearChord()
        clampFocus()
        captureInput.focus = false
        sheet.forceActiveFocus()
    }

    function enterInsertMode() {
        clearChord()
        navMode = "insert"
        insertParentId = ""
        insertParentTitle = ""
        captureInput.forceActiveFocus()
    }

    function enterInsertChildMode() {
        clearChord()
        const task = focusedTask()
        if (!task) return
        let parentId = ""
        let parentTitle = ""
        if (task.parent_id) {
            parentId = String(task.parent_id)
            const items = columnNavItems(focusColumn)
            for (let i = 0; i < items.length; i++) {
                const candidate = items[i]?.task
                if (candidate && String(candidate.id || "") === parentId) {
                    parentTitle = String(candidate.title || "")
                    break
                }
            }
            if (!parentTitle) parentTitle = "父项"
        } else {
            parentId = String(task.id || "")
            parentTitle = String(task.title || "")
        }
        if (!parentId) return
        setExpanded(parentId, true)
        navMode = "insert"
        insertParentId = parentId
        insertParentTitle = parentTitle
        captureInput.forceActiveFocus()
    }

    function moveFocusRow(delta) {
        clearChord()
        const items = columnNavItems(focusColumn)
        if (items.length === 0) return
        focusIndex = Math.max(0, Math.min(items.length - 1, focusIndex + delta))
        focusScrollNonce += 1
    }

    function moveFocusColumn(delta) {
        clearChord()
        const next = Math.max(0, Math.min(2, focusColumn + delta))
        if (next === focusColumn) return
        focusColumn = next
        const items = columnNavItems(focusColumn)
        focusIndex = items.length === 0 ? 0 : Math.min(focusIndex, items.length - 1)
        focusScrollNonce += 1
    }

    function selectTask(column, index) {
        clearChord()
        focusColumn = column
        focusIndex = index
        enterListMode()
        focusScrollNonce += 1
    }

    function toggleFocused() {
        clearChord()
        const task = focusedTask()
        if (!task) return
        const taskId = String(task.id || "")
        const willComplete = String(task.status || "open") === "open"
        rememberRepeat("toggle", {})
        if (willComplete) {
            fadingTaskId = taskId
            fadeCommitTimer.taskId = taskId
            fadeCommitTimer.restart()
            return
        }
        toggleTask(taskId)
    }

    function spaceFocused() {
        clearChord()
        const now = Date.now()
        if (lastSpaceAt > 0 && (now - lastSpaceAt) < 380) {
            lastSpaceAt = 0
            collapseColumn(focusColumn)
            return
        }
        lastSpaceAt = now
        const task = focusedTask()
        if (!task) return
        if (!task.parent_id) {
            const kids = task.children || []
            if (kids.length > 0) {
                toggleExpanded(String(task.id || ""))
                clampFocus()
                focusScrollNonce += 1
                setNotice(isExpanded(String(task.id || "")) ? "已展开子项 · 再按 Space 折叠本栏" : "已折叠子项", "neutral")
                return
            }
        }
        rememberRepeat("toggle", {})
        toggleTask(String(task.id || ""))
    }

    function deleteFocused() {
        const task = focusedTask()
        if (!task) return
        const taskId = String(task.id || "")
        rememberRepeat("delete", {})
        fadingTaskId = taskId
        fadeDeleteTimer.taskId = taskId
        fadeDeleteTimer.restart()
    }

    function yankFocusedTitle() {
        clearChord()
        const task = focusedTask()
        if (!task) return
        const title = String(task.title || "")
        if (!title) return
        Hyprland.dispatch(`exec bash -lc "printf %s '${StringUtils.shellSingleQuoteEscape(title)}' | wl-copy"`)
        setNotice("已复制标题", "success")
    }

    function moveFocusedToBucket(bucket) {
        clearChord()
        const task = focusedTask()
        if (!task) return
        if (task.parent_id) {
            setNotice("子项跟随父项时段，请移动父 Todo", "error")
            return
        }
        rememberRepeat("bucket", {"bucket": bucket})
        moveTask(String(task.id || ""), bucket)
    }

    function repeatLast() {
        clearChord()
        if (!lastRepeat || !lastRepeat.kind) {
            setNotice("还没有可重复的动作", "neutral")
            return
        }
        const kind = String(lastRepeat.kind)
        const payload = lastRepeat.payload || {}
        if (kind === "reorder") {
            const direction = String(payload.direction || "down")
            nudgeFocusedOrder(direction === "up" ? -1 : 1)
        } else if (kind === "bucket") {
            moveFocusedToBucket(String(payload.bucket || "today"))
        } else if (kind === "toggle") {
            toggleFocused()
        } else if (kind === "delete") {
            deleteFocused()
        }
    }

    function undoLast() {
        clearChord()
        runAction(["undo"], "undo", "正在回退…")
    }

    function completeFocused() {
        toggleFocused()
    }

    function cycleFocusedBucket() {
        const task = focusedTask()
        if (!task || task.parent_id) return
        const target = nextBucket(String(task.bucket || "today"))
        rememberRepeat("bucket", {"bucket": target})
        moveTask(String(task.id || ""), target)
    }

    function nudgeFocusedBucket(delta) {
        clearChord()
        const task = focusedTask()
        if (!task) return
        if (task.parent_id) {
            setNotice("子项跟随父项时段，请移动父 Todo", "error")
            return
        }
        const current = String(task.bucket || "today")
        const target = delta < 0 ? prevBucket(current) : nextBucket(current)
        if (target === current) return
        rememberRepeat("bucket", {"bucket": target})
        moveTask(String(task.id || ""), target)
    }

    function nudgeFocusedOrder(delta) {
        clearChord()
        const task = focusedTask()
        if (!task) return
        const direction = delta < 0 ? "up" : "down"
        rememberRepeat("reorder", {"direction": direction})
        reorderTask(String(task.id || ""), direction)
    }

    function openDesk() {
        GlobalStates.overviewOpen = false
        GlobalStates.statusPanelOpen = false
        GlobalStates.terminalsPanelOpen = false
        GlobalStates.actionDeskOpen = true
    }

    function showActions() {
        activeTab = "actions"
        openDesk()
    }

    function showTerminals() {
        activeTab = "terminals"
        openDesk()
        terminalWorkspace.refresh()
    }

    function toggleTerminals() {
        if (GlobalStates.actionDeskOpen && activeTab === "terminals") closeDesk()
        else showTerminals()
    }

    function closeDesk() {
        GlobalStates.actionDeskOpen = false
        requestShellIdleQuit(1800)
    }

    function requestShellIdleQuit(delayMs) {
        if (GlobalStates.actionDeskOpen || GlobalStates.overviewOpen
                || GlobalStates.statusPanelOpen || GlobalStates.terminalsPanelOpen) return
        Hyprland.dispatch(`exec bash -lc '${Directories.shellConfig}/scripts/qs-on-demand.sh quit ${delayMs || 1800}'`)
    }

    function handleEscape() {
        if (desk.activeTab === "actions" && desk.chord.length > 0) {
            desk.clearChord()
            desk.setNotice("", "neutral")
            return
        }
        if (desk.activeTab === "terminals" && terminalWorkspace.cancelTransient()) return
        if (desk.activeTab === "actions" && desk.navMode === "insert") {
            desk.enterListMode()
            return
        }
        desk.closeDesk()
    }

    Timer {
        interval: 1000
        repeat: true
        running: GlobalStates.actionDeskOpen
        onTriggered: desk.now = new Date()
    }

    Timer {
        interval: 5000
        repeat: true
        running: GlobalStates.actionDeskOpen && desk.activeTab === "actions"
        onTriggered: desk.refresh()
    }

    Timer {
        id: focusDelay
        interval: 120
        repeat: false
        onTriggered: {
            if (desk.activeTab === "actions") desk.enterListMode()
            else terminalWorkspace.focusDefault()
        }
    }

    Timer {
        id: chordTimer
        interval: 900
        repeat: false
        onTriggered: {
            desk.clearChord()
            desk.setNotice("和弦已取消", "neutral")
        }
    }

    Timer {
        id: fadeCommitTimer
        interval: 170
        repeat: false
        property string taskId: ""
        onTriggered: {
            if (taskId.length > 0) desk.toggleTask(taskId)
        }
    }

    Timer {
        id: fadeDeleteTimer
        interval: 170
        repeat: false
        property string taskId: ""
        onTriggered: {
            if (taskId.length > 0) desk.deleteTask(taskId)
        }
    }

    Process {
        id: snapshotProcess
        stdout: SplitParser {
            onRead: data => {
                try {
                    const parsed = JSON.parse(data)
                    if (parsed.success) {
                        const preferId = desk.pendingFocusId || desk.focusedTask()?.id
                        desk.state = parsed
                        if (preferId) {
                            const tasks = desk.state.tasks || []
                            for (let i = 0; i < tasks.length; i++) {
                                const root = tasks[i]
                                const kids = root?.children || []
                                for (let c = 0; c < kids.length; c++) {
                                    if (String(kids[c]?.id || "") === String(preferId)) {
                                        desk.setExpanded(String(root.id || ""), true)
                                        break
                                    }
                                }
                            }
                            if (!desk.focusTaskById(preferId)) {
                                desk.focusColumn = Math.max(0, Math.min(2, desk.focusColumn))
                                desk.clampFocus()
                            }
                            desk.pendingFocusId = ""
                        } else {
                            desk.ensureDefaultFocus()
                        }
                        if (desk.navMode === "list" && desk.activeTab === "actions")
                            sheet.forceActiveFocus()
                    } else desk.setNotice(parsed.error || "Todo 读取失败", "error")
                } catch (error) {
                    desk.setNotice("Todo 状态解析失败", "error")
                }
            }
        }
        stderr: SplitParser {
            onRead: data => {
                const message = String(data || "").trim()
                if (message.length > 0) desk.setNotice(message.slice(0, 140), "error")
            }
        }
        onExited: exitCode => {
            desk.loading = false
            if (exitCode !== 0 && desk.notice.length === 0) desk.setNotice(`Todo 读取失败 · exit ${exitCode}`, "error")
        }
    }

    Process {
        id: actionProcess
        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data)
                    if (!result.success) {
                        desk.setNotice(result.error || "操作失败", "error")
                        desk.fadingTaskId = ""
                        return
                    }
                    if (desk.pendingAction === "add") {
                        const wasChild = desk.insertParentId.length > 0
                        const parentId = desk.insertParentId
                        const bucket = String(result.task?.bucket || desk.focusedAddBucket())
                        if (result.task?.id) desk.pendingFocusId = String(result.task.id)
                        if (wasChild && parentId) desk.setExpanded(parentId, true)
                        captureInput.text = ""
                        desk.setNotice(wasChild ? "已加入子项" : `已加入“${desk.bucketName(bucket)}”顶端`, "success")
                        desk.enterListMode()
                    } else if (desk.pendingAction === "complete") {
                        desk.setNotice("完成了。Enter/x 可再切换回来。", "success")
                    } else if (desk.pendingAction === "reopen") {
                        desk.setNotice("已恢复到行动清单", "success")
                    } else if (desk.pendingAction === "toggle") {
                        desk.setNotice("已切换完成状态", "success")
                        desk.fadingTaskId = ""
                    } else if (desk.pendingAction === "delete") {
                        desk.setNotice("已删除 · u/z 可回退", "success")
                        desk.fadingTaskId = ""
                    } else if (desk.pendingAction === "undo") {
                        desk.setNotice("已回退上一步", "success")
                        desk.fadingTaskId = ""
                    } else if (desk.pendingAction === "bucket") {
                        desk.setNotice("已调整时段", "success")
                    } else if (desk.pendingAction === "reorder") {
                        desk.setNotice("已调整顺序", "success")
                    }
                } catch (error) {
                    desk.setNotice("操作结果解析失败", "error")
                }
            }
        }
        stderr: SplitParser {
            onRead: data => {
                const message = String(data || "").trim()
                if (message.length > 0) desk.setNotice(message.slice(0, 140), "error")
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0 && desk.noticeTone !== "error") desk.setNotice(`操作失败 · exit ${exitCode}`, "error")
            if (exitCode !== 0) desk.fadingTaskId = ""
            desk.pendingAction = ""
            desk.refresh()
        }
    }

    Connections {
        target: GlobalStates
        function onActionDeskOpenChanged() {
            if (GlobalStates.actionDeskOpen) {
                desk.setNotice("", "neutral")
                desk.navMode = "list"
                if (desk.activeTab === "actions") {
                    desk.refresh()
                    desk.ensureDefaultFocus()
                } else terminalWorkspace.refresh()
                focusDelay.restart()
            } else {
                desk.requestShellIdleQuit(1800)
            }
        }
    }

    PanelWindow {
        id: root
        screen: {
            const monitor = Hyprland.focusedMonitor
            const screens = Quickshell.screens
            if (!monitor) return screens[0]
            for (let index = 0; index < screens.length; index++) {
                if (screens[index].name === monitor.name) return screens[index]
            }
            return screens[0]
        }
        visible: GlobalStates.actionDeskOpen
        color: "transparent"
        WlrLayershell.namespace: "quickshell:action-desk"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: GlobalStates.actionDeskOpen
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.exclusiveZone: -1
        anchors { top: true; bottom: true; left: true; right: true }

        Rectangle {
            anchors.fill: parent
            color: desk.canvas
            opacity: 0.84
            MouseArea {
                anchors.fill: parent
                onClicked: desk.closeDesk()
            }
        }

        Rectangle {
            id: sheet
            width: Math.min(root.width - 48, 1460)
            height: Math.max(620, root.height - 76)
            x: Math.round((root.width - width) / 2)
            y: GlobalStates.actionDeskOpen ? 46 : -height
            radius: 18
            color: desk.paper
            border.width: 1
            border.color: desk.lineStrong
            clip: true
            focus: true

            Behavior on y {
                NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: mouse => mouse.accepted = true
            }

            Shortcut {
                sequence: "Escape"
                enabled: GlobalStates.actionDeskOpen
                onActivated: desk.handleEscape()
            }

            Shortcut {
                sequence: "Ctrl+1"
                enabled: GlobalStates.actionDeskOpen
                onActivated: desk.showActions()
            }

            Shortcut {
                sequence: "Ctrl+2"
                enabled: GlobalStates.actionDeskOpen
                onActivated: desk.showTerminals()
            }

            // List-mode vim + arrow navigation
            Shortcut {
                sequences: ["j", "Down"]
                enabled: desk.listFree
                onActivated: desk.moveFocusRow(1)
            }
            Shortcut {
                sequences: ["k", "Up"]
                enabled: desk.listFree
                onActivated: desk.moveFocusRow(-1)
            }
            Shortcut {
                sequences: ["h", "Left"]
                enabled: desk.listFree
                onActivated: desk.moveFocusColumn(-1)
            }
            Shortcut {
                sequences: ["l", "Right"]
                enabled: desk.listFree
                onActivated: desk.moveFocusColumn(1)
            }
            Shortcut {
                sequences: ["g"]
                enabled: desk.listFree
                onActivated: desk.jumpFocusEdge(false)
            }
            Shortcut {
                sequences: ["G"]
                enabled: desk.listFree
                onActivated: desk.jumpFocusEdge(true)
            }
            // Ctrl+hjkl / Ctrl+arrows: move the focused Todo
            Shortcut {
                sequences: ["Ctrl+j", "Ctrl+Down"]
                enabled: desk.listFree
                onActivated: desk.nudgeFocusedOrder(1)
            }
            Shortcut {
                sequences: ["Ctrl+k", "Ctrl+Up"]
                enabled: desk.listFree
                onActivated: desk.nudgeFocusedOrder(-1)
            }
            Shortcut {
                sequences: ["Ctrl+h", "Ctrl+Left"]
                enabled: desk.listFree
                onActivated: desk.nudgeFocusedBucket(-1)
            }
            Shortcut {
                sequences: ["Ctrl+l", "Ctrl+Right"]
                enabled: desk.listFree
                onActivated: desk.nudgeFocusedBucket(1)
            }
            Shortcut {
                sequences: ["i", "/"]
                enabled: desk.listFree
                onActivated: desk.enterInsertMode()
            }
            Shortcut {
                sequences: ["Tab"]
                enabled: desk.listFree
                onActivated: desk.enterInsertChildMode()
            }
            Shortcut {
                sequences: ["Return", "Enter", "x"]
                enabled: desk.listFree
                onActivated: desk.toggleFocused()
            }
            Shortcut {
                sequences: ["Space"]
                enabled: desk.listFree
                onActivated: desk.spaceFocused()
            }
            Shortcut {
                sequences: ["z", "u"]
                enabled: desk.listFree
                onActivated: desk.undoLast()
            }
            Shortcut {
                sequences: ["."]
                enabled: desk.listFree
                onActivated: desk.repeatLast()
            }
            Shortcut {
                sequences: [">"]
                enabled: desk.listFree
                onActivated: desk.cycleFocusedBucket()
            }
            // Chord starters
            Shortcut {
                sequences: ["d"]
                enabled: desk.listFree
                onActivated: desk.armChord("d")
            }
            Shortcut {
                sequences: ["y"]
                enabled: desk.listFree
                onActivated: desk.armChord("y")
            }
            Shortcut {
                sequences: ["m"]
                enabled: desk.listFree
                onActivated: desk.armChord("m")
            }
            // Chord completions
            Shortcut {
                sequences: ["d"]
                enabled: desk.listReady && desk.chord === "d"
                onActivated: {
                    desk.clearChord()
                    desk.deleteFocused()
                }
            }
            Shortcut {
                sequences: ["t"]
                enabled: desk.listReady && desk.chord === "y"
                onActivated: desk.yankFocusedTitle()
            }
            Shortcut {
                sequences: ["t"]
                enabled: desk.listReady && desk.chord === "m"
                onActivated: desk.moveFocusedToBucket("today")
            }
            Shortcut {
                sequences: ["w"]
                enabled: desk.listReady && desk.chord === "m"
                onActivated: desk.moveFocusedToBucket("week")
            }
            Shortcut {
                sequences: ["m"]
                enabled: desk.listReady && desk.chord === "m"
                onActivated: desk.moveFocusedToBucket("month")
            }
            Shortcut {
                sequences: ["l"]
                enabled: desk.listReady && desk.chord === "m"
                onActivated: desk.moveFocusedToBucket("later")
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    spacing: 16

                    ColumnLayout {
                        spacing: 1
                        Text {
                            text: "ACTION DESK"
                            color: desk.accent
                            font.family: desk.monoFont
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            font.letterSpacing: 2.2
                        }
                        Text {
                            text: desk.activeTab === "actions" ? "今天 · 本周 · 本月" : "把工作现场接回来"
                            color: desk.ink
                            font.family: desk.uiFont
                            font.pixelSize: 25
                            font.weight: Font.DemiBold
                        }
                    }

                    Rectangle { width: 1; Layout.preferredHeight: 38; color: desk.line }

                    ColumnLayout {
                        spacing: 2
                        Text {
                            text: Qt.formatDate(desk.now, "M月d日 dddd")
                            color: desk.inkSoft
                            font.family: desk.uiFont
                            font.pixelSize: 14
                        }
                        Text {
                            text: desk.activeTab === "actions"
                                ? `${Qt.formatTime(desk.now, "HH:mm")}  ·  ${Number(desk.state.counts?.open || 0)} 件  ·  ${desk.navMode === "list" ? "列表 hjkl" : "输入 i"}`
                                : `${Qt.formatTime(desk.now, "HH:mm")}  ·  ${terminalWorkspace.comboCount} 套终端组合`
                            color: desk.inkMute
                            font.family: desk.monoFont
                            font.pixelSize: 11
                        }
                    }

                    Item { Layout.fillWidth: true }

                    DeskTab {
                        label: "行动"
                        meta: String(Number(desk.state.counts?.open || 0))
                        selected: desk.activeTab === "actions"
                        onTriggered: desk.showActions()
                    }

                    DeskTab {
                        label: "终端"
                        meta: terminalWorkspace.currentComboName
                        selected: desk.activeTab === "terminals"
                        onTriggered: desk.showTerminals()
                    }

                    Text {
                        text: "g/G · . · dd · yt · m · Space×2"
                        color: desk.inkMute
                        font.family: desk.monoFont
                        font.pixelSize: 10
                    }

                    DeskButton {
                        label: "关闭"
                        kind: "ghost"
                        onTriggered: desk.closeDesk()
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: desk.line }

                Rectangle {
                    visible: desk.activeTab === "actions"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 58
                    Layout.topMargin: 14
                    Layout.bottomMargin: 14
                    radius: 12
                    color: desk.paperRaised
                    border.width: captureInput.activeFocus ? 1 : 0
                    border.color: desk.accent

                    Behavior on border.width {
                        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                    }

                    MouseArea {
                        anchors.fill: parent
                        z: 0
                        cursorShape: Qt.IBeamCursor
                        onClicked: desk.enterInsertMode()
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 10
                        spacing: 12
                        z: 1

                        Text {
                            text: desk.navMode === "insert" ? "▌" : "+"
                            color: desk.accent
                            font.family: desk.monoFont
                            font.pixelSize: 20
                            font.weight: Font.Light
                        }
                        TextField {
                            id: captureInput
                            Layout.fillWidth: true
                            selectByMouse: true
                            placeholderText: desk.navMode === "list"
                                ? `按 i 记到「${desk.bucketName(desk.focusedAddBucket())}」顶端 · Tab 建子项…`
                                : (desk.insertParentId.length > 0
                                    ? `子项 · ${desk.insertParentTitle || "父项"}`
                                    : `记到「${desk.bucketName(desk.focusedAddBucket())}」顶端…`)
                            placeholderTextColor: desk.inkMute
                            color: desk.ink
                            font.family: desk.uiFont
                            font.pixelSize: 16
                            background: Item {}
                            Keys.onReturnPressed: desk.addTask(text)
                            Keys.onEnterPressed: desk.addTask(text)
                            Keys.onEscapePressed: desk.enterListMode()
                            onActiveFocusChanged: {
                                if (activeFocus) desk.navMode = "insert"
                            }
                        }
                        Text {
                            text: "Enter"
                            color: desk.inkMute
                            font.family: desk.monoFont
                            font.pixelSize: 10
                        }
                        DeskButton {
                            label: desk.insertParentId.length > 0
                                ? "加入子项"
                                : `加入${desk.bucketName(desk.focusedAddBucket())}`
                            kind: "primary"
                            enabled: captureInput.text.trim().length > 0 && !actionProcess.running
                            onTriggered: desk.addTask(captureInput.text)
                        }
                    }
                }

                RowLayout {
                    visible: desk.activeTab === "actions"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 14

                    Repeater {
                        model: 3
                        delegate: TodoColumn {
                            required property int index
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: (desk.focusColumn === index ? 3 : 1) * 100
                            Layout.minimumWidth: 110
                            columnIndex: index

                            Behavior on Layout.preferredWidth {
                                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }

                ActionDeskTerminals {
                    id: terminalWorkspace
                    visible: desk.activeTab === "terminals"
                    active: GlobalStates.actionDeskOpen && desk.activeTab === "terminals"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: 16
                    Layout.bottomMargin: 4
                    onRequestClose: desk.closeDesk()
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    Layout.topMargin: 8
                    spacing: 8
                    Rectangle {
                        width: 6; height: 6; radius: 3
                        color: desk.noticeTone === "error" ? desk.danger
                            : desk.noticeTone === "success" ? desk.positive : desk.inkMute
                    }
                    Text {
                        Layout.fillWidth: true
                        text: desk.activeTab === "actions"
                            ? (desk.notice.length > 0 ? desk.notice : "g/G 跳转 · . 重复 · dd 删 · yt 复制 · mt/w/m/l 换桶 · Space×2 全折")
                            : (terminalWorkspace.status.length > 0 ? terminalWorkspace.status : "终端组合保存工作现场；恢复只补缺，不关闭现有窗口")
                        color: desk.activeTab === "actions"
                            ? (desk.noticeTone === "error" ? desk.danger
                                : desk.noticeTone === "success" ? desk.positive : desk.inkMute)
                            : (terminalWorkspace.statusTone === "error" ? desk.danger
                                : terminalWorkspace.statusTone === "success" ? desk.positive : desk.inkMute)
                        elide: Text.ElideRight
                        font.family: desk.uiFont
                        font.pixelSize: 11
                    }
                    Text {
                        visible: desk.activeTab === "actions" && (desk.state.recent_done || []).length > 0
                        text: `刚完成 ${Number((desk.state.recent_done || []).length)}`
                        color: desk.positive
                        font.family: desk.monoFont
                        font.pixelSize: 9
                    }
                    Text {
                        text: desk.activeTab === "actions" ? "Todo SQLite source of truth" : "terminal-combos.json source of truth"
                        color: desk.inkMute
                        font.family: desk.monoFont
                        font.pixelSize: 9
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "actionDesk"
        function toggle() {
            if (GlobalStates.actionDeskOpen) desk.closeDesk()
            else desk.openDesk()
        }
        function open() { desk.openDesk() }
        function close() { desk.closeDesk() }
        function openActions() { desk.showActions() }
        function openTerminals() { desk.showTerminals() }
        function toggleTerminals() { desk.toggleTerminals() }
        function currentTab(): string { return desk.activeTab }
        function inputState(): string {
            return JSON.stringify({
                "tab": desk.activeTab,
                "focused": captureInput.activeFocus,
                "composing": captureInput.inputMethodComposing,
                "length": captureInput.text.length,
                "has_han": /[\u3400-\u9fff]/.test(captureInput.text),
                "nav_mode": desk.navMode
            })
        }
        function terminalState(): string {
            return JSON.stringify({
                "tab": desk.activeTab,
                "combo_count": terminalWorkspace.comboCount,
                "current_combo": terminalWorkspace.currentComboName,
                "selected_combo": String(terminalWorkspace.selectedCombo()?.name || ""),
                "terminal_count": Number(terminalWorkspace.selectedCombo()?.terminal_count || 0)
            })
        }
        function shellIdle(): bool {
            return !GlobalStates.actionDeskOpen && !GlobalStates.overviewOpen
                && !GlobalStates.statusPanelOpen && !GlobalStates.terminalsPanelOpen
        }
        function refresh() {
            if (desk.activeTab === "actions") desk.refresh()
            else terminalWorkspace.refresh()
        }
    }

    component DeskTab: Rectangle {
        id: tab
        required property string label
        property string meta: ""
        property bool selected: false
        property bool hovered: false
        signal triggered()

        implicitWidth: Math.max(94, tabLabel.implicitWidth + tabMeta.implicitWidth + 36)
        implicitHeight: 38
        radius: 9
        color: selected ? desk.accentSoft : hovered ? desk.paperHover : "transparent"
        border.width: 1
        border.color: selected ? desk.accent : hovered ? desk.lineStrong : desk.line

        Behavior on color {
            ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        Behavior on border.color {
            ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: tab.hovered = true
            onExited: tab.hovered = false
            onClicked: tab.triggered()
        }

        RowLayout {
            anchors.centerIn: parent
            spacing: 7
            Text {
                id: tabLabel
                text: tab.label
                color: tab.selected ? desk.accent : desk.inkSoft
                font.family: desk.uiFont
                font.pixelSize: 12
                font.weight: tab.selected ? Font.DemiBold : Font.Normal
            }
            Text {
                id: tabMeta
                visible: text.length > 0
                text: tab.meta
                color: tab.selected ? desk.accent : desk.inkMute
                elide: Text.ElideRight
                font.family: desk.monoFont
                font.pixelSize: 9
            }
        }
    }

    component DeskButton: Rectangle {
        id: button
        property string label: ""
        property string kind: "ghost"
        property bool hovered: false
        signal triggered()
        implicitWidth: buttonText.implicitWidth + 24
        implicitHeight: 34
        radius: 8
        opacity: enabled ? 1 : 0.38
        color: kind === "primary" ? (hovered ? "#f0c772" : desk.accent)
            : hovered ? desk.paperHover : desk.paperRaised
        border.width: kind === "primary" ? 0 : 1
        border.color: desk.lineStrong

        Behavior on color {
            ColorAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            enabled: button.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: button.hovered = true
            onExited: button.hovered = false
            onClicked: button.triggered()
        }
        Text {
            id: buttonText
            anchors.centerIn: parent
            text: button.label
            color: button.kind === "primary" ? "#241c0c" : desk.inkSoft
            font.family: desk.uiFont
            font.pixelSize: 12
            font.weight: button.kind === "primary" ? Font.DemiBold : Font.Normal
        }
    }

    component TodoColumn: Rectangle {
        id: col
        required property int columnIndex
        readonly property bool active: desk.focusColumn === columnIndex && desk.navMode === "list"
        readonly property var def: desk.columnDefs[columnIndex]
        readonly property var items: desk.columnNavItems(columnIndex)
        readonly property int rootCount: desk.columnTasks(columnIndex).length
        readonly property int monthCount: columnIndex === 2 ? desk.monthSectionCount() : 0

        radius: 14
        color: desk.paperRaised
        border.width: 1
        border.color: active ? desk.accent : desk.line

        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 3
            radius: 2
            color: col.active ? desk.accent : "transparent"
            Behavior on color {
                ColorAnimation { duration: 180; easing.type: Easing.OutCubic }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    text: String(col.columnIndex + 1).padStart(2, "0")
                    color: col.active ? desk.accent : desk.inkMute
                    font.family: desk.monoFont
                    font.pixelSize: 11
                    Behavior on color {
                        ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
                    }
                }
                ColumnLayout {
                    spacing: 0
                    Text {
                        text: String(col.def?.title || "")
                        color: desk.ink
                        font.family: desk.uiFont
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: String(col.def?.subtitle || "")
                        color: desk.inkMute
                        font.family: desk.uiFont
                        font.pixelSize: 10
                    }
                }
                Item { Layout.fillWidth: true }
                ColumnLayout {
                    spacing: 3
                    Text {
                        readonly property var progress: desk.columnProgress(col.columnIndex)
                        text: progress.total > 0
                            ? `${progress.done}/${progress.total}`
                            : String(col.rootCount).padStart(2, "0")
                        color: desk.inkMute
                        font.family: desk.monoFont
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignRight
                        Layout.alignment: Qt.AlignRight
                    }
                    Rectangle {
                        id: progressTrack
                        readonly property var progress: desk.columnProgress(col.columnIndex)
                        visible: progressTrack.progress.total > 0
                        Layout.alignment: Qt.AlignRight
                        width: 36
                        height: 3
                        radius: 1
                        color: desk.line
                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: progressTrack.progress.total > 0
                                ? parent.width * (progressTrack.progress.done / progressTrack.progress.total)
                                : 0
                            radius: 1
                            color: desk.positive
                            Behavior on width {
                                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }
            }

            Flickable {
                id: colScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: contentCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                }

                NumberAnimation {
                    id: contentYAnim
                    target: colScroll
                    property: "contentY"
                    duration: 140
                    easing.type: Easing.OutCubic
                }

                function ensureItemVisible(item) {
                    if (!item) return
                    const mapped = item.mapToItem(contentCol, 0, 0)
                    const top = mapped.y
                    const bottom = top + item.height
                    const margin = 16
                    const viewTop = contentY
                    const viewBottom = contentY + height
                    let nextY = contentY
                    if (top < viewTop + margin)
                        nextY = Math.max(0, top - margin)
                    else if (bottom > viewBottom - margin)
                        nextY = Math.min(Math.max(0, contentHeight - height), bottom - height + margin)
                    if (Math.abs(nextY - contentY) > 0.5) {
                        contentYAnim.stop()
                        contentYAnim.from = contentY
                        contentYAnim.to = nextY
                        contentYAnim.start()
                    }
                }

                function scrollToFocus() {
                    if (desk.focusColumn !== col.columnIndex) return
                    const item = rowRepeater.itemAt(desk.focusIndex)
                    if (!item) return
                    const target = item.focusAnchor || item
                    Qt.callLater(() => colScroll.ensureItemVisible(target))
                }

                Connections {
                    target: desk
                    function onFocusScrollNonceChanged() { colScroll.scrollToFocus() }
                    function onFocusIndexChanged() {
                        if (desk.focusColumn === col.columnIndex) colScroll.scrollToFocus()
                    }
                    function onFocusColumnChanged() {
                        if (desk.focusColumn === col.columnIndex) colScroll.scrollToFocus()
                    }
                }

                ColumnLayout {
                    id: contentCol
                    width: colScroll.width
                    spacing: 6

                    Text {
                        visible: col.items.length === 0
                        Layout.fillWidth: true
                        Layout.topMargin: 24
                        text: col.columnIndex === 0
                            ? "今天还空着\n按 i 记一件"
                            : "这一栏是空的"
                        color: desk.inkMute
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.family: desk.uiFont
                        font.pixelSize: 12
                        lineHeight: 1.45
                    }

                    Text {
                        visible: col.columnIndex === 2 && col.monthCount > 0
                        text: "本月"
                        color: desk.inkMute
                        font.family: desk.monoFont
                        font.pixelSize: 10
                        font.letterSpacing: 1.1
                    }

                    Repeater {
                        id: rowRepeater
                        model: col.items
                        delegate: TaskRow {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            task: modelData.task
                            depth: Number(modelData.depth || 0)
                            columnIndex: col.columnIndex
                            rowIndex: index
                            selected: desk.navMode === "list"
                                      && desk.focusColumn === col.columnIndex
                                      && desk.focusIndex === index
                            showLaterDivider: col.columnIndex === 2
                                              && Number(modelData.depth || 0) === 0
                                              && index > 0
                                              && String(modelData.task?.bucket || "") === "later"
                                              && String(col.items[index - 1]?.task?.bucket || "") !== "later"
                            onSelectedChanged: {
                                if (selected) colScroll.scrollToFocus()
                            }
                        }
                    }

                    ColumnLayout {
                        visible: col.columnIndex === 0 && (desk.state.recent_done || []).length > 0
                        Layout.fillWidth: true
                        Layout.topMargin: 12
                        spacing: 6
                        Text {
                            text: "刚完成"
                            color: desk.positive
                            font.family: desk.monoFont
                            font.pixelSize: 10
                            font.letterSpacing: 1.2
                        }
                        Repeater {
                            model: desk.state.recent_done || []
                            delegate: CompletedRow {
                                required property var modelData
                                Layout.fillWidth: true
                                task: modelData
                            }
                        }
                    }
                }
            }
        }
    }

    component TaskRow: ColumnLayout {
        id: rowWrap
        required property var task
        required property int columnIndex
        required property int rowIndex
        property int depth: 0
        property bool selected: false
        property bool showLaterDivider: false
        readonly property bool done: String(task?.status || "open") === "done"
        readonly property var focusAnchor: row
        spacing: 6

        Text {
            visible: rowWrap.showLaterDivider
            Layout.fillWidth: true
            Layout.topMargin: 8
            text: "长期"
            color: desk.inkMute
            font.family: desk.monoFont
            font.pixelSize: 10
            font.letterSpacing: 1.1
        }
        Rectangle {
            visible: rowWrap.showLaterDivider
            Layout.fillWidth: true
            height: 1
            color: desk.line
            opacity: 0.85
        }

        Rectangle {
            id: row
            objectName: "taskFocusAnchor"
            Layout.fillWidth: true
            Layout.leftMargin: rowWrap.depth > 0 ? 18 : 0
            implicitHeight: taskMetaText.visible ? 58 : 48
            radius: 9
            opacity: String(rowWrap.task?.id || "") === desk.fadingTaskId
                ? 0
                : (rowWrap.done ? 0.72 : 1)
            color: rowWrap.selected ? desk.accentSoft : (rowHover.containsMouse ? desk.paperHover : desk.paper)
            border.width: 1
            border.color: rowWrap.selected ? desk.accent : (rowHover.containsMouse ? desk.lineStrong : desk.line)

            Behavior on opacity {
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
            Behavior on color {
                ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
            Behavior on border.color {
                ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: 6
                width: 3
                radius: 2
                color: rowWrap.selected ? desk.accent : "transparent"
                Behavior on color {
                    ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
                }
            }

            MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: desk.selectTask(rowWrap.columnIndex, rowWrap.rowIndex)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 10
                spacing: 10
                z: 1

                Rectangle {
                    width: 20; height: 20; radius: 10
                    color: completeArea.containsMouse || rowWrap.done ? desk.accentSoft : "transparent"
                    border.width: 1
                    border.color: (completeArea.containsMouse || rowWrap.done) ? desk.accent : desk.lineStrong
                    Text {
                        anchors.centerIn: parent
                        text: rowWrap.done || completeArea.containsMouse ? "✓" : ""
                        color: desk.accent
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: completeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !actionProcess.running
                        onClicked: {
                            desk.selectTask(rowWrap.columnIndex, rowWrap.rowIndex)
                            desk.toggleTask(String(rowWrap.task?.id || ""))
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text {
                        Layout.fillWidth: true
                        text: (rowWrap.depth > 0 ? "↳ " : "") + String(rowWrap.task?.title || "")
                        color: rowWrap.done ? desk.inkMute : desk.ink
                        elide: Text.ElideRight
                        font.family: desk.uiFont
                        font.pixelSize: rowWrap.depth > 0 ? 12 : 13
                        font.strikeout: rowWrap.done
                    }
                    Text {
                        id: taskMetaText
                        visible: text.length > 0
                        Layout.fillWidth: true
                        text: desk.taskMeta(rowWrap.task)
                        color: desk.inkMute
                        elide: Text.ElideRight
                        font.family: desk.uiFont
                        font.pixelSize: 10
                    }
                }

                Rectangle {
                    visible: !rowWrap.task?.parent_id
                    implicitWidth: bucketText.implicitWidth + 16
                    implicitHeight: 26
                    radius: 6
                    color: bucketArea.containsMouse ? desk.accentSoft : "transparent"
                    border.width: 1
                    border.color: bucketArea.containsMouse ? desk.accent : desk.line
                    Text {
                        id: bucketText
                        anchors.centerIn: parent
                        text: desk.bucketName(String(rowWrap.task?.bucket || "today")) + " →"
                        color: bucketArea.containsMouse ? desk.accent : desk.inkMute
                        font.family: desk.uiFont
                        font.pixelSize: 10
                    }
                    MouseArea {
                        id: bucketArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !actionProcess.running
                        onClicked: {
                            desk.selectTask(rowWrap.columnIndex, rowWrap.rowIndex)
                            desk.moveTask(String(rowWrap.task?.id || ""), desk.nextBucket(String(rowWrap.task?.bucket || "today")))
                        }
                    }
                }
            }
        }
    }

    component CompletedRow: Rectangle {
        id: completed
        required property var task
        implicitHeight: 36
        radius: 7
        color: "transparent"
        RowLayout {
            anchors.fill: parent
            spacing: 8
            Text {
                text: "✓"
                color: desk.positive
                font.family: desk.monoFont
                font.pixelSize: 11
            }
            Text {
                Layout.fillWidth: true
                text: String(completed.task?.title || "")
                color: desk.inkMute
                elide: Text.ElideRight
                font.strikeout: true
                font.family: desk.uiFont
                font.pixelSize: 11
            }
            DeskButton {
                label: "恢复"
                kind: "ghost"
                implicitHeight: 27
                enabled: !actionProcess.running
                onTriggered: desk.reopenTask(String(completed.task?.id || ""))
            }
        }
    }
}
