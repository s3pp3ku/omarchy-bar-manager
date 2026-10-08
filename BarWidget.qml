pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "s3pp3ku.bar-manager"
  readonly property string pluginId: "s3pp3ku.bar-manager"
  readonly property string icon: String(root.setting("icon", "") || "")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    tooltipText: "Bar Manager"
    horizontalMargin: 8.5

    onPressed: function (mouseButton) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle " + root.pluginId + " '{}'")
    }
  }
}
