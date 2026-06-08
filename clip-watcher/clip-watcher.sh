#!/bin/bash
# clip-watcher.sh
# Watches a folder for new video clips, remuxes them with faststart,
# encodes anything over the size limit, uploads via Dropshare CLI,
# and copies the share link to your clipboard.
#
# Dependencies: fswatch, ffmpeg, Dropshare CLI (ds)
# Install: brew install fswatch ffmpeg
# Dropshare CLI: Dropshare → Preferences → General → Install CLI

# ── Configuration ────────────────────────────────────────────────────────────

# Folder to watch for new clips (e.g. Clop output folder)
WATCH_DIR="$HOME/Movies/optimised"

# Folder to store encoded/remuxed files temporarily
TEMP_DIR="$HOME/Movies/encoded"

# Maximum file size before encoding is triggered (in MB)
SIZE_LIMIT_MB=24
SIZE_LIMIT=$(( SIZE_LIMIT_MB * 1024 * 1024 ))

# Your Dropshare upload domain (the domain ds puts in the clipboard)
UPLOAD_DOMAIN="your-nextcloud-domain.com"

# Your ncembed share domain (swapped in before copying to clipboard)
SHARE_DOMAIN="your-share-domain.com"

# OBS app name (as it appears in macOS, usually "OBS")
OBS_APP="OBS"

# ─────────────────────────────────────────────────────────────────────────────

# Ensure Homebrew and local binaries are in PATH (needed for Keyboard Maestro)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$TEMP_DIR"

# Launch OBS with replay buffer if not already running
if ! /usr/bin/pgrep -xi "$OBS_APP" > /dev/null; then
    echo "🎮 OBS not running, launching with replay buffer..."
    open -a "$OBS_APP" --args --startreplaybuffer --minimize-to-tray
    # Wait up to 60 seconds for OBS to appear in process list
    for i in {1..60}; do
        sleep 1
        if /usr/bin/pgrep -xi "$OBS_APP" > /dev/null; then
            echo "✅ OBS is running"
            break
        fi
        if [ "$i" = "60" ]; then
            echo "❌ OBS failed to launch"
            exit 1
        fi
    done
fi

echo "👀 Watching $WATCH_DIR for new clips..."

# Monitor OBS — when it quits, give pending clips 60s to finish then exit
(
    sleep 30
    while true; do
        sleep 5
        if ! /usr/bin/pgrep -xi "$OBS_APP" > /dev/null; then
            echo "⛔ OBS has quit, finishing any pending clips then stopping..."
            sleep 60
            kill $$
            exit
        fi
    done
) &

# Track already-processed files to avoid duplicate uploads
PROCESSED_LOG="$TEMP_DIR/.processed"
touch "$PROCESSED_LOG"

upload_file() {
    local FILE="$1"
    local FILENAME
    FILENAME=$(basename "$FILE")

    echo "☁️  Uploading: $FILENAME"
    OLD_CLIP=$(pbpaste)
    ds "$FILE" 2>/dev/null

    # Poll clipboard until Dropshare puts the URL there (up to 30 seconds)
    SHARE_URL=""
    for i in {1..30}; do
        sleep 1
        NEW_CLIP=$(pbpaste)
        if [[ "$NEW_CLIP" != "$OLD_CLIP" && "$NEW_CLIP" == *"$UPLOAD_DOMAIN"* ]]; then
            SHARE_URL="$NEW_CLIP"
            break
        fi
    done

    if [ -z "$SHARE_URL" ]; then
        echo "❌ Upload failed or timed out for $FILENAME"
        return 1
    fi

    # Swap upload domain for share domain
    SHARE_URL="${SHARE_URL/$UPLOAD_DOMAIN/$SHARE_DOMAIN}"
    echo -n "$SHARE_URL" | pbcopy
    echo "✅ Done! Link copied: $SHARE_URL"
    osascript -e "display notification \"$SHARE_URL\" with title \"Clip Ready\" subtitle \"Link copied to clipboard\""
}

