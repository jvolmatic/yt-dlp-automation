#!/bin/bash

# Parse arguments for optional flags
SINGLE_TRACK=""
SUBDIR=""
FETCH_LYRICS="1"
BATCH_SIZE_ARG=""
ALBUM_MODE=""
FILE_PATH=""
POSITIONAL_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --single|-s)
      SINGLE_TRACK="--no-playlist"
      shift
      ;;
    -d|--dir)
      SUBDIR="$2"
      shift 2
      ;;
    --no-lyrics)
      FETCH_LYRICS=""
      shift
      ;;
    --batch)
      BATCH_SIZE_ARG="$2"
      shift 2
      ;;
    --album)
      ALBUM_MODE="1"
      shift
      ;;
    -f)
      FILE_PATH="$2"
      shift 2
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Restore positional arguments
set -- "${POSITIONAL_ARGS[@]}"

# Error check: -f provided without --album flag
if [ -n "$FILE_PATH" ] && [ -z "$ALBUM_MODE" ]; then
  echo "Error: The -f flag requires the --album flag to be set." >&2
  echo "Proper usage: $0 --album -f \"file.txt\" [-d <subfolder>] [--no-lyrics]" >&2
  exit 1
fi

# Check if a URL was provided (unless -f is used with --album)
if [ -z "$1" ] && [ -z "$FILE_PATH" ]; then
  echo "Usage: $0 [--single|-s] [--album [-f <file.txt>]] [-d <subfolder>] [--no-lyrics] [--batch <N>] <YouTube URL> [browser]"
  exit 1
fi

URL="$1"
BROWSER="${2:-firefox}"
REMOTE_SERVER="selfhost@192.168.1.185"
BASE_REMOTE_DIR="navidrome/music"

# --- Establish SSH connection up front ---
mkdir -p "$HOME/.ssh/sockets"
SSH_CONTROL_PATH="$HOME/.ssh/sockets/%r@%h:%p"
SSH_MUX_OPTS=(-o ControlMaster=auto -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=4h)

echo "Connecting to $REMOTE_SERVER..."
if ! ssh "${SSH_MUX_OPTS[@]}" "$REMOTE_SERVER" true; then
  echo "Error: could not connect to $REMOTE_SERVER. Aborting before download." >&2
  exit 1
fi

cleanup_ssh() {
  ssh "${SSH_MUX_OPTS[@]}" -O exit "$REMOTE_SERVER" >/dev/null 2>&1
}
trap cleanup_ssh EXIT

# --- Cookie source ---
COOKIES_FILE="$HOME/.config/music-dl/youtube-cookies.txt"
if [ -f "$COOKIES_FILE" ]; then
  COOKIE_ARGS=(--cookies "$COOKIES_FILE")
  echo "Using cookies from $COOKIES_FILE..."
else
  COOKIE_ARGS=(--cookies-from-browser "$BROWSER")
  echo "Using cookies from $BROWSER..."
fi

# --- Persistent album metadata cache ---
ALBUM_CACHE_FILE="$HOME/.config/music-dl/album_metadata_cache.json"
mkdir -p "$(dirname "$ALBUM_CACHE_FILE")"

album_cache_get() {
  local key="$1"
  python3 - "$ALBUM_CACHE_FILE" "$key" << 'PYEOF'
import sys, json, os
cache_file, key = sys.argv[1], sys.argv[2]
if not os.path.exists(cache_file):
    sys.exit(1)
try:
    with open(cache_file) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
entry = data.get(key)
if not entry or key == "NA":
    sys.exit(1)
print(entry.get("album_artist", ""))
print(entry.get("date", ""))
PYEOF
}

