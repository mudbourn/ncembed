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

A unified macOS menu bar app and file watcher. Monitors a folder for new video/image files, uploads them to Nextcloud, and creates share links.

**No external dependencies** — native macOS Swift app.

#### Quick Start

```bash
# First time setup
clip setup

# Start (menu bar + watcher)
clip

# Or explicitly
clip start
```

#### Commands

```bash
clip setup        # First-time configuration
clip start        # Start menu bar app + watcher
clip stop         # Stop everything
clip status       # Show status and recent uploads
clip last         # Copy last share URL to clipboard
clip clear        # Clear processed log
clip log          # Tail the live log
```

#### Menu Bar

The app runs in your menu bar:
- **▶ Clip** — watcher is running
- **⏹ Clip** — watcher is stopped

Click to see menu:
- Copy Last Link
- Tail Log
- Restart
- Quit

#### Features

- **Unified service** — menu bar app + file watcher in one process
- **Auto-sort** — videos and images saved to separate folders
- **Samba support** — fast local network copies when available
- **ncembed links** — generates embeddable share links for Discord
- **Debounced scanning** — efficient file system monitoring
- **Skip existing** — only processes files added after launch
- **Skip temp files** — ignores hidden/temporary files

#### Configuration

Run `clip setup` or edit `~/.config/clip-watcher/config.json`:

```json
{
  "watchDir": "~/Movies/Captures",
  "nextcloudURL": "https://cloud.example.com",
  "nextcloudUser": "username",
  "nextcloudPass": "app-password",
  "uploadPath": "",
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

#### Samba Shares

Format: `mountPath:nextcloudPath`
- `mountPath` — local mount path
- `nextcloudPath` — path as seen in Nextcloud

Example: `/Volumes/SSD/nextcloud:/ExternalSSD`

#### SSH File Scan

Nextcloud doesn't automatically detect files copied directly to external storage via Samba. The SSH scan feature forces Nextcloud to reindex files after they're copied.

**How it works:**
1. Copy file via Samba (fast local network)
2. SSH into your server
3. Run `docker exec -u www-data nextcloud php occ files:scan --path=/path/to/folder -q`
4. Nextcloud indexes the new file
5. Create share link

**Configuration:**
- `host` — SSH connection (e.g., `user@192.168.1.100`)
- `container` — Docker container name (e.g., `nextcloud`)
- `scanPath` — Path to scan (e.g., `/mudbourn/files/ExternalSSD`)

**Requirements:**
- SSH key authentication (no password prompts)
- Docker access on the server
- `occ` command available in the container

#### Supported Formats

**Videos:** mp4, mkv, mov, avi, webm
**Images:** png, jpg, jpeg, gif, webp, bmp, tiff

## Notes

- Your Nextcloud share must be public (no password) for Discord embedding
- Use a Nextcloud app password (Settings → Security → App passwords)
- Config is stored at `~/.config/clip-watcher/config.json` (not in repo)
