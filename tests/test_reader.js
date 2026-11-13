const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const reader = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, "../Reader.js"), "utf8"), reader);
const story = (id) => ({id, link: "https://example.com/" + id, title: id, summary: "", content: "Stored text"});
const feeds = [{id: "feed", url: "https://example.com/feed", title: "Daily", items: [story("one"), story("two")]}];
const state = reader.normalizeState({feeds, savedIds: ["one"], readIds: ["two"]});
assert.equal(state.savedArticles.length, 1);
assert.equal(state.savedArticles[0].feedTitle, "Daily");
const refreshed = reader.normalizeState({...state, feeds: [{...feeds[0], items: []}]});
assert.equal(refreshed.savedArticles[0].content, "Stored text");
const deleted = reader.normalizeState({...refreshed, feeds: []});
assert.equal(reader.scopeItems([], deleted.savedArticles, "saved", "").length, 1);
assert.equal(reader.savedAfterToggle(deleted.savedArticles, story("one")).length, 0);
assert.equal(reader.unread(reader.allItems(feeds), ["two"]), 1);
assert.equal(reader.scopeItems(feeds, [], "feed", "").length, 2);
assert.equal(reader.scopeItems([], deleted.savedArticles, "all", "one").length, 1);
const grouped = [{...feeds[0], folder: "Tech"}, {id: "other", title: "Other", items: [story("three")], folder: ""}];
assert.equal(reader.scopeItems(grouped, [], "folder:Tech", "").length, 2);
const marked = reader.markItems(["three"], reader.scopeItems(grouped, [], "feed", ""), true);
assert.equal(marked.length, 3);
assert.equal(reader.markItems(marked, feeds[0].items, false).join(","), "three");
assert.equal(reader.sidebar(grouped).map(entry => entry.kind).join(","), "feed,folder,feed");
assert.equal(reader.sidebar(grouped, ["Empty"], ["Tech"]).map(entry => entry.kind).join(","), "feed,folder,folder");
const folderState = reader.normalizeState({feeds: grouped, folders: ["Empty", "Empty"], collapsedFolders: ["Tech", "Missing"]});
assert.equal(folderState.folders.join(","), "Empty,Tech");
assert.equal(folderState.collapsedFolders.join(","), "Tech");
assert.equal(reader.normalizeState(JSON.parse(JSON.stringify(folderState))).folders.join(","), "Empty,Tech");
assert.equal(reader.normalizeState({preferences: {refreshMinutes: -1, markDelay: 100, textScale: 100}}).preferences.refreshMinutes, 0);

