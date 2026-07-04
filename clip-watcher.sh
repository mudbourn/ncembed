#!/bin/bash
# clip-watcher.sh
# Generic video clip watcher — monitors a folder for new video files,
# uploads them to Nextcloud via WebDAV, creates a public share link,
# converts it to an ncembed URL, and copies it to your clipboard.
#
# Works with any video recorder (OBS, ShadowPlay, ReLive, Xbox Game Bar, etc.)
#
# Dependencies: fswatch, curl, jq
# Install: brew install fswatch jq
#   
# COMMANDS:
#   clip               — start watching the configured folder
#   clip --debug       — start with verbose logging
#   clip stop          — gracefully stop the watcher
#   clip status        — show watcher PID, active jobs, recent clips
#   clip last          — copy last share URL to clipboard again
#   clip retry         — re-process the last clip (re-upload)
#   clip retry <file>  — re-process a specific file
#   clip clear         — clear the processed log (lets all clips be re-queued)
#   clip log           — tail the live log

# ── Configuration ────────────────────────────────────────────────────────────

# Folders
WATCH_DIR="/Users/eli3/Movies/Captures/optimised"
TEMP_DIR="/Users/eli3/Movies/Captures/encoded"
LOG_FILE="$TEMP_DIR/clip-watcher.log"
PID_FILE="$TEMP_DIR/.clip-watcher.pid"
URL_LOG="$TEMP_DIR/.urls"         # one "timestamp<TAB>url<TAB>filename" per line
PROCESSED_LOG="$TEMP_DIR/.processed"

# Nextcloud
NEXTCLOUD_URL="https://save.mudbourn.info"
NEXTCLOUD_USER=""                 # Set via NC_USER env var or fill in here
NEXTCLOUD_PASS=""                 # Set via NC_PASS env var or fill in here
NC_UPLOAD_PATH="/Videos/clips"    # Remote folder in Nextcloud (created if needed)

# Samba shares (local network mounts — much faster than WebDAV for large files)
# These should map to the same Nextcloud directories. First available is used.
SAMBA_SHARES=(
    "/Volumes/UGREENNVME-Share/nextcloud"
    "/Volumes/ToshibaHD-Share/nextcloud"
)

# ncembed
NCEMBED_DOMAIN="share.mudbourn.info"

# Processing
SIZE_LIMIT_MB=24
SIZE_LIMIT=$(( SIZE_LIMIT_MB * 1024 * 1024 ))
STABLE_CHECKS=3                   # Consecutive size-stable checks required
STABLE_INTERVAL=2                 # Seconds between checks

# File patterns to watch (space-separated globs)
VIDEO_EXTENSIONS="mp4 mkv mov avi webm"

# ─────────────────────────────────────────────────────────────────────────────

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Load credentials from environment if not hardcoded
NEXTCLOUD_USER="${NEXTCLOUD_USER:-$NC_USER}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-$NC_PASS}"

