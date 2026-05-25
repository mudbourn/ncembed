import os
import io
import html
import mimetypes
import random
import struct
import time
import threading
import requests
import xml.etree.ElementTree as ET
from flask import Flask, Response, request

app = Flask(__name__)

# ── Nextcloud ────────────────────────────────────────────────────────────────
NEXTCLOUD_URL   = os.environ.get("NEXTCLOUD_URL",    "https://your.nextcloud.example.com")

# ── Embed branding (set these in Coolify) ────────────────────────────────────
EMBED_SITE_NAME   = os.environ.get("EMBED_SITE_NAME",   "My Nextcloud")
# Pipe-separated list of titles — one is picked randomly per request.
# Example: "look mom! no subscription!|shared from the cloud|enjoy"
_raw_titles       = os.environ.get("EMBED_TITLE", "")
EMBED_TITLES      = [t.strip() for t in _raw_titles.split("|") if t.strip()]
EMBED_AUTHOR_URL  = os.environ.get("EMBED_AUTHOR_URL",  NEXTCLOUD_URL)
EMBED_AUTHOR_ICON = os.environ.get("EMBED_AUTHOR_ICON", "")
EMBED_THUMBNAIL   = os.environ.get("EMBED_THUMBNAIL",   "")
EMBED_COLOR       = os.environ.get("EMBED_COLOR",       "#C2185B")

# ── Share info cache ─────────────────────────────────────────────────────────
# Caches WebDAV PROPFIND results in memory to avoid round-tripping Nextcloud
# on every request (Discord scrapes the same URL multiple times).
_CACHE_TTL = 300  # seconds — re-fetch after 5 minutes
_cache: dict = {}
_cache_lock = threading.Lock()

def _cache_get(token):
    with _cache_lock:
        entry = _cache.get(token)
        if entry and time.monotonic() - entry["ts"] < _CACHE_TTL:
            return entry["data"]
    return None

def _cache_set(token, data):
    with _cache_lock:
        _cache[token] = {"data": data, "ts": time.monotonic()}

def get_share_info(token):
    """Fetch share metadata via Nextcloud's public WebDAV endpoint (no auth needed)."""
    cached = _cache_get(token)
    if cached is not None:
        return cached

    webdav_url = f"{NEXTCLOUD_URL}/public.php/webdav/"
    propfind_body = """<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:displayname/>
    <d:getcontenttype/>
  </d:prop>
</d:propfind>"""
    try:
        r = requests.request(
            "PROPFIND",
            webdav_url,
            data=propfind_body,
            auth=(token, ""),
            headers={"Depth": "0", "Content-Type": "application/xml"},
            timeout=10,
        )
        if r.status_code not in (200, 207):
            return None
        root = ET.fromstring(r.text)
        ns = {"d": "DAV:"}
        name = root.findtext(".//d:displayname", namespaces=ns) or ""
        mimetype = root.findtext(".//d:getcontenttype", namespaces=ns) or ""
        result = {"name": name, "mimetype": mimetype}
        _cache_set(token, result)
        return result
    except Exception:
        pass
    return None

def get_image_dimensions(url):
    """Try to read image dimensions by fetching just enough bytes."""
    try:
        r = requests.get(url, stream=True, timeout=10)
        # Read up to 64KB — enough for most image headers
        chunk = b""
        for data in r.iter_content(chunk_size=1024):
            chunk += data
            if len(chunk) >= 65536:
                break
        r.close()
        buf = io.BytesIO(chunk)

        # PNG: 8 byte sig + IHDR chunk with width/height at bytes 16-24
        if chunk[:8] == b'\x89PNG\r\n\x1a\n':
            w, h = struct.unpack('>II', chunk[16:24])
            return w, h

        # JPEG: scan for SOF marker
        if chunk[:2] == b'\xff\xd8':
            i = 2
            while i < len(chunk) - 8:
                if chunk[i] != 0xff:
                    break
                marker = chunk[i+1]
                if marker in (0xC0, 0xC1, 0xC2):
                    h, w = struct.unpack('>HH', chunk[i+5:i+9])
                    return w, h
                seg_len = struct.unpack('>H', chunk[i+2:i+4])[0]
                i += 2 + seg_len

        # GIF: width/height at bytes 6-10
        if chunk[:6] in (b'GIF87a', b'GIF89a'):
            w, h = struct.unpack('<HH', chunk[6:10])
            return w, h

    except Exception:
        pass
    return None, None


