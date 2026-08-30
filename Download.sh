#!/bin/bash

# Parse arguments for optional flags
SINGLE_TRACK=""
SUBDIR=""
FETCH_LYRICS="1"
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
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Restore positional arguments
set -- "${POSITIONAL_ARGS[@]}"

# Check if a URL was provided
if [ -z "$1" ]; then
  echo "Usage: $0 [--single|-s] [-d <subfolder>] [--no-lyrics] <YouTube URL> [browser]"
  echo ""
  echo "Lyrics are fetched from lrclib.net by default. Pass --no-lyrics to skip."
  echo ""
  echo "Examples:"
  echo "  $0 'https://music.youtube.com/playlist?list=...' -d 'Albums/Kanye/BULLY'"
  echo "  $0 -s 'https://music.youtube.com/watch?v=...' -d 'Liked' --no-lyrics"
  exit 1
fi

URL="$1"
BROWSER="${2:-firefox}"
REMOTE_SERVER="selfhost@192.168.1.185"
BASE_REMOTE_DIR="navidrome/music"

# --- Establish SSH connection up front ---
# Open a multiplexed master connection now (prompting for the password here,
# if one is needed) instead of after the download finishes. Later ssh/scp
# calls reuse this same authenticated socket, so there's no second prompt
# and no risk of the session dying/expiring during a long playlist download.
mkdir -p "$HOME/.ssh/sockets"
SSH_CONTROL_PATH="$HOME/.ssh/sockets/%r@%h:%p"
SSH_MUX_OPTS=(-o ControlMaster=auto -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=4h)

echo "Connecting to $REMOTE_SERVER..."
if ! ssh "${SSH_MUX_OPTS[@]}" "$REMOTE_SERVER" true; then
  echo "Error: could not connect to $REMOTE_SERVER. Aborting before download." >&2
  exit 1
fi

# Close the shared connection when the script exits, whether it succeeds or not.
cleanup_ssh() {
  ssh "${SSH_MUX_OPTS[@]}" -O exit "$REMOTE_SERVER" >/dev/null 2>&1
}
trap cleanup_ssh EXIT

# Construct final remote target path
if [ -n "$SUBDIR" ]; then
  CLEAN_SUBDIR=$(echo "$SUBDIR" | sed 's|^/||;s|/$||')
  FINAL_REMOTE_DIR="$BASE_REMOTE_DIR/$CLEAN_SUBDIR"
else
  FINAL_REMOTE_DIR="$BASE_REMOTE_DIR"
fi

# Determine album tagging based on mode (Single/Liked track vs Full Album/Playlist)
if [ -n "$SINGLE_TRACK" ]; then
  # Many official YouTube/YT Music uploads (e.g. "Artist - Topic" channels)
  # already carry real album/album_artist/release_year metadata that yt-dlp
  # extracts natively. Previous versions of this script unconditionally
  # overwrote %(album)s with a constructed "Artist - Liked" name, clobbering
  # that real metadata (e.g. showing "Kanye West - Liked" instead of the
  # track's actual album "Graduation"). Now we prefer the real value and
  # only fall back to the constructed name when the video truly has none
  # (e.g. a remix/edit with no official album).
  #
  # Step 1: compute the fallback name into a custom field first, since
  # --parse-metadata options apply in the order given, and step 2 needs
  # this field to already exist.
  LIKED_FALLBACK_ARGS=(--parse-metadata '%(artist,uploader,channel)s - Liked:%(meta_liked_fallback)s')
  # Step 2: real album wins if present, else the fallback computed above.
  ALBUM_PARSE='%(album,meta_liked_fallback)s:%(album)s'
  # Same idea for album_artist: real value first, else per-track
  # artist/uploader/channel (no playlist_uploader — a true single has no
  # playlist context).
  ALBUM_ARTIST_PARSE="%(album_artist,artist,uploader,channel)s:%(album_artist)s"
  # Only embed a real release_year (present when real album metadata was
  # found) — deliberately no upload_date fallback here. Tracks with a real
  # album get their real, correct, consistent release date. Tracks that
  # fell back to the constructed "Artist - Liked" pseudo-album get no date
  # at all (rather than each getting its own differing upload year), so
  # they still all group together consistently, avoiding the original
  # per-year album-fragmentation bug.
  #
  # IMPORTANT: yt-dlp's embed-metadata postprocessor hardcodes the muxed
  # "date" tag to always come from info_dict['upload_date']
  # (ffmpeg.py: add('date', 'upload_date')) — it completely ignores a
  # plain %(date)s field set via --parse-metadata. The only way to
  # actually override the embedded tag is yt-dlp's "meta_<field>" escape
  # hatch, which bypasses that hardcoded mapping. So this must target
  # %(meta_date)s, not %(date)s — targeting %(date)s silently no-ops.
  DATE_ARGS=(
    --parse-metadata '%(release_year|)s:%(meta_date)s'
  )
  # Safety net: some YouTube Music "share this song" links resolve to a bare
  # playlist/album URL with no video id, in which case --no-playlist has
  # nothing to cut down to and yt-dlp downloads the whole thing. Force a
  # hard cap to the first item whenever --single is used, regardless of
  # what kind of URL it turns out to be.
  SINGLE_ITEM_ARGS=(--playlist-items 1)