mkdir -p "$TEMP_DIR"
touch "$PROCESSED_LOG" "$URL_LOG"

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $*" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO " "$@"; }
log_ok()    { log " OK  " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_err()   { log "ERROR" "$@"; }
log_debug() { $DEBUG && log "DEBUG" "$@"; }
log_separator() {
    echo "──────────────────────────────────────────────────────────" | tee -a "$LOG_FILE"
}

# ── Nextcloud helpers ────────────────────────────────────────────────────────

nc_curl() {
    # Wrapper for curl with Nextcloud auth and common flags
    curl -s -u "$NEXTCLOUD_USER:$NEXTCLOUD_PASS" \
         -H "OCS-APIRequest: true" \
         "$@"
}

nc_upload() {
    # Upload a file to Nextcloud via WebDAV
    local FILE="$1"
    local REMOTE_PATH="$2"
    local FILENAME
    FILENAME=$(basename "$FILE")

    log_debug "Uploading to Nextcloud: $REMOTE_PATH/$FILENAME"

    # Create remote directory if needed (ignore 405 = already exists)
    nc_curl -X MKCOL \
            "$NEXTCLOUD_URL/dav/files/$NEXTCLOUD_USER$NC_UPLOAD_PATH" \
            -o /dev/null 2>/dev/null

    local HTTP_CODE
    HTTP_CODE=$(nc_curl -T "$FILE" \
                 -w "%{http_code}" \
                 -o /dev/null \
                 "$NEXTCLOUD_URL/dav/files/$NEXTCLOUD_USER$REMOTE_PATH/$FILENAME")

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        log_debug "Upload HTTP status: $HTTP_CODE"
        return 0
    else
        log_err "Upload failed (HTTP $HTTP_CODE)"
        return 1
    fi
}

nc_create_share() {
    # Create a public share link for a file, return the share token
    local FILE_PATH="$1"
    local FILENAME="$2"

    log_debug "Creating public share for: $FILE_PATH"

    local RESPONSE
    RESPONSE=$(nc_curl -X POST \
                -d "path=$FILE_PATH" \
                -d "shareType=3" \
                -d "permissions=1" \
                "$NEXTCLOUD_URL/ocs/v2.php/apps/files_sharing/api/v1/shares" 2>/dev/null)

    local STATUS_CODE
    STATUS_CODE=$(echo "$RESPONSE" | jq -r '.ocs.meta.statuscode // empty')

    if [ "$STATUS_CODE" = "100" ]; then
        local SHARE_URL
        SHARE_URL=$(echo "$RESPONSE" | jq -r '.ocs.data.url // empty')
        local TOKEN
        TOKEN=$(echo "$RESPONSE" | jq -r '.ocs.data.token // empty')

        if [ -n "$TOKEN" ]; then
            log_debug "Share created: token=$TOKEN url=$SHARE_URL"
            echo "$TOKEN"
            return 0
        fi
    fi

    log_err "Failed to create share (status: $STATUS_CODE)"
    echo "$RESPONSE" | jq -r '.ocs.meta.message // "unknown error"' >&2
    return 1
}

nc_to_ncembed() {
    # Convert a Nextcloud share token to an ncembed URL
    local TOKEN="$1"
    echo "https://$NCEMBED_DOMAIN/embed/$TOKEN"
}

# ── Samba helpers ────────────────────────────────────────────────────────────

find_samba_share() {
    # Find the first available Samba share mount
    for SHARE in "${SAMBA_SHARES[@]}"; do
        if [ -d "$SHARE" ]; then
            echo "$SHARE"
            return 0
        fi
    done
    return 1
}

samba_upload() {
    # Copy a file to a Samba share (local network copy — much faster than WebDAV)
    local FILE="$1"
    local SAMBA_ROOT="$2"
    local REMOTE_PATH="$3"
    local FILENAME
    FILENAME=$(basename "$FILE")
    local DEST_DIR="$SAMBA_ROOT$REMOTE_PATH"
    local DEST_FILE="$DEST_DIR/$FILENAME"

    log_debug "Copying to Samba share: $DEST_FILE"

    # Create destination directory if needed
    mkdir -p "$DEST_DIR" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_err "Failed to create directory: $DEST_DIR"
        return 1
    fi

    # Copy file
    cp "$FILE" "$DEST_FILE" 2>/dev/null
    if [ $? -eq 0 ] && [ -f "$DEST_FILE" ]; then
        log_debug "Samba copy complete: $DEST_FILE"
        return 0
    else
        log_err "Samba copy failed"
        return 1
    fi
}

# ── Subcommand dispatch ───────────────────────────────────────────────────────

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "clip-watcher is not running (no PID file found)"
        exit 0
    fi
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping clip-watcher (PID $PID)..."
        kill "$PID"
        rm -f "$PID_FILE"
        echo "Stopped."
    else
        echo "clip-watcher is not running (stale PID $PID)"
        rm -f "$PID_FILE"
    fi
    exit 0
}