const root = {
    feeds: [], savedArticles: [], savedIds: [], readIds: [], unseenArticleIds: [], refreshQueue: [],
    busy: false, stateWritable: true, opened: false, defaultFetchAttempted: true,
    batchRefresh: false, refreshFailures: 0, newArticleCount: 0, newArticleIds: [],
    pendingFeedUrl: "", currentFeedUrl: "", selectedId: "", articleOpen: false
};
const tasks = [];
const timerCalls = {};
const timer = name => ({
    restart() { timerCalls[name + "Restart"] = (timerCalls[name + "Restart"] || 0) + 1; },
    stop() { timerCalls[name + "Stop"] = (timerCalls[name + "Stop"] || 0) + 1; }
});
const feedSignals = [];
const articleSignals = [];
const subscriptionSignals = [];
Object.defineProperty(root, "folderNames", {get: () => reader.folderNames(root.feeds, root.folders)});
Object.defineProperty(root, "pendingArticleIds", {get: () => reader.unseenIds(root.allItems(), root.readIds, root.unseenArticleIds)});
const warnings = [];
let persisted;
const context = vm.createContext({
    root, Reader: reader,
    StandardKey: {Paste: "paste"},
    strings: {t: key => key, tn: key => key},
    Commons: {I18n: {formatNumber: String}},
    Qt: {callLater: fn => tasks.push(fn), resolvedUrl: file => "file:///plugin/" + file},
    feedProcess: {running: false, signal: signal => feedSignals.push(signal)},
    articleProcess: {running: false, signal: signal => articleSignals.push(signal)},
    subscriptionProcess: {running: false, signal: signal => subscriptionSignals.push(signal)},
    feedDeadline: timer("feedDeadline"), feedKillTimer: timer("feedKillTimer"),
    articleDeadline: timer("articleDeadline"), articleKillTimer: timer("articleKillTimer"),
    subscriptionDeadline: timer("subscriptionDeadline"), subscriptionKillTimer: timer("subscriptionKillTimer"),
    readTimer: {restart() {}, stop() {}},
    stateLoader: {running: false},
    stateWriter: {running: false},
    notificationProcess: {running: false},
    panel: {loadedContent: null},
    clipboard: {text: "", selectAll() {}, copy() { this.copied = this.text; }},
    console: {warn: (...args) => warnings.push(args)}
});
vm.runInContext("String.prototype.arg = function(value) { return this.replace(/%\\d/, value); };", context);
const qml = fs.readFileSync(path.join(__dirname, "../BarWidget.qml"), "utf8");
for (const match of qml.matchAll(/^  function (\w+)\(([^)]*)\) \{([\s\S]*?)^  \}/gm)) {
    vm.runInContext(`function ${match[1]}(${match[2]}) {${match[3]}}`, context);
    root[match[1]] = (...args) => context[match[1]](...args);
}
root.clearInputFocus = () => {};
const flushState = root.flushState;
root.flushState = () => { persisted = JSON.parse(root.pendingState); root.pendingState = ""; };
root.readState(JSON.stringify({feeds, savedIds: ["one"], readIds: ["two"]}));
assert.equal(root.compactView, false);
assert.equal(root.navigationWidth, 180);
root.navigationWidth = 210;
root.saveState();
assert.equal(persisted.preferences.navigationWidth, 210);
root.navigationWidth = 180;
root.readState(JSON.stringify(persisted));
assert.equal(root.navigationWidth, 210);
assert.equal(reader.normalizeState({preferences: {navigationWidth: 999}}).preferences.navigationWidth, 240);
assert.equal(reader.normalizeState({preferences: {navigationWidth: 1}}).preferences.navigationWidth, 140);
assert.equal(reader.normalizeState({preferences: {navigationWidth: "invalid"}}).preferences.navigationWidth, 180);
root.compactView = true;
root.saveState();
const compactState = JSON.stringify(persisted);
assert.equal(persisted.preferences.compactView, true);
root.compactView = false;
root.readState(compactState);
assert.equal(root.compactView, true);
assert.equal(root.showImages, true); // Compact lists do not change the article image preference.
root.compactView = false;
root.saveState();
assert.equal(persisted.preferences.compactView, false);
const navigationDrag = qml.match(/startWidth = root\.navigationWidth[\s\S]*?onPositionChanged: function\(mouse\) \{([\s\S]*?)\n            \}/);
assert.ok(navigationDrag);
const resizeContext = vm.createContext({
    root, pressed: true, startWidth: 180, startX: 100,
    mapToGlobal: x => ({x}), Style: {spacing: {scale: 1}}
});
vm.runInContext(`function drag(mouse) {${navigationDrag[1]}}`, resizeContext);
resizeContext.drag({x: 125, y: 0});
assert.equal(root.navigationWidth, 205);
resizeContext.drag({x: 200, y: 0});
assert.equal(root.navigationWidth, 240);
resizeContext.drag({x: 0, y: 0});
assert.equal(root.navigationWidth, 140);
resizeContext.Style.spacing.scale = 2;
resizeContext.drag({x: 150, y: 0});
assert.equal(root.navigationWidth, 205);
root.pendingFeedUrl = "";
root.currentFeedUrl = feeds[0].url;
root.acceptFeedResult(0, JSON.stringify({ok: true, url: feeds[0].url, title: "Updated", items: [story("two")]}));
assert.equal(root.savedArticles[0].id, "one");
assert.equal(persisted.savedArticles[0].content, "Stored text");
root.pendingDeleteFeedId = feeds[0].id;
root.removeFeed(feeds[0].id);
assert.equal(root.feeds.length, 1); // The automatically included Omarchy feed remains.
assert.equal(root.savedArticles[0].id, "one");
root.currentFeedUrl = root.feeds[0].url;
root.pendingFeedUrl = "https://example.com/new";
root.feedFailed("Download failed");
assert.equal(root.pendingFeedUrl, "");
assert.equal(root.feeds[0].error, "Download failed");
root.toggleSaved("one");
assert.equal(root.savedArticles.length, 0);
assert.equal(persisted.savedArticles.length, 0);
root.feeds = [{...feeds[0], title: "My custom name", customTitle: true, folder: "Tech"}];
root.currentFeedUrl = feeds[0].url;
root.acceptFeedResult(0, JSON.stringify({ok: true, url: "https://example.com/redirected", title: "Publisher name", items: [story("new")]}));
assert.equal(root.feeds[0].title, "My custom name");
assert.equal(root.feeds[0].id, feeds[0].id);
assert.equal(root.feeds[0].folder, "Tech");
assert.equal(root.feeds[0].error, "");
assert.equal(persisted.unseenArticleIds.join(","), "new");
// An unchanged refresh must not re-highlight articles already acknowledged.
root.open();
assert.equal(root.unseenArticleIds.length, 0);
assert.equal(persisted.unseenArticleIds.length, 0);
assert.ok(!root.readIds.includes("new"));
root.close();
root.acceptFeedResult(0, JSON.stringify({ok: true, url: feeds[0].url, title: "Daily", items: [story("new")]}));
assert.equal(root.pendingArticleIds.length, 0);
root.acceptFeedResult(0, JSON.stringify({ok: true, url: feeds[0].url, title: "Daily", items: [story("new"), story("newer")]}));
assert.equal(root.pendingArticleIds.join(","), "newer");
const highlightedState = JSON.stringify(persisted);
root.readState(highlightedState);
assert.equal(root.pendingArticleIds.join(","), "newer");
root.markRead("newer", true);
assert.equal(root.pendingArticleIds.length, 0);
root.readState(highlightedState);
root.pendingDeleteFeedId = feeds[0].id;
root.removeFeed(feeds[0].id);
assert.equal(root.pendingArticleIds.length, 0);
// Loading while an initial open is awaiting state also acknowledges new items.
root.opened = true;
root.readState(highlightedState);
assert.equal(persisted.unseenArticleIds.length, 0);
root.acceptFeedResult(0, JSON.stringify({ok: true, url: feeds[0].url, title: "Daily", items: [story("latest")]}));
assert.equal(root.pendingArticleIds.length, 0);
root.close();
assert.equal(root.pendingArticleIds.length, 0);
assert.equal(reader.normalizeState({feeds, readIds: ["two"], unseenArticleIds: ["one", "two", "missing"]}).unseenArticleIds.join(","), "one");
assert.equal(reader.normalizeState({feeds}).unseenArticleIds.length, 0);
assert.match(qml, /foreground: root\.hasNewArticles \? Color\.accent : root\.foreground/);
assert.match(qml, /useActiveColor: false/);
const pasteEvent = {accepted: false, matches: key => key === "paste"};
assert.equal(root.blockPaste(pasteEvent), true);
assert.equal(pasteEvent.accepted, true);
assert.equal(root.status, "status.pasteUnavailable");
const ordinaryKey = {accepted: false, matches: () => false};
assert.equal(root.blockPaste(ordinaryKey), false);
assert.equal(ordinaryKey.accepted, false);
assert.equal((qml.match(/Keys\.priority: Keys\.BeforeItem/g) || []).length, 3);
assert.equal((qml.match(/if \(root\.blockPaste\(event\)\) return/g) || []).length, 3);
assert.match(qml, /component ReaderInput: TextInput \{[\s\S]*?acceptedButtons: Qt\.MiddleButton[\s\S]*?root\.showPasteUnavailable\(\)/);
root.busy = true;
root.pendingFeedUrl = "";
root.addFeed("https://example.com/another");
assert.equal(root.pendingFeedUrl, "");
root.busy = false;
root.readState("{broken");
const lastPersisted = persisted;
root.saveState();
assert.equal(persisted, lastPersisted);
assert.equal(warnings.length, 1);
root.stateWritable = true;
root.requestFeed("https://example.com/private-feed?token=feed-secret");
assert.equal(context.feedProcess.command.length, 3);
assert.equal(context.feedProcess.command[2], "feed");
assert.ok(!JSON.stringify(context.feedProcess.command).includes("secret"));
root.requestArticle("https://example.com/private-article?token=article-secret");
assert.equal(context.articleProcess.command.length, 3);
assert.equal(context.articleProcess.command[2], "article");
assert.ok(!JSON.stringify(context.articleProcess.command).includes("secret"));
const thumbnailQml = fs.readFileSync(path.join(__dirname, "../Thumbnail.qml"), "utf8");
assert.match(qml, /onStarted: write\(JSON\.stringify\(\{url: root\.currentFeedUrl\}\) \+ "\\n"\)/);
assert.match(qml, /onStarted: write\(JSON\.stringify\(\{url: root\.articleRequestUrl\}\) \+ "\\n"\)/);
assert.match(thumbnailQml, /imageProcess\.command = \["python3", root\.helperPath, "image"\]/);
assert.match(thumbnailQml, /onStarted: write\(JSON\.stringify\(\{url: root\.requestedUrl\}\) \+ "\\n"\)/);
assert.match(qml, /id: feedDeadline[\s\S]*?interval: 30000[\s\S]*?root\.expireFeedRequest\(\)/);
assert.match(qml, /id: articleDeadline[\s\S]*?interval: 30000[\s\S]*?root\.expireArticleRequest\(\)/);
assert.match(thumbnailQml, /id: requestDeadline[\s\S]*?interval: 15000[\s\S]*?root\.expireImageRequest\(\)/);
const imageSignals = [];
const thumbnailRoot = {requestTimedOut: false};
const thumbnailContext = vm.createContext({
    root: thumbnailRoot,
    imageProcess: {running: true, signal: signal => imageSignals.push(signal)},
    requestDeadline: timer("imageDeadline"),
    killTimer: timer("imageKillTimer")
});
for (const match of thumbnailQml.matchAll(/^  function (\w+)\(([^)]*)\) \{([\s\S]*?)^  \}/gm)) {
    vm.runInContext(`function ${match[1]}(${match[2]}) {${match[3]}}`, thumbnailContext);
    thumbnailRoot[match[1]] = (...args) => thumbnailContext[match[1]](...args);
}
thumbnailRoot.expireImageRequest();
assert.equal(thumbnailRoot.requestTimedOut, true);
assert.equal(imageSignals.at(-1), 15);
thumbnailRoot.forceKillImageRequest();
assert.equal(imageSignals.at(-1), 9);
assert.ok(!/console\.warn\([^\n]*root\.imageUrl/.test(thumbnailQml));
root.busy = false;
root.feeds = [{...feeds[0], folder: "Tech"}, {id: "other", url: "https://other.example/feed", title: "Other", items: [], folder: ""}];
root.savedArticles = [{...story("one"), feedId: "feed", feedTitle: "Daily"}];
root.editingFeedId = "feed";
root.editingTitle = "Renamed";
root.editingFolder = "Reading";
root.applyFeedEdit();
assert.equal(root.feeds[0].customTitle, true);
assert.equal(root.feeds[0].folder, "Reading");
assert.equal(root.savedArticles[0].feedTitle, "Renamed");
const previousLength = root.feeds.length;
root.acceptSubscriptionResult(0, JSON.stringify({ok: true, feeds: [
    {url: feeds[0].url, title: "Duplicate", folder: ""},
    {url: "https://new.example/feed", title: "Imported", folder: "Reading"}
]}));
assert.equal(root.feeds.length, previousLength + 1);
root.moveFeed("feed", 1);
assert.equal(root.feeds[2].id, "feed");
root.draftFolder = " Empty ";
root.createFolder();
assert.ok(persisted.folders.includes("Empty"));
root.toggleFolder("Reading");
assert.ok(persisted.collapsedFolders.includes("Reading"));
root.toggleFolder("Reading");
assert.ok(!persisted.collapsedFolders.includes("Reading"));
root.draftFolder = "Empty";
root.createFolder();
assert.equal(root.status, "status.folderNameRequired");
root.pendingDeleteFolder = "";
root.deleteFolder("Reading");
assert.ok(root.feeds.some(feed => feed.folder === "Reading"));
root.activeFeed = "all";
root.pendingDeleteFolder = "Reading";
const feedCount = root.feeds.length;
root.deleteFolder("Reading");
assert.equal(root.feeds.length, feedCount);
assert.ok(root.feeds.every(feed => feed.folder !== "Reading"));
assert.ok(!persisted.folders.includes("Reading"));
assert.ok(persisted.folders.includes("Empty"));
root.refreshMinutes = 15;
root.notificationsEnabled = true;
root.saveState();
assert.equal(persisted.preferences.refreshMinutes, 15);
assert.equal(persisted.preferences.notifications, true);
root.batchRefresh = true;
root.automaticBatch = true;
root.newArticleCount = 2;
root.refreshFailures = 0;
root.refreshQueue = [];
root.refreshNextFeed();
assert.equal(context.notificationProcess.running, true);
assert.equal(context.notificationProcess.command[0], "notify-send");
assert.equal(root.batchRefresh, false);
root.savedArticles = [];
root.savedIds = [];
root.feeds = [];
root.articleOpen = true;
root.selectedId = "archived";
root.selectedSnapshot = {...story("archived"), feedId: "removed", feedTitle: "Removed feed"};
root.selectedContent = "Preserved full article";
root.selectedFullContent = true;
root.toggleSaved("archived");
assert.equal(root.savedArticles[0].content, "Preserved full article");
root.toggleSaved("archived");
assert.equal(root.savedArticles.length, 0);
root.toggleSaved("archived");
assert.equal(root.savedArticles.length, 1);
root.articleOpen = false;
root.settingsOpen = false;
root.pendingDeleteFeedId = "";
root.visibleItems = [story("next"), story("later")];
root.cursorId = "hidden-after-reading";
root.cursorIndex = -1;
root.cursorPosition = 1;
root.moveCursor(1);
assert.equal(root.cursorId, "later");

root.feeds = [{...feeds[0], folder: "Tech"}];
root.folders = ["Tech", "Empty"];
root.collapsedFolders = ["Tech"];
root.activeFeed = "folder:Tech";
root.renamingFolder = "Tech";
root.draftFolder = "Reading";
root.createFolder();
assert.equal(root.feeds[0].folder, "Reading");
assert.equal(root.activeFeed, "folder:Reading");
assert.equal(root.collapsedFolders.join(","), "Reading");
assert.ok(!persisted.folders.includes("Tech"));
root.renamingFolder = "Reading";
root.draftFolder = "Empty";
root.createFolder();
assert.equal(root.status, "status.folderNameRequired");
assert.equal(root.feeds[0].folder, "Reading");
root.renamingFolder = "";
root.contextKind = "feed";
root.contextTarget = root.feeds[0];
assert.ok(root.buildContextActions().includes("moveFeed"));
root.contextAction("markRead");
assert.ok(root.readIds.includes("one") && root.readIds.includes("two"));
root.contextKind = "folder";
root.contextTarget = "Reading";
root.contextAction("markUnread");
assert.ok(!root.readIds.includes("one") && !root.readIds.includes("two"));
root.contextKind = "article";
root.contextTarget = story("one");
root.contextAction("copyLink");
assert.equal(context.clipboard.copied, story("one").link);
assert.equal(root.buildContextActions().length, 0);
root.contextKind = "folder";
root.contextTarget = "Empty";
root.contextAction("refresh");
assert.equal(root.status, "list.emptyFolder");
let clearedSettingsFocus = false;
root.clearInputFocus = () => { clearedSettingsFocus = true; };
root.selectSettingsTab("updates");
assert.equal(root.settingsTab, "updates");
assert.equal(clearedSettingsFocus, true);
root.clearInputFocus = () => {};
let settingsRoute = "";
context.panel.loadedContent = {
    focusFeedEditor() { settingsRoute = "feed"; },
    revealFolderDelete() { settingsRoute = "folder"; }
};
root.contextKind = "feed";
root.contextTarget = root.feeds[0];
root.contextAction("moveFeed");
assert.equal(root.settingsOpen, true);
assert.equal(root.settingsTab, "subscriptions");
assert.equal(root.subscriptionsSection, "feeds");
assert.equal(root.editingFeedId, root.feeds[0].id);
tasks.pop()();
assert.equal(settingsRoute, "feed");
root.settingsTab = "help";
root.contextKind = "folder";
root.contextTarget = "Reading";
root.contextAction("deleteFolder");
assert.equal(root.settingsTab, "subscriptions");
assert.equal(root.subscriptionsSection, "folders");
assert.equal(root.pendingDeleteFolder, "Reading");
tasks.pop()();
assert.equal(settingsRoute, "folder");
context.panel.loadedContent = null;
root.pendingDeleteFolder = "";
root.settingsOpen = false;
root.changeReaderWidth(-10000);
assert.equal(persisted.preferences.readerWidth, 680);
root.changeReaderWidth(10000);
assert.equal(persisted.preferences.readerWidth, 1320);
const normalizedSession = reader.normalizeState({
    feeds: root.feeds, folders: root.folders,
    session: {activeFeed: "folder:Reading", selectedId: "one", articleOpen: true,
        storyScrollY: 123, articleScrollY: 456, searchText: "Daily"},
    preferences: {readerWidth: 1000}
});
assert.equal(normalizedSession.session.activeFeed, "folder:Reading");
assert.equal(normalizedSession.session.storyScrollY, 123);
assert.equal(normalizedSession.preferences.readerWidth, 1000);
assert.equal(reader.normalizeState({session: {activeFeed: "missing", storyScrollY: -10}}).session.activeFeed, "all");
assert.equal(reader.normalizeState({session: {articleScrollY: Infinity}}).session.articleScrollY, 1000000);
let restoredScroll = false;
context.panel.loadedContent = {
    articleViewport: {contentY: 0},
    restoreStoryScroll() {},
    restoreArticleScroll() { restoredScroll = true; }
};
root.opened = true;
root.resumeArticle = true;
root.articleOpen = false;
root.selectedId = "one";
root.feeds[0].items[0].fullContent = true;
root.articleScrollY = 456;
root.restoreArticle();
assert.equal(root.articleOpen, true);
assert.equal(root.articleScrollY, 456);
tasks.splice(0).forEach(task => task());
assert.equal(restoredScroll, true);
root.close();
assert.equal(persisted.session.articleOpen, true);
assert.equal(persisted.session.articleScrollY, 456);
root.closeArticle();
root.saveState();
assert.equal(persisted.session.articleOpen, false);
root.scopedItems = [story("one")];
root.showRead = false;
root.busy = false;
root.searchText = "";
assert.equal(root.emptyMessage(), "list.noUnread");
root.scopedItems = [];
root.activeFeed = "folder:Empty";
assert.equal(root.emptyMessage(), "list.emptyFolder");
root.activeFeed = "feed";
root.activeFeedData = {lastUpdated: 0, error: ""};
assert.equal(root.emptyMessage(), "list.unfetched");
root.activeFeedData = {lastUpdated: 1, error: ""};
assert.equal(root.emptyMessage(), "list.emptyFeed");
root.activeFeedData.error = "Download failed";
assert.equal(root.emptyMessage(), "list.failedFeed");
root.searchText = "not found";
assert.equal(root.emptyMessage(), "list.noSearchResults");
root.open = () => { root.opened = true; };
root.busy = false;
root.transferBusy = false;
root.transferSubscriptions(true, "/tmp/import.opml");
assert.equal(root.transferBusy, true);
assert.equal(context.subscriptionProcess.command[2], "import-opml");
assert.equal(timerCalls.subscriptionDeadlineRestart, 1);
root.expireSubscriptionTransfer();
assert.equal(root.transferTimedOut, true);
assert.equal(root.status, "status.transferTimeout");
assert.equal(root.transferBusy, true);
assert.equal(subscriptionSignals.at(-1), 15);
assert.equal(timerCalls.subscriptionKillTimerRestart, 1);
const activeTransferCommand = context.subscriptionProcess.command;
root.transferSubscriptions(false, "/tmp/blocked.opml");
assert.equal(context.subscriptionProcess.command, activeTransferCommand);
root.forceKillSubscriptionTransfer();
assert.equal(subscriptionSignals.at(-1), 9);
const feedsBeforeTimeout = root.feeds;
context.subscriptionProcess.running = false;
root.finishSubscriptionProcess(0, JSON.stringify({
    ok: true, feeds: [{title: "Too late", url: "https://late.example/feed", folder: ""}]
}));
assert.equal(root.feeds, feedsBeforeTimeout);
assert.equal(root.transferBusy, false);
assert.equal(root.transferTimedOut, false);
assert.equal(root.status, "status.transferTimeout");
assert.equal(root.exportSnapshot, "");
assert.equal(timerCalls.subscriptionDeadlineStop, 1);
assert.equal(timerCalls.subscriptionKillTimerStop, 1);
root.transferSubscriptions(false, "/tmp/recovered.opml");
assert.equal(root.transferBusy, true);
assert.ok(root.exportSnapshot.endsWith("\n"));
context.subscriptionProcess.running = false;
root.finishSubscriptionProcess(0, JSON.stringify({ok: true, path: "/tmp/recovered.opml"}));
root.checkSubscriptionStopped();
assert.equal(root.transferBusy, false);
assert.equal(root.status, "status.exported");
assert.equal(root.exportSnapshot, "");
root.transferSubscriptions(true, "/tmp/start-failed.opml");
context.subscriptionProcess.running = false;
root.checkSubscriptionStopped();
assert.equal(root.transferBusy, false);
assert.equal(root.status, "status.transferError");
root.transferSubscriptions(true, "/tmp/missed-start-failure.opml");
context.subscriptionProcess.running = false;
root.expireSubscriptionTransfer();
assert.equal(root.transferBusy, false);
assert.equal(root.status, "status.transferError");
const transfers = [];
root.transferSubscriptions = (...args) => transfers.push(args);
root.pickingImport = true;
root.acceptPickedFile(0, "/tmp/My feeds.opml\n", "");
assert.equal(transfers[0][0], true);
assert.equal(transfers[0][1], "/tmp/My feeds.opml");
assert.equal(root.opened, true);
assert.equal(root.settingsOpen, true);
assert.equal(root.settingsTab, "subscriptions");
assert.equal(root.subscriptionsSection, "transfer");
root.acceptPickedFile(1, "", "");
assert.equal(transfers.length, 1);
root.pickingImport = false;
root.acceptPickedFile(0, "/tmp/export with spaces.opml\n", "");
assert.equal(transfers[1][0], false);
assert.equal(transfers[1][1], "/tmp/export with spaces.opml");
root.acceptPickedFile(127, "", "Picker unavailable");
assert.equal(root.status, "status.pickerError");
assert.equal(transfers.length, 2);
console.log("Reader state migration, durable saves, search, and unread checks passed");
root.pendingState = '{"feeds":[]}\n';
root.stateWritable = true;
flushState();
assert.equal(root.writingState, '{"feeds":[]}\n');
assert.equal(root.pendingState, "");
root.pendingState = '{"feeds":[1]}\n';
flushState();
assert.equal(root.writingState, '{"feeds":[]}\n');
root.acceptStateResult(1, '{"ok":false,"error":"Permission denied"}', false);
assert.equal(root.stateWritable, false);
assert.equal(root.pendingState, "");
assert.equal(root.status, "status.saveError");

root.stateWritable = true;
root.currentFeedUrl = feeds[0].url;
root.pendingFeedUrl = "https://example.com/new";
root.feeds = [{...feeds[0], error: ""}];
root.batchRefresh = true;
root.refreshQueue = ["https://next.example/feed"];
root.busy = true;
context.feedProcess.running = true;
root.expireFeedRequest();
assert.equal(root.feedTimedOut, true);
assert.equal(feedSignals.at(-1), 15);
assert.ok(timerCalls.feedKillTimerRestart > 0);
root.forceKillFeedRequest();
assert.equal(feedSignals.at(-1), 9);
context.feedProcess.running = false;
const queuedTaskCount = tasks.length;
root.finishFeedProcess(15, "");
assert.equal(root.feedTimedOut, false);
assert.equal(root.busy, false);
assert.equal(root.pendingFeedUrl, "");
assert.equal(root.feeds[0].error, "status.requestTimeout");
assert.ok(timerCalls.feedDeadlineStop > 0);
assert.equal(tasks.length, queuedTaskCount + 1);
tasks.pop()();
assert.equal(root.currentFeedUrl, "https://next.example/feed");
assert.equal(root.busy, true);
context.feedProcess.running = false;
root.busy = false;
root.batchRefresh = false;

root.articleOpen = true;
root.articleRequestUrl = story("slow").link;
root.selectedUrl = root.articleRequestUrl;
root.selectedFullContent = false;
context.articleProcess.running = true;
root.expireArticleRequest();
assert.equal(root.articleTimedOut, true);
assert.equal(articleSignals.at(-1), 15);
root.forceKillArticleRequest();
assert.equal(articleSignals.at(-1), 9);
context.articleProcess.running = false;
root.finishArticleProcess(15, "");
assert.equal(root.articleTimedOut, false);
assert.equal(root.articleError, "status.requestTimeout");
assert.ok(timerCalls.articleDeadlineStop > 0);

let feedbackUrl;
context.Qt.openUrlExternally = url => { feedbackUrl = url; return true; };
root.openFeedback();
assert.equal(feedbackUrl, "https://github.com/kelmankenberg/MyRSS/issues/new/choose");
context.Qt.openUrlExternally = () => false;
const warningCount = warnings.length;
root.openFeedback();
assert.equal(root.status, "status.feedbackError");
assert.equal(warnings.length, warningCount + 1);

const scrollTasks = [];
const scrollingRoot = {
    readIds: [], opened: true, stateLoaded: true, articleOpen: false,
    settingsOpen: false, restoringView: false, showRead: true, saves: 0, storyRowHeight: 100,
    saveState() { this.saves++; }
};
const scrollStories = [story("a"), story("b"), story("c"), story("d")];
Object.defineProperty(scrollingRoot, "visibleItems", {
    get: () => scrollStories.filter(item => scrollingRoot.showRead || !scrollingRoot.readIds.includes(item.id))
});
const list = {
    contentY: 0, originY: 0, spacing: 6, moving: false,
    positionViewAtIndex(index) { this.contentY = this.originY + index * (scrollingRoot.storyRowHeight + this.spacing); }
};
const scrollContext = vm.createContext({
    root: scrollingRoot, Reader: reader, storyList: list, Style: {space: n => n},
    restoring: false, userScrolling: true, previousY: 0, pendingReadIds: [],
    scrollReadTimer: timer("scrollRead"),
    Qt: {callLater: fn => scrollTasks.push(fn)}, ListView: {Beginning: 0}
});
const storiesSource = qml.slice(qml.indexOf("id: storiesView"), qml.indexOf("id: settingsPage"));
for (const match of storiesSource.matchAll(/^      function (\w+)\(([^)]*)\) \{([\s\S]*?)^      \}/gm))
    vm.runInContext(`function ${match[1]}(${match[2]}) {${match[3]}}`, scrollContext);
