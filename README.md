# ncembed

A proxy that turns Nextcloud share links into embeddable video/image links for Discord, WhatsApp, iMessage, etc.

## How it works

Nextcloud's share pages don't include Open Graph video tags, so Discord can't embed videos inline.
This service sits alongside Nextcloud: you give it a share token, and it will serve an HTML page with the
right `og:video` or `og:image` tags pointing at Nextcloud's direct file URL. Discord will then scrape that
page and embed the media inline.

## Setup

### Option A: Coolify (recommended)

1. Push this repo to a private GitHub/GitLab repository.
2. In Coolify, add a new resource pointing at the repo.
3. Set your environment variables in Coolify's UI (see below).
4. Assign a subdomain (e.g. `share.yournextcloud.com`). Coolify handles SSL and Traefik automatically.
5. Deploy.

### Option B: Standalone Docker Compose

1. Edit `docker-compose.yml` and fill in your environment variables.
2. Build and run:
   ```bash
   docker compose up -d --build
   ```
3. Put it behind your reverse proxy on a public subdomain with HTTPS. Discord won't scrape plain HTTP or localhost.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `NEXTCLOUD_URL` | Yes | Your Nextcloud URL, no trailing slash. e.g. `https://cloud.example.com` |
| `EMBED_SITE_NAME` | No | Site name shown in the embed. Default: `My Nextcloud` |
| `EMBED_TITLE` | No | Pipe-separated list of titles. one is picked randomly per request. Leave blank to use the filename. e.g. `look mom! no subscription!\|shared from the cloud` |
| `EMBED_AUTHOR_URL` | No | URL the site name links to. Defaults to `NEXTCLOUD_URL` |
| `EMBED_AUTHOR_ICON` | No | URL to a small icon shown next to the site name |
| `EMBED_THUMBNAIL` | No | URL to a thumbnail shown beside the embed (videos only) |
| `EMBED_COLOR` | No | Hex accent colour for the embed bar. Default: `#C2185B` |

## Usage

1. In Nextcloud, create a public share link for a file. You'll get a URL like:
   ```
   https://save.yournextcloud.com/s/ABC123xyz
   ```

2. To embed it, just swap the subdomain. the token stays the same:
   ```
   https://share.yournextcloud.com/s/ABC123xyz
   ```

3. Paste the ncembed URL in Discord, WhatsApp, iMessage, or whatever other service. It will embed and play inline.

## Health check

The service exposes a health endpoint at `/health` that returns `ok` with a 200 status.
Docker will check this automatically via the `HEALTHCHECK` in the Dockerfile.
You can also point Coolify's health check at `https://your-ncembed-domain.com/health`.

## Notes

- Works for videos (mp4, webm, mov etc.) and images (png, jpg, gif etc.).
- Videos must be h264-encoded mp4 for Discord to play them inline. Other codecs may show as a download link.
- The file is streamed directly from your Nextcloud. ncembed only serves the HTML wrapper and never stores any file data.
- Shares must be public with no password. Discord's scraper can't authenticate.
- GIFs are supported as images but Discord will show them as a still frame, not animated. This is a Discord limitation.
- For large videos, make sure your Nextcloud allows HTTP range requests (it does by default).
