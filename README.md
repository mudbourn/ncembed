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

**No external dependencies required** — uses native macOS APIs (FSEvents, URLSession, NSPasteboard).

#### Quick Start

```bash
# Start the watcher (runs in background)
clip

# Or start with menu bar app
clip menu
```

#### Commands

```bash
clip              # Start watching (background)
clip stop         # Stop the watcher
clip status       # Show status and recent uploads
clip last         # Copy last share URL to clipboard
clip clear        # Clear processed log (re-queue all clips)
clip log          # Tail the live log
clip menu         # Open menu bar app
```

#### Configuration

Edit `ClipWatcher.swift` to configure:

```swift
struct Config {
    // Directories
    static let watchDir = "~/Movies/Captures/optimised"
    static let uploadPath = "/Videos/clips"
    
    // Nextcloud
    static let nextcloudURL = "https://save.mudbourn.info"
    static let ncembedDomain = "share.mudbourn.info"
    
    // Samba shares (for faster local network transfers)
    static let sambaShares = [
        "/Volumes/UGREENNVME-Share/nextcloud",
        "/Volumes/ToshibaHD-Share/nextcloud"
    ]
    
    // Link behavior
    static let useNcembed = true  // false = raw Nextcloud share links
}
```

Set Nextcloud credentials via environment variables:
```bash
export NC_USER="your-username"
export NC_PASS="your-app-password"
```

#### Menu Bar App

The menu bar app shows:
- **▶ Clip Watcher** — watcher is running
- **⏹ Clip Watcher** — watcher is stopped

Features:
- Start/Stop watcher with one click
- View status and recent uploads
- Copy last link to clipboard
- Tail logs in TextEdit
- Clear processed log

#### How it works

1. **FSEvents** monitors `WATCH_DIR` for new video/image files
2. When a file stabilizes (no size changes for 6s), uploads to Nextcloud:
   - **Samba share** (preferred): Direct local network copy
   - **WebDAV fallback**: Upload via Nextcloud API
3. Creates a public share link via Nextcloud's OCS API
4. Converts to ncembed URL (`share.yourdomain.com/embed/TOKEN`)
5. Copies to clipboard with notification

#### Supported Formats

**Videos:** mp4, mkv, mov, avi, webm
**Images:** png, jpg, jpeg, gif, webp, bmp, tiff

#### Performance Optimizations

- **Concurrent processing**: Multiple files processed simultaneously
- **FSEvents**: Native macOS file watching (no polling)
- **Async/await**: Non-blocking network operations
- **Memory efficient**: Streams large files instead of loading into memory
- **Hardware acceleration**: Uses macOS native APIs

## Notes

- Works for videos (mp4, webm, mov, etc.) and images.
- The video is streamed directly from your Nextcloud — ncembed just serves the HTML wrapper.
- Your Nextcloud share must be public (no password) for this to work, since Discord's
  bot can't authenticate.
- If your videos are large, make sure your Nextcloud's nginx/Apache allows range requests
  (it does by default).
- For clip-watcher: use a Nextcloud app password (Settings → Security → App passwords), not your main password.