process_clip() {
    local FILE="$1"
    local FILENAME SAFE_FILENAME REMUX OUTPUT FILE_SIZE

    FILENAME=$(basename "$FILE")
    SAFE_FILENAME="${FILENAME// /_}"

    # Wait for file to be fully written (up to 2 minutes)
    for i in {1..60}; do
        if [ -f "$FILE" ]; then
            SIZE1=$(stat -f%z "$FILE" 2>/dev/null)
            sleep 2
            SIZE2=$(stat -f%z "$FILE" 2>/dev/null)
            if [ "$SIZE1" = "$SIZE2" ] && [ -n "$SIZE1" ] && [ "$SIZE1" -gt 0 ]; then
                break
            fi
        else
            sleep 2
        fi
        if [ "$i" = "60" ]; then
            echo "❌ File never stabilized: $FILENAME"
            return
        fi
    done

    FILE_SIZE=$(stat -f%z "$FILE" 2>/dev/null)
    echo "🎬 New clip: $FILENAME ($(( FILE_SIZE / 1024 / 1024 ))MB)"

    # Always remux with faststart for instant embedding
    REMUX="$TEMP_DIR/remux_$SAFE_FILENAME"
    ffmpeg -i "$FILE" -c copy -movflags faststart "$REMUX" -y 2>/dev/null

    if [ $? -ne 0 ] || [ ! -f "$REMUX" ]; then
        echo "⚠️  Faststart remux failed, uploading original..."
        REMUX="$FILE"
    fi

    if [ "$FILE_SIZE" -le "$SIZE_LIMIT" ]; then
        echo "✅ Under ${SIZE_LIMIT_MB}MB, uploading..."
        upload_file "$REMUX"
        [ "$REMUX" != "$FILE" ] && rm -f "$REMUX"
    else
        echo "⚙️  Over ${SIZE_LIMIT_MB}MB, encoding..."
        OUTPUT="$TEMP_DIR/encoded_$SAFE_FILENAME"

        ffmpeg -hwaccel videotoolbox -i "$REMUX" \
            -c:v libx264 \
            -profile:v main \
            -level 4.0 \
            -pix_fmt yuv420p \
            -movflags faststart \
            -crf 22 \
            -r 60 \
            -c:a aac \
            -b:a 160k \
            "$OUTPUT" -y 2>/dev/null

        if [ $? -ne 0 ] || [ ! -f "$OUTPUT" ]; then
            echo "❌ Encoding failed for $FILENAME"
            [ "$REMUX" != "$FILE" ] && rm -f "$REMUX"
            return
        fi

        echo "📁 Encoded: $(( $(stat -f%z "$OUTPUT") / 1024 / 1024 ))MB"
        upload_file "$OUTPUT"
        rm -f "$OUTPUT"
        [ "$REMUX" != "$FILE" ] && rm -f "$REMUX"
    fi
}

fswatch -0 --event Created --event Renamed --event MovedTo --event AttributeModified "$WATCH_DIR" | while IFS= read -r -d "" FILE; do
    FILENAME=$(basename "$FILE")

    # Skip empty filenames or the watch directory itself
    if [ -z "$FILENAME" ] || [ "$FILE" = "$WATCH_DIR" ]; then
        continue
    fi

    # Only process .mp4 files, ignore encoded, remuxed, exiftool temp files, and TEMP_DIR
    if [[ "$FILE" != *.mp4 ]] || \
       [[ "$FILE" == "$TEMP_DIR"* ]] || \
       [[ "$FILENAME" == encoded_* ]] || \
       [[ "$FILENAME" == remux_* ]] || \
       [[ "$FILENAME" == *_exiftool_tmp* ]]; then
        continue
    fi

    # Skip already-processed files
    if grep -qF "$FILE" "$PROCESSED_LOG"; then
        continue
    fi
    echo "$FILE" >> "$PROCESSED_LOG"

    process_clip "$FILE" &
done
