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

    // ------------------------------------------------------------ layout screen
    property string view: "list"
    property var layoutData: ({ main: "top", bars: ({}) })
    property var dragInfo: null          // { id, name, isTray, mainTray }
    property var dropTarget: null        // { edge, section, before, intray, rect } in canvas coordinates
    property real dragX: 0
    property real dragY: 0
    property Item canvasItem: null
    property var zoneItems: []

    function refreshLayout() { layoutProc.running = false; layoutProc.running = true }
    Process {
        id: layoutProc
        command: [root.barctl, "layout"]
        stdout: StdioCollector {
            id: layoutOut
            waitForEnd: true
            onStreamFinished: {
                try { root.layoutData = JSON.parse(layoutOut.text) } catch (e) { return }
                if (!root.probed && root.view === "layout") root.probeIcons()
            }
        }
    }
    // Ask Extra Bars to load the widgets on the bars for a moment and report the icons they really draw,
    // then redraw the Layout screen with them.
    property bool probed: false
    function probeIcons() {
        var ids = {}
        var bars = root.layoutData.bars || {}
        for (var e in bars) {
            var secs = bars[e].sections || {}
            for (var s in secs) for (var i = 0; i < secs[s].length; i++) {
                var en = secs[s][i]
                if (!en.tray) ids[en.id] = true
                for (var m = 0; m < (en.members || []).length; m++) ids[en.members[m].id] = true
            }
        }
        var list = Object.keys(ids)
        if (!list.length) return
        probed = true
        Quickshell.execDetached(["omarchy-shell", "s3pp3ku.extra-bars.icons", "probe", list.join(",")])
        probeRefresh.restart()
    }
    Timer { id: probeRefresh; interval: 3600; onTriggered: root.refreshLayout() }
    function registerZone(z) { zoneItems = zoneItems.concat([z]) }

    // chips show the widget's own icon; widgets we could not read one from get letters
    function monogram(name) {
        var words = String(name).replace(/^My /, "").split(/[\s:]+/).filter(function (w) { return w.length })
        if (words.length >= 2) return (words[0].charAt(0) + words[1].charAt(0)).toUpperCase()
        return String(words[0] || "?").substring(0, 2)
    }
    property var tipItem: null
    property string tipText: ""
    function showTip(item, text) { if (!dragInfo) { tipItem = item; tipText = text } }
    function hideTip(item) { if (tipItem === item) tipItem = null }

    function beginLayoutDrag(info) { dragInfo = info; dropTarget = null }
    function moveLayoutDrag(pt) { dragX = pt.x; dragY = pt.y; dropTarget = targetAt(pt.x, pt.y) }
    function endLayoutDrag() {
        var t = dropTarget, d = dragInfo
        dragInfo = null
        dropTarget = null
        if (!t || !d) return
        if (t.intray) act(["intray", d.id, t.intray], "Putting " + d.name + " in the tray")
        else act(["drop", d.id, t.edge, t.section, t.before], "Moving " + d.name)
    }
    function targetAt(px, py) {
        for (var i = 0; i < zoneItems.length; i++) {
            var z = zoneItems[i]
            if (!z.visible) continue
            var p = z.mapToItem(canvasItem, 0, 0)
            if (px >= p.x && px <= p.x + z.width && py >= p.y && py <= p.y + z.height)
                return zoneTarget(z, px - p.x, py - p.y, p)
        }
        return null
    }
    function zoneTarget(z, lx, ly, zp) {
        var d = dragInfo
        var isMain = z.edge === layoutData.main
        if (d.isTray && isMain) return null            // built-in trays live on the extra bars
        if (d.mainTray && !isMain) return null         // the real Tray plugin stays on the main bar
        var slots = z.slotInfo(d.id)
        if (!d.isTray && !d.mainTray) {
            for (var t = 0; t < slots.length; t++) {   // over a tray: the widget goes inside it
                var s = slots[t]
                if (s.isTray && lx >= s.x && lx <= s.x + s.w && ly >= s.y && ly <= s.y + s.h)
                    return { edge: z.edge, section: z.section, before: "", intray: s.id,
                             rect: { x: zp.x + s.x, y: zp.y + s.y, w: s.w, h: s.h } }
            }
        }
        var before = "", mark = null, num = slots.length + 1
        for (var j = 0; j < slots.length; j++) {
            var c = slots[j]
            if (ly < c.y || (ly <= c.y + c.h && lx < c.x + c.w / 2)) {
                before = c.id; num = j + 1; mark = { x: zp.x + c.x - 2, y: zp.y + c.y, w: 4, h: c.h }; break
            }
        }
        if (!mark) {   // append: highlight the spare cell at the end
            var sp = z.spareRect()
            mark = sp ? { x: zp.x + sp.x, y: zp.y + sp.y, w: sp.w, h: sp.h } : { x: zp.x + 8, y: zp.y + 18, w: 30, h: 30 }
        }
        return { edge: z.edge, section: z.section, before: before, intray: "", num: num, rect: mark, cellKey: "" }
    }

    function open(payloadJson) {
        probed = false
        // `omarchy-shell shell summon s3pp3ku.bar-manager '{"view":"layout"}'` opens straight into the Layout screen
        try { var pl = JSON.parse(payloadJson || "{}"); if (pl.view === "layout" || pl.view === "list") root.view = pl.view } catch (e) {}
        closingFromHost = false
        window.visible = true
        refresh()
        refreshLayout()
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
            root.refreshLayout()
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
        implicitWidth: 860
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
                    Btn { label: root.view === "list" ? "Layout" : "List"; picked: root.view === "layout"
                          onClicked: { root.view = root.view === "list" ? "layout" : "list"; if (root.view === "layout") root.refreshLayout() } }
                    Btn { label: "+ Tray"; onClicked: root.act(["addtray", "auto", "right"], "Adding a tray") }
                    Btn { label: "Update all"; onClicked: root.act(["update", "--all"], "Updating all") }
                    Btn { label: "Refresh"; onClicked: root.refresh() }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: root.accent }

                RowLayout {
                    visible: root.view === "list"
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
                    visible: root.view === "list"
                    Layout.fillWidth: true
                    Layout.leftMargin: 6; Layout.rightMargin: 6
                    spacing: 6
                    Text { text: "BAR"; Layout.preferredWidth: 28; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                    Text { text: "PLUGIN"; Layout.fillWidth: true; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                    Text { text: "BAR / SECTION"; Layout.preferredWidth: 250; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                    Text { text: "ACTIONS"; Layout.preferredWidth: 215; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
                }
                Rectangle { visible: root.view === "list"; Layout.fillWidth: true; height: 1; color: root.dim }

                // ---- Layout screen: every bar drawn as it sits on the screen; drag chips between slots
                Item {
                    visible: root.view === "layout"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Item {
                        id: canvas
                        anchors.fill: parent
                        Component.onCompleted: root.canvasItem = canvas
                        readonly property real hThick: 124
                        readonly property real sideW: 180
                        readonly property var bars: root.layoutData.bars || ({})
                        function has(e) { return !!(bars[e] && bars[e].exists) }
                        function dataOf(e) { return bars[e] || ({ exists: false, main: false, sections: ({}) }) }
                        readonly property real topH: has("top") ? Math.min(230, Math.max(60, topBox.needH)) : 34
                        readonly property real botH: has("bottom") ? Math.min(180, Math.max(60, bottomBox.needH)) : 34
                        readonly property real leftW: has("left") ? sideW : 44
                        readonly property real rightW: has("right") ? sideW : 44

                        // top and bottom span the full width; the side bars run between them (as on the real screen)
                        BarBox { id: topBox; edge: "top"; barData: canvas.dataOf("top"); x: 0; y: 0; width: canvas.width; height: canvas.topH }
                        BarBox { id: bottomBox; edge: "bottom"; barData: canvas.dataOf("bottom"); x: 0; y: canvas.height - canvas.botH; width: canvas.width; height: canvas.botH }
                        BarBox { edge: "left"; barData: canvas.dataOf("left"); x: 0; y: canvas.topH; width: canvas.leftW; height: canvas.height - canvas.topH - canvas.botH }
                        BarBox { edge: "right"; barData: canvas.dataOf("right"); x: canvas.width - canvas.rightW; y: canvas.topH; width: canvas.rightW; height: canvas.height - canvas.topH - canvas.botH }

                        Text {
                            anchors.centerIn: parent
                            text: "your screen\ndrag a widget to a slot  ·  drop it on a tray to put it inside"
                            horizontalAlignment: Text.AlignHCenter
                            color: root.dim; font.family: root.mono; font.pixelSize: 12
                        }

                        Rectangle {   // hover label: which widget a chip is
                            z: 70
                            visible: root.tipItem !== null && root.dragInfo === null
                            readonly property point at: root.tipItem ? root.tipItem.mapToItem(canvas, 0, root.tipItem.height + 4) : Qt.point(0, 0)
                            x: Math.max(0, Math.min(canvas.width - width, at.x))
                            y: Math.min(canvas.height - height, at.y)
                            width: tipLabel.implicitWidth + 14; height: tipLabel.implicitHeight + 8
                            color: root.bg; border.color: root.accent; border.width: 1; radius: 3
                            Text { id: tipLabel; anchors.centerIn: parent; text: root.tipText
                                   color: root.fg; font.family: root.mono; font.pixelSize: 11 }
                        }
                        Rectangle {   // drop marker
                            z: 50
                            visible: root.dropTarget !== null
                            x: root.dropTarget ? root.dropTarget.rect.x : 0
                            y: root.dropTarget ? root.dropTarget.rect.y : 0
                            width: root.dropTarget ? root.dropTarget.rect.w : 0
                            height: root.dropTarget ? root.dropTarget.rect.h : 0
                            readonly property bool box: root.dropTarget ? (root.dropTarget.intray !== "" || root.dropTarget.rect.w > 10) : false
                            color: box ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22) : root.accent
                            border.color: root.accent; border.width: box ? 2 : 0
                        }
                        Rectangle {   // "it will become number N"
                            z: 55
                            visible: root.dropTarget !== null && root.dropTarget.num !== undefined
                            readonly property real mx: root.dropTarget ? root.dropTarget.rect.x : 0
                            readonly property real my: root.dropTarget ? root.dropTarget.rect.y : 0
                            x: Math.max(0, Math.min(canvas.width - width, mx + (root.dropTarget && root.dropTarget.rect.w > 10 ? 2 : -width / 2)))
                            y: Math.max(0, my - height + 2)
                            width: 22; height: 16; radius: 8
                            color: root.accent
                            Text { anchors.centerIn: parent; text: root.dropTarget && root.dropTarget.num !== undefined ? "#" + root.dropTarget.num : ""
                                   color: root.bg; font.family: root.mono; font.pixelSize: 10; font.bold: true }
                        }
                        Rectangle {   // the chip being dragged
                            z: 60
                            visible: root.dragInfo !== null
                            x: root.dragX + 12; y: root.dragY + 12
                            width: ghostText.implicitWidth + 14; height: 22
                            color: root.bg; border.color: root.accent; border.width: 1; radius: 3
                            Text { id: ghostText; anchors.centerIn: parent; text: root.dragInfo ? root.dragInfo.name : ""
                                   color: root.fg; font.family: root.mono; font.pixelSize: 11 }
                        }
                    }
                }

                ListView {
                    visible: root.view === "list"
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

                        function curSection() {
                            var sec = row.modelData.section || ""
                            if (sec.indexOf("/") >= 0) return sec.split("/")[1]
                            return ["left", "center", "right"].indexOf(sec) >= 0 ? sec : "right"
                        }
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

                            // Pick the bar (Top / Bottom / Left / Right) and the section (left / center / right).
                            Row {
                                spacing: 2
                                Repeater {
                                    model: [{ k: "top", t: "T" }, { k: "bottom", t: "B" }, { k: "left", t: "L" }, { k: "right", t: "R" }]
                                    Btn {
                                        required property var modelData
                                        label: modelData.t
                                        // a widget can be on several bars at once: each letter adds or removes that bar
                                        picked: row.modelData.isTray ? (row.modelData.bar === modelData.k)
                                                                     : (row.modelData.bars || []).indexOf(modelData.k) !== -1
                                        tip: "Toggle the " + modelData.k + " bar"
                                        onClicked: {
                                            if (row.modelData.isTray)
                                                root.act(["place", row.modelData.id, modelData.k, row.curSection()], "Moving to " + modelData.k)
                                            else
                                                root.act(["toggle", row.modelData.id, modelData.k, row.curSection()], (picked ? "Removing from " : "Adding to ") + modelData.k)
                                        }
                                    }
                                }
                            }
                            Row {
                                spacing: 2
                                Repeater {
                                    model: (row.modelData.bar === "left" || row.modelData.bar === "right")
                                       ? [{ k: "left", t: "↑" }, { k: "center", t: "·" }, { k: "right", t: "↓" }]
                                       : [{ k: "left", t: "‹" }, { k: "center", t: "·" }, { k: "right", t: "›" }]
                                    Btn {
                                        required property var modelData
                                        label: modelData.t
                                        picked: row.modelData.onBar && row.curSection() === modelData.k && row.modelData.section !== "tray"
                                        onClicked: root.act(row.modelData.isTray
                                            ? ["place", row.modelData.id, row.modelData.bar, modelData.k]
                                            : ["setsection", row.modelData.id, modelData.k], "Moving")
                                    }
                                }
                            }
                            Btn {
                                visible: !row.modelData.isTray
                                label: row.modelData.tray ? "▣" + row.modelData.tray.replace("tray:", "") : "▢"
                                picked: !!row.modelData.tray
                                onClicked: {
                                    // cycle: none -> first tray -> next tray ... -> none (back onto the bar)
                                    var trays = []
                                    for (var i = 0; i < root.items.length; i++) if (root.items[i].isTray) trays.push(root.items[i].id)
                                    if (trays.length === 0) { root.status = "Add a tray first (+ Tray)"; root.statusOk = false; return }
                                    var cur = trays.indexOf(row.modelData.tray)
                                    if (cur + 1 < trays.length) root.act(["intray", row.modelData.id, trays[cur + 1]], "Putting in " + trays[cur + 1])
                                    else root.act(["place", row.modelData.id, row.modelData.bar || "bottom", row.curSection()], "Taking out of tray")
                                }
                            }
                            Row {
                                Layout.preferredWidth: 215
                                spacing: 4
                                Btn {
                                    visible: !row.modelData.isTray
                                    label: row.modelData.onBar ? "Hide" : "Show"
                                    onClicked: root.act([row.modelData.onBar ? "hide" : "show", row.modelData.id], row.modelData.onBar ? "Hiding" : "Showing")
                                }
                                Btn {
                                    visible: !row.modelData.isTray
                                    label: row.modelData.enabled ? "Off" : "On"
                                    onClicked: root.act([row.modelData.enabled ? "disable" : "enable", row.modelData.id], row.modelData.enabled ? "Disabling" : "Enabling")
                                }
                                Btn {
                                    visible: row.modelData.canManage
                                    label: "Upd"
                                    onClicked: root.act(["update", row.modelData.id], "Updating")
                                }
                                Btn {
                                    visible: row.modelData.isTray === true
                                    danger: true
                                    label: "Del"
                                    onClicked: root.act(["rmtray", row.modelData.id], "Removing tray")
                                }
                                Btn {
                                    visible: row.modelData.canManage
                                    danger: true
                                    label: root.confirmId === row.modelData.id ? "Sure?" : "Del"
                                    onClicked: {
                                        if (root.confirmId === row.modelData.id) root.act(["uninstall", row.modelData.id], "Uninstalling")
                                        else root.confirmId = row.modelData.id
                                    }
                                }
                            }
                        }
                    }
                }

                // Status line
                Rectangle { Layout.fillWidth: true; height: 1; color: root.dim }
                Text {
                    Layout.fillWidth: true
                    text: root.status !== "" ? root.status : (root.view === "layout" ? "Esc closes.  Drag a chip to a slot; drop it on a tray to put it inside." : "Esc closes.  T B L R: click each bar you want it on (several at once).  ‹ · ›: section.")
                    elide: Text.ElideRight
                    color: root.status === "" ? root.dim : (root.statusOk ? root.accent : root.bad)
                    font.family: root.mono; font.pixelSize: 12
                }
            }
        }
    }

    // ---- Layout screen pieces
    component GrabArea: MouseArea {
        id: grab
        property var info: ({})
        property real pressX: 0
        property real pressY: 0
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.OpenHandCursor
        onPressed: function (m) { pressX = m.x; pressY = m.y }
        onPositionChanged: function (m) {
            if (!(m.buttons & Qt.LeftButton) || !root.canvasItem) return
            if (!root.dragInfo && Math.abs(m.x - pressX) + Math.abs(m.y - pressY) > 8) root.beginLayoutDrag(info)
            if (root.dragInfo) root.moveLayoutDrag(grab.mapToItem(root.canvasItem, m.x, m.y))
        }
        onReleased: function (m) { if (root.dragInfo) root.endLayoutDrag() }
        onCanceled: { root.dragInfo = null; root.dropTarget = null }
    }

    component MemberChip: Rectangle {
        id: mchip
        property var entry: ({})
        implicitWidth: 22
        implicitHeight: 20
        radius: 3
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        border.color: root.dim; border.width: 1
        opacity: root.dragInfo && root.dragInfo.id === entry.id ? 0.35 : 1
        readonly property bool iconIsImage: String(entry.icon || "").indexOf("img:") === 0
        Image {
            visible: mchip.iconIsImage
            anchors.centerIn: parent
            width: 17; height: 17
            fillMode: Image.PreserveAspectFit
            cache: false
            source: mchip.iconIsImage ? "file://" + String(mchip.entry.icon).substring(4) : ""
        }
        Text {
            visible: !mchip.iconIsImage
            anchors.centerIn: parent
            text: mchip.entry.icon ? mchip.entry.icon : root.monogram(mchip.entry.name)
            color: root.fg
            font.family: mchip.entry.icon ? Style.font.family : root.mono
            font.pixelSize: mchip.entry.icon ? 13 : 9
            font.bold: !mchip.entry.icon
        }
        HoverHandler { onHoveredChanged: { if (hovered) root.showTip(mchip, mchip.entry.name + "\n" + mchip.entry.id); else root.hideTip(mchip) } }
        GrabArea { anchors.fill: parent; info: ({ id: mchip.entry.id, name: mchip.entry.name, isTray: false, mainTray: false }) }
    }

    component Chip: Rectangle {
        id: chip
        property var entry: ({})
        readonly property bool isTray: !!entry.tray
        readonly property bool mainTray: entry.id === "io.github.tyrichards.tray"
        readonly property var members: entry.members || []
        radius: 3
        color: isTray ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.06) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        border.color: isTray ? root.accent : root.dim
        border.width: 1
        // a tray is as wide as its icons need (up to a limit, then they wrap)
        implicitWidth: isTray ? Math.min(230, Math.max(70, members.length * 25 + 10)) : 28
        implicitHeight: isTray ? 22 + (members.length ? memberFlow.implicitHeight + 5 : 2) : 24
        opacity: root.dragInfo && root.dragInfo.id === entry.id ? 0.35 : 1
        readonly property bool iconIsImage: String(entry.icon || "").indexOf("img:") === 0
        Image {
            visible: !chip.isTray && chip.iconIsImage
            anchors.centerIn: parent
            width: 21; height: 21
            fillMode: Image.PreserveAspectFit
            cache: false
            source: chip.iconIsImage ? "file://" + String(chip.entry.icon).substring(4) : ""
        }
        Text {
            visible: !chip.isTray && !chip.iconIsImage
            anchors.centerIn: parent
            text: chip.entry.icon ? chip.entry.icon : root.monogram(chip.entry.name)
            color: root.fg
            font.family: chip.entry.icon ? Style.font.family : root.mono
            font.pixelSize: chip.entry.icon ? 15 : 10
            font.bold: !chip.entry.icon
        }
        Text { visible: chip.isTray; x: 6; y: 3; text: "▣ " + (chip.mainTray ? "tray" : String(chip.entry.name).replace(/^Tray /, "")) + (chip.members.length ? "" : " (empty)")
               color: root.accent; font.family: root.mono; font.pixelSize: 10; font.bold: true }
        Flow {
            id: memberFlow
            visible: chip.isTray
            x: 5; y: 22
            width: chip.width - 10
            spacing: 3
            Repeater { model: chip.members; delegate: MemberChip { required property var modelData; entry: modelData } }
        }
        HoverHandler { onHoveredChanged: { if (hovered) root.showTip(chip, chip.entry.name + "\n" + chip.entry.id); else root.hideTip(chip) } }
        // plain chips grab anywhere; a tray only by its header, so its members can be grabbed on their own
        GrabArea {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: chip.isTray ? 20 : parent.height
            info: ({ id: chip.entry.id, name: chip.entry.name, isTray: chip.isTray && !chip.mainTray, mainTray: chip.mainTray })
        }
    }

    // One numbered grid cell: a widget sits in it, or it is the spare cell at the end of a section.
    component Cell: Rectangle {
        id: cell
        property var entry: ({})
        property int num: 1
        readonly property bool spare: !!entry.spare
        readonly property bool dragged: !spare && root.dragInfo !== null && root.dragInfo.id === entry.id
        readonly property bool target: root.dropTarget !== null && root.dropTarget.cellKey === cellKey
        property string cellKey: ""
        implicitWidth: spare ? 34 : (chipHolder.item ? chipHolder.item.implicitWidth : 28) + 8
        implicitHeight: spare ? 34 : (chipHolder.item ? chipHolder.item.implicitHeight : 24) + 11
        color: spare ? "transparent" : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.03)
        border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, spare ? 0.28 : 0.5)
        border.width: 1
        radius: 2
        Text {
            x: 3; y: 1
            text: String(cell.num)
            color: root.accent
            opacity: 0.85
            font.family: root.mono; font.pixelSize: 8; font.bold: true
        }
        Loader {
            id: chipHolder
            active: !cell.spare
            x: 4; y: 10
            sourceComponent: Component { Chip { entry: cell.entry } }
        }
    }

    component Zone: Rectangle {
        id: zone
        property string edge: ""
        property string section: ""
        property string title: ""
        property var entries: []
        readonly property real contentH: zflow.implicitHeight + 22
        Layout.minimumHeight: contentH
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
        border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.5); border.width: 1
        clip: true
        Text { x: 5; y: 2; text: zone.title; color: root.dim; font.family: root.mono; font.pixelSize: 9 }
        Flow {
            id: zflow
            x: 4; y: 14
            width: zone.width - 8
            spacing: 3
            Repeater {
                id: zrep
                model: (zone.entries || []).concat([{ spare: true, id: "" }])
                delegate: Cell { required property var modelData; required property int index; entry: modelData; num: index + 1 }
            }
        }
        // where each cell with a widget sits, in this zone's coordinates (the dragged one left out)
        function slotInfo(excludeId) {
            var out = []
            for (var i = 0; i < zrep.count; i++) {
                var it = zrep.itemAt(i)
                if (!it || it.spare || it.entry.id === excludeId) continue
                var p = it.mapToItem(zone, 0, 0)
                out.push({ id: it.entry.id, x: p.x, y: p.y, w: it.width, h: it.height, isTray: !!it.entry.tray })
            }
            return out
        }
        // the spare cell at the end: where "append" lands
        function spareRect() {
            var it = zrep.itemAt(zrep.count - 1)
            if (!it) return null
            var p = it.mapToItem(zone, 0, 0)
            return { x: p.x, y: p.y, w: it.width, h: it.height }
        }
        Component.onCompleted: root.registerZone(zone)
    }

    component BarBox: Rectangle {
        id: box
        property string edge: ""
        property var barData: ({ exists: false, main: false, sections: ({}) })
        readonly property bool vertical: edge === "left" || edge === "right"
        readonly property var secs: barData.sections || ({})
        // how tall the busiest section needs to be (for a top or bottom bar)
        readonly property real needH: Math.max(zoneA.contentH, zoneB.contentH, zoneC.contentH) + 8
        color: barData.exists ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08) : "transparent"
        border.color: barData.exists ? root.accent : Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.5)
        border.width: 1
        Text {
            visible: box.barData.exists
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 3
            text: box.edge + (box.barData.main ? " · main" : "")
            color: root.accent; font.family: root.mono; font.pixelSize: 9; font.bold: true; z: 5
        }
        GridLayout {
            anchors.fill: parent; anchors.margins: 3
            columns: box.vertical ? 1 : 3
            rowSpacing: 3; columnSpacing: 3
            visible: box.barData.exists
            Zone { id: zoneA; Layout.fillWidth: true; Layout.fillHeight: true; edge: box.edge; section: "left"
                   title: box.vertical ? "top" : "left"; entries: box.secs.left || [] }
            Zone { id: zoneB; Layout.fillWidth: true; Layout.fillHeight: true; edge: box.edge; section: "center"
                   title: box.vertical ? "middle" : "center"; entries: box.secs.center || [] }
            Zone { id: zoneC; Layout.fillWidth: true; Layout.fillHeight: true; edge: box.edge; section: "right"
                   title: box.vertical ? "bottom" : "right"; entries: box.secs.right || [] }
        }
        Btn {
            visible: !box.barData.exists
            anchors.centerIn: parent
            label: box.vertical ? "+" + box.edge.charAt(0).toUpperCase() : "+ add " + box.edge + " bar"
            onClicked: root.act(["togglebar", box.edge], "Adding the " + box.edge + " bar")
        }
    }

    // Old-school text button: [ Label ], inverts on hover.
    component Btn: Rectangle {
        id: btn
        property string label: ""
        property bool danger: false
        property bool picked: false
        property string tip: ""
        signal clicked()
        readonly property color tone: danger ? root.bad : root.fg
        implicitWidth: txt.implicitWidth + 12
        implicitHeight: 22
        color: (ma.containsMouse || picked) ? tone : "transparent"
        border.color: tone
        border.width: 1
        opacity: root.busy ? 0.5 : 1
        Text {
            id: txt
            anchors.centerIn: parent
            text: btn.label
            color: (ma.containsMouse || btn.picked) ? root.bg : btn.tone
            font.family: root.mono; font.pixelSize: 11
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; enabled: !root.busy; onClicked: btn.clicked() }
    }
}
