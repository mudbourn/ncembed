import os
import io
import html
import mimetypes
import random
import struct
import time
import threading
from urllib.parse import quote as url_quote
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
_raw_titles       = os.environ.get("EMBED_TITLES", os.environ.get("EMBED_TITLE", ""))
EMBED_TITLES      = [t.strip() for t in _raw_titles.split("|") if t.strip()]
EMBED_AUTHOR_URL  = os.environ.get("EMBED_AUTHOR_URL",  NEXTCLOUD_URL)
EMBED_AUTHOR_ICON = os.environ.get("EMBED_AUTHOR_ICON", "")
EMBED_COLOR       = os.environ.get("EMBED_COLOR",       "#C2185B")

# ── Umami analytics (optional) ───────────────────────────────────────────────
EMBED_UMAMI_SCRIPT_URL = os.environ.get("EMBED_UMAMI_SCRIPT_URL", "")
EMBED_UMAMI_WEBSITE_ID = os.environ.get("EMBED_UMAMI_WEBSITE_ID", "")
EMBED_UMAMI_HOST_URL   = os.environ.get("EMBED_UMAMI_HOST_URL", "")

# Pipe-separated thumbnails and their paired hex colors.
# Example: EMBED_THUMBNAILS=https://example.com/a.jpg|https://example.com/b.jpg
# Example: EMBED_THUMBNAIL_COLORS=#ff0000|#00ff00
# If colors are fewer than thumbnails, EMBED_COLOR is used as fallback.
_raw_thumbnails   = os.environ.get("EMBED_THUMBNAILS", os.environ.get("EMBED_THUMBNAIL", ""))
EMBED_THUMBNAILS  = [t.strip() for t in _raw_thumbnails.split("|") if t.strip()]
_raw_thumb_colors = os.environ.get("EMBED_THUMBNAIL_COLORS", "")
EMBED_THUMBNAIL_COLORS = [c.strip() for c in _raw_thumb_colors.split("|") if c.strip()]

# ── Share info cache ─────────────────────────────────────────────────────────
_CACHE_TTL = 3600  # seconds — file metadata never changes
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
    cached = _cache_get(token)
    if cached is not None:
        return cached

    webdav_url = f"{NEXTCLOUD_URL}/public.php/webdav/"
    propfind_body = """<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:displayname/>
    <d:getcontenttype/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>"""
    try:
        r = requests.request(
            "PROPFIND",
            webdav_url,
            data=propfind_body,
            auth=(token, ""),
            headers={"Depth": "0", "Content-Type": "application/xml"},
            timeout=5,
        )
        if r.status_code not in (200, 207):
            return None  # don't cache failures
        root = ET.fromstring(r.text)
        ns = {"d": "DAV:"}
        name = root.findtext(".//d:displayname", namespaces=ns) or ""
        mimetype = root.findtext(".//d:getcontenttype", namespaces=ns) or ""
        is_folder = root.find(".//d:resourcetype/d:collection", ns) is not None
        result = {"name": name, "mimetype": mimetype, "is_folder": is_folder}
        _cache_set(token, result)
        return result
    except Exception:
        pass
    return None

def get_folder_contents(token):
    """List the media files inside a shared folder via WebDAV PROPFIND Depth:1."""
    cached = _cache_get(f"folder:{token}")
    if cached is not None:
        return cached

    webdav_url = f"{NEXTCLOUD_URL}/public.php/webdav/"
    propfind_body = """<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:displayname/>
    <d:getcontenttype/>
    <d:resourcetype/>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>"""
    try:
        r = requests.request(
            "PROPFIND",
            webdav_url,
            data=propfind_body,
            auth=(token, ""),
            headers={"Depth": "1", "Content-Type": "application/xml"},
            timeout=10,
        )
        if r.status_code not in (200, 207):
            return []  # don't cache failures
        root = ET.fromstring(r.text)
        ns = {"d": "DAV:"}
        items = []
        for resp in root.findall("d:response", ns):
            href = resp.findtext("d:href", namespaces=ns) or ""
            name = resp.findtext(".//d:displayname", namespaces=ns) or ""
            mimetype = resp.findtext(".//d:getcontenttype", namespaces=ns) or ""
            is_col = resp.find(".//d:resourcetype/d:collection", ns) is not None
            size = resp.findtext(".//d:getcontentlength", namespaces=ns) or "0"
            if is_col:
                continue  # skip subdirectories
            if is_video(mimetype, name) or is_image(mimetype, name):
                items.append({
                    "name": name,
                    "mimetype": mimetype,
                    "is_video": is_video(mimetype, name),
                    "size": int(size),
                })
        _cache_set(f"folder:{token}", items)
        return items
    except Exception:
        pass
    return []


