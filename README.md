# Matter Plugin for KOReader

Download and read articles from your [Matter](https://web.getmatter.com) reading library directly in KOReader.

> Forked in 2025 from [omer-faruq/instapaper.koplugin](https://github.com/omer-faruq/instapaper.koplugin) and rewritten against the [Matter Public API](https://docs.getmatter.com/api).

## Features

- **Bearer token authentication** using a personal access token from Matter
- Browse **Inbox**, **Queue**, **Favorites**, **Archive**, and items by **tag**
- **Search** across your library
- **Download and read** articles as HTML or EPUB in KOReader's reader
- **Markdown → HTML conversion** with footnotes, lists, code blocks, links, and inline emphasis
- **EPUB output** with optional image embedding
- **Download only** (long-press → Download) so you can queue several articles without leaving the list
- **Article metadata** on long-press: author, site, word count, reading time, progress, source URL
- **Manage articles**: Archive, Favorite/Unfavorite, Mark read, Delete
- **Bulk download** with source filter, period filter, and post-download action
- **Auto WiFi connect** — triggers network connection automatically when needed
- **Reading-progress display** in the article list
- **Reading-progress sync** — pulls Matter progress forward on open, with manual pull/push actions and optional auto-push on close
- **Save URL to Matter** — Add web links to Matter directly from document link popups
- **Offline queue** — Links are queued when offline and automatically sent when network becomes available
- **Open downloads folder** shortcut in the menu
- **Clear downloads cache** — delete all downloaded files with a single tap

## Installation

1. Copy the `matter.koplugin` folder to your KOReader plugins directory:
   - For most devices: `koreader/plugins/matter.koplugin/`

2. Restart KOReader.

## Setup

### 1. Get a Matter API token

Matter API access requires a Matter Pro subscription.

1. Visit <https://web.getmatter.com/settings>
2. Click **Generate API Token**
3. Copy the token (it starts with `mat_`). Treat it like a password.

### 2. Configure the plugin

1. Open KOReader → main menu → **Tools** → **Matter**.
2. Select **Set API token**.
3. Paste the token and tap **Save**.

The plugin will verify the token by calling `/me`. On success, your account email is stored alongside the token in `settings/matter.lua`.

## Usage

### Browse

From the Matter menu:

- **Inbox** — Items in your Matter inbox (`status = inbox`)
- **Queue** — Items you've added to your reading queue
- **Favorites** — Anything you've favorited (★)
- **Archive** — Completed/archived items
- **Tags** — Lists every tag in your library; tap a tag to browse items with that tag
- **Search…** — Full-text search across your library (Matter operators are supported: `"exact phrase"`, `-excluded`, `by:author`, `site:domain`, `title:word`)

### Read an article

- **Tap** an article to download and open it in KOReader.
- Articles are saved to `koreader/matter/` as HTML or EPUB depending on your settings.
- Newly-saved articles take a few seconds for Matter to process. If you tap an article that isn't ready yet, you'll see a message — try again in a moment.
- When a Matter article opens, the plugin checks Matter's `reading_progress` and jumps forward only if Matter is ahead of KOReader. It never jumps backward.

### Reading progress

From the Matter menu while a Matter article is open:

- **Pull reading progress now** — Move KOReader to Matter's current `reading_progress`.
- **Push reading progress now** — Send KOReader's current position to Matter, unless Matter is already further ahead.

If **Auto-push progress on close** is enabled, closing a Matter article sends KOReader's final position to Matter. Failed or offline pushes are queued and retried later. Pushes are guarded against downgrades, so a stale local position should not overwrite a newer Matter position.

### Long-press an article

Shows author, site, word count, reading time, progress, and URL, plus these actions:

- **Download** — Save locally without opening (useful for downloading several articles in a row)
- **Open** — Download and open immediately
- **Archive** — Move to Archive (`PATCH status=archive`)
- **Favorite / Unfavorite** — Toggle `is_favorite`
- **Mark read** — Set `reading_progress = 1.0`
- **Delete** — Permanently delete from Matter (also removes annotations and tags)

> Matter's `inbox` status is one-way: items can be moved from `inbox` to `queue` or `archive`, but cannot be moved back to `inbox`.

### Bulk download

Select **Bulk download…** from the menu:

- **Source** — Inbox, Queue, Favorites, or Archive
- **Period** — Limit to items updated within the last N days (0 = all)
- **Archive after** — Automatically archive each item after download
- **Delete after** — Automatically delete each item after download (mutually exclusive with Archive)

Bulk download is throttled (~3 seconds between articles) to stay under Matter's content-extraction rate limit (20 requests/min). Plan accordingly — a 100-article bulk run takes ~5 minutes.

### Save URLs from documents

When reading a document that contains web links:

1. Tap a link in the document.
2. In the link popup, select **Save to Matter**.
3. The URL is sent to Matter:
   - Online → sent immediately
   - Offline with **Auto connect** ON → network opens and URL is sent
   - Offline with **Auto connect** OFF → added to the pending pool

Queued URLs are sent automatically when network becomes available, or on demand via **Process pending URLs (N)** in the menu.

### Settings

- **Article list limit** — 25, 50, or 100 (Matter's API caps at 100)
- **Output format** — HTML or EPUB
- **Include images (EPUB)** — Download and embed images when EPUB is selected
- **After download** — None / Archive / Mark read / Archive + Mark read
- **Auto connect network** — Whether saving a URL while offline should bring the network up
- **Auto-push progress on close** — Send KOReader's final reading position to Matter when closing a Matter article
- **Cache folder** — Custom download directory

## Implementation notes

### API

Matter's public API:

- `GET /me` — verify token, get account info
- `GET /items` — list items, filter by `status` / `is_favorite` / `tag` / `updated_since`
- `GET /items/{id}?include=markdown` — fetch an item with its parsed markdown body
- `POST /items` — save a new URL (`{url, status}`)
- `PATCH /items/{id}` — update `status`, `is_favorite`, or `reading_progress`
- `DELETE /items/{id}` — permanently remove an item
- `GET /tags` — list tags
- `GET /search?query=…&type=items` — full-text search

### Rate limits

- 120 reads/min, 30 writes/min, 10 saves/min, **20 markdown extractions/min**, 5 requests/sec burst.
- Saves can take 20–60 seconds to finish processing before content is available.

### Markdown rendering

`matter_markdown.lua` is a small, pragmatic Markdown → HTML converter calibrated for Matter's extractor output. It handles ATX headings, paragraphs, fenced/indented code, blockquotes, nested ordered/unordered lists, horizontal rules, bold/italic/strikethrough, inline code, links, images, autolinks, and **GFM-style footnotes** (`[^id]` references with `[^id]:` definitions, rendered as a numbered footnote section with backreferences).

For EPUB output, `matter_epub.lua` further balances the HTML through crengine (when available), rewrites image references, optionally downloads and embeds images, and packages everything as a standards-compliant EPUB 2.

## Troubleshooting

### "Please set your Matter API token first"
Generate one at <https://web.getmatter.com/settings> and paste it via **Set API token**.

### "Token rejected (401)"
The token is invalid or revoked. Generating a new token in Matter automatically revokes the previous one. Generate a fresh token and paste it again.

### "This token is valid but Matter Pro is required for API access"
The API requires Matter Pro. Upgrade at <https://web.getmatter.com/settings>.

### "Article is still being processed"
Matter does content extraction asynchronously. Wait 20–60 seconds and try again.

## Credits

This plugin began as a fork of [`omer-faruq/instapaper.koplugin`](https://github.com/omer-faruq/instapaper.koplugin) in 2025. The Instapaper-specific code — OAuth 1.0a signing, xAuth login, the Instapaper API client — has been removed. The Matter API client, the Markdown → HTML converter (`matter_markdown.lua`), and the changes to support Matter's data model are new.

Inherited and adapted from the upstream plugin:

- Plugin scaffolding and KOReader integration (menus, settings, dispatcher actions)
- EPUB packager (`matter_epub.lua`), adapted from `instapaper_epub.lua`
- Offline pending-URL queue pattern
- Link-popup "Save to …" integration
- The `_meta.lua` / file layout conventions

Many thanks to [omer-faruq](https://github.com/omer-faruq) and the contributors of the original Instapaper plugin for the foundation. This project inherits its GPL-3.0 license.

## License

GNU General Public License v3.0 (GPL-3.0). See the [LICENSE](LICENSE) file.
