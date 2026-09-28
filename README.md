# Audiobookshelf Bridge for KOReader

A KOReader plugin that browses an [Audiobookshelf](https://www.audiobookshelf.org/)
server and downloads ebooks straight to your e-reader.

A book you can find in Audiobookshelf, you can find and download on the reader —
and once it lands, its metadata matches what Audiobookshelf says.

Originally inspired by [naleo's Audiobookshelf plugin for KOReader](https://github.com/naleo/audiobookshelf.koplugin).

## Requirements

- KOReader (2025 or newer)
- An Audiobookshelf server the device can reach over the network, and an account on it

## Install

1. Download `audiobookshelfbridge.koplugin.zip` from the
   [latest release](https://github.com/theryanmc/audiobookshelfbridge/releases/latest).
2. Unzip it into KOReader's `plugins` directory. Common locations:

   | Platform | Path |
   |----------|------|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `koreader/plugins/` |
   | Linux | `~/.config/koreader/plugins/` |
   | Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |

3. Restart KOReader.

**Keep the folder name `audiobookshelfbridge.koplugin`.** KOReader only loads
plugin directories whose name ends in `.koplugin`; renaming it means the plugin
is silently ignored, with no error to tell you why.

## Sign in

The easiest way to connect is to sign in with the same username and password
you use on the Audiobookshelf web interface.

In Settings, set your **Server URL**, then choose **Sign in with username and
password** and enter your credentials. The plugin keeps a sign-in session and
renews it on its own — the password itself is never stored. If the server
ever ends the session, the plugin switches to your API token when one is
stored, and tells you once that it did; otherwise it sends you to Settings
so you can sign in again.

### Or use an API token

If your server is too old to issue sign-in sessions, or you'd rather not
type your password, an API token works the same way it always has.

The plugin authenticates as your Audiobookshelf user, so it needs that user's
API token.

In the Audiobookshelf web interface, open **Settings → Users** and select your
user — the API token is shown on that page. Newer server versions manage these
under **Settings → API Keys** instead.

Treat the token like a password: it grants access to your library. A stored
token is not used while you are signed in, but it takes over automatically if your sign-in expires.

## Configure

Open **Tools → Audiobookshelf Bridge**, then tap the **Settings** gear in the
top right.

![The plugin's settings screen](docs/screenshots/settings.png)

| Setting | What it does |
|---------|--------------|
| **Server URL** | Your Audiobookshelf address, including the scheme — `https://books.example.com`. Must start with `http://` or `https://`. |
| **Sign in with username and password** | Signs you in. Once signed in, this row shows `Signed in as …` — choose it again to sign in as someone else. |
| **Sign out** | Only shown while signed in. Removes the session from this device and, when the reader is connected, asks the server to end it too. |
| **API token** | The alternative to signing in. Shows `configured` once set, never the value. |
| **Download folder** | Where downloaded ebooks are saved. |
| **Libraries** | Hide libraries you don't want in the browser. |
| **Book view** | `cover tiles` or `list`. |
| **Test connection** | Checks the URL together with your sign-in or token, and reports which one it used, or which one failed. |
| **Recent errors** | Failures recorded this session — the first place to look when something doesn't work. |

Set the server URL, then sign in (or add a token), then use **Test
connection** to confirm before browsing.

### Configuring from a file instead

Settings live in `audiobookshelfbridge_config.lua` inside the plugin folder. To
pre-seed a device, copy `audiobookshelfbridge_config.example.lua` to that name
and fill it in:

```lua
return {
    ["token"] = 'your api key here',
    ["server"] = 'https://books.example.com'
}
```

That server + token file keeps working unchanged. Signing in from Settings
instead writes `auth`, `access_token`, `refresh_token`, `session_host`, and
`username` into this same file — none of them need to be present up front.
The plugin also writes `download_dir` and `disabled_libraries` as you change
them.

This file holds your API token or sign-in session in plain text. It is
already listed in `.gitignore` and excluded from release archives — keep it
out of anything you publish or share.

## Using it

**Tools → Audiobookshelf Bridge** opens the browser directly.

![The browser showing the library list](docs/screenshots/browser.png)

Pick a library, and its books appear as cover tiles. Tap one for its details,
then choose a file to download.

### Browse books, series, and authors

Use **Books | Series | Authors** below the header to browse the library.
The filled dot marks the active tab.

- **Books** shows ebook covers and titles. Switch to a text list with
  **Settings → Book view** if you prefer.
- **Series** lists series with ebooks in this library, with ebook counts on
  the right. Tap a series to open its books.
- **Authors** lists authors with ebooks in this library, also with ebook counts
  on the right. Tap an author to see their books, as shown for Lewis Carroll
  below.

When you open a series or author, the location below the header identifies the
group you are viewing. Tap **✕** to return to the originating tab.
Each tab remembers its page while the library is open. The first visit to Series
or Authors loads their metadata in batches; subsequent tab switches use the
cached results until you reopen the library.

| Books: cover tiles | Series: names and ebook counts |
|:------------------:|:-----------------------------:|
| <img src="docs/screenshots/books.png" alt="Books tab showing ebook cover tiles and titles on page 37 of 37" width="360"> | <img src="docs/screenshots/series.png" alt="Series tab showing series names and ebook counts on page 3 of 4" width="360"> |

| Authors: names and ebook counts | Books by a selected author |
|:------------------------------:|:--------------------------:|
| <img src="docs/screenshots/authors.png" alt="Authors tab showing author names and ebook counts on page 6 of 8" width="360"> | <img src="docs/screenshots/author-books.png" alt="Author: Lewis Carroll view showing the cover of Alice's Adventures in Wonderland" width="360"> |

### Navigation and search

If only one library is enabled, the browser opens it directly. The X button
then closes the plugin from that library's book list.

| Control | Action |
|---------|--------|
| **Search** (magnifying glass, top right) | Search this library |
| **Settings** (gear, top right) | Open Settings |
| **✕** (top right) | Back one level; closes the plugin at the top level |
| **‹ / ›** (single arrows, bottom) | Previous / next page |
| **« / »** (double arrows, bottom) | First / last page |
| Multi-swipe | Closes the browser from any depth |

The page indicator shows your position in the current list. Arrows are grayed
out when there is no page to move to in that direction.

The header keeps the plugin name on the left, with the current location below it.
Search is scoped to the library you are in and only appears once you have opened
one. Results list matching authors and series alongside
books.

## Notes

- **Covers are cached to disk.** The first view of a page fetches them and shows
  a loading notice; later visits draw from the cache. A cover that fails to
  download is refetched next time rather than cached as broken.
- **Downloads and cover fetches block the UI.** KOReader is single-threaded and
  the Audiobookshelf API is called synchronously, so the reader is unresponsive
  while a page of covers or a book is transferring.
- **Wi-Fi failures are expected.** When something fails, check
  **Settings → Recent errors** for what the server actually said.

## Security notes

Things worth knowing before you point this at a server you care about.

- **Your API token and sign-in session are stored in plain text** in
  `audiobookshelfbridge_config.lua` inside the plugin folder, with ordinary
  file permissions. On a single-user e-reader that is fine. On a shared
  computer, anyone with access to your files can read it.
- **Your password is never stored** or logged, on this device or anywhere
  else. It is sent once, at sign-in, and lives only for the moment that
  request is in flight.
- **Use `https://`.** Over `http://` your password is sent unencrypted at
  sign-in, and your token or session on every request after that. The plugin
  warns in the sign-in dialog, and once when you save an `http://` server
  address.
- **A session is only ever sent to the server host that issued it.**
  Switching between `http://` and `https://`, or changing the port or path,
  keeps you signed in. Pointing Server URL at a different hostname signs you
  out, so your session is never sent to another server.
- **Sign out removes the session from this device immediately.** If the
  reader is connected, it also asks the server to end that session. If it is
  offline, or the server can't be reached, the server's own copy simply
  expires on its own (30 days by default). Sign out never turns Wi-Fi on by
  itself.
- **KOReader does not verify TLS certificates.** Its bundled HTTPS library
  ships with verification turned off, and this plugin inherits that. `https://`
  still protects you from passive eavesdropping, but not from an attacker who
  can sit between the device and your server. This is a KOReader platform
  limitation; the plugin cannot fix it on its own.
- **Redirects are refused.** The plugin never follows an HTTP redirect, so a
  captive-portal Wi-Fi network that redirects every request to its sign-in
  page cannot be handed your password, token, or session. If you see "the
  server redirected the request", sign in to the network first or check the
  URL.
- **Passwords and tokens never appear in logs or on screen.** The password
  field is masked; the settings screen shows `configured` or `Signed in
  as …`, never a value; and the Recent errors list is built to never contain
  a password, token, header, or response body.

## Development and releases

The root contains KOReader's entry points (`main.lua` and `_meta.lua`), the
version file, and the example configuration. Runtime modules live in
`audiobookshelfbridge/`; screenshots live in `docs/screenshots/`.

Run `python3 scripts/package_release.py` to build
`dist/audiobookshelfbridge.koplugin.zip`. The script packages only explicitly
listed files and checks that internal imports are included. When adding a
runtime module, also add it to the script's file list.

`audiobookshelfbridge_version.lua` is the release version's single source of
truth. To release, update it and `CHANGELOG.md`, then push to `main`. CI builds
the archive and publishes the matching `vMAJOR.MINOR.PATCH` tag. If that tag
already exists, CI validates the package without publishing another release.

## License

MIT — see [LICENSE](LICENSE).
