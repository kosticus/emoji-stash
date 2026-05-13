#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") [--discord] [--slack] [file|directory]"
    echo ""
    echo "Verify images meet platform emoji requirements."
    echo "Default: checks both platforms. If a directory is given, checks all images in it."
    exit 1
}

# Platform constraints (verified from official docs, May 2026)
# Discord: docs.discord.com/developers/resources/emoji
# Slack:   slack.com/help/articles/206870177
DISCORD_MAX_BYTES=$((256 * 1024))
SLACK_MAX_BYTES=$((128 * 1024))
SLACK_MAX_GIF_FRAMES=50
RECOMMENDED_DIM=128

check_discord=false
check_slack=false
target=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --discord) check_discord=true; shift ;;
        --slack)   check_slack=true; shift ;;
        -h|--help) usage ;;
        *)         target="$1"; shift ;;
    esac
done

if ! $check_discord && ! $check_slack; then
    check_discord=true
    check_slack=true
fi

cd "$(dirname "$0")"
target="${target:-.}"

if [[ -f "$target" ]]; then
    files=("$target")
elif [[ -d "$target" ]]; then
    files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$target" -type f \( -iname "*.png" -o -iname "*.gif" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.avif" \) | sort -f)
else
    echo "Error: '$target' is not a file or directory"
    exit 1
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "No image files found."
    exit 0
fi

pass_count=0
fail_count=0
warn_count=0

for file in "${files[@]}"; do
    issues=()
    warnings=()
    ext="${file##*.}"
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    size=$(stat -f%z "$file")
    width=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/{print $2}')
    height=$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/{print $2}')

    if $check_discord; then
        case "$ext_lower" in
            png|jpg|jpeg|gif|webp|avif) ;;
            *) issues+=("[Discord] Unsupported format: .$ext_lower (need png/jpg/gif/webp/avif)") ;;
        esac
        if [[ $size -gt $DISCORD_MAX_BYTES ]]; then
            issues+=("[Discord] File too large: $(( size / 1024 ))KB (max 256KB)")
        fi
    fi

    if $check_slack; then
        case "$ext_lower" in
            png|jpg|jpeg|gif) ;;
            *) issues+=("[Slack] Unsupported format: .$ext_lower (need png/jpg/gif)") ;;
        esac
        if [[ $size -gt $SLACK_MAX_BYTES ]]; then
            issues+=("[Slack] File too large: $(( size / 1024 ))KB (max 128KB)")
        fi
    fi

    if [[ -n "$width" && -n "$height" ]]; then
        if [[ "$width" -ne "$height" ]]; then
            warnings+=("Not square: ${width}x${height} (recommend ${RECOMMENDED_DIM}x${RECOMMENDED_DIM})")
        fi
        if [[ "$width" -gt "$RECOMMENDED_DIM" || "$height" -gt "$RECOMMENDED_DIM" ]]; then
            warnings+=("Oversized: ${width}x${height} (recommend ${RECOMMENDED_DIM}x${RECOMMENDED_DIM})")
        fi
    fi

    if [[ "$ext_lower" == "gif" ]]; then
        frame_count=$(grep -c $'\x2c' "$file" 2>/dev/null || echo "?")
        if [[ "$frame_count" != "?" && "$frame_count" -gt 1 ]]; then
            warnings+=("Animated GIF (~${frame_count} frames)")
            if $check_slack && [[ "$frame_count" -gt "$SLACK_MAX_GIF_FRAMES" ]]; then
                issues+=("[Slack] Too many frames: ~${frame_count} (max ${SLACK_MAX_GIF_FRAMES})")
            fi
        fi
    fi

    name=$(basename "$file")
    if [[ ${#issues[@]} -gt 0 ]]; then
        echo "FAIL  $name"
        for issue in "${issues[@]}"; do
            echo "      $issue"
        done
        for w in "${warnings[@]}"; do
            echo "      (warning) $w"
        done
        fail_count=$((fail_count + 1))
    elif [[ ${#warnings[@]} -gt 0 ]]; then
        echo "WARN  $name"
        for w in "${warnings[@]}"; do
            echo "      $w"
        done
        warn_count=$((warn_count + 1))
    else
        echo "PASS  $name"
        pass_count=$((pass_count + 1))
    fi
done

echo ""
echo "--- Results: ${pass_count} passed, ${warn_count} warnings, ${fail_count} failed ---"