assert.match(storiesSource, /id: scrollReadTimer\s+interval: 1000/);
list.contentY = 99;
scrollContext.recordScroll();
assert.equal(scrollContext.pendingReadIds.length, 0);
list.contentY = 150;
scrollContext.recordScroll();
assert.equal(scrollContext.pendingReadIds.join(","), "a");
assert.equal(scrollingRoot.readIds.length, 0); // Pending until the pause expires.
list.moving = true;
scrollContext.markScrolledRead();
assert.equal(scrollingRoot.readIds.length, 0);
list.moving = false;
scrollContext.markScrolledRead();
scrollTasks.splice(0).forEach(fn => fn());
assert.equal(scrollingRoot.readIds.join(","), "a");
assert.equal(scrollingRoot.saves, 1);
// Scrolling back up during the pause leaves the returned article unread.
list.contentY = 230;
scrollContext.recordScroll();
list.contentY = 180;
scrollContext.recordScroll();
scrollContext.markScrolledRead();
assert.equal(scrollingRoot.readIds.join(","), "a");
// Restoring/jumping a list does not count as user scrolling.
scrollContext.userScrolling = false;
list.contentY = 330;
scrollContext.recordScroll();
assert.equal(scrollContext.pendingReadIds.length, 0);
// Hide Read preserves the visible anchor and its intra-row offset.
scrollingRoot.readIds = [];
scrollingRoot.showRead = false;
scrollContext.previousY = 0;
scrollContext.userScrolling = true;
list.contentY = 220;
scrollContext.recordScroll();
scrollContext.markScrolledRead();
scrollTasks.splice(0).forEach(fn => fn());
assert.equal(scrollingRoot.readIds.join(","), "a,b");
assert.equal(list.contentY, 8);
assert.equal(scrollingRoot.storyScrollY, 8);
// A row entirely above an initial restored position is not newly passed.
assert.equal(reader.scrolledPastItems(scrollStories, 220, 330, 0, 100, 6).map(item => item.id).join(","), "c");
// Compact rows use their own boundaries and preserve the anchor in unread-only mode.
scrollingRoot.storyRowHeight = 48;
scrollingRoot.readIds = [];
scrollContext.previousY = 0;
list.contentY = 47;
scrollContext.recordScroll();
assert.equal(scrollContext.pendingReadIds.length, 0);
list.contentY = 58;
scrollContext.recordScroll();
assert.equal(scrollContext.pendingReadIds.join(","), "a");
list.contentY = 46;
scrollContext.recordScroll();
scrollContext.markScrolledRead();
assert.equal(scrollingRoot.readIds.length, 0);
list.contentY = 112;
scrollContext.recordScroll();
scrollContext.markScrolledRead();
scrollTasks.splice(0).forEach(fn => fn());
assert.equal(scrollingRoot.readIds.join(","), "a,b");
assert.equal(list.contentY, 4);
assert.equal(scrollingRoot.storyScrollY, 4);
