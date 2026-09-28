# Changelog

## 0.5.0

- Sign in with your Audiobookshelf username and password from Settings instead
  of typing an API token. The password is never stored; the plugin keeps a
  session that renews itself and lasts as long as you use it at least once
  every 30 days (the server's default). Sign out ends the session on the server
  too when Wi-Fi is connected.
- Sessions are tied to the server's host name: switching between http and
  https or changing the port keeps you signed in, a different host signs you
  out. Plain http still works, with a warning that the password is sent
  unencrypted once at sign-in.
- If a sign-in expires and an API token is saved, the plugin switches to the
  token and tells you once. Test connection now says whether it used your
  sign-in or your API token.
- API tokens keep working as before, and existing configuration files need no
  changes.
- Download failures now name the real cause (connection, redirect, server,
  incomplete transfer, or disk), and the "Downloading" message stays up for the
  whole transfer.
- A trailing slash in the server URL no longer breaks requests; existing
  settings are fixed automatically.
- Missing covers no longer appear in Recent errors, network failures are
  reported as connection problems, and unexpected server data is skipped
  instead of crashing.
- Book details share the cover cache, which now keeps the most recently used
  covers.
- Releases are only built when the test suite passes.

## 0.4.0

- Keep the browser usable when a book's details fail to load; the error message
  is shown without leaving an invisible screen that blocked every tap and key.
- Enforce total time limits on library, search, item and cover requests, so
  slow Wi-Fi can no longer stall the reader indefinitely. Ebook downloads keep
  no total limit and still stop if the connection goes silent.
- Load each cover tile once and move D-pad focus by changing only its border,
  so browsing no longer re-reads covers or makes requests on every key press.
- Remember covers the server reports as missing for the rest of the session,
  instead of re-requesting them and showing "Loading covers" on every visit.
  Network errors are still retried.

## 0.3.0

- Added Books, Series, and Authors tabs to the library browser, with ebook
  counts for authors and series.
- Remember each tab's page and restore it when returning from a book list or
  search results; switching tabs does not add back-navigation steps.
- Load author and series metadata in batches on first use and cache it for
  the library session, supporting Audiobookshelf's condensed listing responses.
- Keep the current tab available for retrying when metadata loading fails.

## 0.2.0

- Shortened runtime module filenames and updated all internal imports.
- Removed unused imports and dispatcher scaffolding from the plugin entry point.
- Package releases from an explicit file list, checking that internal imports
  are included and keeping local configuration and development files out.
- Use the Lua version file as the single source for release tags; existing
  versions are validated without publishing another release.
- Documented the project layout and local packaging and release process.

## 0.1.6

- Credit naleo's Audiobookshelf plugin for KOReader as the original inspiration
  in the README.

## 0.1.5

- Replaced the hamburger menu with a Storefront-style header showing the
  plugin name, current location, and direct Settings and X buttons.
- Added a dedicated Search button that only appears inside a library.
- Automatically open the book list when exactly one library is enabled.
  X exits from that list; deeper screens still go back one level.
- Keep the library picker available if loading the single library fails.

## 0.1.4

Security hardening following a full audit.

- A fresh install no longer crashes KOReader on the first tap. With no server
  or token configured, the browser now opens Settings and says what to fill in.
- HTTP redirects are refused instead of followed, so the API token can no
  longer be handed to a captive-portal Wi-Fi sign-in page or any other host.
- The token entry field is masked and no longer pre-filled with the stored
  value; an empty save keeps the existing token.
- Saving an `http://` server address warns once that the token travels
  unencrypted.
- Server-issued ids are percent-encoded before use in request paths.
- Library and series listings are fetched in pages of 100 instead of one
  request for the whole library.
- Fixed a crash when drawing a page of covers that were not yet cached.

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
