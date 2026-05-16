# ncembed

A tiny proxy that turns Nextcloud share links into embeddable video/image links for Discord, WhatsApp, etc.

## How it works

Nextcloud's share pages don't include Open Graph video tags, so Discord can't embed your videos inline.
This service sits in front of Nextcloud: you give it a share token, it serves an HTML page with the
right `og:video` tags pointing at Nextcloud's direct download URL. Discord scrapes that page and
embeds the video just like YouTube.

## Setup

1. Edit `docker-compose.yml` and set `NEXTCLOUD_URL` to your Nextcloud instance URL (no trailing slash).

2. Build and run:
   ```bash
   docker compose up -d --build
   ```

3. If you want it on a real domain (recommended so Discord trusts it), put it behind your reverse proxy
   (nginx/Caddy/Traefik) on a subdomain like `embed.yournextcloud.com`.

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
