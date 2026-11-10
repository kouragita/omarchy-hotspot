import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar chip for the concurrent Wi-Fi hotspot.
//
// Shows a plain "AP" label that lights up while the hotspot is broadcasting.
// Clicking opens the management panel, which owns all the real work; this file
// only tracks on/off state so the chip can colour itself.
//
// Shape contract required by Bar.findPanelWidget: the root must expose
// open/close/opened and togglePanel.
BarWidget {
  id: root
  moduleName: "kouragita.hotspot"

  readonly property string unit: "omarchy-hotspot.service"

  // Whether the systemd unit that owns the hotspot is currently up.
  property bool running: false

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // `systemctl is-active` needs no privilege, so the chip can poll freely.
  Process {
    id: stateProc
    running: false
    command: ["systemctl", "is-active", root.unit]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.running = String(text).trim() === "active"
      }
    }
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!stateProc.running) stateProc.running = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // IPC so the panel can be opened/closed without a mouse click
  // (omarchy-shell kouragita.hotspot toggle).
  ShellIpc {
    target: "kouragita.hotspot"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function tab(name: string): void {
      if (panelLoader.item) panelLoader.item.selectTab(name)
    }
    function rename(name: string): void {
      if (panelLoader.item) panelLoader.item.renameTo(name)
    }
    function state(): void {
      if (panelLoader.item) panelLoader.item.dumpState()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font md-access_point (U+F0003): a dot radiating waves on both
    // sides - the conventional hotspot/tethering mark. Rendered as text
    // because the bar font is already a Nerd Font, same as omarchy's own icon
    // widgets. Dimmed when off, accent-coloured while broadcasting.
    text: "󰀃"
    // Brightness carries on/off. `active` would paint it in the bar's urgent
    // colour (red), which reads as an error rather than a healthy hotspot.
    dimmed: !root.running
    tooltipText: root.running ? "Hotspot on — click to manage" : "Hotspot off — click to manage"

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
