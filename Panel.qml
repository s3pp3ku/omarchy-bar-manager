import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Panel-kind plugin: manage which bar widgets are enabled / on the bar.
// All real work is done by bin/barctl; this is only a front end for it.
Item {
    id: root

    property var shell: null
    property var manifest: null
    property bool closingFromHost: false
    property bool opened: false
    property bool tiled: false

    readonly property string barctl: String(Qt.resolvedUrl("bin/barctl")).replace("file://", "")
    property var items: []
    property var marketplace: []
    property var marketSelection: null
    property string marketConfirm: ""
    property string shortcutPlugin: ""
    property string marketSearch: ""
    property string marketScope: "All"
    property string filter: ""
    property string status: ""
    property bool statusOk: true
    property string confirmId: ""     // id awaiting uninstall confirmation
    property bool addingTray: false
    property string trayEdge: "bottom"
    property string traySection: "right"

    readonly property string nextTrayId: {
        var n = 1
        while (items.some(function(p) { return p.id === "tray:t" + n })) n++
        return "tray:t" + n
    }
    function edgeHasBar(edge) { return edge === layoutData.main || !!(layoutData.bars || {})[edge] }
    function openAddTray() {
        var edges = ["bottom", "top", "left", "right"], pick = ""
        for (var i = 0; i < edges.length && !pick; i++) if (edges[i] !== layoutData.main && edgeHasBar(edges[i])) pick = edges[i]
        for (var j = 0; j < edges.length && !pick; j++) if (edges[j] !== layoutData.main) pick = edges[j]
        trayEdge = pick
        addingBar = false
        addingTray = true
    }
    property bool addingBar: false
    property string barEdge: ""
    readonly property var freeEdges: ["bottom", "left", "right", "top"].filter(function(e) { return !root.edgeHasBar(e) })
    function openAddBar() {
        if (freeEdges.indexOf(barEdge) < 0) barEdge = freeEdges.length ? freeEdges[0] : ""
        addingTray = false
        addingBar = true
    }
    function itemName(id) {
        for (var i = 0; i < items.length; i++) if (items[i].id === id) return items[i].name
        return id
    }
    function trayMembers(row) {
        return (row.members || []).map(function(m) {
            var id = typeof m === "string" ? m : (m.entry ? (typeof m.entry === "string" ? m.entry : m.entry.id) : m.id)
            return itemName(id || "")
        })
    }
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
        try { var pl = JSON.parse(payloadJson || "{}"); if (["layout", "list", "saved", "updates", "install"].indexOf(pl.view) >= 0) root.view = pl.view } catch (e) {}
        closingFromHost = false
        root.opened = true
        refresh()
        refreshLayout()
        snapshotsProc.running = true
        Qt.callLater(function () { if (root.opened) keyCatcher.forceActiveFocus() })
    }
    function close() { remember(false); closingFromHost = true; root.opened = false; closingFromHost = false }
    function requestClose() {
        remember(false)
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide((root.manifest && root.manifest.id) || "s3pp3ku.bar-manager")
        else root.opened = false
    }

    property var collapsed: ({})
    property string selectedKey: ""
    property string selectedPluginId: ""
    property real savedScroll: 0
    property var savedLayouts: []
    property var updateReports: []
    property string layoutName: "My layout"
    property string restoreConfirm: ""
    property var commandQueue: []
    property var activeArgs: []
    property bool remembering: false
    readonly property string uiPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/bar-manager/ui.json"

    function remember(reopen) {
        if (remembering) return
        uiFile.setText(JSON.stringify({ view: view, filter: filter, collapsed: collapsed,
            selectedKey: selectedKey, selectedPluginId: selectedPluginId, scroll: pluginList.contentY, reopen: !!reopen, at: Date.now() }))
    }
    Timer { id: rememberDelay; interval: 250; onTriggered: root.remember(false) }
    FileView {
        id: uiFile
        path: root.uiPath
        atomicWrites: true
        printErrors: false
        onLoaded: {
            try {
                var state = JSON.parse(uiFile.text())
                root.remembering = true
                root.view = state.view || "list"
                root.filter = state.filter || ""
                root.collapsed = state.collapsed || {}
                root.selectedKey = state.selectedKey || ""
                root.selectedPluginId = state.selectedPluginId || ""
                root.savedScroll = state.scroll || 0
                root.remembering = false
                if (state.reopen && Date.now() - state.at < 60000) {
                    root.open("{}")
                    root.remember(false)
                }
            } catch (e) { root.remembering = false }
        }
    }
    onFilterChanged: rememberDelay.restart()
    onViewChanged: rememberDelay.restart()
    function fold(key) {
        var next = Object.assign({}, collapsed)
        next[key] = !next[key]
        collapsed = next
        rememberDelay.restart()
    }
    function reconcileSelection() {
        if (findSelected()) return
        for (var i = 0; i < listRows.length; i++) if (!listRows[i].header && listRows[i].id === selectedPluginId) {
            selectedKey = listRows[i].key
            return
        }
    }
    onListRowsChanged: Qt.callLater(reconcileSelection)
    function findSelected() {
        for (var i = 0; i < listRows.length; i++) if (listRows[i].key === selectedKey) return listRows[i]
        return null
    }
    function selectStep(delta) {
        var at = -1
        for (var i = 0; i < listRows.length; i++) if (listRows[i].key === selectedKey) at = i
        var next = Math.max(0, Math.min(listRows.length - 1, at + delta))
        while (next >= 0 && next < listRows.length && listRows[next].header) next += delta
        if (next < 0 || next >= listRows.length) return
        selectedKey = listRows[next].key
        selectedPluginId = listRows[next].id
        pluginList.positionViewAtIndex(next, ListView.Contain)
        savedScroll = pluginList.contentY
        rememberDelay.restart()
    }
    function handleKey(event) {
        if (event.isAutoRepeat) return
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) { root.view = "list"; searchInput.forceActiveFocus(); event.accepted = true; return }
        if (view !== "list" || busy) return
        var shift = !!(event.modifiers & Qt.ShiftModifier)
        var ctrl = !!(event.modifiers & Qt.ControlModifier)
        var row = findSelected()
        if (ctrl && event.key === Qt.Key_Z) { act(["undo"], "Undoing"); event.accepted = true; return }
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            var delta = event.key === Qt.Key_Up ? -1 : 1
            if (shift && row && row.onBar) act(["reorder", row.id, row.contextBar, row.contextSection, String(delta), row.contextTray || ""], "Reordering")
            else selectStep(delta)
            event.accepted = true
        } else if (row && shift && (event.key === Qt.Key_Left || event.key === Qt.Key_Right) && row.onBar && !row.contextTray) {
            var sections = ["left", "center", "right"]
            var next = Math.max(0, Math.min(2, sections.indexOf(row.contextSection) + (event.key === Qt.Key_Left ? -1 : 1)))
            act(["move-section", row.id, row.contextBar, sections[next]], "Changing section")
            event.accepted = true
        } else if (row && (event.modifiers & Qt.AltModifier) && [Qt.Key_T, Qt.Key_B, Qt.Key_L, Qt.Key_R].indexOf(event.key) >= 0) {
            var edge = ["top", "bottom", "left", "right"][[Qt.Key_T, Qt.Key_B, Qt.Key_L, Qt.Key_R].indexOf(event.key)]
            act(["place", row.id, edge, row.contextSection || "right"], "Moving to " + edge)
            event.accepted = true
        } else if (row && event.key >= Qt.Key_1 && event.key <= Qt.Key_3 && !row.contextTray) {
            act([row.onBar ? "move-section" : "place", row.id, row.contextBar || layoutData.main, ["left", "center", "right"][event.key - Qt.Key_1]], "Changing section")
            event.accepted = true
        } else if (row && event.key === Qt.Key_Space && !row.isTray) {
            act([row.onBar ? "hide" : "show", row.id], row.onBar ? "Hiding" : "Showing")
            event.accepted = true
        }
    }
    readonly property var listRows: {
        var byId = {}, allowed = {}, seen = {}, result = []
        for (var i = 0; i < items.length; i++) byId[items[i].id] = items[i]
        for (var i = 0; i < shown.length; i++) allowed[shown[i].id] = true
        function addGroup(key, title, entries, edge, section, tray) {
            var matches = entries.filter(function(e) { return !!allowed[e.id] })
            if (!matches.length) return
            result.push({ header: true, key: key, name: title + " (" + matches.length + ")", id: "", onBar: false, enabled: true, canManage: false, isTray: false, section: "", bar: "", tray: "", bars: [], sourceDir: "", description: "", firstParty: false })
            for (var j = 0; j < matches.length; j++) {
                var e = matches[j], meta = byId[e.id]
                if (!meta) continue
                seen[e.id] = true
                if (!filter && collapsed[key]) continue
                var row = Object.assign({}, meta)
                row.key = key + ":" + e.id
                row.contextBar = edge
                row.contextSection = section
                row.contextTray = tray || ""
                row.section = edge ? edge + "/" + section : ""
                row.bar = edge
                row.tray = tray || ""
                result.push(row)
            }
        }
        var edges = ["top", "bottom", "left", "right"]
        var sections = ["left", "center", "right"]
        for (var b = 0; b < edges.length; b++) {
            var edge = edges[b], bar = (layoutData.bars || {})[edge]
            if (!bar || !bar.exists) continue
            for (var s = 0; s < sections.length; s++) {
                var section = sections[s], entries = (bar.sections || {})[section] || []
                var side = edge === "left" || edge === "right"
                addGroup(edge + "/" + section, edge + " · " + (side ? ["top", "middle", "bottom"][s] : section), entries, edge, section, "")
                for (var t = 0; t < entries.length; t++) if (entries[t].tray)
                    addGroup(edge + "/" + entries[t].id, edge + " · " + entries[t].name, entries[t].members || [], edge, section, entries[t].id)
            }
        }
        addGroup("available", "Available", shown.filter(function(p) { return !seen[p.id] && !p.onBar }), "", "right", "")
        return result
    }
    Process {
        id: snapshotsProc
        command: [root.barctl, "snapshots"]
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.savedLayouts = JSON.parse(text) } catch(e) {} } }
    }
    function reviewUpdates(id) {
        view = "updates"
        updateReports = []
        act(["check-updates", id], "Checking updates")
    }

    IpcHandler {
        target: "s3pp3ku.bar-manager.ui"
        function status(): string {
            return JSON.stringify({ view: root.view, plugins: root.items.length, rows: root.listRows.length,
                groups: root.listRows.filter(function(r) { return !!r.header }).length,
                layouts: root.savedLayouts.length, selected: root.selectedKey, busy: root.busy })
        }
    }

    property var pending: null
    function refresh() { listProc.running = true }
    function act(args, label) {
        root.confirmId = ""
        for (var i = 0; i < items.length; i++) if (items[i].id === args[1]) selectedPluginId = args[1]
        if (args[0] === "move-section" || args[0] === "place") selectedKey = args[2] + "/" + args[3] + ":" + args[1]
        root.status = label + "…"
        root.statusOk = true
        remember(true)
        commandQueue = commandQueue.concat([args])
        pumpCommands()
    }
    function pumpCommands() {
        if (runner.running || commandQueue.length === 0) return
        activeArgs = commandQueue[0]
        commandQueue = commandQueue.slice(1)
        runner.command = [root.barctl].concat(activeArgs)
        runner.running = true
    }

    Process {
        id: listProc
        command: [root.barctl, "list"]
        stdout: StdioCollector {
            id: listOut
            waitForEnd: true
            onStreamFinished: {
                try { root.items = JSON.parse(listOut.text); Qt.callLater(function() {
                    pluginList.contentY = Math.max(0, Math.min(root.savedScroll, pluginList.contentHeight - pluginList.height))
                }) } catch (e) { root.status = "Could not read plugin list"; root.statusOk = false }
            }
        }
    }

    Process {
        id: runner
        stdout: StdioCollector { id: rOut; waitForEnd: true }
        stderr: StdioCollector { id: rErr; waitForEnd: true }
        onExited: function (code) {
            root.statusOk = code === 0
            if (code === 0 && root.activeArgs[0] === "check-updates") {
                try { root.updateReports = JSON.parse(rOut.text) } catch(e) { root.statusOk = false }
            }
            if (code === 0 && root.activeArgs[0] === "marketplace") {
                try { root.marketplace = JSON.parse(rOut.text) } catch(e) { root.statusOk = false }
            }
            var msg = (code === 0 ? rOut.text : (rErr.text || rOut.text)).trim().split("\n")
            root.status = root.activeArgs[0] === "check-updates" && code === 0 ? "Review each update before applying it" : (msg[msg.length - 1] || (code === 0 ? "Done" : "Failed"))
            if (code === 0 && root.activeArgs[0] === "marketplace") root.status = "Marketplace loaded: " + root.marketplace.length + " plugins"
            if (code === 0 && root.activeArgs[0] === "apply-update") {
                var reports = root.updateReports.slice()
                for (var i = 0; i < reports.length; i++) if (reports[i].token === root.activeArgs[1]) {
                    reports[i] = Object.assign({}, reports[i], { status: "updated", token: "" })
                }
                root.updateReports = reports
            }
            if (code === 0 && root.activeArgs[0] === "market-install") {
                root.marketplace = root.marketplace.map(function(p) { return p.id === root.activeArgs[1] ? Object.assign({}, p, { installed: true }) : p })
                if (root.marketSelection && root.marketSelection.id === root.activeArgs[1]) root.marketSelection = Object.assign({}, root.marketSelection, { installed: true })
            }
            snapshotsProc.running = true
            root.remember(false)
            Qt.callLater(root.pumpCommands)
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

    // Use the same shell menu roles and state tokens as Plugin Manager.
    function luminance(c) {
        function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }
    function contrast(a, b) {
        var l1 = luminance(a), l2 = luminance(b)
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
    }
    function mix(a, b, t) {
        return Qt.rgba(a.r * t + b.r * (1 - t), a.g * t + b.g * (1 - t), a.b * t + b.b * (1 - t), 1)
    }

    // Push a color toward black/white (whichever the background is not) until it reaches `min` contrast.
    function ensure(c, min) {
        if (contrast(c, solidBg) >= min) return Qt.rgba(c.r, c.g, c.b, 1)
        var target = isLight ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
        for (var t = 0.08; t < 1; t += 0.08) {
            var m = mix(target, c, t)
            if (contrast(m, solidBg) >= min) return m
        }
        return target
    }
    function textOn(fill) {
        var dark = Qt.rgba(0.06, 0.06, 0.06, 1), light = Qt.rgba(0.98, 0.98, 0.98, 1)
        return contrast(fill, dark) >= contrast(fill, light) ? dark : light
    }
    function hueGap(a, b) {
        var d = Math.abs(a - b)
        return Math.min(d, 1 - d)
    }
    // Second accent: the theme's most saturated ANSI color whose hue sits furthest from the main accent.
    function pickAccent2() {
        // Blues, magentas, cyans and orange first; green/yellow/red stay free for status colors.
        var tiers = [["color4", "color5", "color6", "color12", "color13", "color14", "orange"],
                     ["color2", "color3", "color10", "color11"]]
        var base = Color.accent
        for (var t = 0; t < tiers.length; t++) {
            var best = null, bestScore = -1
            for (var i = 0; i < tiers[t].length; i++) {
                var hex = themeAnsi[tiers[t][i]]
                if (!hex) continue
                var c = Qt.color(hex)
                if (c.hslSaturation < 0.2 || c.hslHue < 0) continue
                var gap = base.hslSaturation < 0.12 || base.hslHue < 0 ? 0.25 : hueGap(c.hslHue, base.hslHue)
                if (gap < 0.08) continue
                var score = gap * 2 + c.hslSaturation
                if (score > bestScore) { bestScore = score; best = c }
            }
            if (best) return best
        }
        return mix(fg, solidBg, 0.85)
    }
    function ansi(key, fallback) { return themeAnsi[key] ? Qt.color(themeAnsi[key]) : fallback }

    property var themeAnsi: ({})
    FileView {
        id: themeFile
        path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            var out = {}, lines = text().split("\n")
            for (var i = 0; i < lines.length; i++) {
                var m = lines[i].match(/^\s*([a-z_]+\d*)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
                if (m) out[m[1]] = m[2]
            }
            // Omarchy themes name their palette (red, green, ...) instead of color0-15.
            var names = { red: 1, green: 2, yellow: 3, blue: 4, magenta: 5, cyan: 6 }
            for (var n in names) {
                if (!out["color" + names[n]] && out[n]) out["color" + names[n]] = out[n]
                if (!out["color" + (names[n] + 8)] && out["bright_" + n]) out["color" + (names[n] + 8)] = out["bright_" + n]
            }
            root.themeAnsi = out
        }
    }
    Connections {
        target: Color
        function onAccentChanged() { themeFile.reload() }
        function onBackgroundChanged() { themeFile.reload() }
    }
    onOpenedChanged: if (opened) themeFile.reload()

    readonly property color bg: Color.popups.background
    readonly property color solidBg: Qt.rgba(bg.r, bg.g, bg.b, 1)
    readonly property bool isLight: luminance(solidBg) > 0.4
    readonly property color fg: ensure(Color.popups.text, 7)
    readonly property color dim: ensure(mix(fg, solidBg, 0.66), 4.6)
    readonly property color outline: ensure(mix(fg, solidBg, 0.35), 3)
    readonly property color outlineSoft: ensure(mix(fg, solidBg, 0.18), 1.6)
    readonly property color raised: mix(fg, solidBg, isLight ? 0.04 : 0.06)
    readonly property color surface: Qt.rgba(raised.r, raised.g, raised.b, Math.max(bg.a, 0.92))
    readonly property color sunken: mix(fg, solidBg, isLight ? 0.08 : 0.03)

    readonly property color accent: ensure(Color.accent, 3)
    readonly property color accentText: ensure(Color.accent, 4.6)
    readonly property color onAccent: textOn(accent)
    readonly property color accent2: ensure(pickAccent2(), 3)
    readonly property color accent2Text: ensure(pickAccent2(), 4.6)
    readonly property color onAccent2: textOn(accent2)
    readonly property color good: ensure(ansi("color2", accent), 4.6)
    readonly property color warn: ensure(ansi("color3", accent2), 4.6)
    readonly property color bad: ensure(Color.urgent, 4.6)

    readonly property color hoverSurface: mix(accent, surface, 0.12)
    readonly property color selectedSurface: mix(accent, surface, 0.2)
    readonly property string mono: Style.font.family

    FloatingWindow {
        id: window
        title: "Bar Manager"
        visible: root.opened && root.tiled
        color: root.bg
        implicitWidth: 1040
        implicitHeight: 720
        minimumSize: Qt.size(560, 440)

        onClosed: root.requestClose()
    }

    PanelWindow {
        id: dropdown
        visible: root.opened && !root.tiled
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "bar-manager"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        MouseArea { anchors.fill: parent; onClicked: root.requestClose() }
    }

    Rectangle {
        id: card
        parent: root.tiled ? window.contentItem : dropdown.contentItem
        width: root.tiled ? parent.width : Math.min(920, parent.width - 24)
        height: root.tiled ? parent.height : Math.min(720, parent.height - 80)
        x: root.tiled ? 0 : parent.width - width - 12
        y: root.tiled ? 0 : 48
        color: root.bg
        radius: root.tiled ? 0 : Style.cornerRadius
        border.color: Color.menu.border
        border.width: root.tiled ? 0 : 1
        MouseArea { anchors.fill: parent; onClicked: {} }

        Item {
            id: keyCatcher
            Rectangle { anchors.fill: parent; color: root.bg; z: -1 }
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: { if (root.restoreConfirm) root.restoreConfirm = ""; else root.requestClose() }
            Keys.onPressed: function(event) { root.handleKey(event) }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                // Title bar
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text { text: "Bar Manager"; color: root.fg; font.family: root.mono; font.pixelSize: 17; font.bold: true }
                    Text {
                        id: countText
                        text: (root.filter ? root.shown.length + " of " : "") + root.items.length + " plugins"
                        color: root.dim; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body)
                        HoverHandler { id: countHover }
                        PanelToolTip { visible: countHover.hovered; text: "Every bar widget this Omarchy install has, enabled or not" }
                    }
                    Item { Layout.fillWidth: true }
                    HeaderBtn { label: root.tiled ? "Dropdown" : "Tile window"; tip: "Switch between dropdown and tiled window"; onClicked: { root.tiled = !root.tiled; Qt.callLater(function() { keyCatcher.forceActiveFocus() }) } }
                    HeaderBtn { label: "Close"; tip: "Esc"; onClicked: root.requestClose() }
                }

                // Views on the left, one-off actions on the right
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16
                    Flow {
                        Layout.fillWidth: true
                        Layout.preferredHeight: implicitHeight
                        spacing: 6
                        HeaderBtn { tab: true; label: "List"; picked: root.view === "list"; onClicked: root.view = "list" }
                        HeaderBtn { tab: true; label: "Layout"; picked: root.view === "layout"; tip: "Drag widgets between bars and trays"; onClicked: { root.view = "layout"; root.refreshLayout() } }
                        HeaderBtn { tab: true; label: "Marketplace"; picked: root.view === "install"; tip: "Install a plugin from a Git URL or browse the marketplace"
                                    onClicked: { root.view = "install"; if (!root.marketplace.length) root.act(["marketplace"], "Loading marketplace") } }
                        HeaderBtn { tab: true; label: "Updates"; picked: root.view === "updates"; tip: "Preview available updates and review local changes before applying"
                                    onClicked: root.reviewUpdates("--all") }
                        HeaderBtn { tab: true; label: "Saved layouts"; picked: root.view === "saved"; tip: "Save every bar, restore a layout, or undo a change"
                                    onClicked: { root.view = "saved"; snapshotsProc.running = true } }
                        HeaderBtn { tab: true; label: "Keys"; picked: root.view === "shortcuts"; tip: "Assign plugin launch shortcuts"; onClicked: root.view = "shortcuts" }
                    }
                    Row {
                        Layout.alignment: Qt.AlignTop
                        spacing: 6
                        HeaderBtn { label: "+ Bar"; picked: root.addingBar; tip: "Add a new bar on an empty screen edge"
                                    onClicked: root.addingBar ? root.addingBar = false : root.openAddBar() }
                        HeaderBtn { label: "+ Tray"; picked: root.addingTray; tip: "Choose a bar and section for a new empty tray (a chevron drawer)"
                                    onClicked: root.addingTray ? root.addingTray = false : root.openAddTray() }
                        HeaderBtn { label: "Undo"; tip: "Undo the last bar layout change (Ctrl+Z)"; onClicked: root.act(["undo"], "Undoing") }
                        HeaderBtn { label: "Refresh"; tip: "Re-read the plugin list and bar layout from disk"; onClicked: root.refresh() }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: root.outlineSoft }

                // Add-bar form: only empty edges can be picked (togglebar would remove an existing bar)
                Rectangle {
                    visible: root.addingBar
                    Layout.fillWidth: true
                    Layout.preferredHeight: addBarBody.implicitHeight + 28
                    radius: Style.cornerRadius
                    color: root.surface
                    border.color: root.accent2; border.width: 2
                    ColumnLayout {
                        id: addBarBody
                        x: 16; y: 14; width: parent.width - 32
                        spacing: 12
                        Text { text: "New bar"; color: root.accent2Text; font.family: root.mono; font.pixelSize: 15; font.bold: true }
                        Labeled {
                            title: "Edge"
                            SegGroup {
                                Repeater {
                                    model: [{ k: "top", t: "Top" }, { k: "bottom", t: "Bottom" }, { k: "left", t: "Left" }, { k: "right", t: "Right" }]
                                    SegBtn {
                                        required property var modelData
                                        readonly property bool taken: root.edgeHasBar(modelData.k)
                                        enabled: !taken
                                        label: modelData.t + (modelData.k === root.layoutData.main ? " (main)" : taken ? " (has a bar)" : "")
                                        picked: !taken && root.barEdge === modelData.k
                                        onClicked: root.barEdge = modelData.k
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: !root.barEdge
                                      ? "Every edge of the screen already has a bar, so there's nowhere to add one."
                                      : "Adds an empty bar along the " + root.barEdge + " edge of the screen."
                                        + "  If you had a " + root.barEdge + " bar before and removed it, its widgets come back with it."
                                        + "  Then fill it from the List (Bars buttons) or by dragging on the Layout screen."
                                color: root.fg; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body)
                            }
                            Btn {
                                visible: root.barEdge !== ""
                                picked: true
                                bold: true
                                label: "Add " + root.barEdge + " bar"
                                onClicked: {
                                    if (!root.edgeHasBar(root.barEdge)) root.act(["togglebar", root.barEdge], "Adding the " + root.barEdge + " bar")
                                    root.addingBar = false
                                }
                            }
                            Btn { label: root.barEdge ? "Cancel" : "Close"; onClicked: root.addingBar = false }
                        }
                    }
                }

                // Add-tray form: pick where the new tray goes before creating it
                Rectangle {
                    visible: root.addingTray
                    Layout.fillWidth: true
                    Layout.preferredHeight: addTrayBody.implicitHeight + 28
                    radius: Style.cornerRadius
                    color: root.surface
                    border.color: root.accent2; border.width: 2
                    ColumnLayout {
                        id: addTrayBody
                        x: 16; y: 14; width: parent.width - 32
                        spacing: 12
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "New tray"; color: root.accent2Text; font.family: root.mono; font.pixelSize: 15; font.bold: true }
                            Text {
                                Layout.fillWidth: true
                                text: root.nextTrayId.replace("tray:", "")
                                color: root.dim; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body)
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 20
                            Labeled {
                                title: "Bar"
                                SegGroup {
                                    Repeater {
                                        model: [{ k: "top", t: "Top" }, { k: "bottom", t: "Bottom" }, { k: "left", t: "Left" }, { k: "right", t: "Right" }]
                                        SegBtn {
                                            required property var modelData
                                            enabled: modelData.k !== root.layoutData.main
                                            label: modelData.t + (modelData.k === root.layoutData.main ? " (main)" : "")
                                            picked: root.trayEdge === modelData.k
                                            onClicked: root.trayEdge = modelData.k
                                        }
                                    }
                                }
                            }
                            Labeled {
                                title: "Section"
                                SegGroup {
                                    Repeater {
                                        model: root.trayEdge === "left" || root.trayEdge === "right"
                                            ? [{ k: "left", t: "Top" }, { k: "center", t: "Middle" }, { k: "right", t: "Bottom" }]
                                            : [{ k: "left", t: "Left" }, { k: "center", t: "Center" }, { k: "right", t: "Right" }]
                                        SegBtn {
                                            required property var modelData
                                            label: modelData.t
                                            picked: root.traySection === modelData.k
                                            onClicked: root.traySection = modelData.k
                                        }
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                readonly property string sectionName: (root.trayEdge === "left" || root.trayEdge === "right")
                                    ? ({ left: "top", center: "middle", right: "bottom" }[root.traySection])
                                    : ({ left: "left", center: "center", right: "right" }[root.traySection])
                                text: "Adds " + root.nextTrayId.replace("tray:", "") + " to the " + sectionName + " of the " + root.trayEdge + " bar."
                                      + (root.edgeHasBar(root.trayEdge) ? "" : "  There's no " + root.trayEdge + " bar yet, so one will be created.")
                                      + "  The main (" + root.layoutData.main + ") bar keeps its trays in the Tray plugin."
                                color: root.fg; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body)
                            }
                            Btn {
                                picked: true
                                bold: true
                                label: "Add tray"
                                onClicked: { root.act(["addtray", root.trayEdge, root.traySection], "Adding " + root.nextTrayId + " to the " + root.trayEdge + " bar"); root.addingTray = false }
                            }
                            Btn { label: "Cancel"; onClicked: root.addingTray = false }
                        }
                    }
                }

                Rectangle {
                    id: searchBox
                    visible: root.view === "list"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: Style.cornerRadius
                    color: root.sunken
                    border.color: searchInput.activeFocus ? root.accent : root.outline
                    border.width: searchInput.activeFocus ? 2 : 1
                    Text {
                        id: searchIcon
                        anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                        text: "Search"; color: root.dim; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body)
                    }
                    TextInput {
                        id: searchInput
                        text: root.filter
                        Keys.onDownPressed: { keyCatcher.forceActiveFocus(); root.selectStep(1) }
                        anchors.left: searchIcon.right; anchors.leftMargin: 10
                        anchors.right: clearSearch.left; anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.fg; font.family: root.mono; font.pixelSize: Math.max(14, Style.font.body)
                        selectionColor: root.accent; selectedTextColor: root.onAccent
                        clip: true
                        onTextChanged: root.filter = text
                        Text {
                            visible: !searchInput.text
                            text: "name, id or a rough word like \"sound\""
                            color: root.dim; font: searchInput.font; opacity: 0.8
                        }
                    }
                    Text {
                        id: clearSearch
                        visible: !!root.filter
                        anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                        text: "✕"; color: clearHover.hovered ? root.accentText : root.dim
                        font.family: root.mono; font.pixelSize: 14
                        HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { root.filter = ""; searchInput.text = "" } }
                    }
                }

                // ---- Layout screen: every bar drawn as it sits on the screen; drag chips between slots
                Flickable {
                    id: layoutFlick
                    visible: root.view === "layout"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    // sized to what the bars actually need, so a narrow/tiled window scrolls instead of
                    // squashing them; never smaller than the viewport, so it still fills a roomy window
                    contentWidth: Math.max(width, canvas.leftW + canvas.rightW + 120)
                    contentHeight: Math.max(height, canvas.topH + canvas.botH + Math.max(180, canvas.leftStackH, canvas.rightStackH))
                    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    Item {
                        id: canvas
                        width: layoutFlick.contentWidth
                        height: layoutFlick.contentHeight
                        Component.onCompleted: root.canvasItem = canvas
                        readonly property real hThick: 124
                        readonly property real sideW: Math.max(160, Math.min(230, canvas.width * 0.28))
                        readonly property var bars: root.layoutData.bars || ({})
                        function has(e) { return !!(bars[e] && bars[e].exists) }
                        function dataOf(e) { return bars[e] || ({ exists: false, main: false, sections: ({}) }) }
                        readonly property real topH: has("top") ? Math.max(60, topBox.needH) : 34
                        readonly property real botH: has("bottom") ? Math.max(60, bottomBox.needH) : 34
                        readonly property real leftW: has("left") ? sideW : 44
                        readonly property real rightW: has("right") ? sideW : 44
                        // how tall the three stacked sections of a side bar actually need (so the bar below never overlaps)
                        readonly property real leftStackH: has("left") ? leftBox.stackNeedH : 0
                        readonly property real rightStackH: has("right") ? rightBox.stackNeedH : 0

                        // top and bottom span the full width; the side bars run between them (as on the real screen)
                        BarBox { id: topBox; edge: "top"; barData: canvas.dataOf("top"); x: 0; y: 0; width: canvas.width; height: canvas.topH }
                        BarBox { id: bottomBox; edge: "bottom"; barData: canvas.dataOf("bottom"); x: 0; y: canvas.height - canvas.botH; width: canvas.width; height: canvas.botH }
                        BarBox { id: leftBox; edge: "left"; barData: canvas.dataOf("left"); x: 0; y: canvas.topH; width: canvas.leftW; height: canvas.height - canvas.topH - canvas.botH }
                        BarBox { id: rightBox; edge: "right"; barData: canvas.dataOf("right"); x: canvas.width - canvas.rightW; y: canvas.topH; width: canvas.rightW; height: canvas.height - canvas.topH - canvas.botH }

                        Text {
                            anchors.centerIn: parent
                            text: "your screen\ndrag a widget to a slot  ·  drop it on a tray to put it inside"
                            horizontalAlignment: Text.AlignHCenter
                            color: root.dim; font.family: root.mono; font.pixelSize: Style.font.body
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
                                   color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption }
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
                                   color: root.onAccent; font.family: root.mono; font.pixelSize: 10; font.bold: true }
                        }
                        Rectangle {   // the chip being dragged
                            z: 60
                            visible: root.dragInfo !== null
                            x: root.dragX + 12; y: root.dragY + 12
                            width: ghostText.implicitWidth + 14; height: 22
                            color: root.bg; border.color: root.accent; border.width: 1; radius: 3
                            Text { id: ghostText; anchors.centerIn: parent; text: root.dragInfo ? root.dragInfo.name : ""
                                   color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption }
                        }
                    }
                }

                Marketplace {
                    visible: root.view === "install"
                    Layout.fillWidth: true; Layout.fillHeight: true
                    manager: root
                }

                ColumnLayout {
                    visible: root.view === "shortcuts"
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Text { text: "Plugin launch shortcut"; color: root.fg; font.pixelSize: 18 }
                    ComboBox { background: Rectangle { color: root.bg; border.color: root.outline; radius: Style.cornerRadius } id: shortcutChoice; Layout.fillWidth: true; textRole: "name"; model: root.items.filter(function(p) { return !p.isTray && p.enabled }); onActivated: root.shortcutPlugin = model[currentIndex].id }
                    TextField { id: shortcutCombo; Layout.fillWidth: true; placeholderText: "SUPER + CTRL + G" }
                    Text { Layout.fillWidth: true; text: "Checks live Hyprland bindings before saving. Requires at least one modifier. Existing shortcuts are preserved."; color: root.dim; wrapMode: Text.WordWrap }
                    RowLayout {
                        HeaderBtn { label: "Current"; onClicked: root.act(["shortcut", "status", root.shortcutPlugin || shortcutChoice.model[shortcutChoice.currentIndex].id], "Reading shortcut") }
                        HeaderBtn { label: "Check"; onClicked: root.act(["shortcut", "check", root.shortcutPlugin || shortcutChoice.model[shortcutChoice.currentIndex].id, shortcutCombo.text], "Checking shortcut") }
                        HeaderBtn { label: "Save"; onClicked: root.act(["shortcut", "save", root.shortcutPlugin || shortcutChoice.model[shortcutChoice.currentIndex].id, shortcutCombo.text], "Saving shortcut") }
                        HeaderBtn { label: "Remove"; onClicked: root.act(["shortcut", "remove", root.shortcutPlugin || shortcutChoice.model[shortcutChoice.currentIndex].id], "Removing shortcut") }
                    }
                    Item { Layout.fillHeight: true }
                }

                ColumnLayout {
                    visible: root.view === "saved"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8
                    Text { text: "Saved layouts include every bar, tray and widget setting. Restore takes two clicks."; color: root.dim; font.family: root.mono; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField { id: layoutNameInput; Layout.fillWidth: true; placeholderText: "Name this layout"; text: root.layoutName; onTextChanged: root.layoutName = text }
                        HeaderBtn { label: "Save layout"; tip: "Save the current arrangement of all bars"; onClicked: root.act(["save-layout", root.layoutName], "Saving layout") }
                    }
                    ListView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                        model: root.savedLayouts
                        delegate: Rectangle {
                            required property var modelData
                            width: ListView.view.width; height: 56
                            color: root.surface
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 8
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Text { Layout.fillWidth: true; text: modelData.name; elide: Text.ElideRight; color: root.fg; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body) }
                                    Text { text: (modelData.kind === "saved" ? "Saved layout · " : "Undo history · ") + new Date(modelData.time * 1000).toLocaleString(); color: root.dim; font.family: root.mono; font.pixelSize: 12 }
                                }
                                Btn {
                                    label: root.restoreConfirm === modelData.id ? "Confirm restore" : "Restore"
                                    tip: "Restore all bars. The current arrangement is saved first so you can Undo."
                                    onClicked: {
                                        if (root.restoreConfirm === modelData.id) {
                                            root.act(["restore-layout", modelData.kind, modelData.id], "Restoring layout")
                                            root.restoreConfirm = ""
                                        } else root.restoreConfirm = modelData.id
                                    }
                                }
                            }
                        }
                    }
                }
                ColumnLayout {
                    visible: root.view === "updates"
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        text: root.busy ? "Checking installed plugins…" : "Review changes below. Apply installs the exact commit shown. Plugins with local edits are skipped."
                        color: root.dim; font.family: root.mono; font.pixelSize: Style.font.body
                    }
                    ListView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 8
                        model: root.updateReports
                        delegate: Rectangle {
                            required property var modelData
                            width: ListView.view.width; height: updateContent.implicitHeight + 16
                            color: root.surface
                            ColumnLayout {
                                id: updateContent
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { Layout.fillWidth: true; text: modelData.id + " · " + modelData.status; elide: Text.ElideRight; color: root.accentText; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body) }
                                    Btn { visible: modelData.status === "available"; label: "Apply " + (modelData.commit || ""); tip: "Install these reviewed changes"; onClicked: root.act(["apply-update", modelData.token], "Applying update") }
                                }
                                Text { Layout.fillWidth: true; text: modelData.summary; wrapMode: Text.WrapAnywhere; color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption }
                            }
                        }
                    }
                }

                ListView {
                    id: pluginList
                    visible: root.view === "list"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 0
                    model: root.listRows
                    onContentYChanged: { if (moving) { root.savedScroll = contentY; rememberDelay.restart() } }

                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool selected: root.selectedKey === modelData.key
                        readonly property bool hasUpdate: root.updateReports.some(function(r) { return r.id === row.modelData.id && r.status === "available" })
                        width: ListView.view.width
                        height: modelData.header ? 40 : card.height + 8

                        function curSection() {
                            var sec = row.modelData.section || ""
                            if (sec.indexOf("/") >= 0) return sec.split("/")[1]
                            return ["left", "center", "right"].indexOf(sec) >= 0 ? sec : "right"
                        }
                        function where() {
                            var m = row.modelData
                            if (m.isTray) {
                                var names = root.trayMembers(m)
                                return (m.section || "").replace("/", " bar, ") + "   ·   " + (names.length ? "holds " + names.join(", ") : "empty")
                            }
                            if (m.tray) return "inside " + m.tray
                            if (!m.onBar) return "not on a bar"
                            var s = m.section || ""
                            if (s.indexOf("/") >= 0) { var p = s.split("/"); return p[0] + " bar, " + p[1] }
                            return s
                        }

                        // Group header
                        Item {
                            visible: !!row.modelData.header
                            anchors.fill: parent
                            Text {
                                anchors.left: parent.left; anchors.leftMargin: 4; anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                                text: (root.collapsed[row.modelData.key] && !root.filter ? "▸  " : "▾  ") + row.modelData.name
                                color: root.accent2Text; font.family: root.mono; font.pixelSize: Math.max(14, Style.font.body); font.bold: true
                            }
                            Rectangle { anchors.bottom: parent.bottom; anchors.bottomMargin: 2; width: parent.width; height: 2; radius: 1; color: root.accent2; opacity: 0.6 }
                            TapHandler { onTapped: root.fold(row.modelData.key) }
                        }

                        Rectangle {
                            id: card
                            visible: !row.modelData.header
                            y: 4; width: parent.width - 4
                            height: body.implicitHeight + 24
                            radius: Style.cornerRadius
                            color: row.selected ? root.selectedSurface : (rowHover.hovered ? root.hoverSurface : root.surface)
                            border.color: row.selected ? root.accent : (rowHover.hovered ? root.outline : root.outlineSoft)
                            border.width: row.selected ? 2 : 1
                            HoverHandler { id: rowHover }
                            TapHandler { onTapped: { root.selectedKey = row.modelData.key; root.selectedPluginId = row.modelData.id; rememberDelay.restart(); keyCatcher.forceActiveFocus() } }

                            ColumnLayout {
                                id: body
                                x: 14; y: 12; width: parent.width - 28
                                spacing: 12

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Rectangle {
                                        Layout.alignment: Qt.AlignTop; Layout.topMargin: 6
                                        width: 10; height: 10; radius: 5
                                        color: !row.modelData.enabled ? root.warn : (row.modelData.onBar || row.modelData.isTray ? root.good : root.outline)
                                        HoverHandler { id: dotHover }
                                        PanelToolTip { visible: dotHover.hovered
                                            text: !row.modelData.enabled ? "Disabled" : (row.modelData.onBar ? "On a bar right now" : "Enabled, but not on any bar") }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 120
                                        spacing: 3
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                Layout.fillWidth: false
                                                Layout.maximumWidth: body.width * 0.45
                                                text: row.modelData.name
                                                color: row.modelData.enabled ? root.fg : root.dim
                                                font.family: root.mono; font.pixelSize: Math.max(15, Style.font.body + 1); font.bold: true
                                                elide: Text.ElideRight
                                                HoverHandler { id: nameHover }
                                                PanelToolTip { visible: nameHover.hovered && !!row.modelData.description; text: row.modelData.description || "" }
                                            }
                                            Badge { visible: row.modelData.isTray === true; label: "tray"; tone: root.accent2Text }
                                            Badge { visible: !row.modelData.enabled; label: "disabled"; tone: root.warn }
                                            Badge { visible: row.hasUpdate; label: "update"; tone: root.warn }
                                            Badge { visible: !!row.modelData.clonedFrom; label: "clone"; tone: root.accent2Text }
                                            Badge { visible: !row.modelData.clonedFrom && !!row.modelData.firstParty; label: "built-in"; tone: root.dim }
                                            Item { Layout.fillWidth: true }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: row.modelData.id + "   ·   " + row.where()
                                            color: root.dim; font.family: root.mono; font.pixelSize: Math.max(12, Style.font.caption); elide: Text.ElideRight
                                        }
                                    }
                                    Row {
                                        Layout.alignment: Qt.AlignTop
                                        spacing: 6
                                        Btn {
                                            visible: !row.modelData.isTray
                                            label: row.modelData.onBar ? "Hide" : "Show"
                                            tip: row.modelData.onBar ? "Take it off the bar (stays installed and enabled)" : "Put it back on the bar, where it was"
                                            onClicked: root.act([row.modelData.onBar ? "hide" : "show", row.modelData.id], row.modelData.onBar ? "Hiding" : "Showing")
                                        }
                                        Btn {
                                            visible: !row.modelData.isTray
                                            label: row.modelData.enabled ? "Disable" : "Enable"
                                            tip: row.modelData.enabled ? "Disable this plugin (also takes it off the bar)" : "Enable this plugin"
                                            onClicked: root.act([row.modelData.enabled ? "disable" : "enable", row.modelData.id], row.modelData.enabled ? "Disabling" : "Enabling")
                                        }
                                        Btn {
                                            visible: !!row.modelData.canManage
                                            label: "Update"
                                            tip: "Preview commits available for this plugin"
                                            onClicked: root.reviewUpdates(row.modelData.id)
                                        }
                                        Btn {
                                            visible: !!row.modelData.sourceDir
                                            label: "Open ↗"
                                            tip: "Open this plugin's folder"
                                            onClicked: Quickshell.execDetached(["xdg-open", row.modelData.sourceDir])
                                        }
                                        Btn {
                                            readonly property string short: row.modelData.id.replace("tray:", "")
                                            visible: row.modelData.isTray === true
                                            danger: true
                                            picked: root.confirmId === row.modelData.id
                                            label: root.confirmId === row.modelData.id ? "Yes, delete " + short : "Delete " + short
                                            tip: root.confirmId === row.modelData.id ? "Click again to delete tray " + short : "Delete tray " + short + " — asks first"
                                            onClicked: {
                                                if (root.confirmId === row.modelData.id) { root.act(["rmtray", row.modelData.id], "Deleting tray " + short); root.confirmId = "" }
                                                else root.confirmId = row.modelData.id
                                            }
                                        }
                                        Btn {
                                            visible: row.modelData.isTray === true && root.confirmId === row.modelData.id
                                            label: "Cancel"
                                            onClicked: root.confirmId = ""
                                        }
                                        Btn {
                                            visible: !!row.modelData.canManage
                                            danger: true
                                            picked: root.confirmId === row.modelData.id
                                            label: root.confirmId === row.modelData.id ? "Sure?" : "Remove"
                                            tip: root.confirmId === row.modelData.id ? "Click again to remove the plugin's files" : "Uninstall this plugin"
                                            onClicked: {
                                                if (root.confirmId === row.modelData.id) root.act(["uninstall", row.modelData.id], "Uninstalling")
                                                else root.confirmId = row.modelData.id
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    visible: row.modelData.isTray === true && root.confirmId === row.modelData.id
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: trayWarn.implicitHeight + 20
                                    radius: Style.cornerRadius
                                    color: root.mix(root.bad, root.surface, 0.12)
                                    border.color: root.bad; border.width: 1
                                    Text {
                                        id: trayWarn
                                        x: 12; y: 10; width: parent.width - 24
                                        wrapMode: Text.WordWrap
                                        readonly property var names: root.trayMembers(row.modelData)
                                        text: "Delete tray " + row.modelData.id.replace("tray:", "") + " on the " + row.modelData.bar + " bar?  "
                                              + (names.length ? "Its " + names.length + (names.length === 1 ? " widget (" : " widgets (") + names.join(", ") + ") will move onto the bar where the tray was."
                                                              : "It's empty, so nothing else changes.")
                                              + "  Undo (Ctrl+Z) puts the tray back with everything in it."
                                        color: root.fg; font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body)
                                    }
                                }

                                // Placement controls
                                Flow {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 20
                                    spacing: 20
                                    opacity: row.modelData.enabled || row.modelData.isTray ? 1 : 0.55

                                    Labeled {
                                        title: "Bars"
                                        tip: "Click a bar to add or remove this widget there; it can sit on several bars at once"
                                        SegGroup {
                                            Repeater {
                                                model: [{ k: "top", t: "Top" }, { k: "bottom", t: "Bottom" }, { k: "left", t: "Left" }, { k: "right", t: "Right" }]
                                                SegBtn {
                                                    required property var modelData
                                                    label: modelData.t
                                                    picked: row.modelData.isTray ? (row.modelData.bar === modelData.k)
                                                                                 : (row.modelData.bars || []).indexOf(modelData.k) !== -1
                                                    tip: (picked ? "Take it off the " : "Put it on the ") + modelData.k + " bar"
                                                    onClicked: {
                                                        if (row.modelData.isTray)
                                                            root.act(["place", row.modelData.id, modelData.k, row.curSection()], "Moving to " + modelData.k)
                                                        else
                                                            root.act(["toggle", row.modelData.id, modelData.k, row.curSection()], (picked ? "Removing from " : "Adding to ") + modelData.k)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Labeled {
                                        id: posField
                                        readonly property bool vert: row.modelData.bar === "left" || row.modelData.bar === "right"
                                        title: "Position"
                                        tip: "Where in the bar the widget sits"
                                        SegGroup {
                                            Repeater {
                                                model: posField.vert
                                                   ? [{ k: "left", t: "Top" }, { k: "center", t: "Middle" }, { k: "right", t: "Bottom" }]
                                                   : [{ k: "left", t: "Left" }, { k: "center", t: "Center" }, { k: "right", t: "Right" }]
                                                SegBtn {
                                                    required property var modelData
                                                    label: modelData.t
                                                    picked: !!row.modelData.onBar && row.curSection() === modelData.k && !row.modelData.contextTray
                                                    tip: (posField.vert ? "Put it at the " : "Put it on the ") + modelData.t.toLowerCase() + " of the bar"
                                                    onClicked: root.act(row.modelData.isTray || !row.modelData.onBar || row.modelData.contextTray
                                                        ? ["place", row.modelData.id, row.modelData.contextBar || root.layoutData.main, modelData.k]
                                                        : ["move-section", row.modelData.id, row.modelData.contextBar, modelData.k], "Moving")
                                                }
                                            }
                                        }
                                    }

                                    Labeled {
                                        visible: !row.modelData.isTray
                                        title: "Tray"
                                        tip: "Put this widget inside a tray (a chevron drawer) instead of directly on the bar"
                                        SegGroup {
                                            SegBtn {
                                                label: row.modelData.tray ? "▣ " + row.modelData.tray.replace("tray:", "") + "  ›" : "None  ›"
                                                picked: !!row.modelData.tray
                                                tip: row.modelData.tray ? "In " + row.modelData.tray + " — click to move to the next tray, or back onto the bar"
                                                                         : "Click to put this widget in a tray"
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
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Status line
                Rectangle { Layout.fillWidth: true; height: 1; color: root.outlineSoft }
                Text {
                    Layout.fillWidth: true
                    text: root.status !== "" ? root.status : (root.view === "layout" ? "Esc closes.  Drag a chip to a slot; drop it on a tray to put it inside." : "↑↓ select · Shift+↑↓ reorder · 1/2/3 section · Space hide/show · Ctrl+Z undo")
                    elide: Text.ElideRight
                    color: root.statusOk ? root.dim : root.bad
                    font.family: root.mono; font.pixelSize: Style.font.body
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
        color: "transparent"
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
        property real maxW: 999
        readonly property bool isTray: !!entry.tray
        readonly property bool mainTray: entry.id === "io.github.tyrichards.tray"
        readonly property var members: entry.members || []
        radius: 3
        color: isTray ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.06) : "transparent"
        border.color: isTray ? root.accent : root.dim
        border.width: 1
        // a tray is as wide as its icons need, capped to what the bar actually has room for — past
        // that the icons wrap into more rows instead of being cut off
        readonly property real trayCap: Math.max(70, Math.min(230, chip.maxW))
        implicitWidth: isTray ? Math.min(trayCap, Math.max(70, members.length * 25 + 10)) : 28
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
               color: root.accentText; font.family: root.mono; font.pixelSize: 10; font.bold: true }
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
        property real maxW: 999
        readonly property bool spare: !!entry.spare
        readonly property bool dragged: !spare && root.dragInfo !== null && root.dragInfo.id === entry.id
        readonly property bool target: root.dropTarget !== null && root.dropTarget.cellKey === cellKey
        property string cellKey: ""
        implicitWidth: spare ? 26 : (chipHolder.item ? chipHolder.item.implicitWidth : 28) + 4
        implicitHeight: spare ? 30 : (chipHolder.item ? chipHolder.item.implicitHeight : 24) + 6
        color: spare ? "transparent" : "transparent"
        border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, spare ? 0.28 : 0.5)
        border.width: 1
        radius: 2
        Text {
            x: 3; y: 1
            text: String(cell.num)
            color: root.accentText
            
            font.family: root.mono; font.pixelSize: 8; font.bold: true
        }
        Loader {
            id: chipHolder
            active: !cell.spare
            x: 2; y: 6
            sourceComponent: Component { Chip { entry: cell.entry; maxW: cell.maxW } }
        }
    }

    component Zone: Rectangle {
        id: zone
        property string edge: ""
        property string section: ""
        property string title: ""
        property var entries: []
        // on a side bar, cells read top-to-bottom in a single column, matching the real widget
        // order on screen; on top/bottom they read left-to-right, wrapping into more rows as needed
        property bool vertical: false
        readonly property real contentH: zflow.implicitHeight + 22
        readonly property real contentW: 0
        Layout.minimumHeight: contentH
        Layout.minimumWidth: 0
        color: "transparent"
        border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.5); border.width: 1
        clip: true
        Text { x: 5; y: 2; text: zone.title; color: root.dim; font.family: root.mono; font.pixelSize: 11 }
        Flow {
            id: zflow
            x: 4; y: 14
            width: zone.vertical ? zone.width - 8 : zone.width - 8
            flow: Flow.LeftToRight
            spacing: 3
            Repeater {
                id: zrep
                model: (zone.entries || []).concat([{ spare: true, id: "" }])
                delegate: Cell {
                    required property var modelData
                    required property int index
                    entry: modelData
                    num: index + 1
                    maxW: zone.width - 10
                }
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
        // how tall the busiest section needs to be (for a top or bottom bar, where the 3 sections run side by side)
        readonly property real needH: Math.max(zoneA.contentH, zoneB.contentH, zoneC.contentH) + 8
        // how tall all 3 sections need stacked together (for a side bar, where they run one above the other)
        readonly property real stackNeedH: zoneA.contentH + zoneB.contentH + zoneC.contentH + 12
        color: barData.exists ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08) : "transparent"
        border.color: barData.exists ? root.accent : Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.5)
        border.width: 1
        Text {
            visible: box.barData.exists
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 3
            text: box.edge + (box.barData.main ? " · main" : "")
            color: root.accentText; font.family: root.mono; font.pixelSize: 9; font.bold: true; z: 5
        }
        GridLayout {
            anchors.fill: parent; anchors.margins: 3
            columns: box.vertical ? 1 : 3
            rowSpacing: 3; columnSpacing: 3
            visible: box.barData.exists
            Zone { id: zoneA; Layout.fillWidth: true; Layout.fillHeight: true; edge: box.edge; section: "left"
                   vertical: box.vertical; title: box.vertical ? "top" : "left"; entries: box.secs.left || [] }
            Zone { id: zoneB; Layout.fillWidth: true; Layout.fillHeight: true; edge: box.edge; section: "center"
                   vertical: box.vertical; title: box.vertical ? "middle" : "center"; entries: box.secs.center || [] }
            Zone { id: zoneC; Layout.fillWidth: true; Layout.fillHeight: true; edge: box.edge; section: "right"
                   vertical: box.vertical; title: box.vertical ? "bottom" : "right"; entries: box.secs.right || [] }
        }
        Btn {
            visible: !box.barData.exists
            anchors.centerIn: parent
            label: box.vertical ? "+" + box.edge.charAt(0).toUpperCase() : "+ add " + box.edge + " bar"
            tip: "Add a " + box.edge + " bar, so you can put widgets on it"
            onClicked: root.act(["togglebar", box.edge], "Adding the " + box.edge + " bar")
        }
    }

    // Shared shell action chrome, also used by Plugin Manager.
    // Header button; `tab: true` draws it as a view tab in the second accent.
    component HeaderBtn: Btn {
        implicitHeight: 32
        bold: picked
    }

    // Outlined text button. picked = filled; tab = second accent; danger = urgent tone.
    component Btn: Rectangle {
        id: btn
        property string label: ""
        property bool danger: false
        property bool picked: false
        property bool tab: false
        property bool bold: false
        property string tip: ""
        signal clicked()
        readonly property color edge: danger ? root.bad : (tab ? root.accent2 : (picked ? root.accent : root.outline))
        readonly property color fill: danger ? root.bad : (tab ? root.accent2 : root.accent)
        implicitWidth: txt.implicitWidth + 24
        implicitHeight: 30
        radius: Style.cornerRadius
        color: picked ? fill
             : ma.containsMouse ? (danger ? root.mix(root.bad, root.surface, 0.16) : (tab ? root.mix(root.accent2, root.surface, 0.16) : root.hoverSurface))
             : root.surface
        border.color: ma.containsMouse && !danger && !tab && !picked ? root.accent : edge
        border.width: tab ? 2 : 1
        opacity: root.busy ? 0.5 : 1
        Text {
            id: txt
            anchors.centerIn: parent
            text: btn.label
            color: btn.picked ? root.textOn(btn.fill)
                 : btn.danger ? root.bad
                 : btn.tab ? root.accent2Text : root.fg
            font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body); font.bold: btn.bold
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; enabled: !root.busy; cursorShape: Qt.PointingHandCursor; onClicked: btn.clicked() }
        PanelToolTip { visible: btn.tip !== "" && ma.containsMouse; text: btn.tip }
    }

    // Small outlined tag next to a plugin name.
    component Badge: Rectangle {
        property string label: ""
        property color tone: root.dim
        implicitWidth: badgeText.implicitWidth + 14
        implicitHeight: 20
        radius: 10
        color: root.mix(tone, root.surface, 0.12)
        border.color: tone; border.width: 1
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: parent.label
            color: parent.tone
            font.family: root.mono; font.pixelSize: 11; font.bold: true
        }
    }

    // Caption on the left, control on the right.
    component Labeled: Row {
        id: labeled
        property string title: ""
        property string tip: ""
        default property alias content: slot.data
        spacing: 10
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: labeled.title.toUpperCase()
            color: root.dim; font.family: root.mono; font.pixelSize: 11; font.bold: true; font.letterSpacing: 0.8
            HoverHandler { id: capHover }
            PanelToolTip { visible: labeled.tip !== "" && capHover.hovered; text: labeled.tip }
        }
        Item { id: slot; width: childrenRect.width; height: childrenRect.height }
    }

    // A joined row of SegBtns inside one outline.
    component SegGroup: Rectangle {
        default property alias content: segRow.data
        implicitWidth: segRow.implicitWidth + 6
        implicitHeight: 34
        radius: Style.cornerRadius + 1
        color: root.sunken
        border.color: root.outline; border.width: 1
        Row { id: segRow; x: 3; y: 3; spacing: 2 }
    }

    component SegBtn: Rectangle {
        id: seg
        property string label: ""
        property bool picked: false
        property string tip: ""
        signal clicked()
        implicitWidth: segText.implicitWidth + 22
        implicitHeight: 28
        radius: Style.cornerRadius
        color: picked ? root.accent : (segMa.containsMouse ? root.hoverSurface : "transparent")
        border.color: segMa.containsMouse && !picked ? root.accent : "transparent"
        border.width: 1
        opacity: !enabled ? 0.35 : (root.busy ? 0.5 : 1)
        Text {
            id: segText
            anchors.centerIn: parent
            text: seg.label
            color: seg.picked ? root.onAccent : root.fg
            font.family: root.mono; font.pixelSize: Math.max(13, Style.font.body); font.bold: seg.picked
        }
        MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true; enabled: !root.busy; cursorShape: Qt.PointingHandCursor; onClicked: seg.clicked() }
        PanelToolTip { visible: seg.tip !== "" && segMa.containsMouse; text: seg.tip }
    }
}
