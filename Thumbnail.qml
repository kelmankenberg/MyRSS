import QtQuick
import Quickshell.Io

Item {
  id: root

  property string imageUrl: ""
  property string helperPath: ""
  property string localSource: ""
  property string requestedUrl: ""
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

  onImageUrlChanged: {
    localSource = ""
    loadImage()
  }
  Component.onCompleted: loadImage()

  function loadImage() {
    if (!/^https:\/\//i.test(root.imageUrl) || !root.helperPath || imageProcess.running) return
    root.requestedUrl = root.imageUrl
    imageProcess.command = ["python3", root.helperPath, "image"]
    imageProcess.running = true
  }
}