def get_image_dimensions(url):
    try:
        r = requests.get(url, stream=True, timeout=10)
        chunk = b""
        for data in r.iter_content(chunk_size=1024):
            chunk += data
            if len(chunk) >= 65536:
                break
        r.close()
        buf = io.BytesIO(chunk)

        if chunk[:8] == b'\x89PNG\r\n\x1a\n':
            w, h = struct.unpack('>II', chunk[16:24])
            return w, h

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

        if chunk[:6] in (b'GIF87a', b'GIF89a'):
            w, h = struct.unpack('<HH', chunk[6:10])
            return w, h

    except Exception:
        pass
    return None, None


def get_direct_url(token):
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

def pick_theme():
    """Pick a random index and return (title, thumbnail_url, color) together."""
    count = max(len(EMBED_TITLES), len(EMBED_THUMBNAILS))
    if count == 0:
        return "", "", EMBED_COLOR
    idx = random.randrange(count)
    title = EMBED_TITLES[idx] if idx < len(EMBED_TITLES) else ""
    url = EMBED_THUMBNAILS[idx] if idx < len(EMBED_THUMBNAILS) else ""
    color = EMBED_THUMBNAIL_COLORS[idx] if idx < len(EMBED_THUMBNAIL_COLORS) else EMBED_COLOR
    return title, url, color

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
  <meta name="theme-color" content="{color}">
  {umami_script}
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
        "<h2>ncembed</h2>"
        "<p>Usage:</p>"
        "<ul>"
        "<li><code>/s/&lt;token&gt;</code> — embed a file or folder (folders show as slideshow)</li>"
        "<li><code>/f/&lt;token&gt;</code> — folder slideshow (alias)</li>"
        "</ul>",
        mimetype="text/html"
    )

@app.route("/health")
def health():
    return Response("ok", status=200, mimetype="text/plain")

@app.route("/s/<token>/prefetch")
def prefetch(token):
    """Pre-populate the share info cache so the first real embed load is instant."""
    get_share_info(token)
    return Response("", status=204)

@app.route("/s/<token>")
def embed(token):
    info = get_share_info(token)
    # If this token points to a folder, serve the slideshow instead
    if info and info.get("is_folder"):
        return folder_embed(token)
    # Fallback: if PROPFIND Depth:0 failed, try the folder listing directly
    if info is None:
        folder_items = get_folder_contents(token)
        if folder_items:
            return folder_embed(token)
    mimetype = info["mimetype"] if info else ""
    filename = info["name"] if info else ""
    direct_url = get_direct_url(token)

    # Pick random theme (title, thumbnail, color) together
    chosen, thumbnail_url, color = pick_theme()
    title = html.escape(chosen).replace("&#x27;", "'") if chosen else html.escape(filename or f"Shared file ({token})").replace("&#x27;", "'")
    description = html.escape(filename or token).replace("&#x27;", "'")
    site_name = EMBED_SITE_NAME

    # Umami analytics snippet (optional)
    if EMBED_UMAMI_SCRIPT_URL and EMBED_UMAMI_WEBSITE_ID and EMBED_UMAMI_HOST_URL:
        umami_script = f'<!-- Umami analytics -->\n  <script defer src="{EMBED_UMAMI_SCRIPT_URL}" data-website-id="{EMBED_UMAMI_WEBSITE_ID}" data-host-url="{EMBED_UMAMI_HOST_URL}"></script>'
    else:
        umami_script = ""

    if is_video(mimetype, filename):
        # Use thumbnail as og:image so it fills the embed aspect ratio
        og_thumbnail = f'<meta property="og:image" content="{thumbnail_url}">' if thumbnail_url else ""
        og_media = f"""
  <meta property="og:type" content="video.other">
  <meta property="og:video:url" content="{direct_url}">
  <meta property="og:video:secure_url" content="{direct_url}">
  <meta property="og:video:type" content="video/mp4">
  <meta property="og:video:width" content="1280">
  <meta property="og:video:height" content="720">
  {og_thumbnail}"""
        twitter_card = "player"
        body_media = f'<video controls autoplay style="max-width:100%;max-height:100vh" src="{direct_url}"></video>'

    elif is_image(mimetype, filename):
        preview_url = f"{NEXTCLOUD_URL}/s/{token}/preview"
        og_media = f"""
  <meta property="og:type" content="website">
  <meta property="og:image" content="{preview_url}">"""
        twitter_card = "summary_large_image"
        body_media = f'<img style="max-width:100%;max-height:100vh" src="{direct_url}">'

    else:
        og_media = f'<meta property="og:type" content="website">'
        if thumbnail_url:
            og_media += f'\n  <meta property="og:image" content="{thumbnail_url}">'
        twitter_card = "summary"
        body_media = f'<p style="color:#fff;font-family:sans-serif">Download: <a href="{direct_url}" style="color:#6cf">{filename or token}</a></p>'

    html_out = HTML_TEMPLATE.format(
        site_name=site_name,
        title=title,
        description=description,
        author_url=EMBED_AUTHOR_URL,
        color=color,
        og_media=og_media,
        twitter_card=twitter_card,
        direct_url=direct_url,
        body_media=body_media,
        umami_script=umami_script,
    )
    return Response(html_out, mimetype="text/html")