cmd_status() {
    echo ""
    echo "  ── clip-watcher status ─────────────────────────────────"

    # Watcher process
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "  Watcher:  running (PID $PID)"
        else
            echo "  Watcher:  stopped (stale PID $PID)"
        fi
    else
        echo "  Watcher:  not running"
    fi

    # Nextcloud connection
    if [ -n "$NEXTCLOUD_USER" ] && [ -n "$NEXTCLOUD_PASS" ]; then
        local NC_STATUS
        NC_STATUS=$(nc_curl -w "%{http_code}" -o /dev/null "$NEXTCLOUD_URL/ocs/v2.php/cloud/user" 2>/dev/null)
        if [[ "$NC_STATUS" =~ ^2 ]]; then
            echo "  Nextcloud: connected ($NEXTCLOUD_URL)"
        else
            echo "  Nextcloud: auth failed (HTTP $NC_STATUS)"
        fi
    else
        echo "  Nextcloud: credentials not set"
    fi

    # Samba shares
    local SAMBA_ROOT
    SAMBA_ROOT=$(find_samba_share)
    if [ -n "$SAMBA_ROOT" ]; then
        echo "  Samba:    available ($SAMBA_ROOT)"
    else
        echo "  Samba:    not mounted"
    fi

    # Active upload jobs
    JOBS=$(pgrep -f "process_clip" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Active jobs: $JOBS"

    # Lock files = files currently in-flight
    LOCKS=( "$TEMP_DIR"/.lock_* )
    if [ -f "${LOCKS[0]}" ]; then
        echo "  In-flight clips:"
        for lf in "${LOCKS[@]}"; do
            echo "    • $(basename "$lf" | sed 's/^\.lock_//')"
        done
    fi

    # Last 5 uploads
    echo ""
    echo "  Recent uploads:"
    if [ -s "$URL_LOG" ]; then
        tail -5 "$URL_LOG" | while IFS=$'\t' read -r ts url fname; do
            echo "    [$ts]  $fname"
            echo "    $url"
        done
    else
        echo "    (none yet)"
    fi

    echo "  ────────────────────────────────────────────────────────"
    echo ""
    exit 0
}

cmd_last() {
    if [ ! -s "$URL_LOG" ]; then
        echo "No uploads recorded yet."
        exit 1
    fi
    LAST=$(tail -1 "$URL_LOG")
    URL=$(echo "$LAST" | cut -f2)
    FNAME=$(echo "$LAST" | cut -f3)
    echo -n "$URL" | pbcopy
    echo "Copied: $URL  ($FNAME)"
    osascript -e "display notification \"$URL\" with title \"Clip Link\" subtitle \"Copied to clipboard\""
    exit 0
}

cmd_retry() {
    local TARGET="$1"

    if [ -n "$TARGET" ]; then
        # Explicit file path given
        if [ ! -f "$TARGET" ]; then
            # Try treating it as a filename inside WATCH_DIR
            if [ -f "$WATCH_DIR/$TARGET" ]; then
                TARGET="$WATCH_DIR/$TARGET"
            else
                echo "File not found: $TARGET"
                exit 1
            fi
        fi
    else
        # Use last entry in processed log
        TARGET=$(tail -1 "$PROCESSED_LOG")
        if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
            echo "No clip to retry (processed log is empty or file is gone)."
            exit 1
        fi
    fi

    echo "Retrying: $(basename "$TARGET")"

    # Remove from processed log so the watcher won't skip it if moved again
    grep -vF "$TARGET" "$PROCESSED_LOG" > "$PROCESSED_LOG.tmp" && mv "$PROCESSED_LOG.tmp" "$PROCESSED_LOG"

    # Remove any stale lock
    LOCK_FILE="$TEMP_DIR/.lock_$(echo "$TARGET" | md5)"
    rm -f "$LOCK_FILE"

    # Run processing directly in this shell (watcher doesn't need to be running)
    DEBUG=false
    _run_process_clip "$TARGET"
    exit 0
}

cmd_clear() {
    > "$PROCESSED_LOG"
    rm -f "$TEMP_DIR"/.lock_* 2>/dev/null
    echo "Processed log cleared. All clips can be re-queued."
    exit 0
}

cmd_log() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log file yet: $LOG_FILE"
        exit 1
    fi
    echo "Tailing $LOG_FILE  (Ctrl-C to stop)"
    tail -f "$LOG_FILE"
    exit 0
}

# Dispatch before any startup side-effects
case "$1" in
    stop)   cmd_stop ;;
    status) cmd_status ;;
    last)   cmd_last ;;
    retry)  cmd_retry "$2" ;;
    clear)  cmd_clear ;;
    log)    cmd_log ;;
esac

DEBUG=false
[[ "$1" == "--debug" ]] && DEBUG=true

# ── Startup ──────────────────────────────────────────────────────────────────