album_cache_set() {
  local key="$1" artist="$2" date_val="$3"
  python3 - "$ALBUM_CACHE_FILE" "$key" "$artist" "$date_val" << 'PYEOF'
import sys, json, os
cache_file, key, artist, date_val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
if key == "NA" or not key.strip():
    sys.exit(0)
data = {}
if os.path.exists(cache_file):
    try:
        with open(cache_file) as f:
            data = json.load(f)
    except Exception:
        data = {}
data[key] = {"album_artist": artist, "date": date_val}
with open(cache_file, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# Helper function to execute a single album processing workflow
process_album_target() {
  local target_url="$1"
  local target_subdir="$2"
  local clean_sub FINAL_REMOTE_DIR
  local LIKED_FALLBACK_ARGS REPLACE_ARGS
  local RAW_PLAYLIST_TITLE FINAL_ALBUM_NAME ALBUM_PARSE
  local CACHE_RESULT ALBUM_ARTIST_VALUE ALBUM_YEAR RAW_ALBUM_ARTIST
  local ALBUM_ARTIST_PARSE DATE_ARGS SINGLE_ITEM_ARGS
  local FALLBACK_ALBUM_NAME OUTPUT_TEMPLATE TOTAL_ITEMS START BATCH_NUM END

  if [ -n "$target_subdir" ]; then
    clean_sub=$(echo "$target_subdir" | sed 's|^/||;s|/$||')
    FINAL_REMOTE_DIR="$BASE_REMOTE_DIR/$clean_sub"
  else
    FINAL_REMOTE_DIR="$BASE_REMOTE_DIR"
  fi

  echo "Ensuring remote folder '$FINAL_REMOTE_DIR' exists..."
  ssh "${SSH_MUX_OPTS[@]}" "$REMOTE_SERVER" "mkdir -p '$FINAL_REMOTE_DIR'"

  if [ -n "$ALBUM_MODE" ]; then
    LIKED_FALLBACK_ARGS=()
    REPLACE_ARGS=()

    RAW_PLAYLIST_TITLE=$(yt-dlp "${COOKIE_ARGS[@]}" --flat-playlist --playlist-items 1 --print '%(playlist_title,title|)s' "$target_url" 2>/dev/null | head -n1)

    if [ -z "$RAW_PLAYLIST_TITLE" ] || [[ "$RAW_PLAYLIST_TITLE" == *"NA"* ]]; then
      RAW_PLAYLIST_TITLE=$(basename "$target_subdir")
    fi

    FINAL_ALBUM_NAME=$(echo "$RAW_PLAYLIST_TITLE" | sed -E 's/^[Aa][Ll][Bb][Uu][Mm][[:space:]]*-[[:space:]]*//')

    # Appending %(autowrap_bypass|)s to prevent yt-dlp from turning single-word literals into variable requests
    ALBUM_PARSE="${FINAL_ALBUM_NAME//:/\\:}%(autowrap_bypass|)s:%(album)s"

    echo "Checking cache for metadata for '$FINAL_ALBUM_NAME'..."
    if CACHE_RESULT=$(album_cache_get "$FINAL_ALBUM_NAME"); then
      ALBUM_ARTIST_VALUE=$(echo "$CACHE_RESULT" | sed -n '1p')
      ALBUM_YEAR=$(echo "$CACHE_RESULT" | sed -n '2p')
      echo "Found cached metadata — reusing album_artist='$ALBUM_ARTIST_VALUE' date='$ALBUM_YEAR'."
    else
      echo "No cached metadata — probing this album for the first time."
      RAW_ALBUM_ARTIST=$(yt-dlp "${COOKIE_ARGS[@]}" --playlist-items 1 --print '%(playlist_uploader,uploader,channel|)s' "$target_url" 2>/dev/null | head -n1)
      if [ -z "$RAW_ALBUM_ARTIST" ] || [[ "$RAW_ALBUM_ARTIST" == *"NA"* ]]; then
        RAW_ALBUM_ARTIST=$(echo "$target_subdir" | awk -F'/' '{print $(NF-1)}')
      fi
      ALBUM_ARTIST_VALUE=$(echo "$RAW_ALBUM_ARTIST" | sed -E 's/[[:space:]]*-[[:space:]]*Topic$//I')

      ALBUM_YEAR=$(yt-dlp "${COOKIE_ARGS[@]}" --playlist-items 1 --print '%(release_year,upload_date>%Y|)s' "$target_url" 2>/dev/null | head -n1)
      if ! [[ "$ALBUM_YEAR" =~ ^[0-9]{4}$ ]]; then
        ALBUM_YEAR=""
      fi
      album_cache_set "$FINAL_ALBUM_NAME" "$ALBUM_ARTIST_VALUE" "$ALBUM_YEAR"
    fi

    ALBUM_ARTIST_PARSE="${ALBUM_ARTIST_VALUE//:/\\:}%(autowrap_bypass|)s:%(album_artist)s"
    DATE_ARGS=(
      --parse-metadata "${ALBUM_YEAR}%(autowrap_bypass|)s:%(meta_date)s"
    )
    SINGLE_ITEM_ARGS=()
  else
    if [ -n "$target_subdir" ]; then
      FALLBACK_ALBUM_NAME=$(basename "$target_subdir")
    else
      FALLBACK_ALBUM_NAME="Liked"
    fi
    LIKED_FALLBACK_ARGS=(
      --parse-metadata "${FALLBACK_ALBUM_NAME//:/\\:}%(autowrap_bypass|)s:%(meta_liked_fallback)s"
      --parse-metadata "Various Artists%(autowrap_bypass|)s:%(meta_liked_fallback_artist)s"
    )
    REPLACE_ARGS=()
    ALBUM_PARSE='%(album,meta_liked_fallback|)s:%(album)s'
    ALBUM_ARTIST_PARSE='%(album_artist,meta_liked_fallback_artist|)s:%(album_artist)s'
    DATE_ARGS=(
      --parse-metadata '%(release_year|)s:%(meta_date)s'
    )
    if [ -n "$SINGLE_TRACK" ]; then
      SINGLE_ITEM_ARGS=(--playlist-items 1)
    else
      SINGLE_ITEM_ARGS=()
    fi
  fi

  OUTPUT_TEMPLATE="%(title)s_%(artist)s.%(ext)s"

  if [ -n "$SINGLE_TRACK" ]; then
    download_and_upload_batch "$target_url"
  else
    TOTAL_ITEMS=$(yt-dlp "${COOKIE_ARGS[@]}" --flat-playlist --playlist-items 1 --print '%(playlist_count)s' "$target_url" 2>/dev/null | head -n1)

    if ! [[ "$TOTAL_ITEMS" =~ ^[0-9]+$ ]] || [ "$TOTAL_ITEMS" -le 0 ]; then
      download_and_upload_batch "$target_url"
    else
      START=1
      BATCH_NUM=1
      while [ "$START" -le "$TOTAL_ITEMS" ]; do
        END=$((START + BATCH_SIZE - 1))
        if [ "$END" -gt "$TOTAL_ITEMS" ]; then
          END="$TOTAL_ITEMS"
        fi
        echo "=== Batch $BATCH_NUM: items $START-$END of $TOTAL_ITEMS ==="
        download_and_upload_batch "$target_url" --playlist-items "$START:$END"
        START=$((END + 1))
        BATCH_NUM=$((BATCH_NUM + 1))
      done
    fi
  fi
}

fetch_lyrics_for_file() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import sys, subprocess, json, urllib.request, urllib.parse, os

path = sys.argv[1]

def ffprobe_tag(tag):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", f"format_tags={tag}",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=10
        )
        return out.stdout.strip()
    except Exception:
        return ""

def ffprobe_duration():
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=10
        )
        return int(float(out.stdout.strip()))
    except Exception:
        return None

