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

# Construct final remote target path
if [ -n "$SUBDIR" ]; then
  CLEAN_SUBDIR=$(echo "$SUBDIR" | sed 's|^/||;s|/$||')
  FINAL_REMOTE_DIR="$BASE_REMOTE_DIR/$CLEAN_SUBDIR"
else
  FINAL_REMOTE_DIR="$BASE_REMOTE_DIR"
fi

# Determine album tagging based on mode (Single/Liked track vs Full Album/Playlist)
if [ -n "$SINGLE_TRACK" ]; then
  ALBUM_PARSE="%(artist,uploader,channel)s - Liked:%(album)s"
  # Don't embed a per-track release year here. Navidrome's default album
  # grouping (PID.Album) falls back to artist+album+releasedate when there's
  # no MusicBrainz ID, so if every "Liked" track carries its own real upload
  # year, tracks with the same "Artist - Liked" album name end up split into
  # a separate album per year. Leaving date/year unset keeps it consistent
  # (empty) across all Liked tracks so they group into one album.
  DATE_ARGS=()
else
  # Covers both full albums (-d "Albums/...") and playlists (-d "Playlists/...").
  ALBUM_PARSE="%(playlist_title,title)s:%(album)s"
  DATE_ARGS=(
    --parse-metadata '%(release_year,upload_date>%Y)s:%(date)s'
    --parse-metadata '%(release_year,upload_date>%Y)s:%(year)s'
  )
fi

# Human-readable filename for every mode (single, album, or playlist).
# Navidrome reads track order/album/artist from the embedded ID3 tags above,
# not from the filename, so this is safe everywhere.
OUTPUT_TEMPLATE="%(title)s_%(artist)s.%(ext)s"

# Create a clean temporary directory for this download batch
STAGING_DIR=$(mktemp -d -t music_dl_XXXXXX)

echo "Downloading track/playlist locally using cookies from $BROWSER..."

# 1. Download into the temporary staging directory with clean metadata rules
yt-dlp \
  -x \
  -f 'ba[ext=m4a]' \
  $SINGLE_TRACK \
  --cookies-from-browser "$BROWSER" \
  --embed-metadata \
  --embed-thumbnail \
  --parse-metadata '%(artist,uploader,channel)s:%(artist)s' \
  --parse-metadata '%(playlist_uploader,uploader,channel)s:%(album_artist)s' \
  --parse-metadata "$ALBUM_PARSE" \
  --parse-metadata '%(track_number,playlist_index)s:%(track_number)s' \
  "${DATE_ARGS[@]}" \
  -o "$STAGING_DIR/$OUTPUT_TEMPLATE" \
  "$URL"

# 2. Ensure remote destination directory exists and upload files
if compgen -G "$STAGING_DIR/*.m4a" > /dev/null; then
  echo "Ensuring remote folder '$FINAL_REMOTE_DIR' exists..."
  ssh "$REMOTE_SERVER" "mkdir -p '$FINAL_REMOTE_DIR'"

  echo "Uploading downloaded file(s) to $FINAL_REMOTE_DIR..."
  scp "$STAGING_DIR"/*.m4a "$REMOTE_SERVER:$FINAL_REMOTE_DIR/"

  if [ $? -eq 0 ]; then
    echo "Upload successful. Cleaning up temporary local files..."
    rm -rf "$STAGING_DIR"
    echo "Done!"
  else
    echo "Upload failed! Local files saved in: $STAGING_DIR"
  fi
else
  echo "Error: No .m4a files were downloaded."
  rm -rf "$STAGING_DIR"
fi
