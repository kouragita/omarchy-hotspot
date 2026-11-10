import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Hotspot manager panel.
//
// Layout follows the shell's own panels: a PanelHero, a ButtonGroup acting as
// the tab strip, then one section at a time built from PanelSectionHeader,
// PanelSeparator and the shared controls. Each concern owns one tab so the
// panel never becomes a wall of text:
//
//   Status   - on/off, SSID, share QR
//   Password - change the key
//   Traffic  - bytes and packets in/out
//   Network  - addresses, channel, MTU, uplink
//   Devices  - connected clients
//
// Everything displayed is gathered without privilege escalation (sysfs, iw,
// neighbour table). Only the toggle and password saves touch systemd, through
// the narrow polkit rule for this one unit.
Item {
  id: panel

  property var bar: null
  property Item anchorItem: null
  property var hostWidget: null

  readonly property string unit: "omarchy-hotspot.service"

  // No hardcoded paths: resolve everything from the running user's HOME so the
  // plugin installs unchanged for anyone. Layout follows XDG:
  //   config  ~/.config/omarchy-hotspot/config
  //   state   ~/.local/state/hotspot/enabled
  //   cache   ~/.cache/omarchy-hotspot
  //   runtime ~/.local/share/omarchy-hotspot/{apply,teardown,hotspot-*}
  readonly property string homeDir: Quickshell.env("HOME") || ("/home/" + Quickshell.env("USER"))
  readonly property string appDir: homeDir + "/.local/share/omarchy-hotspot"
  readonly property string stateDir: homeDir + "/.local/state/hotspot"
  readonly property string cfgPath: homeDir + "/.config/omarchy-hotspot/config"
  readonly property string cacheDir: homeDir + "/.cache/omarchy-hotspot"
  readonly property string qrPath: cacheDir + "/qr.png"
  readonly property string clientsBin: appDir + "/hotspot-clients"
  readonly property string infoBin: appDir + "/hotspot-info"
  readonly property string qrBin: appDir + "/hotspot-qr"

  property bool running: false
  property bool busy: false
  property bool qrFailed: false
  property string ssid: ""
  property string pass: ""
  property string passDraft: ""
  property string ssidDraft: ""
  property string saveMsg: ""
  property string qrStamp: ""
  property string tab: "Status"

  property real rxBytes: 0
  property real txBytes: 0
  property int rxPackets: 0
  property int txPackets: 0
  property var clients: []
  property var info: ({})

  property bool qrPending: false

  readonly property var tabNames: ["Status", "Identity", "Traffic", "Network", "Devices"]

  readonly property bool opened: kp.open
  readonly property bool popoutSwitchClosing: kp.popoutSwitchClosing
  readonly property string qrSource:
    (ssid === "" || qrStamp === "") ? "" : "file://" + qrPath + "?v=" + qrStamp

  // Facts for the Network tab, derived from hotspot-info.
  readonly property var netFacts: [
    { label: "Hotspot IP",     value: info.gateway     || "\u2014" },
    { label: "Channel",        value: info.channel     || "\u2014" },
    { label: "MTU",            value: info.mtu         || "\u2014" },
    { label: "Uplink",         value: info.uplink_ssid || "\u2014" },
    { label: "Uplink IP",      value: info.uplink_ip   || "\u2014" },
    { label: "Uplink gateway", value: info.uplink_gw   || "\u2014" }
  ]

  readonly property var trafficFacts: [
    { label: "Received", value: humanBytes(rxBytes) },
    { label: "Sent",     value: humanBytes(txBytes) },
    { label: "Packets in",  value: String(rxPackets) },
    { label: "Packets out", value: String(txPackets) }
  ]

  // 802.11 caps an SSID at 32 OCTETS, not 32 characters. apply.sh enforces
  // bytes, so the panel must measure bytes too or a name full of multi-byte
  // characters passes the UI and then fails the service restart.
  function utf8Bytes(str) {
    var n = 0
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i)
      if (c < 0x80) n += 1
      else if (c < 0x800) n += 2
      else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++ }
      else n += 3
    }
    return n
  }

  function humanBytes(n) {
    var v = Number(n) || 0
    if (v < 1024) return v + " B"
    var units = ["KB", "MB", "GB", "TB"]
    var i = -1
    do { v = v / 1024; i++ } while (v >= 1024 && i < units.length - 1)
    return (v >= 10 ? v.toFixed(0) : v.toFixed(1)) + " " + units[i]
  }

  function open() {
    kp.open = true
    refresh()
  }

  function close() { kp.open = false }

  function toggle() {
    kp.open = !kp.open
    if (kp.open) refresh()
  }

  function closeForPopoutSwitch() { kp.open = false }

  // Let the bar widget (or a keybinding) drive the tab strip.
  function selectTab(name) {
    if (tabNames.indexOf(name) >= 0) tab = name
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!cfgProc.running) cfgProc.running = true
    if (!statsProc.running) statsProc.running = true
    if (!clientsProc.running) clientsProc.running = true
    if (!infoProc.running) infoProc.running = true
    if (qrStamp === "") buildQr()
  }

  function dumpState() {
    console.log("HOTSPOT-STATE ssid=" + JSON.stringify(ssid)
      + " passLen=" + pass.length
      + " clients=" + clients.length
      + " tab=" + tab
      + " rx=" + humanBytes(rxBytes) + " tx=" + humanBytes(txBytes)
      + " service=" + running)
  }

  // qrencode reads the config file directly: building the payload from QML
  // properties once produced "P:T:WPA;S:omarchy-share;P:;;" whenever a binding
  // had not settled. No intermediate state, no race.
  readonly property var qrCmd: [qrBin, cfgPath, qrPath]

  function buildQr() {
    if (qrProc.running) { qrPending = true; return }
    qrProc.running = true
  }

  // Name and password are written together so a rename and a key change are
  // one atomic edit. Validation mirrors apply.sh exactly - a value the service
  // would reject must never reach the config, or the restart fails and the
  // hotspot goes down.
  function saveIdentity() {
    // Fall back to the stored values when a field is empty. The drafts are
    // seeded asynchronously, so requiring them made a save refuse *silently*
    // whenever the panel had not refreshed yet - which is exactly how a rename
    // appeared to do nothing.
    var n = String(ssidDraft).trim()
    if (n === "") n = String(ssid).trim()
    var p = String(passDraft)
    if (p === "") p = String(pass)

    // 802.11 allows any bytes in an SSID, so symbols like < / > ~ are fine.
    // Only control characters are refused: the config is line-based and a
    // newline would end the value early.
    if (n.length < 1 || utf8Bytes(n) > 32 || /[\x00-\x1f\x7f]/.test(n)) {
      saveMsg = "Name: 1-32 bytes, no control characters"
      return
    }
    if (p.length < 8 || p.length > 63 || /\s/.test(p)) {
      saveMsg = "Password: 8-63 characters, no spaces"
      return
    }
    saveMsg = "Saving\u2026"
    busy = true
    writeProc.command = [
      "/bin/sh", "-c",
      'umask 077; { printf "SSID=%s\\n" "$1"; printf "PASS=%s\\n" "$2"; } > "$3"',
      "hotspot", n, p, cfgPath
    ]
    writeProc.running = true
  }

  // Programmatic rename, used by the bar widget's IPC. Verifies the whole
  // write path without depending on a mouse click reaching the button.
  function renameTo(name) {
    ssidDraft = String(name)
    saveIdentity()
  }

  // "Saving…"/"Saved…" are progress; anything else is a refusal.
  readonly property bool saveFailed: saveMsg !== ""
    && saveMsg.indexOf("Saving") !== 0
    && saveMsg.indexOf("Saved") !== 0

  function setEnabled(on) {
    busy = true
    var flag = stateDir + "/enabled"
    flagProc.command = ["/bin/sh", "-c", on
      ? 'mkdir -p "$1" && : > "$2"'
      : 'rm -f "$1"',
      "flag", stateDir, flag]
    flagProc.running = true
    ctlProc.command = ["systemctl", on ? "start" : "stop", unit]
    ctlProc.running = true
  }

  // ---- data sources -------------------------------------------------------
  Process {
    id: stateProc
    running: false
    command: ["systemctl", "is-active", panel.unit]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { panel.running = String(text).trim() === "active" }
    }
  }

  Process {
    id: cfgProc
    running: false
    command: ["cat", panel.cfgPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || ""), s = "", p = ""
        out.split("\n").forEach(function(line) {
          if (line.indexOf("SSID=") === 0) s = line.slice(5).trim()
          else if (line.indexOf("PASS=") === 0) p = line.slice(5).trim()
        })
        if (s !== "" && s !== panel.ssid) {
          panel.ssid = s
          if (panel.ssidDraft === "") panel.ssidDraft = s
        }
        if (p !== "" && p !== panel.pass) {
          panel.pass = p
          if (panel.passDraft === "") panel.passDraft = p
        }
      }
    }
  }

  Process {
    id: statsProc
    running: false
    command: ["/bin/sh", "-c",
      'for f in rx_bytes tx_bytes rx_packets tx_packets; do ' +
      'cat "/sys/class/net/ap0/statistics/$f" 2>/dev/null || echo 0; done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var l = String(text || "").trim().split("\n")
        panel.rxBytes = parseInt(l[0], 10) || 0
        panel.txBytes = parseInt(l[1], 10) || 0
        panel.rxPackets = parseInt(l[2], 10) || 0
        panel.txPackets = parseInt(l[3], 10) || 0
      }
    }
  }

  Process {
    id: infoProc
    running: false
    command: [panel.infoBin, "ap0", "wlp2s0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var o = {}
        String(text || "").split("\n").forEach(function(line) {
          var i = line.indexOf("=")
          if (i > 0) o[line.slice(0, i)] = line.slice(i + 1).trim()
        })
        panel.info = o
      }
    }
  }

  Process {
    id: clientsProc
    running: false
    command: [panel.clientsBin, "ap0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = []
        String(text || "").split("\n").forEach(function(line) {
          var f = line.trim().split(/\s+/)
          if (f.length < 5) return
          rows.push({ mac: f[0], ip: f[1], signal: f[2], rx: Number(f[3]) || 0, tx: Number(f[4]) || 0 })
        })
        rows.sort(function(a, b) { return (b.rx + b.tx) - (a.rx + a.tx) })
        panel.clients = rows
      }
    }
  }

  Process {
    id: qrProc
    running: false
    command: panel.qrCmd
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) {
        panel.qrFailed = false
        panel.qrStamp = String(Date.now())
      } else {
        panel.qrFailed = true
      }
      if (panel.qrPending) {
        panel.qrPending = false
        Qt.callLater(panel.buildQr)
      }
    }
  }

  Process {
    id: writeProc
    running: false
    command: ["/bin/true"]
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        panel.busy = false
        panel.saveMsg = "Could not write config"
        return
      }
      panel.ssid = String(panel.ssidDraft).trim()
      panel.pass = String(panel.passDraft)
      panel.qrStamp = ""
      panel.buildQr()
      // Only bounce the unit if it was running: restarting a stopped unit
      // would turn the hotspot ON, which is not what "save my new name" means.
      if (panel.running) {
        panel.saveMsg = "Saved \u2014 restarting hotspot\u2026"
        ctlProc.command = ["systemctl", "restart", panel.unit]
        ctlProc.running = true
      } else {
        panel.busy = false
        panel.saveMsg = "Saved \u2014 applies when you turn the hotspot on"
      }
    }
  }

  Process {
    id: flagProc
    running: false
    command: ["/bin/true"]
  }

  Process {
    id: ctlProc
    running: false
    command: ["/bin/true"]
    onExited: function(exitCode, exitStatus) {
      panel.busy = false
      panel.saveMsg = ""
      panel.refresh()
    }
  }

  Timer {
    interval: 5000
    running: kp.open
    repeat: true
    onTriggered: panel.refresh()
  }

  // ---- panel --------------------------------------------------------------
  KeyboardPanel {
    id: kp
    anchorItem: panel.anchorItem
    owner: panel.hostWidget ? panel.hostWidget : panel
    bar: panel.bar
    open: false
    contentWidth: kp.fittedContentWidth(Style.space(400))
    contentHeight: kp.fittedContentHeight(kp.loadedContentHeight)

    content: Item {
      id: body
      width: kp.contentWidth
      implicitHeight: col.implicitHeight

      Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.popupPadding

        PanelHero {
          width: parent.width
          title: "Hotspot"
          meta: panel.running
            ? "Broadcasting \u00b7 " + String(panel.info.gateway || "10.42.0.1").split("/")[0]
            : "Off"
          detail: panel.running
            ? (panel.clients.length === 0 ? "No clients connected"
                                          : panel.clients.length + " client(s) connected")
            : "Your uplink stays connected either way"
        }

        ButtonGroup {
          id: tabs
          options: panel.tabNames
          value: panel.tab
          foreground: Commons.Color.foreground
          fontFamily: Style.font.family
          // Caption size keeps all five labels inside the panel width.
          fontSize: Style.font.caption
          onChanged: function(v) { panel.tab = v }
        }

        // ------------------------------------------------ Status
        Column {
          width: parent.width
          spacing: Style.spacing.popupPadding
          visible: panel.tab === "Status"

          Row {
            spacing: Style.spacing.popupPadding

            ToggleSwitch {
              checked: panel.running
              busy: panel.busy
              interactive: !panel.busy
              onToggled: panel.setEnabled(!panel.running)
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              text: panel.busy ? "Working\u2026" : (panel.running ? "On" : "Off")
            }
          }

          Image {
            width: 210
            height: 210
            anchors.horizontalCenter: parent.horizontalCenter
            fillMode: Image.PreserveAspectFit
            smooth: false
            visible: panel.running && panel.qrSource !== "" && !panel.qrFailed
            source: panel.qrSource
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: panel.ssid === "" ? "\u2014" : panel.ssid
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: Commons.Color.foreground
            opacity: 0.65
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            text: panel.running
              ? (panel.qrFailed ? "QR unavailable (qrencode missing)" : "Scan to join")
              : "Turn the hotspot on to share it"
          }
        }

        // ------------------------------------------------ Identity
        Column {
          width: parent.width
          spacing: Style.spacing.popupPadding
          visible: panel.tab === "Identity"

          PanelSectionHeader {
            text: "Network name"
            foreground: Commons.Color.foreground
            fontFamily: Style.font.family
          }

          TextField {
            id: nameField
            width: parent.width
            text: panel.ssidDraft
            placeholderText: "omarchy-share"
            foreground: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            onTextChanged: panel.ssidDraft = text
            onAccepted: panel.saveIdentity()
          }

          PanelSectionHeader {
            text: "Password"
            foreground: Commons.Color.foreground
            fontFamily: Style.font.family
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: passField
              width: parent.width - saveBtn.width - parent.spacing
              text: panel.passDraft
              placeholderText: "8-63 characters"
              foreground: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              onTextChanged: panel.passDraft = text
              onAccepted: panel.saveIdentity()
            }

            PanelActionButton {
              id: saveBtn
              iconText: "\uf00c"
              bordered: true
              foreground: Commons.Color.foreground
              tooltipText: "Save name and password, then restart the hotspot"
              onClicked: panel.saveIdentity()
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: panel.saveFailed ? Commons.Color.urgent : Commons.Color.foreground
            opacity: panel.saveFailed ? 1.0 : 0.65
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            text: panel.saveMsg !== ""
              ? panel.saveMsg
              : "Saving restarts the hotspot. Connected devices drop off and must rejoin with the new name and password."
          }
        }

        // ------------------------------------------------ Traffic
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: panel.tab === "Traffic"

          PanelSectionHeader {
            text: "Traffic"
            foreground: Commons.Color.foreground
            fontFamily: Style.font.family
          }

          Repeater {
            model: panel.trafficFacts

            Row {
              required property var modelData
              width: col.width
              spacing: Style.space(8)

              Text {
                width: Style.space(120)
                textFormat: Text.PlainText
                text: modelData.label
                color: Commons.Color.foreground
                opacity: 0.65
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.value
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // ------------------------------------------------ Network
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: panel.tab === "Network"

          PanelSectionHeader {
            text: "Addresses"
            foreground: Commons.Color.foreground
            fontFamily: Style.font.family
          }

          Repeater {
            model: panel.netFacts

            Row {
              required property var modelData
              width: col.width
              spacing: Style.space(8)

              Text {
                width: Style.space(120)
                textFormat: Text.PlainText
                text: modelData.label
                color: Commons.Color.foreground
                opacity: 0.65
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                elide: Text.ElideRight
                width: col.width - Style.space(128)
                text: modelData.value
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // ------------------------------------------------ Devices
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: panel.tab === "Devices"

          PanelSectionHeader {
            text: panel.clients.length === 0
              ? "No devices connected"
              : panel.clients.length + " device(s) connected"
            foreground: Commons.Color.foreground
            fontFamily: Style.font.family
          }

          Repeater {
            model: panel.clients

            Column {
              required property var modelData
              width: col.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: modelData.ip !== "-" ? modelData.ip : modelData.mac
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: modelData.signal + " dBm   \u2193 "
                      + panel.humanBytes(modelData.rx) + "   \u2191 "
                      + panel.humanBytes(modelData.tx)
                color: Commons.Color.foreground
                opacity: 0.65
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }

    onOpenChanged: {
      if (open) panel.refresh()
    }
  }
}
