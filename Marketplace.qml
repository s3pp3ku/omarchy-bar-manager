import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

Control {
    id: page
    background: Rectangle { color: "transparent" }
    required property var manager
    font.family: Style.font.family
    property string query: ""
    property string scope: "All"
    property string confirmId: ""
    property bool showUrl: false
    property string edge: "bottom"
    property string section: "right"
    readonly property bool compact: width < 820
    property bool detailsOpen: false
    readonly property var selected: manager.marketSelection
    readonly property var entries: manager.marketplace.filter(function(p) {
        return (p.name + " " + p.description + " " + p.author + " " + p.category).toLowerCase().indexOf(page.query.toLowerCase().trim()) >= 0
            && (page.scope !== "Installed" || p.installed)
            && (page.scope !== "Available" || !p.installed && p.installAvailable)
            && (page.scope !== "Verified" || p.verificationStatus === "verified")
    })
    onSelectedChanged: confirmId = ""
    palette.window: manager.bg
    palette.base: manager.surface
    palette.button: manager.surface
    palette.text: manager.fg
    palette.buttonText: manager.fg
    palette.windowText: manager.fg
    palette.highlight: manager.hoverSurface
    palette.highlightedText: manager.fg

    readonly property int bodySize: Math.max(14, Style.font.body)
    readonly property int smallSize: Math.max(12, Style.font.caption)

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 4
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: "Plugin marketplace"; color: manager.fg; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
                Text { Layout.fillWidth: true; text: "Discover plugins and choose where they belong."; color: manager.dim; font.family: Style.font.family; font.pixelSize: page.bodySize; elide: Text.ElideRight }
            }
            Action { text: "Install from URL"; picked: page.showUrl; onClicked: page.showUrl = !page.showUrl }
            Action { text: "Refresh catalog"; onClicked: manager.act(["marketplace"], "Loading marketplace") }
        }

        RowLayout {
            visible: page.showUrl
            Layout.fillWidth: true
            spacing: 10
            Field { id: repoInput; Layout.fillWidth: true; placeholderText: "https://github.com/author/plugin" }
            Action { primary: true; text: "Install"; enabled: !manager.busy && repoInput.text.trim() !== ""; onClicked: manager.act(["add-plugin", repoInput.text], "Installing plugin") }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Field { Layout.fillWidth: true; placeholderText: "Search by name, author, or category"; onTextChanged: page.query = text }
            Seg {
                options: ["All", "Available", "Installed", "Verified"]
                current: page.scope
                onChosen: function(v) { page.scope = v }
            }
            Text {
                Layout.minimumWidth: 80
                horizontalAlignment: Text.AlignRight
                text: page.entries.length + (page.entries.length === 1 ? " result" : " results")
                color: manager.dim; font.family: Style.font.family; font.pixelSize: page.smallSize
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 16

            ListView {
                id: listing
                visible: !page.compact || !page.detailsOpen
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 10
                model: page.entries
                ScrollBar.vertical: ScrollBar {}
                Text {
                    anchors.centerIn: parent; width: parent.width - 40; horizontalAlignment: Text.AlignHCenter
                    visible: listing.count === 0
                    text: manager.busy ? "Loading the marketplace…" : manager.marketplace.length ? "No plugins match your search." : "Load the catalog to discover plugins."
                    wrapMode: Text.WordWrap; color: manager.dim; font.family: Style.font.family; font.pixelSize: 15
                }
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property bool chosen: !!page.selected && page.selected.id === modelData.id
                    width: listing.width - 14
                    height: summary.implicitHeight + 30
                    radius: Style.cornerRadius
                    color: chosen ? manager.selectedSurface : (cardHover.hovered ? manager.hoverSurface : manager.surface)
                    border.color: chosen ? manager.accent : (cardHover.hovered ? manager.outline : manager.outlineSoft)
                    border.width: chosen ? 2 : 1
                    HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { manager.marketSelection = card.modelData; page.detailsOpen = true } }
                    ColumnLayout {
                        id: summary
                        x: 16; y: 15; width: parent.width - 32
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text { Layout.fillWidth: true; text: card.modelData.name; color: manager.fg; font.family: Style.font.family; font.pixelSize: Math.max(16, Style.font.body); font.bold: true; elide: Text.ElideRight }
                            Tag { visible: card.modelData.verificationStatus === "verified"; label: "verified"; tone: manager.accent2Text }
                            Tag { visible: !!card.modelData.installed; label: "installed"; tone: manager.good }
                            Text { visible: !card.modelData.installed && !!card.modelData.version; text: card.modelData.version || ""; color: manager.dim; font.family: Style.font.family; font.pixelSize: page.smallSize }
                        }
                        Text { Layout.fillWidth: true; text: card.modelData.description; color: manager.fg; font.family: Style.font.family; font.pixelSize: page.bodySize; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; lineHeight: 1.15 }
                        Text { Layout.fillWidth: true; text: card.modelData.category + "   ·   " + card.modelData.author; color: manager.dim; font.family: Style.font.family; font.pixelSize: page.smallSize; elide: Text.ElideRight }
                    }
                }
            }

            Rectangle {
                visible: !page.compact || page.detailsOpen
                Layout.fillWidth: page.compact
                Layout.preferredWidth: page.compact ? -1 : Math.max(340, Math.min(440, page.width * 0.42))
                Layout.fillHeight: true
                color: manager.surface
                radius: Style.cornerRadius
                border.color: manager.outlineSoft; border.width: 1

                ScrollView {
                    id: detailsScroll
                    anchors.fill: parent; anchors.margins: 18
                    clip: true
                    contentWidth: availableWidth
                    ColumnLayout {
                        width: detailsScroll.availableWidth
                        spacing: 12
                        Action { visible: page.compact; text: "← Back to plugins"; onClicked: page.detailsOpen = false }
                        Text { Layout.fillWidth: true; text: page.selected ? page.selected.name : "Explore a plugin"; color: manager.fg; font.family: Style.font.family; font.pixelSize: 20; font.bold: true; wrapMode: Text.WordWrap }
                        Text { Layout.fillWidth: true; text: page.selected ? "By " + page.selected.author + "   ·   " + page.selected.version : "Select a plugin to see its preview, details, and install options."; color: manager.dim; font.family: Style.font.family; font.pixelSize: page.bodySize; wrapMode: Text.WordWrap }
                        Rectangle {
                            visible: preview.status === Image.Ready
                            Layout.fillWidth: true; Layout.preferredHeight: 180
                            radius: Style.cornerRadius; color: manager.sunken
                            border.color: manager.outlineSoft; border.width: 1
                            Image { id: preview; anchors.fill: parent; anchors.margins: 6; source: page.selected ? page.selected.previewImage : ""; asynchronous: true; fillMode: Image.PreserveAspectFit }
                        }
                        Text { Layout.fillWidth: true; visible: !!page.selected; text: page.selected ? page.selected.description : ""; color: manager.fg; font.family: Style.font.family; font.pixelSize: page.bodySize; wrapMode: Text.WordWrap; lineHeight: 1.25 }
                        GridLayout {
                            visible: !!page.selected
                            columns: 2; columnSpacing: 14; rowSpacing: 4
                            Text { text: "License"; color: manager.dim; font.family: Style.font.family; font.pixelSize: page.smallSize }
                            Text { text: page.selected ? (page.selected.license || "Not listed") : ""; color: manager.fg; font.family: Style.font.family; font.pixelSize: page.smallSize }
                            Text { text: "Registry"; color: manager.dim; font.family: Style.font.family; font.pixelSize: page.smallSize }
                            Text { text: page.selected ? (page.selected.verificationStatus || "Not listed") : ""; color: manager.fg; font.family: Style.font.family; font.pixelSize: page.smallSize }
                        }
                        Action { text: "View source ↗"; visible: !!page.selected; onClicked: Quickshell.execDetached(["xdg-open", page.selected.repo]) }

                        Rectangle { visible: !!page.selected; Layout.fillWidth: true; Layout.topMargin: 4; height: 1; color: manager.outlineSoft }
                        Text { visible: !!page.selected; text: page.selected && page.selected.installed ? "Already installed" : "Install"; color: manager.fg; font.family: Style.font.family; font.pixelSize: 16; font.bold: true }

                        ColumnLayout {
                            visible: !!page.selected && !page.selected.installed && page.selected.installAvailable
                            Layout.fillWidth: true
                            spacing: 10
                            Text { text: "BAR"; color: manager.dim; font.family: Style.font.family; font.pixelSize: 11; font.bold: true; font.letterSpacing: 0.8 }
                            Seg { options: ["top", "bottom", "left", "right"]; current: page.edge; onChosen: function(v) { page.edge = v } }
                            Text { text: "SECTION"; color: manager.dim; font.family: Style.font.family; font.pixelSize: 11; font.bold: true; font.letterSpacing: 0.8 }
                            Seg { options: ["left", "center", "right"]; current: page.section; onChosen: function(v) { page.section = v } }
                        }
                        Text {
                            Layout.fillWidth: true; visible: !!page.selected && !page.selected.installed
                            text: page.selected ? (page.selected.installNote || "Downloads the current repository version. Registry verification may describe an earlier version.") : ""
                            color: manager.dim; font.family: Style.font.family; font.pixelSize: page.smallSize; wrapMode: Text.WordWrap; lineHeight: 1.3
                        }
                        Text {
                            visible: !!page.selected && page.confirmId === page.selected.id
                            Layout.fillWidth: true; text: "Install on the " + page.edge + " bar, " + page.section + " section?"
                            color: manager.fg; font.family: Style.font.family; font.pixelSize: page.bodySize; wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Action {
                                Layout.fillWidth: true
                                primary: true
                                visible: !!page.selected && !page.selected.installed && page.selected.installAvailable
                                text: page.confirmId === (page.selected ? page.selected.id : "") ? "Confirm install" : "Install plugin"
                                onClicked: {
                                    if (page.confirmId === page.selected.id) { manager.act(["market-install", page.selected.id, page.edge, page.section], "Installing " + page.selected.name); page.confirmId = "" }
                                    else page.confirmId = page.selected.id
                                }
                            }
                            Action { visible: page.confirmId !== ""; text: "Cancel"; onClicked: page.confirmId = "" }
                        }
                    }
                }
            }
        }
    }

    component Field: TextField {
        implicitHeight: 38
        color: manager.fg; placeholderTextColor: manager.dim
        font.family: Style.font.family; font.pixelSize: page.bodySize
        leftPadding: 12; rightPadding: 12; topPadding: 0; bottomPadding: 0
        verticalAlignment: TextInput.AlignVCenter
        selectionColor: manager.accent; selectedTextColor: manager.onAccent
        background: Rectangle {
            radius: Style.cornerRadius; color: manager.sunken
            border.color: parent.activeFocus ? manager.accent : manager.outline
            border.width: parent.activeFocus ? 2 : 1
        }
    }

    component Action: Rectangle {
        id: action
        property string text: ""
        property bool primary: false
        property bool picked: false
        signal clicked()
        readonly property bool filled: primary || picked
        implicitWidth: actionText.implicitWidth + 28
        implicitHeight: 38
        radius: Style.cornerRadius
        opacity: enabled ? 1 : 0.5
        enabled: !manager.busy
        color: filled ? manager.accent : (actionMa.containsMouse ? manager.hoverSurface : manager.surface)
        border.color: filled || actionMa.containsMouse ? manager.accent : manager.outline
        border.width: 1
        Text {
            id: actionText
            anchors.centerIn: parent
            text: action.text
            color: action.filled ? manager.onAccent : manager.fg
            font.family: Style.font.family; font.pixelSize: page.bodySize; font.bold: action.primary
        }
        MouseArea { id: actionMa; anchors.fill: parent; hoverEnabled: true; enabled: action.enabled; cursorShape: Qt.PointingHandCursor; onClicked: action.clicked() }
    }

    component Seg: Rectangle {
        id: seg
        property var options: []
        property string current: ""
        signal chosen(string value)
        implicitWidth: segRow.implicitWidth + 6
        implicitHeight: 38
        radius: Style.cornerRadius + 1
        color: manager.sunken
        border.color: manager.outline; border.width: 1
        Row {
            id: segRow
            x: 3; y: 3
            spacing: 2
            Repeater {
                model: seg.options
                Rectangle {
                    required property string modelData
                    readonly property bool on: seg.current === modelData
                    implicitWidth: optText.implicitWidth + 22
                    implicitHeight: 32
                    radius: Style.cornerRadius
                    color: on ? manager.accent : (optMa.containsMouse ? manager.hoverSurface : "transparent")
                    border.color: optMa.containsMouse && !on ? manager.accent : "transparent"
                    border.width: 1
                    Text {
                        id: optText
                        anchors.centerIn: parent
                        text: parent.modelData.charAt(0).toUpperCase() + parent.modelData.slice(1)
                        color: parent.on ? manager.onAccent : manager.fg
                        font.family: Style.font.family; font.pixelSize: Math.max(13, Style.font.body); font.bold: parent.on
                    }
                    MouseArea { id: optMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: seg.chosen(parent.modelData) }
                }
            }
        }
    }

    component Tag: Rectangle {
        property string label: ""
        property color tone: manager.dim
        implicitWidth: tagText.implicitWidth + 14
        implicitHeight: 20
        radius: 10
        color: manager.mix(tone, manager.surface, 0.12)
        border.color: tone; border.width: 1
        Text { id: tagText; anchors.centerIn: parent; text: parent.label; color: parent.tone; font.family: Style.font.family; font.pixelSize: 11; font.bold: true }
    }
}
