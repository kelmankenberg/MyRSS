import QtQuick
import Quickshell.Io

Item {
  id: root

  property string imageUrl: ""
  property string helperPath: ""
  property string localSource: ""
  property string requestedUrl: ""
  property bool requestTimedOut: false
  readonly property bool ready: thumbnail.status === Image.Ready

  Image {
    id: thumbnail
    anchors.fill: parent
    source: root.localSource
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    onStatusChanged: {
      if (status === Image.Error) console.warn("MyRSS: could not decode thumbnail")
    }
  }

  Process {
    id: imageProcess
    stdinEnabled: true
    onStarted: write(JSON.stringify({url: root.requestedUrl}) + "\n")
    stdout: StdioCollector { id: imageOutput }
    onExited: function(exitCode) {
      requestDeadline.stop()
      killTimer.stop()
      var timedOut = root.requestTimedOut
      root.requestTimedOut = false
      if (timedOut) {
        console.warn("MyRSS: thumbnail request timed out")
        if (root.requestedUrl !== root.imageUrl) root.loadImage()
        return
      }
      try {
        var result = JSON.parse(imageOutput.text || "{}")
        if (root.requestedUrl !== root.imageUrl) {
          root.loadImage()
        } else if (exitCode === 0 && result.ok && typeof result.path === "string") {
          root.localSource = "file://" + result.path
        } else {
          console.warn("MyRSS: thumbnail download failed", result.error || exitCode)
        }
      } catch (error) {
        console.warn("MyRSS: invalid thumbnail response")
      }
    }
  }

  Timer {
    id: requestDeadline
    interval: 15000
    onTriggered: root.expireImageRequest()
  }

  Timer {
    id: killTimer
    interval: 1000
    onTriggered: root.forceKillImageRequest()
  }

  onImageUrlChanged: {
    localSource = ""
    loadImage()
  }
  Component.onCompleted: loadImage()

  function loadImage() {
    if (!/^https:\/\//i.test(root.imageUrl) || !root.helperPath || imageProcess.running) return
    root.requestedUrl = root.imageUrl
    root.requestTimedOut = false
    imageProcess.command = ["python3", root.helperPath, "image"]
    imageProcess.running = true
    requestDeadline.restart()
  }

  function expireImageRequest() {
    if (!imageProcess.running) return
    root.requestTimedOut = true
    imageProcess.signal(15)
    killTimer.restart()
  }

  function forceKillImageRequest() {
    if (root.requestTimedOut && imageProcess.running) imageProcess.signal(9)
  }
}
