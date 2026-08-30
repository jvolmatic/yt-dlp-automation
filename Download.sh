#!/bin/bash

# Parse arguments for optional flags
SINGLE_TRACK=""
SUBDIR=""
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
  echo "Usage: $0 [--single|-s] [-d <subfolder>] <YouTube URL> [browser]"
  echo ""
  echo "Examples:"
  echo "  $0 'https://music.youtube.com/playlist?list=...' -d 'Albums/Kanye/BULLY'"
  echo "  $0 -s 'https://music.youtube.com/watch?v=...' -d 'Liked'"
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
  DATE_ARGS=(
    --parse-metadata '%(release_year|)s:%(date)s'
    --parse-metadata '%(release_year|)s:%(year)s'
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
  DATE_ARGS=(
    --parse-metadata '%(release_year,upload_date>%Y)s:%(date)s'
    --parse-metadata '%(release_year,upload_date>%Y)s:%(year)s'
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

# Batch size for large playlists. Downloading + uploading in smaller chunks
# keeps each yt-dlp run short (less time for YouTube cookies to rotate
# mid-run) and means a failure only costs you one batch, not the whole
# playlist — already-uploaded batches are safe either way.
BATCH_SIZE=50

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

  echo "Uploading batch to $FINAL_REMOTE_DIR..."
  if scp -o ControlPath="$SSH_CONTROL_PATH" "$batch_dir"/*.m4a "$REMOTE_SERVER:$FINAL_REMOTE_DIR/"; then
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

echo ""
if [ "${#FAILED_BATCHES[@]}" -gt 0 ]; then
  echo "Done, but these batches had problems: ${FAILED_BATCHES[*]}"
  echo "Re-run with the same URL and -d, adding --playlist-items <range> to retry just those."
  exit 1
else
  echo "All batches completed and uploaded successfully!"
fi