log_separator
log_info "clip-watcher starting (debug=$DEBUG)"
log_info "Watching: $WATCH_DIR"
log_info "Temp dir: $TEMP_DIR"
log_info "Log file: $LOG_FILE"
log_info "Nextcloud: $NEXTCLOUD_URL"
log_info "Upload path: $NC_UPLOAD_PATH"
log_info "ncembed: $NCEMBED_DOMAIN"

# Check Samba shares
SAMBA_ROOT=$(find_samba_share)
if [ -n "$SAMBA_ROOT" ]; then
    log_ok "Samba share available: $SAMBA_ROOT"
else
    log_warn "No Samba shares mounted (will use WebDAV fallback)"
fi

log_info "Size limit: ${SIZE_LIMIT_MB}MB"
log_info "Commands: clip stop | clip status | clip last | clip retry | clip clear | clip log"
log_separator

# Check dependencies
for dep in fswatch curl jq; do
    if ! command -v "$dep" &>/dev/null; then
        log_err "Missing dependency: $dep (not found in PATH)"
        exit 1
    else
        log_debug "Found: $dep → $(command -v "$dep")"
    fi
done

# Validate configuration
if [ -z "$NEXTCLOUD_USER" ] || [ -z "$NEXTCLOUD_PASS" ]; then
    log_err "Nextcloud credentials not set"
    log_err "Set NC_USER and NC_PASS environment variables, or edit NEXTCLOUD_USER/NEXTCLOUD_PASS in the script"
    exit 1
fi

if [ ! -d "$WATCH_DIR" ]; then
    log_err "Watch directory does not exist: $WATCH_DIR"
    exit 1
fi

# Test Nextcloud connection
log_info "Testing Nextcloud connection..."
NC_TEST=$(nc_curl -w "%{http_code}" -o /dev/null "$NEXTCLOUD_URL/ocs/v2.php/cloud/user" 2>/dev/null)
if [[ "$NC_TEST" =~ ^2 ]]; then
    log_ok "Nextcloud connection OK"
else
    log_err "Nextcloud connection failed (HTTP $NC_TEST)"
    log_err "Check NEXTCLOUD_URL, NEXTCLOUD_USER, and NEXTCLOUD_PASS"
    exit 1
fi

# Write PID so `clip stop` and `clip status` can find us
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"; log_info "clip-watcher stopped."; log_separator' EXIT

# ── Upload + Share ───────────────────────────────────────────────────────────

upload_and_share() {
    local FILE="$1"
    local FILENAME
    FILENAME=$(basename "$FILE")
    local FILE_SIZE
    FILE_SIZE=$(stat -f%z "$FILE" 2>/dev/null)

    log_info "Uploading: $FILENAME ($(( FILE_SIZE / 1024 / 1024 ))MB)"

    # Try Samba first (much faster for local network)
    local SAMBA_ROOT
    SAMBA_ROOT=$(find_samba_share)
    local UPLOAD_METHOD="webdav"

    if [ -n "$SAMBA_ROOT" ]; then
        log_info "Using Samba share: $SAMBA_ROOT"
        if samba_upload "$FILE" "$SAMBA_ROOT" "$NC_UPLOAD_PATH"; then
            UPLOAD_METHOD="samba"
            log_ok "Copied to Samba: $SAMBA_ROOT$NC_UPLOAD_PATH/$FILENAME"
        else
            log_warn "Samba copy failed, falling back to WebDAV"
        fi
    else
        log_debug "No Samba shares available, using WebDAV"
    fi

    # Fall back to WebDAV if Samba failed or unavailable
    if [ "$UPLOAD_METHOD" = "webdav" ]; then
        if ! nc_upload "$FILE" "$NC_UPLOAD_PATH"; then
            log_err "Upload failed for $FILENAME"
            return 1
        fi
        log_ok "Uploaded via WebDAV: $NC_UPLOAD_PATH/$FILENAME"
    fi

    # Create public share
    local TOKEN
    TOKEN=$(nc_create_share "$NC_UPLOAD_PATH/$FILENAME" "$FILENAME")
    if [ -z "$TOKEN" ]; then
        log_err "Failed to create share for $FILENAME"
        return 1
    fi

    # Convert to ncembed URL
    local SHARE_URL
    SHARE_URL=$(nc_to_ncembed "$TOKEN")

    # Copy to clipboard
    echo -n "$SHARE_URL" | pbcopy

    # Record URL for `clip last` and `clip status`
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SHARE_URL" "$FILENAME" >> "$URL_LOG"

    log_ok "Link copied: $SHARE_URL"
    osascript -e "display notification \"$SHARE_URL\" with title \"Clip Ready\" subtitle \"Link copied to clipboard\""
}