else
  # Covers both full albums (-d "Albums/...") and playlists (-d "Playlists/...").
  LIKED_FALLBACK_ARGS=()
  ALBUM_PARSE="%(playlist_title,title)s:%(album)s"
  # Source album_artist from the playlist's owning channel, not the
  # per-track artist field — per-track artist varies with features
  # (e.g. "Kanye West, Ye" vs "Kanye West, Ye, Travis Scott"), and since
  # Navidrome groups albums by album_artist, letting it vary fractures one
  # album into several. playlist_uploader stays identical for every track
  # in the playlist/album, so grouping stays intact.
  ALBUM_ARTIST_PARSE="%(playlist_uploader,uploader,channel)s:%(album_artist)s"
  # See the long comment above on meta_date — %(date)s alone is a no-op,
  # since yt-dlp always embeds upload_date for that tag unless overridden
  # via the meta_ prefix.
  DATE_ARGS=(
    --parse-metadata '%(release_year,upload_date>%Y)s:%(meta_date)s'
  )
  SINGLE_ITEM_ARGS=()
fi

# Human-readable filename for every mode (single, album, or playlist).
# Navidrome reads track order/album/artist from the embedded ID3 tags above,
# not from the filename, so this is safe everywhere.
OUTPUT_TEMPLATE="%(title)s_%(artist)s.%(ext)s"

# --- Cookie source ---
# YouTube rotates certain account cookies whenever the browser itself touches
# youtube.com. On a long playlist, --cookies-from-browser can go stale
# mid-download if Firefox touches YouTube while yt-dlp is still running,
# producing "cookies are no longer valid" errors partway through.
# Prefer a frozen cookies.txt exported once from a private/incognito window
# (see https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies)
# if one exists; otherwise fall back to live browser extraction as before.
COOKIES_FILE="$HOME/.config/music-dl/youtube-cookies.txt"
if [ -f "$COOKIES_FILE" ]; then
  COOKIE_ARGS=(--cookies "$COOKIES_FILE")
  echo "Using cookies from $COOKIES_FILE..."
else
  COOKIE_ARGS=(--cookies-from-browser "$BROWSER")
  echo "Using cookies from $BROWSER..."
  echo "Tip: for large playlists, export a frozen cookies.txt to $COOKIES_FILE to avoid mid-download cookie rotation errors."
fi

# Make sure the remote destination exists once, up front.
echo "Ensuring remote folder '$FINAL_REMOTE_DIR' exists..."
ssh "${SSH_MUX_OPTS[@]}" "$REMOTE_SERVER" "mkdir -p '$FINAL_REMOTE_DIR'"