title = ffprobe_tag("title")
artist = ffprobe_tag("artist")
album = ffprobe_tag("album")
duration = ffprobe_duration()

if not title or not artist:
    sys.exit(0)

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "music-dl-script/1.0 (personal use)"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None

lyrics = None
is_synced = False

params = {"track_name": title, "artist_name": artist}
if album:
    params["album_name"] = album
if duration:
    params["duration"] = str(duration)
data = fetch("https://lrclib.net/api/get?" + urllib.parse.urlencode(params))
if data:
    if data.get("syncedLyrics"):
        lyrics, is_synced = data["syncedLyrics"], True
    elif data.get("plainLyrics"):
        lyrics, is_synced = data["plainLyrics"], False

if not lyrics:
    params = {"track_name": title, "artist_name": artist}
    data = fetch("https://lrclib.net/api/search?" + urllib.parse.urlencode(params))
    if isinstance(data, list) and data:
        best = data[0]
        if best.get("syncedLyrics"):
            lyrics, is_synced = best["syncedLyrics"], True
        elif best.get("plainLyrics"):
            lyrics, is_synced = best["plainLyrics"], False

if lyrics:
    ext = ".lrc" if is_synced else ".txt"
    lyrics_path = os.path.splitext(path)[0] + ext
    with open(lyrics_path, "w", encoding="utf-8") as f:
        f.write(lyrics)

    tmp_path = path + ".lyricstmp.m4a"
    embed = subprocess.run(
        ["ffmpeg", "-y", "-i", path, "-c", "copy", "-metadata", f"lyrics={lyrics}", tmp_path],
        capture_output=True, text=True, timeout=30
    )
    if embed.returncode == 0 and os.path.exists(tmp_path):
        os.replace(tmp_path, path)
    elif os.path.exists(tmp_path):
        os.remove(tmp_path)
