# Changelog

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
