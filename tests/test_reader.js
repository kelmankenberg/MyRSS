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
    feeds: [], savedArticles: [], savedIds: [], readIds: [], refreshQueue: [],
    busy: false, stateWritable: true, opened: false, defaultFetchAttempted: true,
    batchRefresh: false, refreshFailures: 0, newArticleCount: 0, newArticleIds: [],
    pendingFeedUrl: "", currentFeedUrl: "", selectedId: "", articleOpen: false
};
const tasks = [];
Object.defineProperty(root, "folderNames", {get: () => reader.folderNames(root.feeds, root.folders)});
const warnings = [];
let persisted;
const context = vm.createContext({
    root, Reader: reader,
    strings: {t: key => key, tn: key => key},
    Commons: {I18n: {formatNumber: String}},
    Qt: {callLater: fn => tasks.push(fn)},
    feedProcess: {running: false}, articleProcess: {running: false},
    readTimer: {restart() {}, stop() {}},
    stateFile: {setText: text => { persisted = JSON.parse(text); }},
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
root.readState(JSON.stringify({feeds, savedIds: ["one"], readIds: ["two"]}));
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
const transfers = [];
root.transferSubscriptions = (...args) => transfers.push(args);
root.pickingImport = true;
root.acceptPickedFile(0, "/tmp/My feeds.opml\n", "");
assert.equal(transfers[0][0], true);
assert.equal(transfers[0][1], "/tmp/My feeds.opml");
assert.equal(root.opened, true);
assert.equal(root.settingsOpen, true);
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