PYEOF
}

download_and_upload_batch() {
  local batch_url="$1"
  shift
  local range_args=("$@")
  local batch_dir
  batch_dir=$(mktemp -d -t music_dl_XXXXXX)

  yt-dlp \
    -x \
    -f 'ba[ext=m4a]' \
    $SINGLE_TRACK \
    "${SINGLE_ITEM_ARGS[@]}" \
    "${range_args[@]}" \
    "${COOKIE_ARGS[@]}" \
    --embed-metadata \
    --embed-thumbnail \
    --parse-metadata '%(artist,uploader,channel|)s:%(artist)s' \
    --replace-in-metadata artist ',\s*' '; ' \
    "${LIKED_FALLBACK_ARGS[@]}" \
    --parse-metadata "$ALBUM_ARTIST_PARSE" \
    --parse-metadata "$ALBUM_PARSE" \
    "${REPLACE_ARGS[@]}" \
    --parse-metadata '%(track_number,playlist_index|)s:%(track_number)s' \
    "${DATE_ARGS[@]}" \
    -o "$batch_dir/$OUTPUT_TEMPLATE" \
    "$batch_url" </dev/null

  if ! compgen -G "$batch_dir/*.m4a" > /dev/null; then
    echo "No .m4a files were downloaded for this batch."
    rm -rf "$batch_dir"
    return 1
  fi

  if [ -n "$FETCH_LYRICS" ]; then
    echo "Fetching lyrics..."
    for f in "$batch_dir"/*.m4a; do
      fetch_lyrics_for_file "$f"
    done
  fi

  echo "Uploading batch to $FINAL_REMOTE_DIR..."
  shopt -s nullglob
  local upload_files=("$batch_dir"/*.m4a "$batch_dir"/*.lrc "$batch_dir"/*.txt)
  shopt -u nullglob
  if scp -o ControlPath="$SSH_CONTROL_PATH" "${upload_files[@]}" "$REMOTE_SERVER:$FINAL_REMOTE_DIR/"; then
    rm -rf "$batch_dir"
    return 0
  else
    echo "Upload failed for this batch! Files kept locally in: $batch_dir" >&2
    return 1
  fi
}

BATCH_SIZE=50
if [ -n "$BATCH_SIZE_ARG" ]; then
  BATCH_SIZE="$BATCH_SIZE_ARG"
fi

if [ -n "$FILE_PATH" ]; then
  if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found." >&2
    exit 1
  fi

  while IFS='|' read -u 3 -r line_subdir line_url; do
    line_subdir=$(echo "$line_subdir" | xargs)
    line_url=$(echo "$line_url" | xargs)

    [[ -z "$line_subdir" || "$line_subdir" =~ ^# ]] && continue
    [[ -z "$line_url" ]] && continue

    echo ""
    echo "=== Processing Album: $line_subdir ==="
    process_album_target "$line_url" "$line_subdir"
  done 3< "$FILE_PATH"
else
  process_album_target "$URL" "$SUBDIR"
fi

echo ""
echo "All processing completed successfully!"