# ── Folder slideshow ────────────────────────────────────────────────────────

FOLDER_SLIDESHOW_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>{title}</title>
  <meta property="og:site_name" content="{site_name}">
  <meta property="og:title" content="{title}">
  <meta property="og:url" content="{author_url}">
  <meta property="og:description" content="{description}">
  {og_media}
  <meta name="theme-color" content="{color}">
  {umami_script}
  <meta name="twitter:card" content="{twitter_card}">
  <meta name="twitter:title" content="{title}">
  <meta name="twitter:player" content="{first_url}">
  <style>
    * {{ margin:0; padding:0; box-sizing:border-box; }}
    body {{ background:#000; height:100vh; overflow:hidden; }}
    .slideshow {{ position:relative; width:100vw; height:100vh; }}
    .slideshow img,
    .slideshow video {{
      position:absolute; top:0; left:0;
      width:100%; height:100%;
      object-fit:contain;
      opacity:0;
      transition: opacity {fade_ms}ms ease-in-out;
    }}
    .slideshow img.active,
    .slideshow video.active {{ opacity:1; }}
  </style>
</head>
<body>
  <div class="slideshow" id="slideshow">
    {media_tags}
  </div>
  <script>
    (function() {{
      var items = document.querySelectorAll('.slideshow img, .slideshow video');
      if (!items.length) return;
      var idx = 0;
      var fadeMs = {fade_ms};
      var imageDuration = {image_duration_ms};

      function show(i) {{
        items.forEach(function(el) {{ el.classList.remove('active'); }});
        items[i].classList.add('active');
      }}

      function next() {{
        // pause any video that was playing
        var prev = items[idx];
        if (prev.tagName === 'VIDEO') {{ prev.pause(); prev.currentTime = 0; }}
        idx = (idx + 1) % items.length;
        show(idx);
        scheduleNext();
      }}

      function scheduleNext() {{
        var cur = items[idx];
        if (cur.tagName === 'VIDEO') {{
          cur.play();
          cur.onended = next;
        }} else {{
          setTimeout(next, imageDuration);
        }}
      }}

      show(0);
      scheduleNext();
    }})();
  </script>
</body>
</html>"""


@app.route("/f/<token>")
def folder_embed(token):
    items = get_folder_contents(token)
    if not items:
        return Response(
            "<h2>Empty or inaccessible folder</h2>",
            mimetype="text/html",
            status=404,
        )

    # Build per-item direct URLs and tags
    media_tags = []
    first_url = ""
    first_preview_url = ""
    for i, item in enumerate(items):
        fname_encoded = url_quote(item["name"])
        item_url = f"{NEXTCLOUD_URL}/public.php/webdav/{fname_encoded}"
        if i == 0:
            first_url = item_url
            if item["is_video"]:
                first_preview_url = EMBED_THUMBNAILS[0] if EMBED_THUMBNAILS else ""
            else:
                first_preview_url = f"{NEXTCLOUD_URL}/index.php/s/{token}/preview?file=/{fname_encoded}"
        if item["is_video"]:
            tag = f'<video src="{item_url}" preload="metadata" muted></video>'
        else:
            tag = f'<img src="{item_url}" alt="{html.escape(item["name"])}">'
        media_tags.append(tag)

    chosen, thumbnail_url, color = pick_theme()
    title = html.escape(chosen) if chosen else f"Shared folder ({token})"
    description = f"{len(items)} items"
    site_name = EMBED_SITE_NAME

    if EMBED_UMAMI_SCRIPT_URL and EMBED_UMAMI_WEBSITE_ID and EMBED_UMAMI_HOST_URL:
        umami_script = f'<!-- Umami analytics -->\n  <script defer src="{EMBED_UMAMI_SCRIPT_URL}" data-website-id="{EMBED_UMAMI_WEBSITE_ID}" data-host-url="{EMBED_UMAMI_HOST_URL}"></script>'
    else:
        umami_script = ""

    # OG tags — use the first item so embeds show something meaningful
    og_image = first_preview_url or (thumbnail_url if thumbnail_url else "")
    og_media = '<meta property="og:type" content="website">'
    if og_image:
        og_media += f'\n  <meta property="og:image" content="{og_image}">'
    twitter_card = "summary_large_image"

    html_out = FOLDER_SLIDESHOW_TEMPLATE.format(
        site_name=site_name,
        title=title,
        description=description,
        author_url=EMBED_AUTHOR_URL,
        color=color,
        og_media=og_media,
        twitter_card=twitter_card,
        first_url=first_url,
        umami_script=umami_script,
        media_tags="\n    ".join(media_tags),
        fade_ms=1500,
        image_duration_ms=5000,
    )
    return Response(html_out, mimetype="text/html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