# Sanity-check lyrics dependencies once, up front, instead of failing
# silently per-track later.
if [ -n "$FETCH_LYRICS" ]; then
  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Warning: ffprobe not found — lyrics lookup needs it to read back" >&2
    echo "  title/artist tags. Install it (it ships with ffmpeg) or pass" >&2
    echo "  --no-lyrics. Continuing without lyrics for this run." >&2
    FETCH_LYRICS=""
  elif ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not found — lyrics lookup needs it. Install it" >&2
    echo "  or pass --no-lyrics. Continuing without lyrics for this run." >&2
    FETCH_LYRICS=""
  fi
fi

# Batch size for large playlists. Downloading + uploading in smaller chunks
# keeps each yt-dlp run short (less time for YouTube cookies to rotate
# mid-run) and means a failure only costs you one batch, not the whole
# playlist — already-uploaded batches are safe either way.
BATCH_SIZE=50

# Looks up lyrics on lrclib.net (free, no API key) for one downloaded file,
# using the title/artist/album tags already embedded on it, and writes a
# sidecar .lrc file next to it with the same basename (e.g. Song_Artist.lrc
# next to Song_Artist.m4a). Navidrome (0.63+) reads these directly as long
# as LyricsPriority in its config includes ".lrc" — see the note printed at
# the end of the script. Never fails the batch; a missed lookup just means
# no lyrics for that one track.
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
        if out.returncode != 0 and out.stderr.strip():
            print(f"  ffprobe error reading '{tag}': {out.stderr.strip()}")
        return out.stdout.strip()
    except FileNotFoundError:
        print("  ffprobe not found on PATH")
        return ""
    except Exception as e:
        print(f"  ffprobe failed reading '{tag}': {e}")
        return ""

def ffprobe_all_tags():
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format_tags",
             "-of", "json", path],
            capture_output=True, text=True, timeout=10
        )
        return out.stdout.strip()
    except Exception as e:
        return f"(could not dump tags: {e})"

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
    print(f"  Skipping lyrics for {os.path.basename(path)}: missing title/artist tag")
    print(f"  Debug — title={title!r} artist={artist!r}")
    print(f"  Debug — full tag dump: {ffprobe_all_tags()}")
    sys.exit(0)

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "music-dl-script/1.0 (personal use)"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
            if resp.status != 200:
                print(f"  lrclib HTTP {resp.status} for {url}")
                return None
            return json.loads(body)
    except urllib.error.HTTPError as e:
        # lrclib returns 404 for "no match" on /api/get — expected/normal,
        # not worth alarming about, but printed anyway for full visibility.
        print(f"  lrclib HTTP {e.code} for {url}")
        return None
    except urllib.error.URLError as e:
        print(f"  lrclib network error: {e.reason} for {url}")
        return None
    except json.JSONDecodeError as e:
        print(f"  lrclib returned unparseable JSON: {e}")
        return None
    except Exception as e:
        print(f"  lrclib request failed: {type(e).__name__}: {e}")
        return None

lyrics = None
is_synced = False

print(f"  Looking up lyrics: title={title!r} artist={artist!r} album={album!r} duration={duration!r}")

# Exact match first: most reliable when title/artist/album/duration all
# line up with lrclib's database.
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

# Fuzzy fallback: helps when album is the constructed "Artist - Liked"
# placeholder (no real album metadata) or duration is slightly off from
# the official release.
if not lyrics:
    params = {"track_name": title, "artist_name": artist}
    data = fetch("https://lrclib.net/api/search?" + urllib.parse.urlencode(params))
    print(f"  Fallback search returned {len(data) if isinstance(data, list) else 0} result(s)")
    if isinstance(data, list) and data:
        best = data[0]
        if best.get("syncedLyrics"):
            lyrics, is_synced = best["syncedLyrics"], True
        elif best.get("plainLyrics"):
            lyrics, is_synced = best["plainLyrics"], False

