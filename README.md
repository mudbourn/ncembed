# ncembed

A proxy that turns Nextcloud share links into embeddable video/image links for Discord, WhatsApp, iMessage, etc.

## How it works

Nextcloud's share pages don't include Open Graph video tags, so Discord can't embed videos inline.
This service sits alongside Nextcloud: you give it a share token, and it will serve an HTML page with the
right `og:video` or `og:image` tags pointing at Nextcloud's direct file URL. Discord will then scrape that
page and embed the media inline.

## Setup

<<<<<<< HEAD
### ncembed proxy

1. Edit `docker-compose.yml` and set `NEXTCLOUD_URL` to your Nextcloud instance URL (no trailing slash).
=======
### Option A: Coolify (recommended)
>>>>>>> 5c7e5a377b5349aec95c796e7eaf98cbe2832662

1. Push this repo to a private GitHub/GitLab repository.
2. In Coolify, add a new resource pointing at the repo.
3. Set your environment variables in Coolify's UI (see below).
4. Assign a subdomain (e.g. `share.yournextcloud.com`). Coolify handles SSL and Traefik automatically.
5. Deploy.

### Option B: Standalone Docker Compose

1. Edit `docker-compose.yml` and fill in your environment variables.
2. Build and run:

```
docker compose up -d --build
```

3. Put it behind your reverse proxy on a public subdomain with HTTPS. Discord won't scrape plain HTTP or localhost.

## Environment variables

| Variable                  | Required | Description                                                                                                                                                   |
| ------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NEXTCLOUD_URL`           | Yes      | Your Nextcloud URL, no trailing slash. e.g. `https://cloud.example.com`                                                                                       |
| `EMBED_SITE_NAME`         | No       | Site name shown in the embed. Default: `My Nextcloud`                                                                                                         |
| `EMBED_TITLES`            | No       | Pipe-separated list of titles — one is picked randomly per request, paired with its thumbnail and color. Leave blank to use the filename.                      |
| `EMBED_THUMBNAILS`        | No       | Pipe-separated list of thumbnail URLs — one is picked per request, paired with its title and color by index.                                                   |
| `EMBED_THUMBNAIL_COLORS`  | No       | Pipe-separated list of hex colors, one per thumbnail. Falls back to `EMBED_COLOR` if fewer colors than thumbnails.                                            |
| `EMBED_COLOR`             | No       | Fallback hex accent color for the embed bar. Default: `#C2185B`                                                                                               |
| `EMBED_AUTHOR_URL`        | No       | URL the site name links to. Defaults to `NEXTCLOUD_URL`                                                                                                       |
| `EMBED_AUTHOR_ICON`       | No       | URL to a small icon shown next to the site name                                                                                                               |
| `EMBED_UMAMI_SCRIPT_URL`  | No       | URL to your Umami tracking script. All three Umami vars must be set to enable analytics.                                                                      |
| `EMBED_UMAMI_WEBSITE_ID`  | No       | Your Umami website ID.                                                                                                                                        |
| `EMBED_UMAMI_HOST_URL`    | No       | Your Umami host URL.                                                                                                                                          |

