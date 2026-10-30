function cleanItems(items) {
    return (Array.isArray(items) ? items : []).filter(function(item) {
        return item && typeof item.id === "string" && item.id.length <= 2048
            && typeof item.link === "string" && /^https:\/\//i.test(item.link)
            && typeof item.title === "string";
    }).map(function(item) {
        return {
            id: item.id, link: item.link.slice(0, 2048), title: item.title.slice(0, 500),
            date: String(item.date || "").slice(0, 120),
            summary: String(item.summary || "").slice(0, 2000),
            image: /^https:\/\//i.test(item.image || "") ? String(item.image).slice(0, 2048) : "",
            content: String(item.content || "").slice(0, 12000),
            fullContent: item.fullContent === true,
            feedId: String(item.feedId || "").slice(0, 2048),
            feedTitle: String(item.feedTitle || "").slice(0, 200)
        };
    });
}

function unique(items) {
    var seen = {};
    return items.filter(function(item) {
        if (Object.prototype.hasOwnProperty.call(seen, item.id)) return false;
        seen[item.id] = true;
        return true;
    });
}

function allItems(feeds) {
    var result = [];
    feeds.forEach(function(feed) {
        (feed.items || []).forEach(function(item) {
            result.push(Object.assign({}, item, {feedId: feed.id, feedTitle: feed.title}));
        });
    });
    return unique(result);
}

function scopeItems(feeds, saved, active, query) {
    var live = allItems(feeds);
    query = query.trim().toLowerCase();
    var items = query ? unique(live.concat(saved)) : active === "saved" ? saved : live;
    if (!query && active.indexOf("folder:") === 0) {
        var folder = active.substring(7);
        var ids = feeds.filter(function(feed) { return feed.folder === folder; }).map(function(feed) { return feed.id; });
        items = items.filter(function(item) { return ids.indexOf(item.feedId) >= 0; });
    } else if (!query && active !== "all" && active !== "saved") {
        items = items.filter(function(item) { return item.feedId === active; });
    }
    return items.filter(function(item) {
        return !query || (item.title + " " + item.summary + " " + item.feedTitle).toLowerCase().indexOf(query) >= 0;
    });
}

function unread(items, readIds) {
    return items.filter(function(item) { return readIds.indexOf(item.id) < 0; }).length;
}

function markItems(readIds, items, read) {
    var ids = items.map(function(item) { return item.id; });
    return read ? Array.from(new Set(readIds.concat(ids))) : readIds.filter(function(id) { return ids.indexOf(id) < 0; });
}

function savedAfterToggle(saved, item) {
    if (saved.some(function(story) { return story.id === item.id; }))
        return saved.filter(function(story) { return story.id !== item.id; });
    return saved.concat([Object.assign({}, item)]);
}

function normalizeState(state) {
    var feeds = (Array.isArray(state.feeds) ? state.feeds : []).slice(0, 100).filter(function(feed) {
        return feed && typeof feed.id === "string" && typeof feed.url === "string"
            && /^https:\/\//i.test(feed.url) && typeof feed.title === "string";
    }).map(function(feed) {
        return {
            id: feed.id.slice(0, 2048), url: feed.url.slice(0, 2048),
            title: feed.title.slice(0, 200), customTitle: feed.customTitle === true,
            folder: String(feed.folder || "").trim().slice(0, 100),
            lastUpdated: Number(feed.lastUpdated) > 0 ? Number(feed.lastUpdated) : 0,
            error: String(feed.error || "").slice(0, 500),
            items: cleanItems(Array.isArray(feed.items) ? feed.items.slice(0, 100) : [])
        };
    });
    var legacyIds = Array.isArray(state.savedIds) ? state.savedIds : [];
    var saved = unique(cleanItems(Array.isArray(state.savedArticles) ? state.savedArticles : [])
        .concat(allItems(feeds).filter(function(item) { return legacyIds.indexOf(item.id) >= 0; })));
    var prefs = state.preferences || {};
    var session = state.session || {};
    var active = typeof session.activeFeed === "string" ? session.activeFeed : "all";
    if (active !== "all" && active !== "saved"
        && !feeds.some(function(feed) { return feed.id === active; })
        && !(active.indexOf("folder:") === 0 && folderNames(feeds, state.folders).indexOf(active.substring(7)) >= 0))
        active = "all";
    return {
        schemaVersion: state.schemaVersion,
        feeds: feeds, savedArticles: saved,
        folders: folderNames(feeds, state.folders),
        collapsedFolders: (Array.isArray(state.collapsedFolders) ? state.collapsedFolders : [])
            .filter(function(name) { return folderNames(feeds, state.folders).indexOf(name) >= 0; }),
        readIds: (Array.isArray(state.readIds) ? state.readIds : []).filter(function(id) {
            return typeof id === "string" && id.length <= 2048;
        }),
        defaultFeedDisabled: state.defaultFeedDisabled === true,
        session: {
            activeFeed: active,
            searchText: typeof session.searchText === "string" ? session.searchText.slice(0, 500) : "",
            selectedId: typeof session.selectedId === "string" ? session.selectedId.slice(0, 2048) : "",
            articleOpen: session.articleOpen === true,
            storyScrollY: Math.max(0, Math.min(1000000, Number(session.storyScrollY) || 0)),
            articleScrollY: Math.max(0, Math.min(1000000, Number(session.articleScrollY) || 0))
        },
        preferences: {
            readerWidth: Math.max(680, Math.min(1320, Number(prefs.readerWidth) || 860)),
            refreshMinutes: [0, 15, 30, 60].indexOf(prefs.refreshMinutes) >= 0 ? prefs.refreshMinutes : 0,
            textScale: [0.9, 1, 1.15, 1.3, 1.5].indexOf(prefs.textScale) >= 0 ? prefs.textScale : 1,
            markDelay: [0, 2, 5, 10].indexOf(prefs.markDelay) >= 0 ? prefs.markDelay : 5,
            notifications: prefs.notifications === true,
            showImages: prefs.showImages !== false,
            showRead: prefs.showRead !== false
        }
    };
}

function folderNames(feeds, folders) {
    var names = (Array.isArray(folders) ? folders : []).slice(0, 100)
        .concat(feeds.map(function(feed) { return feed.folder; }));
    return names.filter(function(name) { return typeof name === "string" && name.trim(); })
        .map(function(name) { return name.trim().slice(0, 100); })
        .filter(function(name, index, all) { return all.indexOf(name) === index; });
}

function sidebar(feeds, folders, collapsedFolders) {
    var result = [];
    feeds.forEach(function(feed) {
        if (!feed.folder) result.push({kind: "feed", feed: feed});
    });
    folderNames(feeds, folders).forEach(function(folder) {
        result.push({kind: "folder", title: folder});
        if ((collapsedFolders || []).indexOf(folder) >= 0) return;
        feeds.filter(function(feed) { return feed.folder === folder; }).forEach(function(feed) {
            result.push({kind: "feed", feed: feed});
        });
    });
    return result;
}
