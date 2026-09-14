# Changelog

## 0.1.0

First release under the Audiobookshelf Bridge name.

### Browsing

- Book lists render as a grid of cover tiles instead of text rows. Applies to
  any level containing books, including search results, where authors and
  series appear as labelled text tiles.
- Covers are cached to disk, so a page is fetched once and redrawn locally
  afterwards. Bad entries are dropped and refetched rather than persisting.
- A loading notice appears while uncached covers are fetched, and stays silent
  when the page is already cached.
- `Settings -> Book view` switches between cover tiles and the list.

### Navigation

- The Tools entry opens the browser directly; the intermediate two-row menu is
  gone.
- Search and Settings live behind the title-bar menu icon. Search appears only
  inside a library, which is the only place it can be scoped to.
- The Tools menu entry is named "Audiobookshelf Bridge" and sits near the top
  of the section rather than at the end.

### Fixes

- A search matching nothing reports "no results" instead of opening an empty
  screen.
- The release archive now unpacks to `audiobookshelfbridge.koplugin/`. It
  previously used the repository name, which KOReader does not load.