def get_direct_url(token):
    """Build the direct download URL for a Nextcloud share token."""
    return f"{NEXTCLOUD_URL}/s/{token}/download"

def is_video(mimetype, filename):
    if mimetype and mimetype.startswith("video/"):
        return True
    if filename:
        guessed, _ = mimetypes.guess_type(filename)
        if guessed and guessed.startswith("video/"):
            return True
    return False

def is_image(mimetype, filename):
    if mimetype and mimetype.startswith("image/"):
        return True
    if filename:
        guessed, _ = mimetypes.guess_type(filename)
        if guessed and guessed.startswith("image/"):
            return True
    return False

HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>{title}</title>
  <meta property="og:site_name" content="{site_name}">
  <meta property="og:title" content="{title}">
  <meta property="og:url" content="{author_url}">
  <meta property="og:description" content="{description}">
  {og_media}
  {og_thumbnail}
  <meta name="theme-color" content="{color}">
  <!-- Twitter/X card -->
  <meta name="twitter:card" content="{twitter_card}">
  <meta name="twitter:title" content="{title}">
  <meta name="twitter:player" content="{direct_url}">
</head>
<body style="margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh">
  {body_media}
</body>
</html>"""

@app.route("/")
def index():
    return Response(
        "<h2>ncembed</h2><p>Usage: <code>/s/&lt;nextcloud-share-token&gt;</code></p>",
        mimetype="text/html"
    )

@app.route("/health")
def health():
    return Response("ok", status=200, mimetype="text/plain")

@app.route("/s/<token>")
def embed(token):
    info = get_share_info(token)
    mimetype = info["mimetype"] if info else ""
    filename = info["name"] if info else ""
    direct_url = get_direct_url(token)
    page_url = request.url

    chosen = html.escape(random.choice(EMBED_TITLES), quote=False).replace("&#x27;", "'") if EMBED_TITLES else ""
    title = chosen or html.escape(filename or f"Shared file ({token})", quote=False).replace("&#x27;", "'")
    description = html.escape(filename or token, quote=False).replace("&#x27;", "'")
    site_name = html.escape(EMBED_SITE_NAME, quote=False).replace("&#x27;", "'")

    og_thumbnail = f'<meta property="og:image" content="{EMBED_THUMBNAIL}">' if EMBED_THUMBNAIL else ""

    if is_video(mimetype, filename):
        og_media = f"""
  <meta property="og:type" content="video.other">
  <meta property="og:video:url" content="{direct_url}">
  <meta property="og:video:secure_url" content="{direct_url}">
  <meta property="og:video:type" content="video/mp4">
  <meta property="og:video:width" content="1280">
  <meta property="og:video:height" content="720">"""
        twitter_card = "player"
        body_media = f'<video controls autoplay style="max-width:100%;max-height:100vh" src="{direct_url}"></video>'

    elif is_image(mimetype, filename):
        preview_url = f"{NEXTCLOUD_URL}/s/{token}/preview"
        og_media = f"""
  <meta property="og:type" content="website">
  <meta property="og:image" content="{preview_url}">"""
        og_thumbnail = ""  # image IS the embed, don't also show thumbnail
        twitter_card = "summary_large_image"
        body_media = f'<img style="max-width:100%;max-height:100vh" src="{direct_url}">'

    else:
        og_media = '<meta property="og:type" content="website">'
        twitter_card = "summary"
        body_media = f'<p style="color:#fff;font-family:sans-serif">Download: <a href="{direct_url}" style="color:#6cf">{filename or token}</a></p>'

    html_out = HTML_TEMPLATE.format(
        site_name=site_name,
        title=title,
        description=description,
        author_url=EMBED_AUTHOR_URL,
        color=EMBED_COLOR,
        og_media=og_media,
        og_thumbnail=og_thumbnail,
        twitter_card=twitter_card,
        direct_url=direct_url,
        body_media=body_media,
        page_url=page_url,
    )
    return Response(html_out, mimetype="text/html")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
