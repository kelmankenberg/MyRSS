# Changelog

## 0.1.10 - 2026-11-13

### Fixed

- Prevent Qt's automatic clipboard receive (which has no byte ceiling) from
  pulling a foreign Wayland clipboard offer while ReaderInput fields are
  focused. Fields are now read-only unless actively focused, closing the
  remaining availability vector reported by the marketplace review.

## 0.1.9 - 2026-11-12

### Added

- Add a persistent **Compact view** toggle in Settings → Reading. Compact
  story lists show only a one-line title and source/date metadata, without
  thumbnails or preview text. Opened articles retain their existing layout
  and image preference.
- Show the installed plugin version in Settings → Help beside the reporting
  link, using the manifest as the single source of version information.

### Changed

- Organize Settings into horizontal Reading, Updates, Subscriptions, and Help
  tabs with a fixed header, compact preference rows, and expandable
  subscription-management sections.
- Open the relevant subscription section from feed/folder context actions
  and show Help directly with the `?` shortcut.
- Move the global mark-all-read/unread action to the reading toolbar.
- Keep scroll-to-read calculations aligned with the shorter compact rows.

### Fixed

- Reject named pipes and other non-regular OPML inputs before reading. Apply a
  30-second import/export deadline, terminate stalled helpers, and restore the
  transfer controls when the helper exits or fails to start.
- Limit the current thumbnail cache to 100 MiB and 2,000 files, evicting
  least-recently-used images. Serialize eviction and atomic writes across
  helpers, reserve space for temporary writes, and clean interrupted writes.

## 0.1.8 - 2026-11-12

### Added

- GitHub issue forms for bug reports and feature requests, with privacy
  reminders and the option to submit a blank issue.
- A **Report bug / request feature** button in Settings that opens the form
  chooser in the browser without attaching reading data.
- Prominent README links to both reporting forms.

## 0.1.7 - 2026-11-10

### Added

- Resize the navigation panel by dragging its divider, from 140 to 240 pixels
  following Omarchy's spacing scale. The default remains 180 pixels, and the
  chosen width persists between sessions.
- Automatically mark articles as read after scrolling them completely above
  the list and pausing for one second. Partially visible articles stay unread;
  scrolling back before the pause prevents marking them. The visible position
  is preserved when read articles are hidden.

### Changed

- Remove borders from read articles while retaining accent borders on unread
  articles.
