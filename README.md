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

### Clip Watcher (Native Swift)

A native macOS menu bar app that watches for new video/image files and uploads them to Nextcloud with share links.

**No external dependencies required** — uses native macOS APIs.

#### Quick Start

```bash
# First time setup (creates config file)
clip setup

# Start the watcher
clip start

# Or open menu bar app
clip menu
```

#### Setup

Run `clip setup` to create your configuration file. You'll be prompted for:

- **Watch directory** — folder to monitor for new files
- **Nextcloud URL** — your Nextcloud instance (e.g., `https://cloud.example.com`)
- **Nextcloud credentials** — username and app password
- **Upload path** — remote folder in Nextcloud
- **ncembed domain** — your ncembed proxy domain (optional)
- **Samba shares** — local network mounts for faster transfers (optional)

Configuration is saved to `~/.config/clip-watcher/config.json` (not in repo).

#### Commands

```bash
clip setup        # First-time configuration
clip start        # Start watching (background)
clip stop         # Stop watcher and menu bar app
clip status       # Show status and recent uploads
clip last         # Copy last share URL to clipboard
clip clear        # Clear processed log (re-queue all clips)
clip log          # Tail the live log
clip menu         # Open menu bar app
```

#### Menu Bar App

The menu bar app shows:
- **▶ Clip** — watcher is running
- **⏹ Clip** — watcher is stopped

Features:
- Start/Stop watcher with one click
- Copy last link to clipboard
- Tail logs in TextEdit
- Quit menu bar app

#### How it works

1. **kqueue** monitors watch directory for new video/image files
2. When a file stabilizes (no size changes for 6s), uploads to Nextcloud:
   - **Samba share** (preferred): Direct local network copy
   - **WebDAV fallback**: Upload via Nextcloud API
3. Creates a public share link via Nextcloud's OCS API
4. Converts to ncembed URL or raw Nextcloud share link
5. Copies to clipboard with notification

#### Supported Formats

**Videos:** mp4, mkv, mov, avi, webm
**Images:** png, jpg, jpeg, gif, webp, bmp, tiff

#### Performance Optimizations

- Serial processing (one file at a time)
- Debounced file system events (1.5s)
- kqueue-based file watching (native macOS)
- Async/await for network operations
- Actor-based Nextcloud client

## Notes

- Works for videos (mp4, webm, mov, etc.) and images.
- The video is streamed directly from your Nextcloud — ncembed just serves the HTML wrapper.
- Your Nextcloud share must be public (no password) for this to work, since Discord's
  bot can't authenticate.
- If your videos are large, make sure your Nextcloud's nginx/Apache allows range requests
  (it does by default).
- Use a Nextcloud app password (Settings → Security → App passwords), not your main password.
