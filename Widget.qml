import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ypmrg.fire-tv-remote"

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  property bool online: false
  property bool sessionReady: false
  property bool reconnecting: false
  property bool scanning: false
  property string statusText: "READY"
  property string processError: ""
  property string viewMode: "remote"
  property string activeDeviceName: deviceName
  property string activeIdentifier: ""
  property string authName: ""
  property string authIdentifier: ""
  property string authMessage: ""
  property var devices: []
  property var actionQueue: []
  property int selectedDeviceIndex: 0
  property string pressedAction: ""

  readonly property string deviceName: String(setting("deviceName", "Fire TV Stick"))
  readonly property string host: String(setting("host", "192.168.1.100:5555"))
  readonly property string remotePath: decodeURIComponent(
    String(Qt.resolvedUrl("fire-tv-remote")).replace(/^file:\/\//, "")
  )
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.58)
  readonly property color accent: bar ? bar.urgent : Color.accent
  readonly property color offlineColor: bar ? bar.urgent : Color.urgent
  readonly property color onlineColor: Qt.hsla(
    0.35,
    offlineColor.hslSaturation,
    Math.max(0.38, offlineColor.hslLightness),
    1
  )
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property string statusHeadline: online ? "ONLINE" : "OFFLINE"
  readonly property string statusDetail: {
    var stripped = String(statusText || "").replace(/^(ONLINE|OFFLINE)\s*(·\s*)?/, "")
    if (stripped === "" || stripped === statusHeadline) return ""
    return stripped
  }
  readonly property color statusHeadlineColor: online ? onlineColor : offlineColor
  // Layout must track [font] base-size. Fixed px keys + Style.font icons overflow
  // when the OS text scale is small/large. Style.space() already follows font
  // scale; clamp glyphs so they never exceed their control box.
  readonly property int panelPreferredContentWidth: Style.space(280)
  readonly property int panelHorizontalMargin: Style.space(10)
  readonly property int keyGap: Style.space(6)
  readonly property int dpadPreferredKey: Math.max(Style.space(36), Style.space(44))

  function equalKeyWidth(availableWidth, columns) {
    return Math.max(
      1,
      Math.floor((availableWidth - keyGap * (columns - 1)) / columns)
    )
  }

  function clampFont(preferred, minPx, maxPx) {
    var lo = Math.max(1, minPx)
    var hi = Math.max(lo, maxPx)
    return Math.max(lo, Math.min(hi, Math.round(preferred)))
  }

  function iconForBox(boxPx) {
    // Keep Nerd Font glyphs inside the painted control, even when the theme
    // icon-large token outgrows (or undershoots) fixed control geometry.
    var room = Math.max(10, Math.round(boxPx * 0.42))
    return clampFont(Style.font.iconLarge, Style.space(10), room)
  }

  function textForBox(boxPx) {
    var room = Math.max(9, Math.round(boxPx * 0.30))
    return clampFont(Style.font.bodySmall, Style.space(9), room)
  }

  function close() {
    popupOpen = false
    viewMode = "remote"
    actionQueue = []
  }

  function open() {
    popupOpen = true
  }

  function actionLabel(action) {
    var value = String(action || "")
    if (value.indexOf("app-") === 0) return value.slice(4).toUpperCase()
    return value.toUpperCase().replace(/-/g, " ")
  }

  function powerStatusLabel(status) {
    var value = String(status || "")
    if (value === "awake") return "ONLINE · AWAKE"
    if (value === "asleep") return "ONLINE · ASLEEP"
    if (value === "idle") return "ONLINE · IDLE"
    return value ? "ONLINE" : "ONLINE"
  }

  function sendAction(action) {
    if (!action) return
    if (action !== "status") {
      pressedAction = action
      pressedFeedback.restart()
    }
    if (sessionProcess.running && sessionReady) {
      statusText = actionLabel(action)
      sessionProcess.write(action + "\n")
      return
    }
    if (actionQueue.length < 64) actionQueue = actionQueue.concat([action])
  }

  function sendRequest(request) {
    if (!sessionProcess.running) return false
    sessionProcess.write(JSON.stringify(request) + "\n")
    return true
  }

  function flushQueuedActions() {
    if (!sessionProcess.running || !sessionReady || actionQueue.length === 0) return

    var pending = actionQueue
    actionQueue = []
    for (var index = 0; index < pending.length; index++) {
      sessionProcess.write(pending[index] + "\n")
    }
  }

  function updateActiveDevice(message) {
    activeDeviceName = String(message.name || activeDeviceName)
    activeIdentifier = String(message.identifier || activeIdentifier)
  }

  function openDevices() {
    viewMode = "devices"
    processError = ""
    scanDevices()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function scanDevices() {
    processError = ""
    if (sendRequest({ "op": "discover" })) {
      scanning = true
      statusText = "SCANNING"
    } else {
      scanning = false
      statusText = "OFFLINE"
      processError = "Remote session is not running"
    }
  }

  function applyDetectedHost(deviceList) {
    var list = deviceList || []
    var pick = null
    var index
    for (index = 0; index < list.length; index++) {
      if (list[index] && list[index].online) {
        pick = list[index]
        break
      }
    }
    if (!pick && list.length > 0)
      pick = list[0]

    if (!pick) {
      processError = "No Fire TV found. Enable ADB debugging, keep the TV awake, then try again."
      statusText = "NONE FOUND"
      return
    }

    var hostValue = String(pick.host || "")
    if (!hostValue && pick.address) {
      hostValue = String(pick.address)
      if (pick.port)
        hostValue += ":" + String(pick.port)
    }
    hostInput.text = hostValue
    if (pick.name)
      nameInput.text = String(pick.name)
    processError = ""
    statusText = "FOUND"
    selectedDeviceIndex = 0
    for (index = 0; index < list.length; index++) {
      if (String(list[index].identifier) === String(pick.identifier)) {
        selectedDeviceIndex = index
        break
      }
    }
  }

  function backToRemote() {
    viewMode = "remote"
    processError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function startAuthorize(identifier, name) {
    authIdentifier = String(identifier || "")
    authName = String(name || "Fire TV Stick")
    authMessage = "Accept Allow USB debugging on the Fire TV, then press Retry."
    processError = ""
    statusText = "AUTHORIZING"
    viewMode = "auth"
    sendRequest({ "op": "authorize", "identifier": authIdentifier })
  }

  function retryAuthorize() {
    processError = ""
    statusText = "AUTHORIZING"
    sendRequest({ "op": "authorize", "identifier": authIdentifier || activeIdentifier || host })
  }

  function cancelAuthorize() {
    sendRequest({ "op": "auth-cancel" })
    viewMode = "devices"
    processError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function activateSelectedDevice() {
    if (selectedDeviceIndex < 0 || selectedDeviceIndex >= devices.length) return
    var device = devices[selectedDeviceIndex]
    if (device.paired || device.authorized) {
      statusText = "CONNECTING"
      sendRequest({ "op": "switch", "identifier": String(device.identifier) })
    } else {
      startAuthorize(device.identifier, device.name)
    }
  }

  function addHost() {
    var value = String(hostInput.text || "").trim()
    if (!value) {
      processError = "Enter a host as IP or IP:port"
      return
    }
    processError = ""
    statusText = "ADDING"
    sendRequest({
      "op": "add",
      "host": value,
      "name": String(nameInput.text || "").trim()
    })
  }

  function moveDeviceCursor(dy) {
    if (devices.length === 0 || dy === 0) return
    selectedDeviceIndex = Math.max(0, Math.min(devices.length - 1, selectedDeviceIndex + dy))
  }

  function handleSessionLine(line) {
    var message
    try {
      message = JSON.parse(String(line || ""))
    } catch (error) {
      return
    }

    if (message.event === "ready") {
      sessionReady = true
      reconnecting = false
      online = true
      updateActiveDevice(message)
      statusText = powerStatusLabel(message.status)
      flushQueuedActions()
      return
    }

    if (message.event === "restarting") {
      sessionReady = false
      reconnecting = true
      online = false
      statusText = "RECONNECTING"
      actionQueue = [String(message.action || "")].concat(actionQueue)
      return
    }

    if (message.event === "devices") {
      scanning = false
      devices = message.devices || []
      selectedDeviceIndex = 0
      for (var index = 0; index < devices.length; index++) {
        if (String(devices[index].identifier) === activeIdentifier) {
          selectedDeviceIndex = index
          break
        }
      }
      applyDetectedHost(devices)
      return
    }

    if (message.event === "auth-required") {
      authIdentifier = String(message.identifier || authIdentifier || activeIdentifier)
      authName = String(message.name || authName || activeDeviceName)
      authMessage = String(message.message || "Accept Allow USB debugging on the Fire TV, then press Retry.")
      viewMode = "auth"
      statusText = "AUTH REQUIRED"
      sessionReady = false
      online = false
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }

    if (message.event === "auth-cancelled") {
      viewMode = "devices"
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }

    if (message.event === "switched" || message.event === "authorized" || message.event === "paired") {
      updateActiveDevice(message)
      sessionReady = true
      online = true
      viewMode = "remote"
      statusText = message.event === "authorized" || message.event === "paired" ? "AUTHORIZED" : "ONLINE"
      processError = ""
      flushQueuedActions()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }

    if (message.event === "error") {
      scanning = false
      online = Boolean(message.connected)
      processError = String(message.message || "")
      statusText = online ? String(message.action || "").toUpperCase() + " FAILED" : "OFFLINE"
      if (message.action === "authorize" || message.action === "add") {
        viewMode = "auth"
      }
      return
    }

    if (message.event !== "result") return

    online = true
    if (message.action === "status") {
      statusText = powerStatusLabel(message.result)
    } else {
      statusText = actionLabel(String(message.action || ""))
    }
  }

  function handleTextKey(text) {
    var key = String(text || "").toLowerCase()
    if (viewMode === "devices") {
      if (key === "r") scanDevices()
      else if (key === "b") backToRemote()
      else if (key === "a") {
        hostInput.forceActiveFocus()
      }
      else if (key === "q") close()
      return
    }
    if (viewMode === "auth") {
      if (key === "r") retryAuthorize()
      else if (key === "b" || key === "q") cancelAuthorize()
      return
    }
    if (viewMode !== "remote") return

    if (key === "b") sendAction("back")
    else if (key === "d") openDevices()
    else if (key === "g") sendAction("home")
    else if (key === "m") sendAction("menu")
    else if (key === "p") sendAction("play-pause")
    else if (key === "w") sendAction("wake")
    else if (key === "s") sendAction("sleep")
    else if (key === "+" || key === "=") sendAction("volume-up")
    else if (key === "-" || key === "_") sendAction("volume-down")
    else if (key === "1") sendAction("app-netflix")
    else if (key === "2") sendAction("app-prime")
    else if (key === "3") sendAction("app-disney")
    else if (key === "4") sendAction("app-youtube")
    else if (key === "q") close()
  }

  onPopupOpenChanged: {
    if (!popupOpen) return
    sendAction("status")
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: sessionProcess
    command: [
      root.remotePath,
      "--host",
      root.host,
      "--name",
      root.deviceName,
      "session",
    ]
    stdinEnabled: true
    running: true

    stdout: SplitParser {
      onRead: function(line) { root.handleSessionLine(line) }
    }

    stderr: SplitParser {
      onRead: function(line) { root.processError = String(line || "").trim() }
    }

    onExited: function() {
      root.sessionReady = false
      root.online = false
      root.scanning = false
      root.statusText = root.reconnecting ? "RECONNECTING" : "OFFLINE"
      sessionRestart.restart()
    }
  }

  Timer {
    id: sessionRestart
    interval: 1000
    repeat: false
    onTriggered: {
      if (!sessionProcess.running) sessionProcess.running = true
    }
  }

  Timer {
    id: pressedFeedback
    interval: 150
    repeat: false
    onTriggered: root.pressedAction = ""
  }

  component RemoteIcon: Item {
    id: iconRoot
    property url source: Qt.resolvedUrl("assets/remote.svg")
    property alias mipmap: remoteIconImage.mipmap
    property alias asynchronous: remoteIconImage.asynchronous
    property alias sourceSize: remoteIconImage.sourceSize

    implicitWidth: Style.bar.iconCanvas
    implicitHeight: Style.bar.iconCanvas

    Image {
      id: remoteIconImage
      anchors.fill: parent
      source: iconRoot.source
      fillMode: Image.PreserveAspectFit
      horizontalAlignment: Image.AlignHCenter
      verticalAlignment: Image.AlignVCenter
      smooth: true
      visible: false
      layer.enabled: iconRoot.source !== ""
    }

    MultiEffect {
      anchors.fill: remoteIconImage
      source: remoteIconImage
      visible: iconRoot.source !== ""
      autoPaddingEnabled: false
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  component StatusCaption: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
    font.bold: true
  }

  component RemoteKey: Button {
    property string action: ""
    property string logo: ""
    property real keyWidth: Style.space(40)
    property real keyHeight: Style.space(40)
    property bool visualPressed: root.pressedAction === action

    width: keyWidth
    height: keyHeight
    // Theme owns rounding (Hyprland decoration:rounding via Style.cornerRadius).
    radius: Style.cornerRadius
    // Clip glyph paint so Nerd Font metrics cannot bleed past the control.
    clip: true
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: root.textForBox(keyHeight)
    iconSize: root.iconForBox(Math.min(keyWidth, keyHeight))
    bordered: true
    scale: visualPressed ? 0.96 : 1
    opacity: visualPressed ? 0.72 : 1
    Behavior on scale { NumberAnimation { duration: 70 } }
    Behavior on opacity { NumberAnimation { duration: 70 } }
    onClicked: root.sendAction(action)

    RemoteIcon {
      anchors.fill: parent
      anchors.margins: Style.space(6)
      source: logo !== "" ? Qt.resolvedUrl(logo) : ""
      mipmap: true
      asynchronous: true
      sourceSize.width: Math.round(width * 2)
      sourceSize.height: Math.round(height * 2)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    iconComponent: barRemoteIcon
    active: root.popupOpen
    useActiveColor: false
    tooltipText: "Fire TV Remote"
    onPressed: root.popupOpen = !root.popupOpen
  }

  Component {
    id: barRemoteIcon
    RemoteIcon {
      anchors.fill: parent
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    // Width tracks font/spacing scale; height is capped to the screen via
    // fittedContentHeight, with a Flickable for residual overflow.
    contentWidth: panel.fittedContentWidth(
      root.panelPreferredContentWidth + root.panelHorizontalMargin * 2
    )
    contentHeight: panel.fittedContentHeight(
      Math.min(scroll.contentHeight, Style.space(560))
    )

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hostInput.activeFocus || nameInput.activeFocus
      clip: true

      onMoveRequested: function(dx, dy) {
        if (root.viewMode === "devices") {
          root.moveDeviceCursor(dy)
        } else if (root.viewMode === "remote") {
          if (dx < 0) root.sendAction("left")
          else if (dx > 0) root.sendAction("right")
          else if (dy < 0) root.sendAction("up")
          else if (dy > 0) root.sendAction("down")
        }
      }
      onActivateRequested: {
        if (root.viewMode === "devices") root.activateSelectedDevice()
        else if (root.viewMode === "remote") root.sendAction("select")
        else if (root.viewMode === "auth") root.retryAuthorize()
      }
      onCloseRequested: {
        if (root.viewMode === "remote") root.close()
        else if (root.viewMode === "auth") root.cancelAuthorize()
        else root.backToRemote()
      }
      onTextKey: function(text) { root.handleTextKey(text) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height + 1

        Column {
          id: contentColumn
          width: Math.max(0, scroll.width - root.panelHorizontalMargin * 2)
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

        Row {
          width: parent.width
          spacing: Style.space(9)

          RemoteIcon {
            id: headerIcon
            width: root.clampFont(Style.font.title, Style.space(12), Style.space(18))
            height: width
          }

          Column {
            width: Math.max(Style.space(80), parent.width - parent.spacing - headerIcon.width)
            spacing: Style.space(1)

            Text {
              width: parent.width
              text: root.activeDeviceName.toUpperCase()
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.clampFont(Style.font.subtitle, Style.space(11), Style.space(16))
              font.bold: true
              wrapMode: Text.Wrap
            }

            Row {
              spacing: Style.space(5)

              StatusCaption {
                text: root.online ? "●" : "○"
                color: root.statusHeadlineColor
              }

              StatusCaption {
                text: root.statusHeadline
                color: root.statusHeadlineColor
              }

              StatusCaption {
                visible: root.statusDetail !== ""
                text: "· " + root.statusDetail
                wrapMode: Text.Wrap
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        Column {
          id: remoteView
          visible: root.viewMode === "remote"
          width: parent.width
          spacing: Style.space(8)

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.keyGap

            RemoteKey {
              action: "back"
              iconText: "󰁍"
              text: "BACK"
              keyWidth: root.equalKeyWidth(remoteView.width, 3)
            }

            RemoteKey {
              action: "home"
              iconText: "󰋜"
              text: "HOME"
              keyWidth: root.equalKeyWidth(remoteView.width, 3)
            }

            RemoteKey {
              action: "menu"
              iconText: "󰍜"
              text: "MENU"
              keyWidth: root.equalKeyWidth(remoteView.width, 3)
            }
          }

          Grid {
            id: dpad
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 3
            spacing: root.keyGap
            readonly property real cellSize: Math.min(
              root.dpadPreferredKey,
              root.equalKeyWidth(remoteView.width, 3)
            )

            Item { width: dpad.cellSize; height: dpad.cellSize }
            RemoteKey {
              action: "up"
              iconText: "󰜷"
              keyWidth: dpad.cellSize
              keyHeight: dpad.cellSize
            }
            Item { width: dpad.cellSize; height: dpad.cellSize }

            RemoteKey {
              action: "left"
              iconText: "󰜱"
              keyWidth: dpad.cellSize
              keyHeight: dpad.cellSize
            }
            RemoteKey {
              action: "select"
              text: "OK"
              keyWidth: dpad.cellSize
              keyHeight: dpad.cellSize
            }
            RemoteKey {
              action: "right"
              iconText: "󰜴"
              keyWidth: dpad.cellSize
              keyHeight: dpad.cellSize
            }

            Item { width: dpad.cellSize; height: dpad.cellSize }
            RemoteKey {
              action: "down"
              iconText: "󰜮"
              keyWidth: dpad.cellSize
              keyHeight: dpad.cellSize
            }
            Item { width: dpad.cellSize; height: dpad.cellSize }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.keyGap

            RemoteKey {
              action: "volume-down"
              iconText: "󰕿"
              text: "VOL−"
              keyWidth: root.equalKeyWidth(remoteView.width, 3)
            }

            RemoteKey {
              action: "play-pause"
              iconText: "󰐎"
              keyWidth: root.equalKeyWidth(remoteView.width, 3)
            }

            RemoteKey {
              action: "volume-up"
              iconText: "󰖀"
              text: "VOL+"
              keyWidth: root.equalKeyWidth(remoteView.width, 3)
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.keyGap

            RemoteKey {
              action: "wake"
              iconText: "󰤄"
              text: "WAKE"
              keyWidth: root.equalKeyWidth(remoteView.width, 2)
            }

            RemoteKey {
              action: "sleep"
              iconText: "󰒲"
              text: "SLEEP"
              keyWidth: root.equalKeyWidth(remoteView.width, 2)
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.keyGap

            RemoteKey {
              action: "app-netflix"
              logo: "assets/netflix.svg"
              keyWidth: root.equalKeyWidth(remoteView.width, 4)
            }
            RemoteKey {
              action: "app-prime"
              logo: "assets/prime.svg"
              keyWidth: root.equalKeyWidth(remoteView.width, 4)
            }
            RemoteKey {
              action: "app-disney"
              logo: "assets/disney.svg"
              keyWidth: root.equalKeyWidth(remoteView.width, 4)
            }
            RemoteKey {
              action: "app-youtube"
              logo: "assets/youtube.svg"
              keyWidth: root.equalKeyWidth(remoteView.width, 4)
            }
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            width: remoteView.width
            height: Style.space(34)
            clip: true
            text: "DEVICES"
            iconText: "󰒋"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.textForBox(height)
            iconSize: root.iconForBox(height)
            bordered: true
            onClicked: root.openDevices()
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            text: "[↑↓←→] MOVE  [↵] OK  [B/G/M]  [P] PLAY  [-/+] VOL  [1-4] APPS  [D] DEV  [ESC]"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
          }
        }

        Column {
          id: devicesView
          visible: root.viewMode === "devices"
          width: parent.width
          spacing: Style.space(8)

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.keyGap

            Button {
              width: root.equalKeyWidth(devicesView.width, 2)
              height: Style.space(34)
              clip: true
              text: "BACK"
              iconText: "󰁍"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.textForBox(height)
              iconSize: root.iconForBox(height)
              bordered: true
              onClicked: root.backToRemote()
            }

            Button {
              width: root.equalKeyWidth(devicesView.width, 2)
              height: Style.space(34)
              clip: true
              text: root.scanning ? "SCANNING" : "SCAN"
              iconText: "󰑓"
              iconSpinning: root.scanning
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.textForBox(height)
              iconSize: root.iconForBox(height)
              bordered: true
              onClicked: root.scanDevices()
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "ADD HOST"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
            }

            TextField {
              id: hostInput
              width: parent.width
              placeholderText: "192.168.1.50:5555"
              foreground: root.foreground
              accent: root.accent
              onAccepted: root.addHost()
              Keys.onEscapePressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            TextField {
              id: nameInput
              width: parent.width
              placeholderText: "Optional name"
              foreground: root.foreground
              accent: root.accent
              onAccepted: root.addHost()
              Keys.onEscapePressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            Button {
              width: parent.width
              height: Style.space(34)
              clip: true
              text: "CONNECT HOST"
              iconText: "󰌘"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.textForBox(height)
              iconSize: root.iconForBox(height)
              bordered: true
              onClicked: root.addHost()
            }
          }

          Text {
            visible: root.processError !== ""
            width: parent.width
            text: root.processError
            textFormat: Text.PlainText
            color: root.accent
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
          }

          Text {
            visible: !root.scanning && root.devices.length === 0 && root.processError === ""
            width: parent.width
            text: "NO FIRE TVS FOUND"
            color: root.dim
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.bodySmall, Style.space(9), Style.space(14))
          }

          Repeater {
            model: root.devices

            Button {
              id: deviceButton
              required property int index
              required property var modelData

              width: devicesView.width
              height: Style.space(34)
              clip: true
              text: ""
              iconText: ""
              tooltipText: String(modelData.host || modelData.address || "")
              selected: String(modelData.identifier) === root.activeIdentifier
              hasCursor: index === root.selectedDeviceIndex
              leftAlign: true
              foreground: modelData.online ? root.foreground : root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.textForBox(height)
              bordered: true

              Text {
                anchors.fill: parent
                anchors.leftMargin: deviceButton.horizontalPadding
                anchors.rightMargin: deviceButton.horizontalPadding
                text: ((modelData.paired || modelData.authorized) ? "󰌆  " : "󰐕  ")
                  + String(modelData.name).toUpperCase()
                  + ((modelData.paired || modelData.authorized) ? "  ·  AUTH" : "  ·  NEW")
                  + (modelData.online ? "" : "  ·  OFFLINE")
                textFormat: Text.PlainText
                color: deviceButton.selected
                  ? Style.selectedStateColor(deviceButton.foreground, deviceButton.accent)
                  : deviceButton.foreground
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                font.family: deviceButton.fontFamily
                font.pixelSize: deviceButton.fontSize
                font.bold: deviceButton.selected
              }

              onHovered: function(isHovered) {
                if (isHovered) root.selectedDeviceIndex = index
              }
              onClicked: {
                root.selectedDeviceIndex = index
                root.activateSelectedDevice()
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "[J/K] SELECT   [ENTER] OPEN   [R] RESCAN   [ESC] BACK"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
          }
        }

        Column {
          id: authView
          visible: root.viewMode === "auth"
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "Authorize ADB for\n" + root.authName
            textFormat: Text.PlainText
            color: root.foreground
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.body, Style.space(10), Style.space(16))
          }

          Text {
            width: parent.width
            text: root.authMessage || "On the Fire TV, accept Allow USB debugging? then press Retry."
            textFormat: Text.PlainText
            color: root.dim
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
          }

          Text {
            visible: root.processError !== ""
            width: parent.width
            text: root.processError
            textFormat: Text.PlainText
            color: root.accent
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.keyGap

            Button {
              width: root.equalKeyWidth(authView.width, 2)
              height: Style.space(34)
              clip: true
              text: "CANCEL"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.textForBox(height)
              bordered: true
              onClicked: root.cancelAuthorize()
            }

            Button {
              width: root.equalKeyWidth(authView.width, 2)
              height: Style.space(34)
              clip: true
              text: "RETRY"
              iconText: "󰑓"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.textForBox(height)
              iconSize: root.iconForBox(height)
              bordered: true
              onClicked: root.retryAuthorize()
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "[ENTER/R] RETRY   [ESC] CANCEL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.clampFont(Style.font.caption, Style.space(8), Style.space(12))
          }
        }
      }
      }
    }
  }
}
