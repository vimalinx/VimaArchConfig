//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import "./modules/common/"
import "./modules/actiondesk/"
import "./modules/overview/"
import "./modules/statuspanel/"
import "./modules/terminalspanel/"
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "./services/"

ShellRoot {
    // Enable/disable modules here. False = not loaded at all, so rest assured
    // no unnecessary stuff will take up memory if you decide to only use, say, the overview.
    property bool enableOverview: true
    property bool enableActionDesk: true
    property bool enableStatusPanel: false
    property bool enableTerminalsPanel: false

    // Force initialization of some singletons
    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme()
        ConfigLoader.loadConfig()
    }

    Loader { active: enableOverview; sourceComponent: Overview {} }
    Loader { active: enableActionDesk; sourceComponent: ActionDesk {} }
    Loader { active: enableStatusPanel; sourceComponent: StatusPanel {} }
    Loader { active: enableTerminalsPanel; sourceComponent: TerminalsPanel {} }

}
