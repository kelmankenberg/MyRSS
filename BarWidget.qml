import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Reader.js" as Reader

BarWidget {
  id: root

  moduleName: "kel.news-reader"
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  property bool opened: false
  property bool stateLoaded: false
  property bool articleOpen: false
  property bool settingsOpen: false
  property bool showRead: true
  property bool busy: false
  property bool feedTimedOut: false
  property bool articleTimedOut: false
  property bool addingFeed: false
  property bool addingFolder: false
  property string pendingDeleteFeedId: ""
  property string status: ""
  property string activeFeed: "all"
  property string searchText: ""
  property string selectedId: ""
  property string selectedTitle: ""
  property string selectedUrl: ""
  property string selectedContent: ""
  property string selectedImage: ""
  property var feeds: []
  property var folders: []
  property var collapsedFolders: []
  property string draftFolder: ""
  property string pendingDeleteFolder: ""
  property string renamingFolder: ""
  property string contextKind: ""
  property var contextTarget: null
  property real contextX: 0
  property real contextY: 0
  property int readerWidth: 860
  property int navigationWidth: 180
  property real storyScrollY: 0
  property real articleScrollY: 0
  property bool resumeArticle: false
  property bool restoringView: false
  property real pendingArticleScroll: -1
  property var savedIds: []
  property var savedArticles: []
  property bool stateWritable: false
  property string pendingState: ""
  property string writingState: ""
  property var readIds: []
  property var unseenArticleIds: []
  property var refreshQueue: []
  property bool defaultFeedDisabled: false
  property bool defaultFetchAttempted: false
  property string draftUrl: ""
  property int refreshMinutes: 0
  property real textScale: 1
  property int markDelay: 5
  property bool notificationsEnabled: false
  property bool showImages: true
  property bool settingsEditorFocused: false
  property bool selectedFullContent: false
  property string currentFeedUrl: ""
  property bool batchRefresh: false
  property bool automaticBatch: false
  property int refreshFailures: 0
  property int newArticleCount: 0
  property var newArticleIds: []
  property string editingFeedId: ""
  property string editingTitle: ""
  property string editingFolder: ""
  property bool pickingImport: false
  property bool pickerBusy: false
  property bool transferBusy: false
  property string cursorId: ""
  property int cursorPosition: 0
  property var selectedSnapshot: null
  property string exportSnapshot: ""
  property var focusedControl: null
  property string articleRequestUrl: ""
  property string articleError: ""

  readonly property string pluginId: "kel.news-reader"
  readonly property string helperPath: localPath("feed.py")
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/news-reader/state.json"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color popupText: Color.popups.text
  readonly property color muted: Color.muted
  readonly property var selectedItem: findItem(selectedId)
  readonly property var visibleItems: buildVisibleItems()
  readonly property int unreadCount: allItems().filter(function(item) { return root.readIds.indexOf(item.id) < 0 }).length
  readonly property var pendingArticleIds: Reader.unseenIds(allItems(), readIds, unseenArticleIds)
  readonly property bool hasNewArticles: !opened && pendingArticleIds.length > 0
  readonly property int savedCount: savedArticles.length
  readonly property var scopedItems: Reader.scopeItems(feeds, savedArticles, activeFeed, searchText)
  readonly property var activeFeedData: feeds.find(function(feed) { return feed.id === root.activeFeed }) || null
  readonly property var folderNames: Reader.folderNames(feeds, folders)
  readonly property var sidebarEntries: Reader.sidebar(feeds, folders, collapsedFolders)
  readonly property int cursorIndex: visibleItems.findIndex(function(item) { return item.id === root.cursorId })
  readonly property var contextActions: buildContextActions()

  component ReaderText: Text {
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
  }

  component ReaderInput: TextInput {
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    clip: true
    selectByMouse: true
    color: root.popupText
    activeFocusOnTab: true
    onActiveFocusChanged: {
      root.settingsEditorFocused = activeFocus
      if (activeFocus) { root.focusedControl = this; root.revealControl(this) }
      else if (root.focusedControl === this) root.focusedControl = null
    }
    Component.onDestruction: if (activeFocus) root.settingsEditorFocused = false
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.MiddleButton
      onPressed: function(mouse) {
        mouse.accepted = true
        root.showPasteUnavailable()
      }
    }
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (root.blockPaste(event)) return
      if (event.key === Qt.Key_Escape) { focus = false; event.accepted = true }
    }
  }

  component ActionButton: Item {
    id: action
    property string label: ""
    property bool selected: false
    property string counter: ""
    property bool alignLeft: false
    signal clicked()
    implicitWidth: labelText.implicitWidth + counterText.implicitWidth + Style.space(18)
    implicitHeight: Style.space(30)
    opacity: enabled ? 1 : 0.45
    activeFocusOnTab: true
    onActiveFocusChanged: {
      if (activeFocus) { root.focusedControl = this; root.revealControl(this) }
      else if (root.focusedControl === this) root.focusedControl = null
    }
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    Keys.onSpacePressed: clicked()

    ReaderText {
      id: labelText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(5)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(10) - (action.counter ? counterText.implicitWidth + Style.space(6) : 0)
      text: action.label
      color: action.selected || action.activeFocus || actionMouse.containsMouse ? Color.accent : Color.popups.text
      font.bold: action.selected
      font.underline: action.activeFocus
      elide: Text.ElideRight
      horizontalAlignment: action.alignLeft || action.counter ? Text.AlignLeft : Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
    }

    ReaderText {
      id: counterText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(5)
      anchors.verticalCenter: parent.verticalCenter
      text: action.counter
      color: Color.accent
      font.bold: action.selected
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      enabled: action.enabled
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { action.forceActiveFocus(); action.clicked() }
    }
  }

  component InputField: Rectangle {
    property alias text: field.text
    property alias editor: field
    property string placeholder: ""
    signal accepted()
    implicitHeight: Style.space(32)
    color: Style.hoverFill
    radius: Style.cornerRadius
    ReaderInput {
      id: field
      anchors.fill: parent
      anchors.margins: Style.space(6)
      verticalAlignment: TextInput.AlignVCenter
      Keys.onReturnPressed: parent.accepted()
      Keys.onEnterPressed: parent.accepted()
    }
    ReaderText {
      anchors.fill: parent
      anchors.margins: Style.space(6)
      verticalAlignment: Text.AlignVCenter
      visible: !field.text
      text: parent.placeholder
      color: root.muted
      elide: Text.ElideRight
    }
  }

  implicitWidth: bar && bar.vertical ? bar.barSize : Style.bar.statusSlot
  implicitHeight: bar && bar.vertical ? Style.bar.statusSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  function localPath(file) {
    var url = String(Qt.resolvedUrl(file))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try { return decodeURIComponent(url) } catch (e) { return url }
  }

  function showPasteUnavailable() {
    root.status = strings.t("status.pasteUnavailable")
  }

  function openFeedback() {
    if (!Qt.openUrlExternally("https://github.com/kelmankenberg/MyRSS/issues/new/choose")) {
      root.status = strings.t("status.feedbackError")
      console.warn("MyRSS: could not open GitHub feedback forms")
    }
  }

  function blockPaste(event) {
    if (!event.matches(StandardKey.Paste)) return false
    event.accepted = true
    root.showPasteUnavailable()
    return true
  }

  function open() {
    root.opened = true
    root.unseenArticleIds = []
    if (root.opened && !root.stateLoaded) root.loadState()
    else {
      root.saveState()
      root.refreshDefaultFeed()
      root.restoreArticle()
    }
  }

  function close() {
    root.saveState()
    root.contextKind = ""
    root.pendingDeleteFeedId = ""
    root.addingFolder = false
    root.articleOpen = false
    root.opened = false
    root.clearInputFocus()
    readTimer.stop()
  }

  function clearInputFocus() {
    var content = panel.loadedContent
    if (!content) return
    content.feedUrlEditor.focus = false
    content.searchEditor.focus = false
    if (root.focusedControl) root.focusedControl.focus = false
    content.forceActiveFocus()
  }

  function revealControl(control) {
    var ancestor = control.parent
    while (ancestor) {
      if (typeof ancestor.contentY === "number" && ancestor.contentItem) {
        var top = control.mapToItem(ancestor.contentItem, 0, 0).y
        if (top < ancestor.contentY) ancestor.contentY = top
        else if (top + control.height > ancestor.contentY + ancestor.height)
          ancestor.contentY = Math.max(0, top + control.height - ancestor.height)
        return
      }
      ancestor = ancestor.parent
    }
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function readState(raw) {
    var defaultUrl = "https://omarchy.org/news/rss.xml"
    root.restoringView = true
    try {
      var state = Reader.normalizeState(JSON.parse(String(raw || "{}")))
      root.defaultFeedDisabled = state.defaultFeedDisabled === true
      root.feeds = state.feeds
      root.folders = state.folders
      root.collapsedFolders = state.collapsedFolders
      root.savedArticles = state.savedArticles
      root.savedIds = state.savedArticles.map(function(item) { return item.id })
      root.readIds = state.readIds
      root.unseenArticleIds = root.opened ? [] : state.unseenArticleIds
      root.stateWritable = true
      root.refreshMinutes = state.preferences.refreshMinutes
      root.textScale = state.preferences.textScale
      root.markDelay = state.preferences.markDelay
      root.notificationsEnabled = state.preferences.notifications
      root.showImages = state.preferences.showImages
      root.showRead = state.preferences.showRead
      root.readerWidth = state.preferences.readerWidth
      root.navigationWidth = state.preferences.navigationWidth
      root.activeFeed = state.session.activeFeed
      root.searchText = state.session.searchText
      root.selectedId = state.session.selectedId
      root.cursorId = state.session.selectedId
      root.storyScrollY = state.session.storyScrollY
      root.articleScrollY = state.session.articleScrollY
      root.resumeArticle = state.session.articleOpen
    } catch (error) {
      root.feeds = [{
        id: "https://omarchy.org/news/rss.xml",
        url: "https://omarchy.org/news/rss.xml",
        title: "Omarchy News",
        items: [], folder: "", customTitle: false, lastUpdated: 0, error: ""
      }]
      root.savedIds = []
      root.readIds = []
      root.unseenArticleIds = []
      root.defaultFeedDisabled = false
      root.status = strings.t("status.readError")
      root.stateWritable = false
      console.warn("MyRSS: saved state is invalid; refusing to overwrite it", error)
    }
    var hasDefaultFeed = root.feeds.some(function(feed) { return feed.url === defaultUrl })
    if (!root.defaultFeedDisabled && !hasDefaultFeed && root.feeds.length < 100)
      root.feeds.unshift({ id: defaultUrl, url: defaultUrl, title: "Omarchy News", items: [], folder: "", customTitle: false, lastUpdated: 0, error: "" })
    root.stateLoaded = true
    Qt.callLater(function() {
      if (root.opened && panel.loadedContent) {
        panel.loadedContent.restoreStoryScroll()
        root.restoreArticle()
      }
      root.restoringView = false
    })
    if (root.stateWritable && (state.schemaVersion !== 2 || (root.opened && state.unseenArticleIds.length > 0))) root.saveState()
    if (root.opened) root.refreshDefaultFeed()
  }

  function saveState() {
    if (!root.stateWritable) {
      root.status = strings.t("status.readError")
      return
    }
    root.pendingState = JSON.stringify({
      schemaVersion: 2,
      feeds: root.feeds.slice(0, 100),
      folders: root.folderNames,
      collapsedFolders: root.collapsedFolders,
      session: {
        activeFeed: root.activeFeed, searchText: root.searchText,
        selectedId: root.selectedId, articleOpen: root.resumeArticle,
        storyScrollY: root.storyScrollY, articleScrollY: root.articleScrollY
      },
      savedIds: root.savedIds.slice(-10000),
      savedArticles: root.savedArticles,
      readIds: root.readIds,
      unseenArticleIds: root.pendingArticleIds,
      preferences: {
        refreshMinutes: root.refreshMinutes, textScale: root.textScale,
        markDelay: root.markDelay, notifications: root.notificationsEnabled,
        showImages: root.showImages, showRead: root.showRead, readerWidth: root.readerWidth,
        navigationWidth: root.navigationWidth
      },
      defaultFeedDisabled: root.defaultFeedDisabled
    }) + "\n"
    root.flushState()
  }

  function loadState() {
    if (stateLoader.running) return
    stateLoader.command = ["python3", root.localPath("state.py"), "load", root.statePath]
    stateLoader.running = true
  }

  function flushState() {
    if (stateWriter.running || !root.pendingState || !root.stateWritable) return
    root.writingState = root.pendingState
    root.pendingState = ""
    stateWriter.command = ["python3", root.localPath("state.py"), "save", root.statePath]
    stateWriter.running = true
  }

  function acceptStateResult(code, output, loading) {
    var result
    try { result = JSON.parse(output) } catch (error) {
      result = {ok: false, error: "Invalid persistence helper response"}
    }
    if (code !== 0 || !result.ok) {
      root.stateWritable = false
      root.pendingState = ""
      root.status = strings.t(loading ? "status.readError" : "status.saveError")
      console.warn("MyRSS: private state " + (loading ? "load" : "save") + " failed", result.error)
      return
    }
    if (loading) root.readState(JSON.stringify(result.state))
    else Qt.callLater(root.flushState)
  }

  function refreshDefaultFeed() {
    if (root.defaultFetchAttempted || root.defaultFeedDisabled || root.busy) return
    for (var i = 0; i < root.feeds.length; i++) {
      if (root.feeds[i].url === "https://omarchy.org/news/rss.xml") {
        root.defaultFetchAttempted = true
        if (!Array.isArray(root.feeds[i].items) || root.feeds[i].items.length === 0)
          root.requestFeed(root.feeds[i].url)
        return
      }
    }
  }

  function allItems() {
    return Reader.allItems(root.feeds)
  }

  function findItem(id) {
    if (!id) return null
    var items = Reader.unique(root.savedArticles.concat(allItems()))
    for (var i = 0; i < items.length; i++) if (items[i].id === id) return items[i]
    if (root.articleOpen && root.selectedSnapshot && root.selectedSnapshot.id === id) return root.selectedSnapshot
    return null
  }

  function buildVisibleItems() {
    var items = Reader.scopeItems(root.feeds, root.savedArticles, root.activeFeed, root.searchText)
    if (!root.showRead) items = items.filter(function(item) { return root.readIds.indexOf(item.id) < 0 })
    return items
  }

  function requestFeed(url) {
    if (root.busy) {
      root.status = strings.t("status.busy")
      return
    }
    root.status = strings.t("status.loading")
    root.busy = true
    root.feedTimedOut = false
    root.currentFeedUrl = url
    feedProcess.command = ["python3", root.helperPath, "feed"]
    feedProcess.running = true
    feedDeadline.restart()
  }

  function expireFeedRequest() {
    if (!feedProcess.running) return
    root.feedTimedOut = true
    feedProcess.signal(15)
    feedKillTimer.restart()
  }

  function forceKillFeedRequest() {
    if (root.feedTimedOut && feedProcess.running) feedProcess.signal(9)
  }

  function finishFeedProcess(exitCode, output) {
    feedDeadline.stop()
    feedKillTimer.stop()
    if (root.feedTimedOut) {
      root.feedTimedOut = false
      root.busy = false
      root.feedFailed(strings.t("status.requestTimeout"))
      return
    }
    root.acceptFeedResult(exitCode, output)
  }

  function refreshAllFeeds(automatic) {
    if (root.busy || root.feeds.length === 0) return
    root.batchRefresh = true
    root.automaticBatch = automatic === true
    root.refreshFailures = 0
    root.newArticleCount = 0
    root.newArticleIds = []
    root.refreshQueue = root.feeds.map(function(feed) { return feed.url })
    root.refreshNextFeed()
  }

  function refreshNextFeed() {
    var queue = root.refreshQueue.slice()
    if (queue.length === 0) {
      root.batchRefresh = false
      root.status = root.refreshFailures ? strings.t("status.refreshFailures").arg(Commons.I18n.formatNumber(root.refreshFailures)) : strings.t("status.allUpdated")
      if (root.automaticBatch && root.notificationsEnabled && root.newArticleCount > 0) {
        notificationProcess.command = ["notify-send", "--app-name=MyRSS", strings.t("reader.title"),
          strings.tn("status.newArticles", root.newArticleCount).arg(Commons.I18n.formatNumber(root.newArticleCount))]
        notificationProcess.running = true
      }
      return
    }
    var url = queue.shift()
    root.refreshQueue = queue
    root.requestFeed(url)
  }

  function addFeed(url) {
    if (root.busy) {
      root.status = strings.t("status.busy")
      return
    }
    url = String(url || "").trim().replace(/^http:\/\//i, "https://")
    if (!/^https:\/\/[^ ]+$/i.test(url) || root.feeds.length >= 100) {
      root.status = strings.t("status.invalidUrl")
      return
    }
    root.pendingFeedUrl = url
    root.requestFeed(url)
  }

  property string pendingFeedUrl: ""

  function feedFailed(message) {
    root.pendingFeedUrl = ""
    root.refreshFailures++
    root.status = message
    root.feeds = root.feeds.map(function(feed) {
      return feed.url === root.currentFeedUrl ? Object.assign({}, feed, {error: message}) : feed
    })
    root.saveState()
    if (root.batchRefresh) Qt.callLater(root.refreshNextFeed)
  }

  function acceptFeedResult(code, output) {
    root.busy = false
    var result
    try { result = JSON.parse(output || "{}") } catch (error) {
      root.feedFailed(strings.t("status.responseError"))
      return
    }
    if (code !== 0 || !result.ok) {
      root.feedFailed(result.error || strings.t("status.feedError"))
      return
    }
    var id = result.url
    var knownIds = root.allItems().map(function(item) { return item.id })
    var incoming = result.items.filter(function(item) { return knownIds.indexOf(item.id) < 0 && root.readIds.indexOf(item.id) < 0 }).map(function(item) { return item.id })
    root.newArticleIds = Array.from(new Set(root.newArticleIds.concat(incoming)))
    root.newArticleCount = root.newArticleIds.length
    var next = root.feeds.slice()
    var found = false
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === id || next[i].url === root.currentFeedUrl) {
        id = next[i].id
        next[i] = Object.assign({}, next[i], {
          title: next[i].customTitle ? next[i].title : result.title,
          items: Reader.cleanItems(result.items), lastUpdated: Date.now(), error: ""
        })
        found = true
        break
      }
    }
    if (!found) next.push({ id: id, title: result.title, url: result.url, items: Reader.cleanItems(result.items), folder: "", customTitle: false, lastUpdated: Date.now(), error: "" })
    root.feeds = next
    root.unseenArticleIds = root.opened ? [] :
        Reader.unseenIds(root.allItems(), root.readIds, root.unseenArticleIds.concat(incoming))
    if (root.pendingFeedUrl) {
      root.activeFeed = id
      root.settingsOpen = false
      root.searchText = ""
      root.cursorId = ""
      root.cursorPosition = 0
      root.pendingFeedUrl = ""
      root.draftUrl = ""
      root.addingFeed = false
      root.clearInputFocus()
    }
    root.status = strings.t("status.updated").arg(result.title)
    root.saveState()
    if (root.batchRefresh) Qt.callLater(root.refreshNextFeed)
  }

  function refreshFeed(feed) {
    if (feed) root.requestFeed(feed.url)
  }

  function chooseView(id) {
    root.activeFeed = id
    root.searchText = ""
    root.settingsOpen = false
    root.clearInputFocus()
    root.closeArticle()
    root.cursorId = ""
    root.storyScrollY = 0
    root.saveState()
  }

  function moveCursor(direction) {
    if (root.settingsOpen || root.pendingDeleteFeedId || !root.visibleItems.length) return
    var index = root.cursorIndex < 0 ? (root.cursorId
      ? Math.max(0, Math.min(root.visibleItems.length - 1, root.cursorPosition + (direction < 0 ? -1 : 0)))
      : direction > 0 ? 0 : root.visibleItems.length - 1)
      : Math.max(0, Math.min(root.visibleItems.length - 1, root.cursorIndex + direction))
    root.cursorPosition = index
    root.cursorId = root.visibleItems[index].id
    if (root.articleOpen) root.selectArticle(root.visibleItems[index])
  }

  function activateCursor() {
    if (root.settingsOpen || root.pendingDeleteFeedId || !root.visibleItems.length) return
    root.selectArticle(root.visibleItems[Math.max(0, root.cursorIndex)])
  }

  function refreshView() {
    if (root.activeFeedData) root.refreshFeed(root.activeFeedData)
    else root.refreshAllFeeds(false)
  }

  function editFeed(feed) {
    root.editingFeedId = feed.id
    root.editingTitle = feed.title
    root.editingFolder = feed.folder || ""
    root.settingsOpen = true
  }

  function showContext(kind, target, item, x, y) {
    var point = item.mapToItem(panel.loadedContent, x, y)
    root.clearInputFocus()
    root.contextX = point.x
    root.contextY = point.y
    root.contextTarget = target
    root.contextKind = kind
  }

  function buildContextActions() {
    if (!root.contextKind) return []
    if (root.contextKind === "feed")
      return ["renameFeed", "moveFeed", "refresh", "markRead", "markUnread", "deleteFeed", "createFolder"]
    if (root.contextKind === "folder")
      return ["toggleFolder", "renameFolder", "refresh", "markRead", "markUnread", "deleteFolder", "createFolder"]
    if (root.contextKind === "article")
      return ["openArticle", "copyLink", root.savedIds.indexOf(root.contextTarget.id) >= 0 ? "unsaveArticle" : "saveArticle",
              root.readIds.indexOf(root.contextTarget.id) >= 0 ? "markUnread" : "markRead"]
    return ["createFolder"]
  }

  function contextAction(action) {
    var kind = root.contextKind
    var target = root.contextTarget
    root.contextKind = ""
    if (action === "createFolder" || action === "renameFolder") {
      root.renamingFolder = action === "renameFolder" ? target : ""
      root.draftFolder = root.renamingFolder
      root.addingFolder = true
      if (panel.loadedContent) panel.loadedContent.focusFolderEditor()
    } else if (action === "renameFeed" || action === "moveFeed") {
      root.closeArticle()
      root.editFeed(target)
      Qt.callLater(function() {
        if (panel.loadedContent) panel.loadedContent.focusFeedEditor()
      })
    } else if (action === "toggleFolder") root.toggleFolder(target)
    else if (action === "deleteFeed") root.pendingDeleteFeedId = target.id
    else if (action === "deleteFolder") {
      root.closeArticle()
      root.settingsOpen = true
      root.pendingDeleteFolder = target
      Qt.callLater(function() {
        if (panel.loadedContent) panel.loadedContent.revealFolderDelete()
      })
    } else if (action === "refresh") {
      if (kind === "feed") root.refreshFeed(target)
      else root.refreshFolder(target)
    } else if (action === "markRead" || action === "markUnread") {
      var items = kind === "article" ? [target] : kind === "feed" ? target.items
          : Reader.scopeItems(root.feeds, [], "folder:" + target, "")
      readTimer.stop()
      root.readIds = Reader.markItems(root.readIds, items, action === "markRead")
      root.saveState()
    } else if (action === "openArticle") Qt.openUrlExternally(target.link)
    else if (action === "copyLink") {
      clipboard.text = target.link
      clipboard.selectAll()
      clipboard.copy()
      root.status = strings.t("status.linkCopied")
    } else if (action === "saveArticle" || action === "unsaveArticle") root.toggleSaved(target.id)
  }

  function refreshFolder(name) {
    if (root.busy) { root.status = strings.t("status.busy"); return }
    root.refreshQueue = root.feeds.filter(function(feed) { return feed.folder === name })
        .map(function(feed) { return feed.url })
    if (!root.refreshQueue.length) { root.status = strings.t("list.emptyFolder"); return }
    root.batchRefresh = true
    root.automaticBatch = false
    root.refreshFailures = 0
    root.newArticleIds = []
    root.newArticleCount = 0
    root.refreshNextFeed()
  }

  function changeReaderWidth(delta) {
    root.readerWidth = Math.max(680, Math.min(1320, root.readerWidth + delta))
    root.saveState()
  }

  function emptyMessage() {
    if (root.busy) return strings.t("status.loading")
    if (root.searchText.trim()) return strings.t("list.noSearchResults")
    if (root.scopedItems.length && !root.showRead) return strings.t("list.noUnread")
    if (root.activeFeed === "saved") return strings.t("list.noSaved")
    if (root.activeFeedData) {
      if (root.activeFeedData.error) return strings.t("list.failedFeed")
      return strings.t(root.activeFeedData.lastUpdated ? "list.emptyFeed" : "list.unfetched")
    }
    var scope = root.activeFeed.indexOf("folder:") === 0
        ? root.feeds.filter(function(feed) { return feed.folder === root.activeFeed.substring(7) }) : root.feeds
    if (!scope.length) return strings.t(root.activeFeed.indexOf("folder:") === 0 ? "list.emptyFolder" : "list.empty")
    if (scope.some(function(feed) { return feed.error })) return strings.t("list.failedFeed")
    if (scope.some(function(feed) { return !feed.lastUpdated })) return strings.t("list.unfetched")
    return strings.t("list.emptyFeed")
  }

  function toggleFolder(name) {
    root.collapsedFolders = root.collapsedFolders.indexOf(name) >= 0
      ? root.collapsedFolders.filter(function(folder) { return folder !== name })
      : root.collapsedFolders.concat([name])
    root.saveState()
  }

  function createFolder() {
    var name = root.draftFolder.trim().slice(0, 100)
    if (!name || (name !== root.renamingFolder && root.folderNames.indexOf(name) >= 0)
        || (!root.renamingFolder && root.folderNames.length >= 100)) {
      root.status = strings.t("status.folderNameRequired")
      return
    }
    var previous = root.renamingFolder
    root.folders = previous ? root.folderNames.map(function(folder) { return folder === previous ? name : folder })
                            : root.folderNames.concat([name])
    if (previous) {
      root.feeds = root.feeds.map(function(feed) {
        return feed.folder === previous ? Object.assign({}, feed, {folder: name}) : feed
      })
      root.collapsedFolders = root.collapsedFolders.map(function(folder) { return folder === previous ? name : folder })
      if (root.activeFeed === "folder:" + previous) root.activeFeed = "folder:" + name
      if (root.editingFolder === previous) root.editingFolder = name
    }
    root.renamingFolder = ""
    root.draftFolder = ""
    if (root.addingFolder) root.clearInputFocus()
    root.addingFolder = false
    root.status = ""
    root.saveState()
  }

  function deleteFolder(name) {
    if (root.pendingDeleteFolder !== name) return
    root.folders = root.folderNames.filter(function(folder) { return folder !== name })
    root.feeds = root.feeds.map(function(feed) {
      return feed.folder === name ? Object.assign({}, feed, {folder: ""}) : feed
    })
    root.collapsedFolders = root.collapsedFolders.filter(function(folder) { return folder !== name })
    if (root.activeFeed === "folder:" + name) root.chooseView("all")
    if (root.editingFolder === name) root.editingFolder = ""
    root.pendingDeleteFolder = ""
    root.saveState()
  }

  function applyFeedEdit() {
    if (!root.editingTitle.trim()) {
      root.status = strings.t("status.feedNameRequired")
      return
    }
    root.folders = root.folderNames
    root.feeds = root.feeds.map(function(feed) {
      return feed.id === root.editingFeedId ? Object.assign({}, feed, {
        title: root.editingTitle.trim().slice(0, 200), customTitle: true,
        folder: root.editingFolder.trim().slice(0, 100)
      }) : feed
    })
    root.savedArticles = root.savedArticles.map(function(item) {
      return item.feedId === root.editingFeedId ? Object.assign({}, item, {feedTitle: root.editingTitle.trim().slice(0, 200)}) : item
    })
    root.editingFeedId = ""
    root.saveState()
  }

  function moveFeed(id, direction) {
    var next = root.feeds.slice()
    var index = next.findIndex(function(feed) { return feed.id === id })
    var other = index + direction
    while (other >= 0 && other < next.length && next[other].folder !== next[index].folder) other += direction
    if (other < 0 || other >= next.length) return
    var feed = next[index]
    next[index] = next[other]
    next[other] = feed
    root.feeds = next
    root.saveState()
  }

  function pickSubscriptions(importing) {
    if (root.transferBusy || root.busy || root.pickerBusy) return
    root.pickingImport = importing
    root.pickerBusy = true
    root.clearInputFocus()
    root.closeArticle()
    root.opened = false
    var command = ["zenity", "--file-selection",
      "--title=" + strings.t(importing ? "settings.import" : "settings.export"),
      "--file-filter=" + strings.t("settings.opmlFilter"),
      "--file-filter=" + strings.t("settings.allFiles")]
    if (!importing) command.push("--save", "--filename=" + Quickshell.env("HOME") + "/news-reader.opml")
    filePicker.command = command
    pickerLaunch.restart()
  }

  function acceptPickedFile(code, output, error) {
    root.pickerBusy = false
    root.settingsOpen = true
    root.open()
    if (code === 1) return
    if (code !== 0) {
      root.status = strings.t("status.pickerError")
      console.warn("MyRSS: file picker failed", code, error)
      return
    }
    var path = String(output).replace(/[\r\n]+$/, "")
    if (!path || path.charAt(0) !== "/") {
      root.status = strings.t("status.pickerError")
      console.warn("MyRSS: file picker returned an invalid path")
      return
    }
    root.transferSubscriptions(root.pickingImport, path)
  }

  function transferSubscriptions(importing, path) {
    if (root.transferBusy || root.busy) return
    if (!path) {
      root.status = strings.t("status.pathRequired")
      return
    }
    root.transferBusy = true
    root.exportSnapshot = importing ? "" : JSON.stringify({feeds: root.feeds.map(function(feed) {
      return {title: feed.title, url: feed.url, folder: feed.folder}
    })}) + "\n"
    subscriptionProcess.command = importing
      ? ["python3", root.helperPath, "import-opml", path]
      : ["python3", root.helperPath, "export-opml", "-", path]
    subscriptionProcess.running = true
  }

  function acceptSubscriptionResult(code, output) {
    root.transferBusy = false
    try {
      var result = JSON.parse(output)
      if (code !== 0 || !result.ok) {
        root.status = result.error || strings.t("status.transferError")
        return
      }
      if (Array.isArray(result.feeds)) {
        var known = root.feeds.map(function(feed) { return feed.url })
        var additions = result.feeds.filter(function(feed) { return known.indexOf(feed.url) < 0 })
        if (root.feeds.length + additions.length > 100) {
          root.status = strings.t("status.invalidUrl")
          return
        }
        root.feeds = root.feeds.concat(additions.map(function(feed) {
          return {id: feed.url, url: feed.url, title: feed.title, customTitle: true, folder: feed.folder, items: [], lastUpdated: 0, error: ""}
        }))
        root.saveState()
        root.status = strings.t("status.imported").arg(Commons.I18n.formatNumber(additions.length))
      } else root.status = strings.t("status.exported").arg(result.path)
    } catch (error) {
      root.status = strings.t("status.transferError")
      console.warn("MyRSS: invalid OPML response", error)
    }
  }

  function removeFeed(feedId) {
    if (!feedId || root.pendingDeleteFeedId !== feedId) return
    root.pendingDeleteFeedId = ""
    if (feedId === "https://omarchy.org/news/rss.xml") root.defaultFeedDisabled = true
    root.feeds = root.feeds.filter(function(feed) { return feed.id !== feedId })
    if (root.activeFeed === feedId) root.activeFeed = "all"
    root.saveState()
  }

  function selectArticle(item) {
    root.restoringView = true
    root.pendingArticleScroll = -1
    var index = root.visibleItems.findIndex(function(story) { return story.id === item.id })
    if (index >= 0) root.cursorPosition = index
    root.selectedSnapshot = Object.assign({}, item)
    root.cursorId = item.id
    root.selectedId = item.id
    root.selectedTitle = item.title
    root.selectedUrl = item.link
    root.selectedContent = item.content || item.summary || strings.t("status.articleLoading")
    root.selectedImage = item.image || ""
    root.selectedFullContent = item.fullContent === true
    root.articleError = ""
    root.articleOpen = true
    root.resumeArticle = true
    root.articleScrollY = 0
    if (panel.loadedContent) panel.loadedContent.articleViewport.contentY = 0
    if (root.markDelay > 0) readTimer.restart()
    else readTimer.stop()
    if (!item.fullContent) root.requestArticle(item.link)
    root.restoringView = false
    root.saveState()
  }

  function restoreArticle() {
    if (!root.opened || !root.resumeArticle || root.articleOpen) return
    var item = root.findItem(root.selectedId)
    if (!item) { root.resumeArticle = false; return }
    var position = root.articleScrollY
    root.selectArticle(item)
    root.restoringView = true
    root.pendingArticleScroll = position
    root.articleScrollY = position
    Qt.callLater(function() {
      if (panel.loadedContent) panel.loadedContent.restoreArticleScroll()
      root.restoringView = false
    })
    root.saveState()
  }

  function requestArticle(url) {
    if (articleProcess.running) return
    root.articleRequestUrl = url
    root.articleTimedOut = false
    articleProcess.command = ["python3", root.helperPath, "article"]
    articleProcess.running = true
    articleDeadline.restart()
  }

  function expireArticleRequest() {
    if (!articleProcess.running) return
    root.articleTimedOut = true
    articleProcess.signal(15)
    articleKillTimer.restart()
  }

  function forceKillArticleRequest() {
    if (root.articleTimedOut && articleProcess.running) articleProcess.signal(9)
  }

  function finishArticleProcess(exitCode, output) {
    articleDeadline.stop()
    articleKillTimer.stop()
    var timedOut = root.articleTimedOut
    root.articleTimedOut = false
    if (timedOut) {
      root.acceptArticleResult(1, JSON.stringify({
        ok: false, error: strings.t("status.requestTimeout")
      }))
      return
    }
    root.acceptArticleResult(exitCode, output)
  }

  function closeArticle() {
    root.articleOpen = false
    root.resumeArticle = false
    root.pendingArticleScroll = -1
    readTimer.stop()
  }

  TextEdit { id: clipboard; visible: false }
  Timer {
    id: sessionSave
    interval: 400
    onTriggered: if (root.stateLoaded) root.saveState()
  }
  Timer {
    id: restoreScrollTimer
    interval: 60
    onTriggered: {
      if (root.articleOpen && root.pendingArticleScroll >= 0
          && (root.selectedFullContent || root.articleError !== "") && panel.loadedContent)
        panel.loadedContent.applyArticleScroll()
    }
  }

  function changeTextScale(direction) {
    var scales = [0.9, 1, 1.15, 1.3, 1.5]
    root.textScale = scales[Math.max(0, Math.min(scales.length - 1, scales.indexOf(root.textScale) + direction))]
    root.saveState()
  }

  function markRead(id, read) {
    var next = root.readIds.slice()
    var index = next.indexOf(id)
    if (read && index < 0) next.push(id)
    else if (!read && index >= 0) next.splice(index, 1)
    root.readIds = next
    root.saveState()
  }

  function toggleSaved(id) {
    var item = root.findItem(id)
    if (!item) return
    if (root.savedArticles.length >= 10000 && root.savedIds.indexOf(id) < 0) {
      root.status = strings.t("status.savedLimit")
      return
    }
    if (id === root.selectedId && root.articleOpen)
      item = Object.assign({}, item, {content: root.selectedContent, fullContent: root.selectedFullContent})
    root.savedArticles = Reader.savedAfterToggle(root.savedArticles, item)
    root.savedIds = root.savedArticles.map(function(story) { return story.id })
    root.saveState()
  }

  function markAll(global) {
    var items = global ? allItems() : root.scopedItems
    var unread = items.some(function(item) { return root.readIds.indexOf(item.id) < 0 })
    root.readIds = Reader.markItems(root.readIds, items, unread)
    root.saveState()
  }

  function acceptArticleResult(code, output) {
    var result
    try { result = JSON.parse(output || "{}") } catch (error) {
      root.status = strings.t("status.articleError")
      console.warn("MyRSS: invalid article response", error)
      result = {}
    }
    if (code === 0 && result.ok && result.content) {
      if (root.articleOpen && root.articleRequestUrl === root.selectedUrl) {
        root.selectedContent = result.content
        root.selectedFullContent = true
      }
      root.savedArticles = root.savedArticles.map(function(item) {
        return item.link === root.articleRequestUrl ? Object.assign({}, item, {content: result.content, fullContent: true}) : item
      })
      if (root.savedIds.indexOf(root.articleRequestUrl) >= 0) root.saveState()
    } else if (root.articleOpen && root.articleRequestUrl === root.selectedUrl)
      root.articleError = result.error || strings.t("status.articleError")
    if (root.articleOpen && !root.selectedFullContent && root.articleRequestUrl !== root.selectedUrl)
      Qt.callLater(function() { root.requestArticle(root.selectedUrl) })
    if (root.pendingArticleScroll >= 0) restoreScrollTimer.restart()
  }

  Process {
    id: stateLoader
    stdout: StdioCollector { id: stateLoadOutput }
    onExited: function(code) { root.acceptStateResult(code, stateLoadOutput.text, true) }
    Component.onCompleted: root.loadState()
  }

  Process {
    id: stateWriter
    stdinEnabled: true
    onStarted: write(root.writingState)
    stdout: StdioCollector { id: stateWriteOutput }
    onExited: function(code) { root.acceptStateResult(code, stateWriteOutput.text, false) }
  }

  Timer {
    id: pickerLaunch
    interval: Style.duration(250) + 50
    onTriggered: filePicker.running = true
  }

  Process {
    id: filePicker
    stdout: StdioCollector { id: pickedPath }
    stderr: StdioCollector { id: pickerError }
    onExited: function(code) { root.acceptPickedFile(code, pickedPath.text, pickerError.text) }
  }

  Process {
    id: subscriptionProcess
    stdinEnabled: true
    onStarted: if (root.exportSnapshot) write(root.exportSnapshot)
    stdout: StdioCollector { id: subscriptionOutput }
    onExited: function(code) { root.acceptSubscriptionResult(code, subscriptionOutput.text) }
  }

  Process {
    id: notificationProcess
    onExited: function(code) {
      if (code !== 0) {
        root.status = strings.t("status.notificationError")
        console.warn("MyRSS: notification failed", code)
      }
    }
  }

  Timer {
    interval: Math.max(1, root.refreshMinutes) * 60000
    running: root.stateLoaded && root.refreshMinutes > 0
    repeat: true
    onTriggered: root.refreshAllFeeds(true)
  }

  Process {
    id: feedProcess
    stdinEnabled: true
    onStarted: write(JSON.stringify({url: root.currentFeedUrl}) + "\n")
    stdout: StdioCollector { id: feedOutput }
    onExited: function(exitCode) { root.finishFeedProcess(exitCode, feedOutput.text) }
  }

  Timer {
    id: feedDeadline
    interval: 30000
    onTriggered: root.expireFeedRequest()
  }

  Timer {
    id: feedKillTimer
    interval: 1000
    onTriggered: root.forceKillFeedRequest()
  }

  Process {
    id: articleProcess
    stdinEnabled: true
    onStarted: write(JSON.stringify({url: root.articleRequestUrl}) + "\n")
    stdout: StdioCollector { id: articleOutput }
    onExited: function(exitCode) { root.finishArticleProcess(exitCode, articleOutput.text) }
  }

  Timer {
    id: articleDeadline
    interval: 30000
    onTriggered: root.expireArticleRequest()
  }

  Timer {
    id: articleKillTimer
    interval: 1000
    onTriggered: root.forceKillArticleRequest()
  }

  Timer {
    id: readTimer
    interval: Math.max(1, root.markDelay) * 1000
    onTriggered: if (root.articleOpen && root.selectedId) root.markRead(root.selectedId, true)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    text: "\uf09e"
    foreground: root.hasNewArticles ? Color.accent : root.foreground
    useActiveColor: false
    tooltipText: strings.t("reader.title")
    active: root.opened
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton && root.feeds.length > 0) root.refreshFeed(root.feeds[0])
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(root.readerWidth, 1320)
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, 720)

    content: PanelKeyCatcher {
      id: keys
      property alias feedUrlEditor: feedUrlInput
      property alias searchEditor: searchInput
      property alias articleViewport: articleScroll
      function focusFolderEditor() {
        Qt.callLater(function() { newFolderInput.editor.forceActiveFocus() })
      }
      function focusFeedEditor() {
        Qt.callLater(function() {
          if (mainPage.item) mainPage.item.focusFeedEditor()
        })
      }
      function revealFolderDelete() {
        Qt.callLater(function() {
          if (mainPage.item) mainPage.item.revealFolderDelete()
        })
      }
      function restoreArticleScroll() {
        restoreScrollTimer.restart()
      }
      function applyArticleScroll() {
        root.restoringView = true
        articleScroll.contentY = Math.max(0, Math.min(root.pendingArticleScroll, articleScroll.contentHeight - articleScroll.height))
        root.articleScrollY = articleScroll.contentY
        root.pendingArticleScroll = -1
        root.restoringView = false
        root.saveState()
      }
      function restoreStoryScroll() {
        if (!root.settingsOpen && mainPage.item) mainPage.item.restoreScroll()
      }
      function moveMenuFocus(direction) {
        var index = -1
        for (var i = 0; i < contextItems.count; i++)
          if (contextItems.itemAt(i).activeFocus) index = i
        for (var step = 0; step < contextItems.count; step++) {
          index = (index + direction + contextItems.count) % contextItems.count
          if (contextItems.itemAt(index).enabled) {
            contextItems.itemAt(index).forceActiveFocus()
            return
          }
        }
      }
      anchors.fill: parent
      clip: true
      implicitHeight: 640
      blocked: feedUrlInput.activeFocus || searchInput.activeFocus || root.settingsEditorFocused
      onMoveRequested: function(dx, dy) {
        if (root.contextKind) {
          if (dy) keys.moveMenuFocus(dy)
          return
        }
        if (dy) root.moveCursor(dy)
        else if (dx > 0) root.activateCursor()
        else if (root.articleOpen) root.closeArticle()
        else if (root.settingsOpen) root.settingsOpen = false
      }
      onActivateRequested: if (!root.contextKind) root.activateCursor()
      onTabRequested: function(direction) {
        if (root.contextKind) { keys.moveMenuFocus(direction); return }
        var current = root.focusedControl || keys
        var next = current.nextItemInFocusChain(direction > 0)
        while (next && next !== current) {
          if (next.visible && next.enabled && next.activeFocusOnTab) {
            next.forceActiveFocus()
            return
          }
          next = next.nextItemInFocusChain(direction > 0)
        }
      }
      onTextKey: function(text, modifiers) {
        if (root.contextKind) return
        if (root.pendingDeleteFeedId) return
        if (text === "/") {
          root.settingsOpen = false
          searchInput.forceActiveFocus()
          searchInput.selectAll()
          return
        }
        if (text === "?") { root.settingsOpen = true; root.closeArticle(); return }
        if (root.settingsOpen) return
        var item = root.articleOpen ? root.findItem(root.selectedId) : root.visibleItems[Math.max(0, root.cursorIndex)]
        if (text === "r") root.refreshView()
        else if (item && text === "s") root.toggleSaved(item.id)
        else if (item && text === "m") { readTimer.stop(); root.markRead(item.id, root.readIds.indexOf(item.id) < 0) }
        else if (item && text === "o") Qt.openUrlExternally(item.link)
      }
      onCloseRequested: {
        if (root.contextKind) root.contextKind = ""
        else if (root.pendingDeleteFeedId) root.pendingDeleteFeedId = ""
        else if (root.articleOpen) root.closeArticle()
        else if (root.settingsOpen) root.settingsOpen = false
        else root.close()
      }

      Row {
        id: columns
        anchors.fill: parent
        spacing: Style.space(10)

        Rectangle {
          id: feedColumn
          width: Style.space(root.navigationWidth)
          height: parent.height
          color: "transparent"
          MouseArea {
            anchors.fill: parent
            z: 10
            acceptedButtons: Qt.RightButton
            onClicked: function(mouse) {
              var point = mapToItem(feedList.contentItem, mouse.x, mouse.y)
              var index = feedList.indexAt(point.x, point.y)
              var entry = index >= 0 ? root.sidebarEntries[index] : null
              root.showContext(entry ? entry.kind : "blank", entry ? (entry.feed || entry.title) : null,
                               this, mouse.x, mouse.y)
            }
          }
          Column {
            id: feedHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)
            ReaderText {
              text: strings.t("feeds.heading")
              color: root.popupText
              font.bold: true
              font.pixelSize: Style.font.title
              textFormat: Text.PlainText
            }
            Column {
              width: parent.width
              visible: root.addingFolder
              spacing: Style.space(4)
              InputField {
                id: newFolderInput
                width: parent.width
                placeholder: strings.t("settings.newFolder")
                text: root.draftFolder
                onTextChanged: root.draftFolder = text
                onAccepted: root.createFolder()
              }
              Row {
                ActionButton { label: root.renamingFolder ? strings.t("settings.apply") : strings.t("settings.createFolder"); onClicked: root.createFolder() }
                ActionButton {
                  label: strings.t("feeds.cancelDelete")
                  onClicked: { root.addingFolder = false; root.renamingFolder = ""; root.draftFolder = ""; root.clearInputFocus() }
                }
              }
            }
            ActionButton {
              visible: !root.addingFeed
              label: strings.t("feeds.add")
              onClicked: {
                root.addingFeed = true
                Qt.callLater(function() { feedUrlInput.forceActiveFocus() })
              }
            }
            Rectangle {
              visible: root.addingFeed
              width: parent.width
              height: Style.space(32)
              radius: Style.cornerRadius
              color: Style.hoverFill
              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(4)
                ReaderInput {
                  id: feedUrlInput
                  width: parent.width - addFeedButton.width - cancelFeedButton.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  clip: true
                  color: root.popupText
                  text: root.draftUrl
                  selectByMouse: true
                  onTextChanged: root.draftUrl = text
                  Keys.priority: Keys.BeforeItem
                  Keys.onPressed: function(event) {
                    if (root.blockPaste(event)) return
                    if (event.key === Qt.Key_Escape) {
                      root.addingFeed = false
                      feedUrlInput.focus = false
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.addFeed(root.draftUrl)
                      event.accepted = true
                    }
                  }
                }
                ActionButton {
                  id: addFeedButton
                  label: "+"
                  onClicked: root.addFeed(root.draftUrl)
                }
                ActionButton {
                  id: cancelFeedButton
                  label: "×"
                  onClicked: {
                    root.addingFeed = false
                    root.draftUrl = ""
                    feedUrlInput.focus = false
                  }
                }
              }
              ReaderText {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: feedUrlInput.width
                elide: Text.ElideRight
                visible: !feedUrlInput.text
                text: strings.t("feed.urlPlaceholder")
                color: root.muted
                textFormat: Text.PlainText
              }
            }
            ActionButton {
              label: strings.t("feeds.saved").arg(Commons.I18n.formatNumber(root.savedCount))
              selected: root.activeFeed === "saved"
              onClicked: root.chooseView("saved")
            }
            ActionButton {
              label: strings.t("feeds.all").arg(Commons.I18n.formatNumber(root.unreadCount))
              selected: root.activeFeed === "all"
              onClicked: root.chooseView("all")
            }
            Rectangle { width: parent.width; height: 1; color: Color.popups.border }
          }
          ListView {
            id: feedList
            anchors.top: feedHeader.bottom
            anchors.bottom: feedFooter.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: Style.space(8)
            anchors.bottomMargin: Style.space(8)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.sidebarEntries
            delegate: Column {
              required property var modelData
              readonly property var subscription: modelData.kind === "feed" ? modelData.feed : null
              readonly property string feedId: subscription ? subscription.id : ""
              width: ListView.view.width
              spacing: Style.space(4)
              Row {
                visible: modelData.kind === "folder"
                width: parent.width
                ActionButton {
                  width: Style.space(24)
                  label: root.collapsedFolders.indexOf(modelData.title) >= 0 ? "+" : "−"
                  onClicked: root.toggleFolder(modelData.title)
                }
                ActionButton {
                  width: parent.width - Style.space(24)
                  alignLeft: true
                  label: modelData.kind === "folder" ? modelData.title : ""
                  counter: modelData.kind === "folder" ? Commons.I18n.formatNumber(
                      Reader.unread(Reader.scopeItems(root.feeds, [], "folder:" + modelData.title, ""), root.readIds)) : ""
                  selected: modelData.kind === "folder" && root.activeFeed === "folder:" + modelData.title
                  onClicked: root.chooseView("folder:" + modelData.title)
                }
              }
              Row {
                x: subscription && subscription.folder ? Style.space(32) : 0
                width: parent.width - x
                visible: subscription !== null && root.pendingDeleteFeedId !== feedId
                spacing: Style.space(4)
                ActionButton {
                    width: parent.width - Style.space(34)
                    label: subscription ? (subscription.error ? "! " + subscription.title : subscription.title) : ""
                    counter: subscription ? Commons.I18n.formatNumber(Reader.unread(subscription.items, root.readIds)) : ""
                    selected: root.activeFeed === feedId
                    onClicked: root.chooseView(feedId)
                }
                ActionButton {
                  label: "×"
                  enabled: !root.busy
                  onClicked: {
                    root.clearInputFocus()
                    root.pendingDeleteFeedId = feedId
                  }
                }
              }
              Column {
                width: parent.width
                visible: subscription !== null && root.pendingDeleteFeedId === feedId
                spacing: Style.space(4)
                ReaderText {
                  width: parent.width
                  text: subscription ? strings.t("feeds.confirmDelete").arg(subscription.title) : ""
                  color: root.popupText
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                }
                Row {
                  spacing: Style.space(4)
                  ActionButton {
                    label: strings.t("feeds.cancelDelete")
                    onClicked: root.pendingDeleteFeedId = ""
                  }
                  ActionButton {
                    label: strings.t("feeds.delete")
                    onClicked: root.removeFeed(feedId)
                  }
                }
              }
            }
          }
          Column {
            id: feedFooter
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)
            Rectangle { width: parent.width; height: 1; color: Color.popups.border }
            ActionButton {
              label: strings.t("list.settings")
              selected: root.settingsOpen
              onClicked: { root.clearInputFocus(); root.closeArticle(); root.settingsOpen = !root.settingsOpen }
            }
          }
        }

        Rectangle {
          width: 1
          height: parent.height
          color: Color.popups.border
          MouseArea {
            anchors.centerIn: parent
            width: Style.space(10)
            height: parent.height
            cursorShape: Qt.SizeHorCursor
            enabled: root.stateLoaded
            property real startX: 0
            property int startWidth: 180
            onPressed: function(mouse) {
              startX = mapToGlobal(mouse.x, mouse.y).x
              startWidth = root.navigationWidth
            }
            onPositionChanged: function(mouse) {
              if (pressed)
                root.navigationWidth = Math.round(Math.max(140, Math.min(240,
                    startWidth + (mapToGlobal(mouse.x, mouse.y).x - startX) / Style.spacing.scale)))
            }
            onReleased: root.saveState()
            onCanceled: root.saveState()
          }
        }

        Column {
          id: listColumn
          width: Math.max(0, columns.width - feedColumn.width - columns.spacing * 2 - 1)
          height: parent.height
          enabled: !root.articleOpen
          spacing: Style.space(8)
          Row {
            width: parent.width
            spacing: Style.space(6)
            ReaderText {
              width: parent.width - markButton.width
              text: root.activeFeed === "saved" ? strings.t("list.saved") : root.activeFeed === "all" ? strings.t("list.all") : strings.t("list.feed")
              color: root.popupText
              font.bold: true
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
            ActionButton {
              id: markButton
              label: root.scopedItems.length > 0 && Reader.unread(root.scopedItems, root.readIds) === 0 ? strings.t("list.markUnread") : strings.t("list.markRead")
              enabled: root.scopedItems.length > 0
              onClicked: root.markAll(false)
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            ActionButton {
              label: root.showRead ? strings.t("list.hideRead") : strings.t("list.showRead")
              onClicked: { root.showRead = !root.showRead; root.saveState() }
            }
            ActionButton {
              label: strings.t("list.refresh")
              enabled: !root.busy
              onClicked: {
                root.refreshView()
              }
            }
          }
          Rectangle {
            width: parent.width
            height: Style.space(32)
            radius: Style.cornerRadius
            color: Style.hoverFill
            ReaderInput {
              id: searchInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              verticalAlignment: TextInput.AlignVCenter
              color: root.popupText
              text: root.searchText
              clip: true
              selectByMouse: true
              onTextChanged: root.searchText = text
              onTextEdited: root.settingsOpen = false
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (root.blockPaste(event)) return
                if (event.key === Qt.Key_Escape) {
                  if (text) text = ""
                  else focus = false
                  event.accepted = true
                }
              }
            }
            ReaderText {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              visible: !searchInput.text
              text: strings.t("list.search")
              color: root.muted
              textFormat: Text.PlainText
            }
          }
          ReaderText {
            visible: root.activeFeedData !== null
            width: parent.width
            text: root.activeFeedData ? (root.activeFeedData.error || (root.activeFeedData.lastUpdated
              ? strings.t("status.lastUpdated").arg(new Date(root.activeFeedData.lastUpdated).toLocaleString(Qt.locale(Commons.I18n.formatLocale)))
              : strings.t("status.neverUpdated"))) : ""
            color: root.activeFeedData && root.activeFeedData.error ? Color.accent : root.muted
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
          }
          ActionButton {
            visible: root.activeFeedData !== null && root.activeFeedData.error !== ""
            label: strings.t("list.retry")
            enabled: !root.busy
            onClicked: root.refreshFeed(root.activeFeedData)
          }
          ReaderText {
            visible: root.status !== ""
            width: parent.width
            text: root.status
            color: root.muted
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
          }
          Loader {
            id: mainPage
            width: parent.width
            height: parent.height - y
            sourceComponent: root.settingsOpen ? settingsPage : storiesPage
          }
        }

      }

        MouseArea {
          width: Style.space(6)
          height: parent.height
          z: 50
          cursorShape: Qt.SizeHorCursor
          property real startX: 0
          property int startWidth: 0
          onPressed: function(mouse) {
            startX = mapToGlobal(mouse.x, mouse.y).x
            startWidth = root.readerWidth
          }
          onPositionChanged: function(mouse) {
            if (pressed)
              root.readerWidth = Math.round(Math.max(680, Math.min(1320, startWidth + startX - mapToGlobal(mouse.x, mouse.y).x)))
          }
          onReleased: root.saveState()
        }

        Item {
          anchors.fill: parent
          z: 100
          visible: root.contextKind !== ""
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: { root.contextKind = ""; root.clearInputFocus() }
          }
          Rectangle {
            x: Math.max(0, Math.min(root.contextX, keys.width - width))
            y: Math.max(0, Math.min(root.contextY, keys.height - height))
            width: Style.space(210)
            height: contextMenuColumn.implicitHeight + Style.space(8)
            color: Color.popups.background
            border.color: Color.popups.border
            radius: Style.cornerRadius
            Column {
              id: contextMenuColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(4)
              Repeater {
                id: contextItems
                model: root.contextActions
                ActionButton {
                  required property string modelData
                  width: contextMenuColumn.width
                  alignLeft: true
                  label: strings.t("menu." + modelData)
                  enabled: modelData !== "refresh" || !root.busy
                  onClicked: root.contextAction(modelData)
                  Component.onCompleted: if (index === 0) forceActiveFocus()
                  required property int index
                }
              }
            }
          }
        }

        MouseArea {
          x: listColumn.x
          width: listColumn.width - articleColumn.width
          height: parent.height
          visible: root.articleOpen
          onClicked: root.closeArticle()
        }

        Rectangle {
          id: articleColumn
          z: 2
          enabled: root.articleOpen
          width: listColumn.width * 0.88
          x: root.articleOpen ? keys.width - width : keys.width
          height: parent.height
          clip: true
          visible: root.articleOpen || articleSlide.running
          color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 1)
          Behavior on x {
            NumberAnimation {
              id: articleSlide
              duration: Style.duration(root.articleOpen ? 220 : 140)
              easing.type: Easing.Bezier
              easing.bezierCurve: Style.easeOut
            }
          }
          MouseArea { anchors.fill: parent }
          MouseArea {
            anchors.fill: parent
            z: 10
            acceptedButtons: Qt.RightButton
            onClicked: function(mouse) {
              var item = root.findItem(root.selectedId)
              if (item) root.showContext("article", item, this, mouse.x, mouse.y)
            }
          }
          Rectangle { width: 1; height: parent.height; color: Color.popups.border }
          Column {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            spacing: Style.space(8)
            Row {
              width: parent.width
              ActionButton { label: strings.t("article.close"); onClicked: root.closeArticle() }
              ReaderText {
                width: parent.width - saveButton.width - Style.space(60)
                text: root.selectedTitle
                color: root.popupText
                font.bold: true
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
              }
              ActionButton {
                id: saveButton
                label: root.savedIds.indexOf(root.selectedId) >= 0 ? strings.t("article.saved") : strings.t("article.save")
                onClicked: root.toggleSaved(root.selectedId)
              }
            }
            ReaderText {
              width: parent.width
              text: root.selectedUrl
              color: root.muted
              elide: Text.ElideMiddle
              textFormat: Text.PlainText
            }
            Flow {
              width: parent.width
              spacing: Style.space(4)
              ActionButton {
                label: strings.t("article.openOriginal")
                onClicked: Qt.openUrlExternally(root.selectedUrl)
              }
              ActionButton {
                label: root.readIds.indexOf(root.selectedId) >= 0 ? strings.t("article.markUnread") : strings.t("article.markRead")
                onClicked: { readTimer.stop(); root.markRead(root.selectedId, root.readIds.indexOf(root.selectedId) < 0) }
              }
              ActionButton {
                label: "A−"
                enabled: root.textScale > 0.9
                onClicked: root.changeTextScale(-1)
              }
              ActionButton {
                label: "A+"
                enabled: root.textScale < 1.5
                onClicked: root.changeTextScale(1)
              }
            }
            Flickable {
              id: articleScroll
              width: parent.width
              height: parent.height - y
              clip: true
              contentWidth: width
              contentHeight: articleContent.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              onMovementEnded: { root.articleScrollY = contentY; root.saveState() }
              onContentYChanged: if (root.articleOpen && !root.restoringView && root.pendingArticleScroll < 0) {
                root.articleScrollY = Math.max(0, contentY)
                sessionSave.restart()
              }
              onContentHeightChanged: if (root.articleOpen && root.pendingArticleScroll >= 0) keys.restoreArticleScroll()
              Column {
                id: articleContent
                width: parent.width
                spacing: Style.space(8)
                ReaderText {
                  width: parent.width
                  visible: root.articleError !== "" || (articleProcess.running && root.articleRequestUrl === root.selectedUrl)
                  text: root.articleError || strings.t("status.articleLoading")
                  color: root.muted
                  wrapMode: Text.Wrap
                }
                Thumbnail {
                  visible: root.showImages && ready
                  width: parent.width
                  height: visible ? Style.space(180) : 0
                  imageUrl: root.showImages ? root.selectedImage : ""
                  helperPath: root.helperPath
                }
                ReaderText {
                  width: parent.width
                  text: root.selectedContent
                  color: root.popupText
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  font.pixelSize: Math.round(Style.font.body * root.textScale)
                  lineHeight: 1.5
                }
              }
            }
          }
        }
    }
  }

  Component {
    id: storiesPage
    Item {
      id: storiesView
      property bool restoring: true
      property bool userScrolling: false
      property real previousY: 0
      property var pendingReadIds: []
      implicitHeight: 640
      onVisibleChanged: if (!visible) cancelScrollRead()
      function cancelScrollRead() {
        scrollReadTimer.stop()
        pendingReadIds = []
        previousY = storyList.contentY
      }
      function recordScroll() {
        var currentY = storyList.contentY
        if (!restoring && !root.restoringView && root.stateLoaded && root.opened
            && !root.articleOpen && (userScrolling || storyList.moving)) {
          var passed = Reader.scrolledPastItems(root.visibleItems, previousY, currentY,
              storyList.originY, Style.space(100), storyList.spacing)
          pendingReadIds = Array.from(new Set(pendingReadIds.concat(
              passed.map(function(item) { return item.id }))))
          if (pendingReadIds.length) scrollReadTimer.restart()
        }
        previousY = currentY
      }
      function markScrolledRead() {
        if (restoring || !root.opened || root.articleOpen || root.settingsOpen) {
          cancelScrollRead()
          return
        }
        if (storyList.moving) { scrollReadTimer.restart(); return }
        var items = root.visibleItems
        var stride = Style.space(100) + storyList.spacing
        var top = storyList.contentY - storyList.originY
        var passed = items.filter(function(item, index) {
          return pendingReadIds.indexOf(item.id) >= 0
              && index * stride + Style.space(100) <= top
              && root.readIds.indexOf(item.id) < 0
        })
        pendingReadIds = []
        if (!passed.length) return
        var anchorIndex = Math.max(0, Math.min(items.length - 1, Math.floor((top + storyList.spacing) / stride)))
        var anchorId = items[anchorIndex].id
        var offset = top - anchorIndex * stride
        restoring = true
        root.readIds = Reader.markItems(root.readIds, passed, true)
        Qt.callLater(function() {
          if (!root.showRead) {
            var index = root.visibleItems.findIndex(function(item) { return item.id === anchorId })
            if (index >= 0) {
              storyList.positionViewAtIndex(index, ListView.Beginning)
              storyList.contentY = storyList.originY + index * stride + offset
            }
          }
          restoring = false
          previousY = storyList.contentY
          root.storyScrollY = Math.max(0, storyList.contentY)
          root.saveState()
        })
      }
      Timer {
        id: scrollReadTimer
        interval: 1000
        onTriggered: storiesView.markScrolledRead()
      }
      function restoreScroll() {
        restoring = true
        storyList.contentY = Math.max(0, Math.min(root.storyScrollY, storyList.contentHeight - storyList.height))
        restoring = false
      }
      ListView {
        id: storyList
        anchors.fill: parent
        clip: true
        model: root.visibleItems
        currentIndex: root.cursorIndex
        onCurrentIndexChanged: if (currentIndex >= 0 && !storiesView.restoring) positionViewAtIndex(currentIndex, ListView.Contain)
        onModelChanged: storiesView.cancelScrollRead()
        spacing: Style.space(6)
        onMovementStarted: storiesView.userScrolling = true
        onMovementEnded: {
          storiesView.userScrolling = false
          if (storiesView.pendingReadIds.length) scrollReadTimer.restart()
          root.storyScrollY = contentY
          root.saveState()
        }
        onContentYChanged: {
          storiesView.recordScroll()
          if (root.stateLoaded && root.opened && !root.restoringView && !storiesView.restoring) {
            root.storyScrollY = Math.max(0, contentY)
            sessionSave.restart()
          }
        }
        Component.onCompleted: Qt.callLater(storiesView.restoreScroll)
        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width
          height: Style.space(100)
          radius: Style.cornerRadius
          color: root.cursorId === modelData.id ? Style.hoverFill : "transparent"
          border.width: root.readIds.indexOf(modelData.id) >= 0 ? 0 : 2
          border.color: root.readIds.indexOf(modelData.id) >= 0 ? Color.popups.border : Color.accent
          Row {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            spacing: Style.space(8)
            Thumbnail {
              id: storyThumbnail
              width: Style.space(76)
              height: Style.space(76)
              visible: root.showImages && ready
              imageUrl: root.showImages ? modelData.image : ""
              helperPath: root.helperPath
            }
            Column {
              width: parent.width - (storyThumbnail.visible ? storyThumbnail.width + parent.spacing : 0)
              ReaderText {
                width: parent.width
                text: modelData.title
                color: root.popupText
                font.bold: root.readIds.indexOf(modelData.id) < 0
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
              ReaderText {
                width: parent.width
                text: modelData.feedTitle + (modelData.date ? " · " + modelData.date : "")
                color: root.muted
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
              ReaderText {
                width: parent.width
                text: modelData.summary
                color: root.muted
                maximumLineCount: 2
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
              }
            }
          }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(mouse) {
              if (mouse.button === Qt.RightButton) root.showContext("article", modelData, this, mouse.x, mouse.y)
              else root.selectArticle(modelData)
            }
          }
        }
      }
      ReaderText {
        anchors.centerIn: parent
        visible: storyList.count === 0
        width: parent.width
        text: root.emptyMessage()
        color: root.muted
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
      }
    }
  }

  Component {
    id: settingsPage
    Flickable {
      id: settingsScroll
      function focusFeedEditor() {
        feedNameInput.editor.forceActiveFocus()
        contentY = feedEditColumn.y
      }
      function revealFolderDelete() { contentY = folderManagement.y }
      clip: true
      contentWidth: width
      contentHeight: settingsContent.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: settingsContent
        width: parent.width
        spacing: Style.space(10)
        ActionButton { label: strings.t("settings.back"); onClicked: root.settingsOpen = false }
        ReaderText {
          text: strings.t("settings.title")
          color: root.popupText
          font.bold: true
          font.pixelSize: Style.font.title
        }
        ActionButton {
          label: strings.t("settings.feedback")
          onClicked: root.openFeedback()
        }
        ReaderText {
          width: parent.width
          text: strings.t("settings.feedbackPrivacy")
          color: root.muted
          wrapMode: Text.Wrap
        }
        ReaderText { text: strings.t("settings.readerWidth"); color: root.popupText }
        Flow {
          width: parent.width
          ActionButton { label: strings.t("settings.narrower"); enabled: root.readerWidth > 680; onClicked: root.changeReaderWidth(-80) }
          ActionButton { label: strings.t("settings.wider"); enabled: root.readerWidth < 1320; onClicked: root.changeReaderWidth(80) }
          ActionButton { label: strings.t("settings.resetWidth"); onClicked: { root.readerWidth = 860; root.saveState() } }
        }
        ReaderText {
          width: parent.width
          text: strings.t("settings.refresh")
          color: root.popupText
          wrapMode: Text.Wrap
        }
        Flow {
          width: parent.width
          Repeater {
            model: [0, 15, 30, 60]
            ActionButton {
              required property int modelData
              label: modelData === 0 ? strings.t("settings.off") : strings.t("settings.minutes").arg(Commons.I18n.formatNumber(modelData))
              selected: root.refreshMinutes === modelData
              onClicked: { root.refreshMinutes = modelData; root.saveState() }
            }
          }
        }
        ReaderText {
          width: parent.width
          text: strings.t("settings.refreshDisclosure")
          color: root.muted
          wrapMode: Text.Wrap
        }
        ActionButton {
          width: parent.width
          label: root.notificationsEnabled ? strings.t("settings.notificationsOn") : strings.t("settings.notificationsOff")
          selected: root.notificationsEnabled
          onClicked: { root.notificationsEnabled = !root.notificationsEnabled; root.saveState() }
        }
        ReaderText {
          width: parent.width
          text: strings.t("settings.markDelay")
          color: root.popupText
          wrapMode: Text.Wrap
        }
        Flow {
          width: parent.width
          Repeater {
            model: [0, 2, 5, 10]
            ActionButton {
              required property int modelData
              label: modelData === 0 ? strings.t("settings.off") : strings.t("settings.seconds").arg(Commons.I18n.formatNumber(modelData))
              selected: root.markDelay === modelData
              onClicked: { readTimer.stop(); root.markDelay = modelData; root.saveState() }
            }
          }
        }
        Row {
          spacing: Style.space(6)
          ReaderText {
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("settings.textSize").arg(Commons.I18n.formatNumber(Math.round(root.textScale * 100)))
            color: root.popupText
          }
          ActionButton { label: "A−"; enabled: root.textScale > 0.9; onClicked: root.changeTextScale(-1) }
          ActionButton { label: "A+"; enabled: root.textScale < 1.5; onClicked: root.changeTextScale(1) }
        }
        ActionButton {
          width: parent.width
          label: root.showImages ? strings.t("settings.imagesOn") : strings.t("settings.imagesOff")
          selected: root.showImages
          onClicked: { root.showImages = !root.showImages; root.saveState() }
        }
        ReaderText {
          width: parent.width
          text: strings.t("settings.appearance")
          color: root.muted
          wrapMode: Text.Wrap
        }
        ActionButton {
          width: parent.width
          label: Reader.unread(root.allItems(), root.readIds) > 0 ? strings.t("settings.markGlobalRead") : strings.t("settings.markGlobalUnread")
          enabled: root.allItems().length > 0
          onClicked: root.markAll(true)
        }
        Rectangle { width: parent.width; height: 1; color: Color.popups.border }
        ReaderText { id: folderManagement; text: strings.t("settings.folders"); color: root.popupText; font.bold: true }
        InputField {
          id: settingsFolderInput
          width: parent.width
          placeholder: strings.t("settings.newFolder")
          text: root.draftFolder
          onTextChanged: root.draftFolder = text
          onAccepted: root.createFolder()
        }
        Row {
          ActionButton { label: root.renamingFolder ? strings.t("settings.apply") : strings.t("settings.createFolder"); onClicked: root.createFolder() }
          ActionButton {
            visible: root.renamingFolder !== ""
            label: strings.t("feeds.cancelDelete")
            onClicked: { root.renamingFolder = ""; root.draftFolder = "" }
          }
        }
        Repeater {
          model: root.folderNames
          Column {
            required property string modelData
            width: settingsContent.width
            ReaderText { width: parent.width; text: modelData; color: root.popupText; elide: Text.ElideRight }
            ActionButton {
              label: strings.t("menu.renameFolder")
              onClicked: {
                root.renamingFolder = modelData
                root.draftFolder = modelData
                settingsFolderInput.editor.forceActiveFocus()
              }
            }
            ActionButton {
              visible: root.pendingDeleteFolder !== modelData
              label: strings.t("settings.deleteFolder")
              onClicked: root.pendingDeleteFolder = modelData
            }
            Column {
              width: parent.width
              visible: root.pendingDeleteFolder === modelData
              ReaderText {
                width: parent.width
                text: strings.t("settings.confirmDeleteFolder").arg(modelData)
                color: root.popupText
                wrapMode: Text.Wrap
              }
              Row {
                ActionButton { label: strings.t("feeds.cancelDelete"); onClicked: root.pendingDeleteFolder = "" }
                ActionButton { label: strings.t("feeds.delete"); onClicked: root.deleteFolder(modelData) }
              }
            }
          }
        }
        Rectangle { width: parent.width; height: 1; color: Color.popups.border }
        ReaderText {
          text: strings.t("settings.feeds")
          color: root.popupText
          font.bold: true
        }
        Column {
          id: feedEditColumn
          width: parent.width
          visible: root.editingFeedId !== ""
          spacing: Style.space(6)
          ReaderText { text: strings.t("settings.feedName"); color: root.popupText }
          InputField {
            id: feedNameInput
            width: parent.width
            text: root.editingTitle
            onTextChanged: root.editingTitle = text
            onAccepted: root.applyFeedEdit()
          }
          ReaderText { text: strings.t("settings.folder"); color: root.popupText }
          InputField {
            width: parent.width
            placeholder: strings.t("settings.noFolder")
            text: root.editingFolder
            onTextChanged: root.editingFolder = text
            onAccepted: root.applyFeedEdit()
          }
          Flow {
            width: parent.width
            ActionButton {
              label: strings.t("settings.ungrouped")
              selected: root.editingFolder === ""
              onClicked: root.editingFolder = ""
            }
            Repeater {
              model: root.folderNames
              ActionButton {
                required property string modelData
                label: modelData
                selected: root.editingFolder === modelData
                onClicked: root.editingFolder = modelData
              }
            }
          }
          Row {
            ActionButton { label: strings.t("settings.apply"); onClicked: root.applyFeedEdit() }
            ActionButton { label: strings.t("feeds.cancelDelete"); onClicked: root.editingFeedId = "" }
          }
        }
        Repeater {
          model: root.feeds
          Column {
            required property var modelData
            width: settingsContent.width
            spacing: Style.space(2)
            ReaderText {
              width: parent.width
              text: modelData.folder ? strings.t("settings.feedInFolder").arg(modelData.title).arg(modelData.folder) : modelData.title
              color: root.popupText
              wrapMode: Text.Wrap
            }
            ReaderText {
              width: parent.width
              text: modelData.error || (modelData.lastUpdated
                ? strings.t("status.lastUpdated").arg(new Date(modelData.lastUpdated).toLocaleString(Qt.locale(Commons.I18n.formatLocale)))
                : strings.t("status.neverUpdated"))
              color: modelData.error ? Color.accent : root.muted
              wrapMode: Text.Wrap
            }
            Flow {
              width: parent.width
              ActionButton { label: strings.t("settings.edit"); onClicked: { root.editFeed(modelData); Qt.callLater(settingsScroll.focusFeedEditor) } }
              ActionButton { label: "↑"; onClicked: root.moveFeed(modelData.id, -1) }
              ActionButton { label: "↓"; onClicked: root.moveFeed(modelData.id, 1) }
              ActionButton { label: modelData.error ? strings.t("list.retry") : strings.t("list.refresh"); enabled: !root.busy; onClicked: root.refreshFeed(modelData) }
            }
          }
        }
        Rectangle { width: parent.width; height: 1; color: Color.popups.border }
        ReaderText { text: strings.t("settings.opml"); color: root.popupText; font.bold: true }
        ReaderText {
          width: parent.width
          text: strings.t("settings.opmlHelp")
          color: root.muted
          wrapMode: Text.Wrap
        }
        Flow {
          width: parent.width
          ActionButton { label: strings.t("settings.import"); enabled: !root.transferBusy && !root.busy && !root.pickerBusy; onClicked: root.pickSubscriptions(true) }
          ActionButton { label: strings.t("settings.export"); enabled: !root.transferBusy && !root.busy && !root.pickerBusy; onClicked: root.pickSubscriptions(false) }
        }
        Rectangle { width: parent.width; height: 1; color: Color.popups.border }
        ReaderText { text: strings.t("settings.keyboard"); color: root.popupText; font.bold: true }
        ReaderText {
          width: parent.width
          text: strings.t("settings.shortcuts")
          color: root.muted
          wrapMode: Text.Wrap
        }
      }
    }
  }

}
