import QtQuick
import QtTest
import "../Reader.js" as Reader

Item {
    id: model
    property var feeds: []
    property var saved: []
    property var readIds: []
    property var collapsedFolders: []
    readonly property var sidebar: Reader.sidebar(feeds, ["Empty"], collapsedFolders)
    readonly property int unreadCount: Reader.unread(Reader.allItems(feeds), readIds)
    readonly property int savedCount: saved.length

    TestCase {
        name: "Reader"

        function story(id) {
            return {id: id, link: "https://example.com/" + id, title: id, content: "Stored article", summary: ""}
        }

        function init() {
            model.feeds = [{id: "feed", url: "https://example.com/feed", title: "Daily", items: [story("one"), story("two")]}]
            model.saved = []
            model.readIds = []
            model.collapsedFolders = []
        }

        function test_counters_react_to_reassignment() {
            compare(model.unreadCount, 2)
            model.readIds = Reader.markItems([], [story("one")], true)
            compare(model.unreadCount, 1)
            model.saved = Reader.savedAfterToggle([], story("one"))
            compare(model.savedCount, 1)
            model.saved = Reader.savedAfterToggle(model.saved, story("one"))
            compare(model.savedCount, 0)
            model.readIds = Reader.markItems(model.readIds, [story("one")], false)
            compare(model.unreadCount, 2)
        }

        function test_migration_and_feed_removal_preserve_saved_articles() {
            var state = Reader.normalizeState({feeds: model.feeds, savedIds: ["one"]})
            state.feeds = []
            var restored = Reader.normalizeState(JSON.parse(JSON.stringify(state)))
            compare(restored.savedArticles.length, 1)
            compare(restored.savedArticles[0].content, "Stored article")
            compare(Reader.scopeItems([], restored.savedArticles, "saved", "").length, 1)
        }

        function test_scope_does_not_mark_other_feeds() {
            var feeds = model.feeds.concat([{id: "other", title: "Other", items: [story("three")]}])
            var scope = Reader.scopeItems(feeds, [], "feed", "")
            var read = Reader.markItems([], scope, true)
            compare(read.length, 2)
            verify(read.indexOf("three") < 0)
        }

        function test_folder_collapse_updates_sidebar_without_removing_stories() {
            model.feeds = [Object.assign({}, model.feeds[0], {folder: "Tech"})]
            compare(model.sidebar.length, 3)
            model.collapsedFolders = ["Tech"]
            compare(model.sidebar.length, 2)
            compare(model.unreadCount, 2)
            model.collapsedFolders = []
            compare(model.sidebar.length, 3)
        }
    }
}
