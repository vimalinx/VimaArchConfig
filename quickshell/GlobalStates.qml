import "root:/modules/common/"
import QtQuick
import Quickshell
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root
    property bool overviewOpen: false
    property bool actionDeskOpen: false
    property bool statusPanelOpen: false
    property bool terminalsPanelOpen: false
}