# ── Process clip ─────────────────────────────────────────────────────────────

# Defined as _run_process_clip so `clip retry` can call it without a running watcher
_run_process_clip() {
    local FILE="$1"
    local FILENAME

    FILENAME=$(basename "$FILE")

    log_info "[$FILENAME] Processing started"
    log_info "[$FILENAME] Waiting for file to stabilize..."

    # Require consecutive size-stable checks
    local SIZE1 SIZE2 STABLE=0
    SIZE1=$(stat -f%z "$FILE" 2>/dev/null)
    for i in {1..30}; do
        sleep "$STABLE_INTERVAL"
        SIZE2=$(stat -f%z "$FILE" 2>/dev/null)
        log_debug "[$FILENAME] Size check $i: $SIZE1 → $SIZE2 (stable streak: $STABLE)"
        if [ "$SIZE1" = "$SIZE2" ] && [ -n "$SIZE1" ] && [ "$SIZE1" -gt 0 ]; then
            (( STABLE++ ))
            if [ "$STABLE" -ge "$STABLE_CHECKS" ]; then
                log_info "[$FILENAME] File stable after $i checks"
                break
            fi
        else
            STABLE=0
        fi
        SIZE1="$SIZE2"
        if [ "$i" = "30" ]; then
            log_err "[$FILENAME] File never stabilized after 60s, skipping"
            return
        fi
    done

    local FILE_SIZE
    FILE_SIZE=$(stat -f%z "$FILE" 2>/dev/null)
    log_info "[$FILENAME] File ready: $(( FILE_SIZE / 1024 / 1024 ))MB"

    # Upload and share
    upload_and_share "$FILE"

    # Mark as processed only after successful completion
    echo "$FILE" >> "$PROCESSED_LOG"

    log_ok "[$FILENAME] Done"
    log_separator
}

process_clip() { _run_process_clip "$@"; }

# ── fswatch loop ─────────────────────────────────────────────────────────────

log_info "Starting fswatch on $WATCH_DIR"

# Build extension filter for fswatch
EXT_FILTER=""
for ext in $VIDEO_EXTENSIONS; do
    EXT_FILTER="$EXT_FILTER --include=.*\\.$ext\$"
done

# Only watch for Renamed/MovedTo — most recorders write to a temp file and
# rename on completion, so this is the reliable "file is done" signal.
fswatch -0 \
    --event Renamed \
    --event MovedTo \
    $EXT_FILTER \
    "$WATCH_DIR" | while IFS= read -r -d "" FILE; do

    FILENAME=$(basename "$FILE")

    log_debug "fswatch event: $FILE"

    [ -z "$FILENAME" ] || [ "$FILE" = "$WATCH_DIR" ] && { log_debug "Skipped (dir itself)"; continue; }
    [[ "$FILE" == "$TEMP_DIR"* ]]    && { log_debug "Skipped (TEMP_DIR): $FILENAME"; continue; }
    [[ "$FILENAME" == encoded_* ]]   && { log_debug "Skipped (encoded_): $FILENAME"; continue; }
    [[ "$FILENAME" == remux_* ]]     && { log_debug "Skipped (remux_): $FILENAME"; continue; }
    [[ "$FILENAME" == *_exiftool_tmp* ]] && { log_debug "Skipped (exiftool): $FILENAME"; continue; }

    LOCK_FILE="$TEMP_DIR/.lock_$(echo "$FILE" | md5)"
    if ! (set -C; echo "$$" > "$LOCK_FILE") 2>/dev/null; then
        log_debug "Skipped (already queued): $FILENAME"
        continue
    fi
    if grep -qF "$FILE" "$PROCESSED_LOG"; then
        rm -f "$LOCK_FILE"
        log_debug "Skipped (previous run): $FILENAME"
        continue
    fi

    log_info "New clip detected: $FILENAME"

    (process_clip "$FILE"; rm -f "$LOCK_FILE") >> "$LOG_FILE" 2>&1 &

done
