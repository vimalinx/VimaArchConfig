import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io

// Embedded terminal worksite for Action Desk. TerminalCombos.py and its state
// file remain authoritative; this component only renders and invokes its CLI.
Item {
    id: workspace

    property bool active: false
    readonly property string comboScript: "/home/vimalinx/.config/hypr/UserScripts/TerminalCombos.py"
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

    property var terminalData: ({
        "updated_at": "--:--:--",
        "current_mode": "single",
        "combos": []
    })
    property string selectedComboName: ""
    property string draftName: ""
    property string typeFilter: "all"
    property string status: ""
    property string statusTone: "neutral"
    property string pendingAction: ""
    property string pendingSelection: ""
    property string deleteArmedName: ""
    property bool renaming: false

    readonly property int comboCount: (terminalData.combos || []).length
    readonly property string currentComboName: {
        const combos = terminalData.combos || []
        for (let index = 0; index < combos.length; index++) {
            if (Boolean(combos[index]?.is_current)) return String(combos[index]?.name || "")
        }
        return ""
    }
    readonly property bool busy: dataProcess.running || actionProcess.running

    signal requestClose()

    function setStatus(message, tone) {
        status = String(message || "")
        statusTone = tone || "neutral"
    }

    function selectedCombo() {
        const combos = terminalData.combos || []
        for (let index = 0; index < combos.length; index++) {
            if (String(combos[index]?.name || "") === selectedComboName) return combos[index]
        }
        return {
            "name": "",
            "saved_at": "",
            "mode": "single",
            "eligible": true,
            "is_current": false,
            "terminal_count": 0,
            "match_ratio": 0,
            "summary": {},
            "terminals": []
        }
    }

    function syncSelection() {
        const combos = terminalData.combos || []
        if (combos.length === 0) {
            selectedComboName = ""
            return
        }
        for (let index = 0; index < combos.length; index++) {
            if (String(combos[index]?.name || "") === selectedComboName) return
        }
        for (let index = 0; index < combos.length; index++) {
            if (Boolean(combos[index]?.is_current)) {
                selectedComboName = String(combos[index]?.name || "")
                return
            }
        }
        selectedComboName = String(combos[0]?.name || "")
    }

    function selectCombo(name) {
        selectedComboName = String(name || "")
        draftName = ""
        renaming = false
        deleteArmedName = ""
        typeFilter = "all"
    }

    function typeBadge(type) {
        if (type === "foot-tmux") return "tmux"
        if (type === "foot-codex") return "codex"
        if (type === "foot-claude") return "claude"
        if (type === "foot-command" || type === "foot-agent" || type === "foot-omp") return "cmd"
        if (type === "foot-shell") return "shell"
        return "other"
    }

    function modeLabel(mode) {
        return mode === "dual" ? "双屏" : "单屏"
    }

    function comboSummary(combo) {
        const summary = combo?.summary || {}
        const parts = []
        if (summary.tmux) parts.push(`${summary.tmux} mux`)
        if (summary.codex) parts.push(`${summary.codex} Codex`)
        if (summary.claude) parts.push(`${summary.claude} Claude`)
        if (summary.command) parts.push(`${summary.command} Pi/命令`)
        if (summary.shell) parts.push(`${summary.shell} Shell`)
        return parts.length > 0 ? parts.join("  ·  ") : "空组合"
    }

    function matchPercent(combo) {
        return Math.max(0, Math.min(100, Math.round(Number(combo?.match_ratio || 0) * 100)))
    }

    function typeCount(filter) {
        const terminals = selectedCombo().terminals || []
        if (filter === "all") return terminals.length
        let count = 0
        for (let index = 0; index < terminals.length; index++) {
            if (typeBadge(String(terminals[index]?.type || "")) === filter) count++
        }
        return count
    }

    function filteredTerminals() {
        const terminals = selectedCombo().terminals || []
        const result = []
        for (let index = 0; index < terminals.length; index++) {
            const terminal = terminals[index]
            const badge = typeBadge(String(terminal?.type || ""))
            if (typeFilter !== "all" && badge !== typeFilter) continue
            result.push({
                type: terminal?.type,
                title: terminal?.title,
                workspace: terminal?.workspace,
                cwd: terminal?.cwd,
                session: terminal?.session,
                floating: terminal?.floating,
                originalIndex: index
            })
        }
        return result
    }

    function refresh() {
        if (dataProcess.running) return
        dataProcess.command = ["python3", comboScript, "list"]
        dataProcess.running = true
    }

    function runAction(args, kind, selection, busyMessage) {
        if (actionProcess.running || !args || args.length === 0) return
        pendingAction = kind
        pendingSelection = String(selection || "")
        deleteArmedName = ""
        setStatus(busyMessage || "处理中…", "neutral")
        actionProcess.command = ["python3", comboScript].concat(args)
        actionProcess.running = true
    }

    function captureCombo(name) {
        const clean = String(name || "").trim()
        if (!clean) {
            setStatus("组合名不能为空", "error")
            nameInput.forceActiveFocus()
            return
        }
        runAction(["capture", "--name", clean], "capture", clean, "正在保存当前终端现场…")
    }

    function restoreCombo(name) {
        const clean = String(name || "")
        if (!clean) return
        runAction(["restore", clean], "restore", clean, "正在补齐缺失终端…")
    }

    function openTerminal(comboName, index) {
        const clean = String(comboName || "")
        if (!clean || index < 0) return
        runAction(["open-terminal", clean, String(index)], "open", clean, "正在定位终端…")
    }

    function beginRename() {
        const combo = selectedCombo()
        if (!combo.name) return
        draftName = String(combo.name)
        renaming = true
        deleteArmedName = ""
        nameInput.forceActiveFocus()
        nameInput.selectAll()
    }

    function commitRename(oldName, newName) {
        const clean = String(newName || "").trim()
        if (!clean) {
            setStatus("组合名不能为空", "error")
            return
        }
        if (clean === String(oldName || "")) {
            renaming = false
            draftName = ""
            return
        }
        runAction(["rename", String(oldName), clean], "rename", clean, "正在重命名…")
    }

    function requestDelete(name) {
        const clean = String(name || "")
        if (!clean) return
        if (deleteArmedName !== clean) {
            deleteArmedName = clean
            setStatus(`再点一次删除“${clean}”`, "error")
            return
        }
        runAction(["delete", clean], "delete", "", "正在删除组合…")
    }

    function focusDefault() {
        if (!active) return
        if (comboCount === 0) nameInput.forceActiveFocus()
        else terminalList.forceActiveFocus()
    }

    function cancelTransient() {
        if (renaming) {
            renaming = false
            draftName = ""
            setStatus("已取消重命名", "neutral")
            return true
        }
        if (deleteArmedName.length > 0) {
            deleteArmedName = ""
            setStatus("已取消删除", "neutral")
            return true
        }
        return false
    }

    onActiveChanged: {
        if (active) {
            setStatus("", "neutral")
            deleteArmedName = ""
            refresh()
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: workspace.active
        onTriggered: workspace.refresh()
    }

    Process {
        id: dataProcess
        stdout: SplitParser {
            onRead: data => {
                try {
                    workspace.terminalData = JSON.parse(data)
                    workspace.syncSelection()
                } catch (error) {
                    workspace.setStatus("终端组合状态解析失败", "error")
                }
            }
        }
        stderr: SplitParser {
            onRead: data => {
                const message = String(data || "").trim()
                if (message.length > 0) workspace.setStatus(message.slice(0, 140), "error")
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0 && workspace.statusTone !== "error") {
                workspace.setStatus(`终端组合读取失败 · exit ${exitCode}`, "error")
            }
        }
    }

    Process {
        id: actionProcess
        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data)
                    if (!result.success) {
                        workspace.setStatus(result.error || "终端操作失败", "error")
                        return
                    }
                    if (workspace.pendingAction === "capture") {
                        workspace.selectedComboName = workspace.pendingSelection
                        workspace.draftName = ""
                        workspace.setStatus(`已保存 ${Number(result.captured || 0)} 个终端`, "success")
                    } else if (workspace.pendingAction === "restore") {
                        workspace.setStatus(`已补齐 ${Number(result.restored || 0)} 个，跳过 ${Number(result.skipped || 0)} 个，失败 ${Number(result.failed || 0)} 个`, Number(result.failed || 0) > 0 ? "error" : "success")
                    } else if (workspace.pendingAction === "rename") {
                        workspace.selectedComboName = workspace.pendingSelection
                        workspace.draftName = ""
                        workspace.renaming = false
                        workspace.setStatus(`已重命名为“${workspace.pendingSelection}”`, "success")
                    } else if (workspace.pendingAction === "delete") {
                        workspace.setStatus(`已删除“${String(result.deleted || "组合")}”`, "success")
                    } else if (workspace.pendingAction === "open") {
                        if (Boolean(result.focused)) {
                            workspace.setStatus("已切换到现有终端", "success")
                            workspace.requestClose()
                        } else if (Boolean(result.spawned)) {
                            workspace.setStatus("已补开该终端", "success")
                        }
                    }
                } catch (error) {
                    workspace.setStatus("终端操作结果解析失败", "error")
                }
            }
        }
        stderr: SplitParser {
            onRead: data => {
                const message = String(data || "").trim()
                if (message.length > 0) workspace.setStatus(message.slice(0, 140), "error")
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0 && workspace.statusTone !== "error") {
                workspace.setStatus(`终端操作失败 · exit ${exitCode}`, "error")
            }
            workspace.pendingAction = ""
            workspace.pendingSelection = ""
            workspace.renaming = false
            workspace.refresh()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 14

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 94
            radius: 12
            color: workspace.canvas
            border.width: 1
            border.color: workspace.lineStrong

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 18
                anchors.rightMargin: 14
                spacing: 18

                ColumnLayout {
                    Layout.preferredWidth: 270
                    spacing: 2
                    Text {
                        text: "LIVE WORKSITE"
                        color: workspace.accent
                        font.family: workspace.monoFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.6
                    }
                    Text {
                        Layout.fillWidth: true
                        text: workspace.currentComboName.length > 0 ? workspace.currentComboName : "当前现场未命名"
                        color: workspace.ink
                        elide: Text.ElideRight
                        font.family: workspace.uiFont
                        font.pixelSize: 19
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: `${workspace.modeLabel(workspace.terminalData.current_mode)} · ${workspace.comboCount} 套已保存组合`
                        color: workspace.inkMute
                        font.family: workspace.monoFont
                        font.pixelSize: 10
                    }
                }

                Rectangle { width: 1; Layout.preferredHeight: 54; color: workspace.line }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 7
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: workspace.selectedCombo().name ? `“${workspace.selectedCombo().name}”现场匹配度` : "选择一个终端组合"
                            color: workspace.inkSoft
                            font.family: workspace.uiFont
                            font.pixelSize: 12
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: `${workspace.matchPercent(workspace.selectedCombo())}%`
                            color: workspace.selectedCombo().is_current ? workspace.positive : workspace.accent
                            font.family: workspace.monoFont
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 8
                        radius: 4
                        color: workspace.paperRaised
                        Rectangle {
                            width: parent.width * workspace.matchPercent(workspace.selectedCombo()) / 100
                            height: parent.height
                            radius: parent.radius
                            color: workspace.selectedCombo().is_current ? workspace.positive : workspace.accent
                            Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: workspace.selectedCombo().name
                            ? `${Number(workspace.selectedCombo().terminal_count || 0)} 个终端  ·  ${workspace.comboSummary(workspace.selectedCombo())}`
                            : "保存当前终端后，Action Desk 会用真实窗口状态计算匹配度。"
                        color: workspace.inkMute
                        elide: Text.ElideRight
                        font.family: workspace.uiFont
                        font.pixelSize: 10
                    }
                }

                WorkButton {
                    label: dataProcess.running ? "同步中…" : "刷新现场"
                    enabled: !workspace.busy
                    onTriggered: workspace.refresh()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 14

            Rectangle {
                Layout.preferredWidth: 320
                Layout.fillHeight: true
                radius: 12
                color: workspace.paperRaised
                border.width: 1
                border.color: workspace.line

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: "保存的现场"
                            color: workspace.ink
                            font.family: workspace.uiFont
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: String(workspace.comboCount).padStart(2, "0")
                            color: workspace.inkMute
                            font.family: workspace.monoFont
                            font.pixelSize: 10
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 7
                        TextField {
                            id: nameInput
                            Layout.fillWidth: true
                            enabled: !actionProcess.running
                            selectByMouse: true
                            placeholderText: workspace.renaming ? "输入新名称…" : "给当前现场命名…"
                            placeholderTextColor: workspace.inkMute
                            text: workspace.draftName
                            color: workspace.ink
                            selectionColor: workspace.accentSoft
                            selectedTextColor: workspace.ink
                            font.family: workspace.uiFont
                            font.pixelSize: 12
                            background: Rectangle {
                                radius: 8
                                color: workspace.paper
                                border.width: 1
                                border.color: nameInput.activeFocus ? workspace.accent : workspace.lineStrong
                            }
                            onTextChanged: if (workspace.draftName !== text) workspace.draftName = text
                            onAccepted: {
                                if (workspace.renaming) workspace.commitRename(workspace.selectedCombo().name, workspace.draftName)
                                else workspace.captureCombo(workspace.draftName)
                            }
                        }
                        WorkButton {
                            label: workspace.renaming ? "改名" : "保存"
                            kind: "primary"
                            enabled: !workspace.busy && workspace.draftName.trim().length > 0
                            onTriggered: {
                                if (workspace.renaming) workspace.commitRename(workspace.selectedCombo().name, workspace.draftName)
                                else workspace.captureCombo(workspace.draftName)
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: workspace.renaming ? "Esc 取消改名；Enter 确认" : "保存当前所有 Foot 终端、工作区与启动方式"
                        color: workspace.inkMute
                        wrapMode: Text.WordWrap
                        font.family: workspace.uiFont
                        font.pixelSize: 10
                    }

                    ScrollView {
                        id: comboScroll
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentWidth: availableWidth
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                        ColumnLayout {
                            width: comboScroll.availableWidth
                            spacing: 5

                            Repeater {
                                model: workspace.terminalData.combos || []
                                delegate: ComboCard {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    combo: modelData
                                    selected: workspace.selectedComboName === String(modelData?.name || "")
                                    onTriggered: workspace.selectCombo(String(modelData?.name || ""))
                                }
                            }

                            Text {
                                visible: workspace.comboCount === 0
                                Layout.fillWidth: true
                                Layout.topMargin: 24
                                text: "还没有保存终端现场\n在上方命名并保存当前终端"
                                color: workspace.inkMute
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                font.family: workspace.uiFont
                                font.pixelSize: 12
                                lineHeight: 1.5
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 12
                color: workspace.paperRaised
                border.width: 1
                border.color: workspace.line

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            RowLayout {
                                spacing: 8
                                Text {
                                    text: String(workspace.selectedCombo().name || "选择一个终端组合")
                                    color: workspace.ink
                                    elide: Text.ElideRight
                                    font.family: workspace.uiFont
                                    font.pixelSize: 18
                                    font.weight: Font.DemiBold
                                }
                                Rectangle {
                                    visible: Boolean(workspace.selectedCombo().is_current)
                                    implicitWidth: currentLabel.implicitWidth + 14
                                    implicitHeight: 23
                                    radius: 6
                                    color: "#20352f"
                                    Text {
                                        id: currentLabel
                                        anchors.centerIn: parent
                                        text: "当前现场"
                                        color: workspace.positive
                                        font.family: workspace.uiFont
                                        font.pixelSize: 10
                                        font.weight: Font.DemiBold
                                    }
                                }
                                Rectangle {
                                    implicitWidth: modeText.implicitWidth + 14
                                    implicitHeight: 23
                                    radius: 6
                                    color: workspace.paper
                                    border.width: 1
                                    border.color: workspace.line
                                    Text {
                                        id: modeText
                                        anchors.centerIn: parent
                                        text: workspace.modeLabel(workspace.selectedCombo().mode)
                                        color: workspace.inkMute
                                        font.family: workspace.monoFont
                                        font.pixelSize: 9
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: workspace.selectedCombo().name
                                    ? `${workspace.comboSummary(workspace.selectedCombo())}  ·  保存于 ${String(workspace.selectedCombo().saved_at || "")}`
                                    : "从左侧选择一个现场，或保存当前终端。"
                                color: workspace.inkMute
                                elide: Text.ElideRight
                                font.family: workspace.uiFont
                                font.pixelSize: 10
                            }
                        }

                        WorkButton {
                            label: `恢复 ${Number(workspace.selectedCombo().terminal_count || 0)}`
                            kind: "primary"
                            enabled: Boolean(workspace.selectedCombo().name) && Boolean(workspace.selectedCombo().eligible) && !workspace.busy
                            onTriggered: workspace.restoreCombo(workspace.selectedCombo().name)
                        }
                        WorkButton {
                            label: "重命名"
                            enabled: Boolean(workspace.selectedCombo().name) && !workspace.busy
                            onTriggered: workspace.beginRename()
                        }
                        WorkButton {
                            label: workspace.deleteArmedName === String(workspace.selectedCombo().name || "") ? "确认删除" : "删除"
                            kind: workspace.deleteArmedName === String(workspace.selectedCombo().name || "") ? "danger" : "ghost"
                            enabled: Boolean(workspace.selectedCombo().name) && !workspace.busy
                            onTriggered: workspace.requestDelete(workspace.selectedCombo().name)
                        }
                    }

                    Rectangle {
                        visible: Boolean(workspace.selectedCombo().name) && !Boolean(workspace.selectedCombo().eligible)
                        Layout.fillWidth: true
                        implicitHeight: unavailableText.implicitHeight + 18
                        radius: 8
                        color: "#332320"
                        Text {
                            id: unavailableText
                            anchors.fill: parent
                            anchors.margins: 9
                            text: "当前是单屏环境；这个双屏组合暂时不能恢复，但仍可查看和打开单个终端。"
                            color: workspace.danger
                            wrapMode: Text.WordWrap
                            font.family: workspace.uiFont
                            font.pixelSize: 11
                        }
                    }

                    RowLayout {
                        visible: Boolean(workspace.selectedCombo().name)
                        Layout.fillWidth: true
                        spacing: 6
                        FilterButton { label: `全部 ${workspace.typeCount("all")}`; selected: workspace.typeFilter === "all"; onTriggered: workspace.typeFilter = "all" }
                        FilterButton { label: `Codex ${workspace.typeCount("codex")}`; selected: workspace.typeFilter === "codex"; onTriggered: workspace.typeFilter = "codex" }
                        FilterButton { label: `Claude ${workspace.typeCount("claude")}`; selected: workspace.typeFilter === "claude"; onTriggered: workspace.typeFilter = "claude" }
                        FilterButton { label: `Pi/命令 ${workspace.typeCount("cmd")}`; selected: workspace.typeFilter === "cmd"; onTriggered: workspace.typeFilter = "cmd" }
                        FilterButton { label: `tmux ${workspace.typeCount("tmux")}`; selected: workspace.typeFilter === "tmux"; onTriggered: workspace.typeFilter = "tmux" }
                        FilterButton { label: `Shell ${workspace.typeCount("shell")}`; selected: workspace.typeFilter === "shell"; onTriggered: workspace.typeFilter = "shell" }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: "单击：切换或补开"
                            color: workspace.inkMute
                            font.family: workspace.uiFont
                            font.pixelSize: 10
                        }
                    }

                    ScrollView {
                        id: terminalList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentWidth: availableWidth
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                        ColumnLayout {
                            width: terminalList.availableWidth
                            spacing: 5

                            Repeater {
                                model: workspace.filteredTerminals()
                                delegate: TerminalCard {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    terminal: modelData
                                    onTriggered: workspace.openTerminal(workspace.selectedCombo().name, Number(modelData?.originalIndex ?? -1))
                                }
                            }

                            Text {
                                visible: workspace.filteredTerminals().length === 0
                                Layout.fillWidth: true
                                Layout.topMargin: 24
                                text: workspace.selectedCombo().name ? "这个分类里没有终端" : "先从左侧选择一个终端现场"
                                color: workspace.inkMute
                                horizontalAlignment: Text.AlignHCenter
                                font.family: workspace.uiFont
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }
        }
    }

    component WorkButton: Rectangle {
        id: button
        required property string label
        property string kind: "ghost"
        property bool hovered: false
        signal triggered()

        implicitWidth: labelText.implicitWidth + 22
        implicitHeight: 32
        radius: 8
        opacity: enabled ? 1 : 0.38
        color: kind === "primary" ? (hovered ? "#f0c772" : workspace.accent)
            : kind === "danger" ? (hovered ? "#4b2925" : "#38211f")
            : hovered ? workspace.paperHover : workspace.paper
        border.width: kind === "primary" ? 0 : 1
        border.color: kind === "danger" ? workspace.danger : workspace.lineStrong

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
            id: labelText
            anchors.centerIn: parent
            text: button.label
            color: button.kind === "primary" ? "#241c0c"
                : button.kind === "danger" ? workspace.danger : workspace.inkSoft
            font.family: workspace.uiFont
            font.pixelSize: 11
            font.weight: button.kind === "primary" ? Font.DemiBold : Font.Normal
        }
    }

    component FilterButton: Rectangle {
        id: filter
        required property string label
        property bool selected: false
        property bool hovered: false
        signal triggered()

        implicitWidth: filterLabel.implicitWidth + 16
        implicitHeight: 27
        radius: 7
        color: selected ? workspace.accentSoft : hovered ? workspace.paperHover : workspace.paper
        border.width: 1
        border.color: selected ? workspace.accent : workspace.line

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: filter.hovered = true
            onExited: filter.hovered = false
            onClicked: filter.triggered()
        }
        Text {
            id: filterLabel
            anchors.centerIn: parent
            text: filter.label
            color: filter.selected ? workspace.accent : workspace.inkMute
            font.family: workspace.monoFont
            font.pixelSize: 9
        }
    }

    component ComboCard: Rectangle {
        id: card
        required property var combo
        property bool selected: false
        property bool hovered: false
        signal triggered()

        implicitHeight: 68
        radius: 9
        opacity: Boolean(combo?.eligible) ? 1 : 0.52
        color: selected ? workspace.accentSoft : hovered ? workspace.paperHover : workspace.paper
        border.width: 1
        border.color: selected ? workspace.accent : hovered ? workspace.lineStrong : workspace.line

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: card.hovered = true
            onExited: card.hovered = false
            onClicked: card.triggered()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 11
            anchors.rightMargin: 9
            spacing: 9

            Rectangle {
                width: 7
                Layout.preferredHeight: 38
                radius: 3
                color: Boolean(card.combo?.is_current) ? workspace.positive
                    : card.selected ? workspace.accent : workspace.lineStrong
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: String(card.combo?.name || "")
                        color: workspace.ink
                        elide: Text.ElideRight
                        font.family: workspace.uiFont
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: `${workspace.matchPercent(card.combo)}%`
                        color: Boolean(card.combo?.is_current) ? workspace.positive : workspace.inkMute
                        font.family: workspace.monoFont
                        font.pixelSize: 10
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: `${Number(card.combo?.terminal_count || 0)} 个 · ${workspace.modeLabel(card.combo?.mode)} · ${workspace.comboSummary(card.combo)}`
                    color: workspace.inkMute
                    elide: Text.ElideRight
                    font.family: workspace.uiFont
                    font.pixelSize: 9
                }
            }
        }
    }

    component TerminalCard: Rectangle {
        id: terminalCard
        required property var terminal
        property bool hovered: false
        signal triggered()

        implicitHeight: 54
        radius: 9
        color: hovered ? workspace.paperHover : workspace.paper
        border.width: 1
        border.color: hovered ? workspace.accent : workspace.line

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: terminalCard.hovered = true
            onExited: terminalCard.hovered = false
            onClicked: terminalCard.triggered()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10

            Rectangle {
                implicitWidth: Math.max(54, badgeText.implicitWidth + 14)
                implicitHeight: 24
                radius: 6
                color: workspace.accentSoft
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: workspace.typeBadge(String(terminalCard.terminal?.type || ""))
                    color: workspace.accent
                    font.family: workspace.monoFont
                    font.pixelSize: 9
                    font.weight: Font.DemiBold
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: String(terminalCard.terminal?.title || "未命名终端")
                    color: workspace.ink
                    elide: Text.ElideRight
                    font.family: workspace.uiFont
                    font.pixelSize: 12
                }
                Text {
                    Layout.fillWidth: true
                    text: `工作区 ${String(terminalCard.terminal?.workspace || "?")}${terminalCard.terminal?.session ? "  ·  " + String(terminalCard.terminal.session) : ""}  ·  ${String(terminalCard.terminal?.cwd || "")}`
                    color: workspace.inkMute
                    elide: Text.ElideMiddle
                    font.family: workspace.monoFont
                    font.pixelSize: 9
                }
            }

            Text {
                text: "↗"
                color: terminalCard.hovered ? workspace.accent : workspace.inkMute
                font.family: workspace.monoFont
                font.pixelSize: 15
            }
        }
    }
}
