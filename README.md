# ncembed

A tiny proxy that turns Nextcloud share links into embeddable video/image links for Discord, WhatsApp, etc.

## How it works

Nextcloud's share pages don't include Open Graph video tags, so Discord can't embed your videos inline.
This service sits in front of Nextcloud: you give it a share token, it serves an HTML page with the
right `og:video` tags pointing at Nextcloud's direct download URL. Discord scrapes that page and
embeds the video just like YouTube.

## Setup

### ncembed proxy

1. Edit `docker-compose.yml` and set `NEXTCLOUD_URL` to your Nextcloud instance URL (no trailing slash).

2. Build and run:
   ```bash
   docker compose up -d --build
   ```

3. If you want it on a real domain (recommended so Discord trusts it), put it behind your reverse proxy
   (nginx/Caddy/Traefik) on a subdomain like `embed.yournextcloud.com`.

### Clip Watcher

A native macOS menu bar app that watches for new screen recordings and clips, uploads them to
Nextcloud, and copies an embeddable share link to your clipboard — all automatically.

**Zero dependencies.** Pure Swift using Cocoa and Foundation. No Python, no shell scripts, no Homebrew.

```
 ┌─────────────────────────────┐
 │  ▶ Clip                     │  ← menu bar icon
 ├─────────────────────────────┤
 │  Status: Watching           │
 │                             │
 │  Copy Last Link       ⌘C   │
 │  Tail Log             ⌘L   │
 │  Clear Log                  │
 │                             │
 │  Restart              ⌘R   │
 │  Quit                 ⌘Q   │
 └─────────────────────────────┘
```

#### Quick start

```bash
# One-time setup (interactive prompts for Nextcloud credentials, paths, etc.)
swift ClipWatcher.swift setup

# Launch — appears in your menu bar immediately
swift ClipWatcher.swift
```

Or use the `clip` wrapper:
```bash
clip setup    # first-time config
clip          # start (menu bar + watcher)
clip stop     # stop
clip status   # show status + recent uploads
clip last     # copy last share URL to clipboard
clip log      # tail the live log
```

#### What it does

1. Watches `~/Movies/Captures` (configurable) for new video/image files
2. Waits for the file to finish writing (stable size checks)
3. Copies to Nextcloud via Samba (fast local) or WebDAV (fallback)
4. Triggers a Nextcloud file scan so it's indexed immediately
5. Creates a public share link
6. Builds an ncembed URL and copies it to your clipboard
7. Shows a macOS notification — paste into Discord and it just works

#### Features

- **Native menu bar app** — lives in your menu bar, no terminal window needed
- **Auto-sort** — videos and images go to separate subfolders
- **Samba + WebDAV** — uses fast local Samba when available, falls back to WebDAV
- **SSH file scan** — forces Nextcloud to index Samba-copied files instantly
- **ncembed prewarming** — pre-caches the embed page so Discord gets OG tags instantly
- **Log rotation** — auto-rotates at 5 MB, keeps one backup; clear from the menu
- **Debounced scanning** — efficient file system monitoring via GCD
- **Skip existing** — only processes files added after launch
- **Skip temp files** — ignores hidden files, `encoded_*`, `remux_*`, exiftool temps

#### Menu bar

| Icon | Meaning |
|------|---------|
| ▶ Clip | Watcher is running |
| ⏹ Clip | Watcher is stopped |

Click the icon for:
- **Copy Last Link** — copies the most recent ncembed URL to clipboard
- **Tail Log** — opens the log file in your default editor
- **Clear Log** — truncates the log (old log rotated to `.log.1` automatically at 5 MB)
- **Restart** — restarts the watcher
- **Quit** — stops everything and removes the menu bar icon

#### Configuration

Run `clip setup` or edit `~/.config/clip-watcher/config.json`:

```json
{
  "watchDir": "~/Movies/Captures",
  "nextcloudURL": "https://cloud.example.com",
  "nextcloudUser": "username",
  "nextcloudPass": "app-password",
  "uploadPath": "/Videos/clips",
  "ncembedDomain": "embed.example.com",
  "useNcembed": true,
  "sambaShares": [
    {
      "mountPath": "/Volumes/Share/nextcloud",
      "nextcloudPath": "/ExternalStorage"
    }
  ],
  "sshScan": {
    "host": "user@server",
    "container": "nextcloud",
    "scanPath": "/username/files/ExternalStorage"
  }
}
```

#### Samba shares

Format: `mountPath:nextcloudPath`
- `mountPath` — local mount point (e.g. `/Volumes/SSD/nextcloud`)
- `nextcloudPath` — path as seen inside Nextcloud (e.g. `/ExternalSSD`)

#### SSH file scan

Nextcloud doesn't detect files copied directly to external storage via Samba.
The SSH scan feature forces a reindex after each copy:

1. File copied via Samba (fast, local network)
2. SSH into server → `docker exec -u www-data nextcloud php occ files:scan --path=... -q`
3. Nextcloud indexes the file → share link works immediately

Requirements: SSH key auth (no password prompts), Docker access on server, `occ` available in container.

#### Supported formats

| Type | Extensions |
|------|-----------|
| Video | mp4, mkv, mov, avi, webm |
| Image | png, jpg, jpeg, gif, webp, bmp, tiff |

#### Deprecated files

`clip-watcher-menu.py` and the shell-based `clip` wrapper are deprecated in favor of the native
Swift app. They remain in the repo for reference but are no longer maintained.

## Notes

- Your Nextcloud share must be public (no password) for Discord embedding
- Use a Nextcloud app password (Settings → Security → App passwords)
- Config is stored at `~/.config/clip-watcher/config.json` (not in repo)
