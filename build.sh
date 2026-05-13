#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $(basename "$0") [--discord] [--slack] [--dry-run] [--clean]"
    echo ""
    echo "Build platform-ready emoji folders from originals/."
    echo "Mirrors folder structure and resizes to meet platform constraints."
    echo ""
    echo "  --discord   Build only the discord/ folder"
    echo "  --slack     Build only the slack/ folder"
    echo "  --dry-run   Preview what would be built without writing files"
    echo "  --clean     Remove platform folders before building"
    echo ""
    echo "Default: builds both discord/ and slack/."
    exit 1
}

# Platform constraints (verified from official docs, May 2026)
# Discord: docs.discord.com/developers/resources/emoji — 256KB, 128x128, png/jpg/gif/webp/avif
# Slack:   slack.com/help/articles/206870177 — 128KB, square, png/jpg/gif
DISCORD_MAX_BYTES=$((256 * 1024))
SLACK_MAX_BYTES=$((128 * 1024))
MAX_DIM=128

DISCORD_FORMATS="png|jpg|jpeg|gif|webp|avif"
SLACK_FORMATS="png|jpg|jpeg|gif"

build_discord=false
build_slack=false
dry_run=false
clean=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --discord)  build_discord=true; shift ;;
        --slack)    build_slack=true; shift ;;
        --dry-run)  dry_run=true; shift ;;
        --clean)    clean=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

if ! $build_discord && ! $build_slack; then
    build_discord=true
    build_slack=true
fi

if [[ ! -d "originals" ]]; then
    echo "Error: originals/ directory not found."
    echo "Drop your emoji and gif files in originals/ first."
    exit 1
fi

files=()
while IFS= read -r f; do
    files+=("$f")
done < <(find originals -type f \( -iname "*.png" -o -iname "*.gif" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.avif" \) | sort -f)

if [[ ${#files[@]} -eq 0 ]]; then
    echo "No image files found in originals/."
    exit 0
fi

is_animated_gif() {
    local file="$1"
    local ext="${file##*.}"
    [[ "$(echo "$ext" | tr '[:upper:]' '[:lower:]')" != "gif" ]] && return 1
    local frames
    frames=$(grep -c $'\x2c' "$file" 2>/dev/null || echo "1")
    [[ "$frames" -gt 1 ]]
}

build_for_platform() {
    local platform="$1"
    local outdir="$2"
    local max_bytes="$3"
    local formats="$4"

    echo "=== Building $platform/ ==="
    if $dry_run; then
        echo "(dry run)"
    fi
    echo ""

    if $clean && ! $dry_run; then
        rm -rf "$outdir"
    fi

    local built=0
    local skipped=0
    local warnings=0

    for file in "${files[@]}"; do
        local rel="${file#originals/}"
        local name
        name=$(basename "$file")
        local ext="${file##*.}"
        local ext_lower
        ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        local dest="$outdir/$rel"
        local dest_dir
        dest_dir=$(dirname "$dest")

        if ! echo "$ext_lower" | grep -qiE "^($formats)$"; then
            echo "SKIP  $rel — .$ext_lower not supported on $platform"
            skipped=$((skipped + 1))
            continue
        fi

        if is_animated_gif "$file"; then
            if ! $dry_run; then
                mkdir -p "$dest_dir"
                cp "$file" "$dest"
            fi
            local size
            size=$(stat -f%z "$file")
            if [[ $size -gt $max_bytes ]]; then
                echo "WARN  $rel — animated GIF copied as-is ($(( size / 1024 ))KB, over limit)"
                echo "      Cannot resize animated GIFs with sips — use gifsicle"
                warnings=$((warnings + 1))
            else
                echo "COPY  $rel — animated GIF ($(( size / 1024 ))KB)"
            fi
            built=$((built + 1))
            continue
        fi

        local width height
        width=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/{print $2}')
        height=$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/{print $2}')
        local needs_resize=false

        if [[ -n "$width" && -n "$height" ]]; then
            if [[ "$width" -gt "$MAX_DIM" || "$height" -gt "$MAX_DIM" ]]; then
                needs_resize=true
            fi
        fi

        if $dry_run; then
            if $needs_resize; then
                echo "WOULD $rel — resize ${width}x${height} -> fit ${MAX_DIM}x${MAX_DIM}"
            else
                echo "WOULD $rel — copy as-is (${width}x${height})"
            fi
        else
            mkdir -p "$dest_dir"
            cp "$file" "$dest"
            if $needs_resize; then
                sips -Z "$MAX_DIM" "$dest" >/dev/null 2>&1
                local new_w new_h new_size
                new_w=$(sips -g pixelWidth "$dest" 2>/dev/null | awk '/pixelWidth/{print $2}')
                new_h=$(sips -g pixelHeight "$dest" 2>/dev/null | awk '/pixelHeight/{print $2}')
                new_size=$(stat -f%z "$dest")
                echo "BUILT $rel — ${width}x${height} -> ${new_w}x${new_h} ($(( new_size / 1024 ))KB)"
                if [[ $new_size -gt $max_bytes ]]; then
                    echo "      Still over ${platform} size limit — consider compressing"
                    warnings=$((warnings + 1))
                fi
            else
                local size
                size=$(stat -f%z "$dest")
                if [[ $size -gt $max_bytes ]]; then
                    echo "COPY  $rel — ${width}x${height} but $(( size / 1024 ))KB exceeds limit"
                    warnings=$((warnings + 1))
                else
                    echo "COPY  $rel — ${width}x${height} ($(( size / 1024 ))KB)"
                fi
            fi
        fi
        built=$((built + 1))
    done

    echo ""
    echo "  $built built, $skipped skipped, $warnings warnings"
    echo ""
}

if $build_discord; then
    build_for_platform "discord" "discord" "$DISCORD_MAX_BYTES" "$DISCORD_FORMATS"
fi

if $build_slack; then
    build_for_platform "slack" "slack" "$SLACK_MAX_BYTES" "$SLACK_FORMATS"
fi