Titles, thumbnails, and colors are matched by position — index 0 of each list goes together, index 1 goes together, and so on. Make sure all three lists have the same number of entries.

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
USE_NCEMBED=true                         # false = use raw Nextcloud share links

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
clip              # Start watching (runs in background)
clip --debug      # Start with verbose logging
clip --no-ncembed # Start with raw Nextcloud share links (no ncembed)
clip stop         # Stop the watcher
clip status       # Show watcher status, recent uploads
clip last         # Copy last share URL to clipboard
clip retry        # Re-process the last clip
clip retry FILE   # Re-process a specific file
clip clear        # Clear processed log (re-queue all clips)
clip log          # Tail the live log
```

#### Menu Bar App (Optional)

A macOS menu bar app is included for easy control:

```bash
./clip-menu       # Launch the menu bar app
```

**Features:**
- ▶ = watcher running, ⏹ = watcher stopped
- "Clip Watcher" name in menu bar
- Start/Stop watcher with one click
- View status, copy last link, tail logs
- Runs in background (no dock icon)

**Dependencies:** `rumps` (Python library)
```bash
pip3 install rumps
```

#### How it works

1. `fswatch` monitors `WATCH_DIR` for new video and image files (mp4, mkv, mov, avi, webm, png, jpg, gif, etc.)
2. When a file stabilizes (no size changes for 6 seconds), it copies/uploads to Nextcloud:
   - **Samba share** (preferred): Direct local network copy to mounted share — much faster for large files
   - **WebDAV fallback**: Upload via Nextcloud API if no Samba shares are available
3. Creates a public share link via Nextcloud's OCS API
4. Converts the share token to an ncembed URL (`share.yourdomain.com/embed/TOKEN`)
5. Copies the ncembed URL to your clipboard with a notification

## Usage

1. In Nextcloud, create a public share link for a file. You'll get a URL like:

```
https://save.yournextcloud.com/s/ABC123xyz
```

2. To embed it, swap the subdomain — the token stays the same:

```
https://share.yournextcloud.com/s/ABC123xyz
```

3. Paste the ncembed URL in Discord, WhatsApp, iMessage, etc. It will embed and play inline.

## Using Nextcloud-hosted images as thumbnails

Nextcloud share URLs serve an HTML page, not a raw image. To use a Nextcloud-hosted image as a thumbnail, use the direct download URL instead:

```
https://save.yournextcloud.com/s/YOUR_TOKEN/download
```

This serves the raw file and works exactly like a direct image link.

## Encoding your videos for Discord

Discord has strict requirements for inline video playback. Videos that don't meet these will show as a link or embed without playing.

### Requirements

- **Codec:** H.264 (libx264), Main profile, Level 4.0
- **Pixel format:** yuv420p
- **Audio:** AAC
- **Faststart:** moov atom must be at the beginning of the file
- **File size:** under 24MB — Discord will not play videos larger than this inline, even if the codec is correct

### ffmpeg command

```bash
ffmpeg -i /path/to/input.mp4 -c:v libx264 -profile:v main -level 4.0 -pix_fmt yuv420p -movflags faststart -crf 22 -r 60 -c:a aac -b:a 160k /path/to/output.mp4
```

Adjust `-crf` to trade off quality vs file size — lower is higher quality and larger (18 is near-lossless, 22 is a good balance, 28 is smaller but noticeably compressed). If your output is still over 24MB, increase the crf value or trim the clip.

### Fixing the unsupported 'chnl' box error

Some screen recorders (including Dropshare on passthrough and OBS with certain settings) produce files with an Apple-specific audio metadata box that ffmpeg can't parse. Fix it by converting with avconvert first:

```bash
avconvert --source /path/to/input.mp4 --output /path/to/output.m4v --preset PresetHEVCHighestQuality
```

Then run ffmpeg on the `.m4v` output.

### Automated clip workflow (macOS)

For a fully automated clip-to-Discord workflow on macOS using OBS Replay Buffer, [Clop](https://lowtechguys.com/clop/), and Dropshare:

1. Set OBS to record in HEVC and save replays to `~/Movies`
2. Configure Clop to watch `~/Movies`, optimise new videos, and output to `~/Movies/optimised`
3. Run the included `clip-watcher.sh` script — it watches `~/Movies/optimised`, remuxes each clip with faststart, encodes anything over 24MB, uploads via the Dropshare CLI, and copies the ncembed share link to your clipboard
4. A macOS notification fires when the link is ready

Install dependencies first:

```bash
brew install fswatch ffmpeg
```

Then install the Dropshare CLI via **Dropshare → Preferences → General → Install CLI**.

Lastly install and activate/purchase your license for Clop Pro. 

Note:
**Clop is "freemium", meaning the developers let you use it once or twice then tell you to pay them**.

## Health check

The service exposes a health endpoint at `/health` that returns `ok` with a 200 status.
Docker will check this automatically via the `HEALTHCHECK` in the Dockerfile.
You can also point Coolify's health check at `https://your-ncembed-domain.com/health`.

## Notes

<<<<<<< HEAD
- Works for videos (mp4, webm, mov, etc.) and images.
- The video is streamed directly from your Nextcloud — ncembed just serves the HTML wrapper.
- Your Nextcloud share must be public (no password) for this to work, since Discord's
  bot can't authenticate.
- If your videos are large, make sure your Nextcloud's nginx/Apache allows range requests
  (it does by default).
- For clip-watcher: use a Nextcloud app password (Settings → Security → App passwords), not your main password.
=======
- Works for videos (mp4, webm, mov etc.) and images (png, jpg, gif etc.).
- Videos must be H.264-encoded MP4 for Discord to play them inline. Other codecs may show as a download link.
- The file is streamed directly from your Nextcloud — ncembed only serves the HTML wrapper and never stores any file data.
- Shares must be public with no password. Discord's scraper can't authenticate.
- GIFs are supported as images but Discord will show them as a still frame, not animated. This is a Discord limitation.
- For large videos, make sure your Nextcloud allows HTTP range requests (it does by default).
- Analytics tracking via Umami only fires on real browser visits — Discord's scraper doesn't execute JavaScript.
>>>>>>> 5c7e5a377b5349aec95c796e7eaf98cbe2832662
