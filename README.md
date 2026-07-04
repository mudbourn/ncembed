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

### clip-watcher (optional)

`clip-watcher.sh` monitors a folder for new video clips, uploads them to your Nextcloud, creates a public share link, converts it to an ncembed URL, and copies it to your clipboard.

Works with any video recorder (OBS, ShadowPlay, ReLive, Xbox Game Bar, etc.)

#### Dependencies

```bash
brew install fswatch jq
```

#### Configuration

Edit the top of `clip-watcher.sh`:

```bash
WATCH_DIR="/path/to/your/recordings"     # Folder to monitor
NC_UPLOAD_PATH="/Videos/clips"           # Remote folder in Nextcloud
NCEMBED_DOMAIN="share.yournextcloud.com" # Your ncembed domain

# Samba shares (optional — much faster for local network)
SAMBA_SHARES=(
    "/Volumes/UGREENNVME-Share/nextcloud"
    "/Volumes/ToshibaHD-Share/nextcloud"
)
```

Set Nextcloud credentials via environment variables:

```bash
export NC_USER="your-username"
export NC_PASS="your-app-password"  # Use an app password, not your main password
```

Or edit `NEXTCLOUD_USER` and `NEXTCLOUD_PASS` directly in the script.

#### Samba Shares (Optional)

If you have Samba shares mounted that map to your Nextcloud data directory, the script will automatically use them for faster local network transfers instead of WebDAV uploads.

Common mount paths:
- `/Volumes/UGREENNVME-Share/nextcloud`
- `/Volumes/ToshibaHD-Share/nextcloud`

The script checks if these directories exist and uses the first available one. If no Samba shares are found, it falls back to WebDAV upload.

#### Usage

```bash
clip              # Start watching
clip --debug      # Start with verbose logging
clip stop         # Stop the watcher
clip status       # Show watcher status, recent uploads
clip last         # Copy last share URL to clipboard
clip retry        # Re-process the last clip
clip retry FILE   # Re-process a specific file
clip clear        # Clear processed log (re-queue all clips)
clip log          # Tail the live log
```

#### How it works

1. `fswatch` monitors `WATCH_DIR` for new `.mp4`, `.mkv`, `.mov`, `.avi`, `.webm` files
2. When a file stabilizes (no size changes for 6 seconds), it copies/uploads to Nextcloud:
   - **Samba share** (preferred): Direct local network copy to mounted share — much faster for large files
   - **WebDAV fallback**: Upload via Nextcloud API if no Samba shares are available
3. Creates a public share link via Nextcloud's OCS API
4. Converts the share token to an ncembed URL (`share.yourdomain.com/embed/TOKEN`)
5. Copies the ncembed URL to your clipboard with a notification

## Usage

1. In Nextcloud, create a public share link for a video. You'll get a URL like:
   ```
   https://your.nextcloud.example.com/s/ABC123xyz
   ```

2. The token is the `ABC123xyz` part. Paste this into ncembed:
   ```
   https://embed.yournextcloud.com/embed/ABC123xyz
   ```

3. Share that ncembed URL in Discord. It will embed and play inline.

## Notes

- Works for videos (mp4, webm, mov, etc.) and images.
- The video is streamed directly from your Nextcloud — ncembed just serves the HTML wrapper.
- Your Nextcloud share must be public (no password) for this to work, since Discord's
  bot can't authenticate.
- If your videos are large, make sure your Nextcloud's nginx/Apache allows range requests
  (it does by default).
- For clip-watcher: use a Nextcloud app password (Settings → Security → App passwords), not your main password.