if lyrics:
    # Navidrome's own web player only reliably shows lyrics embedded
    # directly in the file's tags — external .lrc/.txt sidecar files are
    # a real, still-open limitation of its web UI (they mainly work in
    # third-party Subsonic clients like Feishin/Symfonium, not the
    # built-in player). So embed the lyrics into the file itself via an
    # ffmpeg remux, and also drop the sidecar file for those third-party
    # clients that do read it.
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
        embedded = True
    else:
        embedded = False
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        print(f"  Warning: failed to embed lyrics into file tags: {embed.stderr.strip()[-300:]}")

    kind = "synced" if is_synced else "plain (unsynced)"
    where = "embedded + sidecar" if embedded else "sidecar only (embed failed)"
    print(f"  Lyrics found for {os.path.basename(path)} ({kind}, {where}: {os.path.basename(lyrics_path)})")
else:
    print(f"  No lyrics found for {os.path.basename(path)}")
PYEOF
}

# Downloads one batch (optionally restricted to a --playlist-items range)
# into its own staging dir, uploads it, then cleans up. Returns non-zero on
# failure so the caller can track which batches need a retry.
download_and_upload_batch() {
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
    --parse-metadata '%(artist,uploader,channel)s:%(artist)s' \
    "${LIKED_FALLBACK_ARGS[@]}" \
    --parse-metadata "$ALBUM_ARTIST_PARSE" \
    --parse-metadata "$ALBUM_PARSE" \
    --parse-metadata '%(track_number,playlist_index)s:%(track_number)s' \
    "${DATE_ARGS[@]}" \
    -o "$batch_dir/$OUTPUT_TEMPLATE" \
    "$URL"

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
  # nullglob so *.lrc simply contributes nothing if lyrics were skipped/not
  # found for every track in this batch, instead of scp erroring on a
  # literal unmatched glob.
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

FAILED_BATCHES=()

if [ -n "$SINGLE_TRACK" ]; then
  download_and_upload_batch || FAILED_BATCHES+=("single track")
else
  echo "Checking playlist size..."
  TOTAL_ITEMS=$(yt-dlp "${COOKIE_ARGS[@]}" --flat-playlist --playlist-items 1 --print '%(playlist_count)s' "$URL" 2>/dev/null | head -n1)

  if ! [[ "$TOTAL_ITEMS" =~ ^[0-9]+$ ]] || [ "$TOTAL_ITEMS" -le 0 ]; then
    echo "Could not determine playlist size — downloading as a single batch."
    download_and_upload_batch || FAILED_BATCHES+=("full playlist")
  else
    echo "Playlist has $TOTAL_ITEMS item(s) — downloading in batches of $BATCH_SIZE."
    START=1
    BATCH_NUM=1
    while [ "$START" -le "$TOTAL_ITEMS" ]; do
      END=$((START + BATCH_SIZE - 1))
      if [ "$END" -gt "$TOTAL_ITEMS" ]; then
        END="$TOTAL_ITEMS"
      fi
      echo ""
      echo "=== Batch $BATCH_NUM: items $START-$END of $TOTAL_ITEMS ==="
      if ! download_and_upload_batch --playlist-items "$START:$END"; then
        FAILED_BATCHES+=("$START:$END")
      fi
      START=$((END + 1))
      BATCH_NUM=$((BATCH_NUM + 1))
    done
  fi
fi

if [ -n "$FETCH_LYRICS" ]; then
  echo ""
  echo "Note: for Navidrome to actually display these .lrc files, your"
  echo "docker-compose.yml needs LyricsPriority set to include .lrc and .txt, e.g.:"
  echo "  ND_LYRICSPRIORITY: .lrc,.txt,embedded"
  echo "(Navidrome only checks embedded tags by default.)"
fi

echo ""
if [ "${#FAILED_BATCHES[@]}" -gt 0 ]; then
  echo "Done, but these batches had problems: ${FAILED_BATCHES[*]}"
  echo "Re-run with the same URL and -d, adding --playlist-items <range> to retry just those."
  exit 1
else
  echo "All batches completed and uploaded successfully!"
fi
