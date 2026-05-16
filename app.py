import os
import mimetypes
import requests
from flask import Flask, Response, abort, request
from urllib.parse import urljoin

app = Flask(__name__)

NEXTCLOUD_URL = os.environ.get("NEXTCLOUD_URL", "https://your.nextcloud.example.com")

def get_share_info(token):
    """Fetch share metadata from Nextcloud's OCS API."""
    api_url = f"{NEXTCLOUD_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares/{token}"
    try:
        r = requests.get(api_url, headers={"OCS-APIRequest": "true"}, timeout=10)
        r.raise_for_status()
        data = r.json()
        ocs = data.get("ocs", {})
        if ocs.get("meta", {}).get("statuscode") == 200:
            share = ocs["data"]
            return {
                "name": share.get("item_source_name") or share.get("file_target", "").lstrip("/"),
                "mimetype": share.get("mimetype", ""),
            }
    except Exception:
        pass
    return None

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
  <meta property="og:site_name" content="Nextcloud">
  <meta property="og:title" content="{title}">
  <meta property="og:url" content="{page_url}">
  <meta property="og:description" content="{description}">
  {og_media}
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
        "<h2>ncembed</h2><p>Usage: <code>/embed/&lt;nextcloud-share-token&gt;</code></p>",
        mimetype="text/html"
    )

@app.route("/embed/<token>")
def embed(token):
    info = get_share_info(token)
    mimetype = info["mimetype"] if info else ""
    filename = info["name"] if info else ""
    direct_url = get_direct_url(token)
    page_url = request.url
    title = filename or f"Shared file ({token})"

    if is_video(mimetype, filename):
        og_media = f"""
  <meta property="og:type" content="video.other">
  <meta property="og:video:url" content="{direct_url}">
  <meta property="og:video:secure_url" content="{direct_url}">
  <meta property="og:video:type" content="video/mp4">
  <meta property="og:video:width" content="1280">
  <meta property="og:video:height" content="720">"""
        twitter_card = "player"
        description = "Click to play video"
        body_media = f'<video controls autoplay style="max-width:100%;max-height:100vh" src="{direct_url}"></video>'

    elif is_image(mimetype, filename):
        og_media = f"""
  <meta property="og:type" content="website">
  <meta property="og:image" content="{direct_url}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">"""
        twitter_card = "summary_large_image"
        description = "Shared image"
        body_media = f'<img style="max-width:100%;max-height:100vh" src="{direct_url}">'

    else:
        og_media = f'<meta property="og:type" content="website">'
        twitter_card = "summary"
        description = "Shared file from Nextcloud"
        body_media = f'<p style="color:#fff;font-family:sans-serif">Download: <a href="{direct_url}" style="color:#6cf">{title}</a></p>'

    html = HTML_TEMPLATE.format(
        title=title,
        page_url=page_url,
        description=description,
        og_media=og_media,
        twitter_card=twitter_card,
        direct_url=direct_url,
        body_media=body_media,
    )
    return Response(html, mimetype="text/html")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
