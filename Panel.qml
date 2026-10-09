import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons

// Panel-kind plugin: manage which bar widgets are enabled / on the bar.
// All real work is done by bin/barctl; this is only a front end for it.
Item {
    id: root

    property var shell: null
    property var manifest: null
    property bool closingFromHost: false

    readonly property string barctl: String(Qt.resolvedUrl("bin/barctl")).replace("file://", "")
    property var items: []
    property string filter: ""
    property string status: ""
    property bool statusOk: true
    property string confirmId: ""     // id awaiting uninstall confirmation
    property bool busy: runner.running

    function open(payloadJson) {
        closingFromHost = false
        window.visible = true
        refresh()
        Qt.callLater(function () { if (window.visible) keyCatcher.forceActiveFocus() })
    }
    function close() { closingFromHost = true; window.visible = false; closingFromHost = false }
    function requestClose() {
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide((root.manifest && root.manifest.id) || "s3pp3ku.bar-manager")
        else window.visible = false
    }

    property var pending: null
    function refresh() { listProc.running = true }
    function act(args, label) {
        if (runner.running) return
        root.confirmId = ""
        root.status = label + "…"
        root.statusOk = true
        runner.command = [root.barctl].concat(args)
        runner.running = true
    }

    Process {
        id: listProc
        command: [root.barctl, "list"]
        stdout: StdioCollector {
            id: listOut
            waitForEnd: true
            onStreamFinished: {
                try { root.items = JSON.parse(listOut.text) } catch (e) { root.status = "Could not read plugin list"; root.statusOk = false }
            }
        }
    }

    Process {
        id: runner
        stdout: StdioCollector { id: rOut; waitForEnd: true }
        stderr: StdioCollector { id: rErr; waitForEnd: true }
        onExited: function (code) {
            root.statusOk = code === 0
            var msg = (code === 0 ? rOut.text : (rErr.text || rOut.text)).trim().split("\n")
            root.status = msg[msg.length - 1] || (code === 0 ? "Done" : "Failed")
            root.refresh()
        }
    }

    // Plain words people use -> the words plugins actually use.
    readonly property var synonyms: ({
        "sound": ["audio", "volume", "speaker", "mixer", "output"],
        "volume": ["audio", "sound", "mixer"],
        "speaker": ["audio", "sound"],
        "mic": ["microphone", "audio", "input"],
        "wifi": ["network", "wireless", "internet"],
        "internet": ["network", "wifi", "online"],
        "ethernet": ["network"],
        "bt": ["bluetooth"],
        "wireless": ["bluetooth", "network", "wifi"],
        "battery": ["power", "charge"],
        "charge": ["battery", "power"],
        "screen": ["display", "monitor", "brightness"],
        "brightness": ["display", "monitor", "keylight", "backlight"],
        "backlight": ["keylight", "keyboard", "brightness"],
        "light": ["keylight", "backlight", "nightlight"],
        "music": ["media", "mpd", "player", "audio"],
        "player": ["media", "music", "mpd"],
        "time": ["clock", "date"],
        "date": ["clock", "calendar"],
        "cpu": ["sysmon", "monitor", "system", "resources"],
        "ram": ["sysmon", "memory", "system"],
        "memory": ["sysmon", "ram", "system"],
        "temp": ["sysmon", "temperature", "fan"],
        "fan": ["sysmon", "cooling", "temperature"],
        "update": ["upgrade", "system-update", "updates"],
        "keys": ["keyboard", "layout"],
        "language": ["keyboard", "layout"],
        "print": ["printer", "cups", "scan"],
        "icons": ["tray", "systray"],
        "windows": ["workspaces", "active-window"],
        "desktop": ["workspaces"],
        "ai": ["agents", "agent", "claude"],
        "vpn": ["tailscale", "network"],
        "cloud": ["dropbox", "sync"],
        "notes": ["manual", "docs"],
        "help": ["manual", "docs"],
        "plugin": ["plugin-manager", "marketplace"],
        "theme": ["glass", "blur", "style"]
    })

    function editDistanceAtMost1(a, b) {
        if (Math.abs(a.length - b.length) > 1) return false
        var i = 0, j = 0, edits = 0
        while (i < a.length && j < b.length) {
            if (a[i] === b[j]) { i++; j++; continue }
            if (++edits > 1) return false
            if (a.length > b.length) i++
            else if (a.length < b.length) j++
            else { i++; j++ }
        }
        return edits + (a.length - i) + (b.length - j) <= 1
    }

    // Score one query word against a plugin: name > aliases/category > id > description.
    function scoreWord(p, w) {
        var name = p.name.toLowerCase()
        var id = p.id.toLowerCase()
        var tags = ((p.aliases || []).join(" ") + " " + (p.category || "")).toLowerCase()
        var desc = (p.description || "").toLowerCase()
        var best = 0
        var terms = [w].concat(synonyms[w] || [])
        for (var t = 0; t < terms.length; t++) {
            var term = terms[t]
            var weight = t === 0 ? 1.0 : 0.7        // direct typing beats synonyms
            var s = 0
            if (name.indexOf(term) === 0) s = 100
            else if (name.indexOf(term) !== -1) s = 80
            else if (tags.indexOf(term) !== -1) s = 70
            else if (id.indexOf(term) !== -1) s = 50
            else if (desc.indexOf(term) !== -1) s = 30
            else if (term.length >= 4) {
                // typo tolerance on whole words of name / aliases / id parts
                var words = (name + " " + tags + " " + id.replace(/[._-]/g, " ")).split(/\s+/)
                for (var k = 0; k < words.length; k++) {
                    if (editDistanceAtMost1(term, words[k])) { s = 40; break }
                }
            }
            best = Math.max(best, s * weight)
        }
        return best
    }

    readonly property var shown: {
        var q = filter.toLowerCase().trim()
        if (!q) return items
        var words = q.split(/\s+/), scored = []
        for (var i = 0; i < items.length; i++) {
            var total = 0, ok = true
            for (var w = 0; w < words.length; w++) {
                var s = scoreWord(items[i], words[w])
                if (s <= 0) { ok = false; break }
                total += s
            }
            if (ok) scored.push({ p: items[i], s: total })
        }
        scored.sort(function (a, b) { return b.s - a.s })
        return scored.map(function (x) { return x.p })
    }

    readonly property color fg: Color.foreground
    readonly property color bg: Color.background
    readonly property color accent: Color.accent
    readonly property color dim: Color.muted
    readonly property color bad: Color.urgent
    readonly property string mono: "monospace"

    FloatingWindow {
        id: window
        title: "Bar Manager"
        color: root.bg
        implicitWidth: 640
        implicitHeight: 720
        minimumSize: Qt.size(560, 400)

        onVisibleChanged: { if (!visible && !root.closingFromHost) root.requestClose() }

        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.requestClose()

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                // Title bar: plain text, rule underneath.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text { text: "BAR MANAGER"; color: root.accent; font.family: root.mono; font.pixelSize: 15; font.bold: true }
                    Text {
                        text: (root.filter ? root.shown.length + " of " : "") + root.items.length + " plugins"
                        color: root.dim; font.family: root.mono; font.pixelSize: 12
                    }
                    Item { Layout.fillWidth: true }
                    Btn { label: "Update all"; onClicked: root.act(["update", "--all"], "Updating all") }
                    Btn { label: "Refresh"; onClicked: root.refresh() }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: root.accent }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text { text: "Search:"; color: root.dim; font.family: root.mono; font.pixelSize: 13 }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 24
                        color: "transparent"; border.color: root.dim; border.width: 1
                        TextInput {
                            anchors.fill: parent; anchors.margins: 4
                            color: root.fg; font.family: root.mono; font.pixelSize: 13
                            selectionColor: root.accent; selectedTextColor: root.bg
                            verticalAlignment: TextInput.AlignVCenter
                            onTextChanged: root.filter = text
                        }
                    }
                }

                // Column headers
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 6; Layout.rightMargin: 6
                    spacing: 6
                    Text { text: "BAR"; Layout.preferredWidth: 28; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                    Text { text: "PLUGIN"; Layout.fillWidth: true; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                    Text { text: "ACTIONS"; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: root.dim }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 0
                    model: root.shown

                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: 40
                        color: rowHover.hovered ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : "transparent"
                        HoverHandler { id: rowHover }

                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35) }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6; anchors.rightMargin: 6
                            spacing: 6

                            Text {
                                Layout.preferredWidth: 28
                                text: row.modelData.onBar ? "[x]" : "[ ]"
                                color: row.modelData.onBar ? root.accent : root.dim
                                font.family: root.mono; font.pixelSize: 13
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 100
                                spacing: 0
                                Text {
                                    Layout.fillWidth: true
                                    text: row.modelData.name
                                    color: row.modelData.enabled ? root.fg : root.dim
                                    font.family: root.mono; font.pixelSize: 13; font.bold: true; elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: row.modelData.id + (row.modelData.onBar ? "  @" + row.modelData.section : "") +
                                          (row.modelData.enabled ? "" : "  (disabled)") + (row.modelData.firstParty ? "  (built-in)" : "")
                                    color: root.dim; font.family: root.mono; font.pixelSize: 10; elide: Text.ElideRight
                                }
                            }

                            Btn {
                                label: row.modelData.onBar ? "Hide" : "Show"
                                onClicked: root.act([row.modelData.onBar ? "hide" : "show", row.modelData.id], row.modelData.onBar ? "Hiding" : "Showing")
                            }
                            Btn {
                                label: "Bar:" + (row.modelData.bar || "top")
                                onClicked: {
                                    var order = ["top", "bottom", "left", "right"]
                                    var next = order[(order.indexOf(row.modelData.bar || "top") + 1) % order.length]
                                    var sect = row.modelData.section.indexOf("/") >= 0 ? row.modelData.section.split("/")[1]
                                             : (["left", "center", "right"].indexOf(row.modelData.section) >= 0 ? row.modelData.section : "right")
                                    root.act(["place", row.modelData.id, next, sect], "Moving to " + next)
                                }
                            }
                            Btn {
                                label: row.modelData.enabled ? "Disable" : "Enable"
                                onClicked: root.act([row.modelData.enabled ? "disable" : "enable", row.modelData.id], row.modelData.enabled ? "Disabling" : "Enabling")
                            }
                            Btn {
                                visible: row.modelData.canManage
                                label: "Update"
                                onClicked: root.act(["update", row.modelData.id], "Updating")
                            }
                            Btn {
                                visible: row.modelData.canManage
                                danger: true
                                label: root.confirmId === row.modelData.id ? "Sure?" : "Uninstall"
                                onClicked: {
                                    if (root.confirmId === row.modelData.id) root.act(["uninstall", row.modelData.id], "Uninstalling")
                                    else root.confirmId = row.modelData.id
                                }
                            }
                        }
                    }
                }

                // Status line
                Rectangle { Layout.fillWidth: true; height: 1; color: root.dim }
                Text {
                    Layout.fillWidth: true
                    text: root.status !== "" ? root.status : "Esc closes.  [x] = shown on bar.  Bar: click to move top→bottom→left→right."
                    elide: Text.ElideRight
                    color: root.status === "" ? root.dim : (root.statusOk ? root.accent : root.bad)
                    font.family: root.mono; font.pixelSize: 12
                }
            }
        }
    }

    // Old-school text button: [ Label ], inverts on hover.
    component Btn: Rectangle {
        id: btn
        property string label: ""
        property bool danger: false
        signal clicked()
        readonly property color tone: danger ? root.bad : root.fg
        implicitWidth: txt.implicitWidth + 12
        implicitHeight: 22
        color: ma.containsMouse ? tone : "transparent"
        border.color: tone
        border.width: 1
        opacity: root.busy ? 0.5 : 1
        Text {
            id: txt
            anchors.centerIn: parent
            text: btn.label
            color: ma.containsMouse ? root.bg : btn.tone
            font.family: root.mono; font.pixelSize: 11
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; enabled: !root.busy; onClicked: btn.clicked() }
    }
}
