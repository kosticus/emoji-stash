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
# Slack:   slack.com/help/articles/206870177 — 128KB, square, png/jpg/gif, max 50 frames
DISCORD_MAX_BYTES=$((256 * 1024))
SLACK_MAX_BYTES=$((128 * 1024))
SLACK_MAX_FRAMES=50
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

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

is_animated_gif() {
    local file="$1"
    local ext="${file##*.}"
    [[ "$(echo "$ext" | tr '[:upper:]' '[:lower:]')" != "gif" ]] && return 1
    local frames
    frames=$(grep -c $'\x2c' "$file" 2>/dev/null || echo "1")
    [[ "$frames" -gt 1 ]]
}

gif_frame_count() {
    gifsicle --info "$1" 2>/dev/null | awk '/^[*]/{print $3}'
}

gif_dimensions() {
    gifsicle --info "$1" 2>/dev/null | awk '/logical screen/{print $3}'
}

# ── Phase 1: Scan for problem GIFs ──

scan_platform() {
    local platform="$1"
    local max_bytes="$2"
    local max_frames="$3"
    local formats="$4"
    local problems_file="$tmpdir/problems_${platform}"

    for file in "${files[@]}"; do
        local ext="${file##*.}"
        local ext_lower
        ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

        if ! echo "$ext_lower" | grep -qiE "^($formats)$"; then
            continue
        fi

        if ! is_animated_gif "$file"; then
            continue
        fi

        local rel="${file#originals/}"
        local size
        size=$(stat -f%z "$file")
        local frame_count
        frame_count=$(gif_frame_count "$file")
        local dims
        dims=$(gif_dimensions "$file")

        local over_size=false
        local over_frames=false

        if [[ $size -gt $max_bytes ]]; then
            over_size=true
        fi
        if [[ "$max_frames" -gt 0 && "$frame_count" -gt "$max_frames" ]]; then
            over_frames=true
        fi

        if ! $over_size && ! $over_frames; then
            continue
        fi

        echo "$rel|$size|$frame_count|$dims|$over_size|$over_frames" >> "$problems_file"
    done
}

compute_options() {
    local file="$1"
    local max_bytes="$2"
    local options_file="$3"
    local preview_dir="$4"

    mkdir -p "$preview_dir"
    cp "$file" "$preview_dir/original.gif"

    local frame_count
    frame_count=$(gif_frame_count "$file")

    # Option A: lossy compression only
    gifsicle -O3 --lossy=80 "$file" -o "$preview_dir/a.gif" 2>/dev/null
    local size_a
    size_a=$(stat -f%z "$preview_dir/a.gif")
    local fc_a=$frame_count
    echo "a|Lossy compression only|${fc_a} frames, $(( size_a / 1024 ))KB|$size_a|$fc_a" >> "$options_file"

    # Option B: drop every other frame (no lossy)
    local half_frames
    half_frames=$(seq 0 2 $((frame_count - 1)) | sed 's/^/#/')
    gifsicle "$file" $half_frames -O3 -o "$preview_dir/b.gif" 2>/dev/null
    local size_b
    size_b=$(stat -f%z "$preview_dir/b.gif")
    local fc_b
    fc_b=$(gif_frame_count "$preview_dir/b.gif")
    echo "b|Drop every other frame|${fc_b} frames, $(( size_b / 1024 ))KB|$size_b|$fc_b" >> "$options_file"

    # Option C: drop every other frame + lossy
    gifsicle "$file" $half_frames -O3 --lossy=80 -o "$preview_dir/c.gif" 2>/dev/null
    local size_c
    size_c=$(stat -f%z "$preview_dir/c.gif")
    local fc_c
    fc_c=$(gif_frame_count "$preview_dir/c.gif")
    echo "c|Drop every other frame + lossy|${fc_c} frames, $(( size_c / 1024 ))KB|$size_c|$fc_c" >> "$options_file"

    # Option D: every 3rd frame + lossy
    local third_frames
    third_frames=$(seq 0 3 $((frame_count - 1)) | sed 's/^/#/')
    gifsicle "$file" $third_frames -O3 --lossy=80 -o "$preview_dir/d.gif" 2>/dev/null
    local size_d
    size_d=$(stat -f%z "$preview_dir/d.gif")
    local fc_d
    fc_d=$(gif_frame_count "$preview_dir/d.gif")
    echo "d|Every 3rd frame + lossy|${fc_d} frames, $(( size_d / 1024 ))KB|$size_d|$fc_d" >> "$options_file"

    echo "s|Skip — don't include|n/a|0|0" >> "$options_file"
}

generate_preview_html() {
    local rel="$1"
    local preview_dir="$2"
    local options_file="$3"
    local max_bytes="$4"
    local max_frames="$5"
    local html_file="$preview_dir/preview.html"

    local name
    name=$(basename "$rel")
    local orig_size orig_fc
    orig_size=$(stat -f%z "$preview_dir/original.gif")
    orig_fc=$(gif_frame_count "$preview_dir/original.gif")

    cat > "$html_file" <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
<title>Preview: $name</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, system-ui, sans-serif; background: #1a1a2e; color: #eee; padding: 24px; }
  h1 { font-size: 18px; margin-bottom: 4px; }
  .subtitle { color: #999; font-size: 13px; margin-bottom: 24px; }
  .grid { display: flex; flex-wrap: wrap; gap: 20px; }
  .card {
    background: #16213e; border-radius: 12px; padding: 16px; text-align: center;
    border: 2px solid transparent; min-width: 180px; flex: 1;
  }
  .card.original { border-color: #555; }
  .card.fits { border-color: #4ade80; }
  .card.over { border-color: #f87171; }
  .card img { image-rendering: pixelated; width: 128px; height: 128px; object-fit: contain; margin-bottom: 12px; background: #0f0f23; border-radius: 8px; padding: 8px; }
  .label { font-weight: 600; font-size: 14px; margin-bottom: 6px; }
  .detail { font-size: 12px; color: #999; }
  .badge { display: inline-block; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 4px; margin-top: 6px; }
  .badge.fits { background: #166534; color: #4ade80; }
  .badge.over { background: #7f1d1d; color: #f87171; }
  .badge.orig { background: #333; color: #999; }
  .key { font-size: 22px; font-weight: 700; color: #818cf8; margin-bottom: 4px; }
  .hint { text-align: center; color: #666; font-size: 13px; margin-top: 20px; }
</style>
</head>
<body>
<h1>$name</h1>
<div class="subtitle">Choose a compression option in the terminal</div>
<div class="grid">
  <div class="card original">
    <div class="label">Original</div>
    <img src="original.gif">
    <div class="detail">${orig_fc} frames &middot; $(( orig_size / 1024 ))KB</div>
    <span class="badge orig">source</span>
  </div>
HTMLEOF

    while IFS='|' read -r key label detail size_val fc_val; do
        [[ "$key" == "s" ]] && continue
        local status="fits"
        if [[ $size_val -gt $max_bytes ]] || { [[ "$max_frames" -gt 0 ]] && [[ "$fc_val" -gt "$max_frames" ]]; }; then
            status="over"
        fi
        local badge_text="fits"
        [[ "$status" == "over" ]] && badge_text="over limit"

        cat >> "$html_file" <<CARDEOF
  <div class="card $status">
    <div class="key">$key</div>
    <div class="label">$label</div>
    <img src="${key}.gif">
    <div class="detail">${detail}</div>
    <span class="badge $status">$badge_text</span>
  </div>
CARDEOF
    done < "$options_file"

    cat >> "$html_file" <<'TAILEOF'
</div>
<div class="hint">Return to the terminal to enter your choice</div>
</body>
</html>
TAILEOF
}

# ── Phase 2: Present problems and prompt ──

prompt_for_problems() {
    local platform="$1"
    local max_bytes="$2"
    local max_frames="$3"
    local problems_file="$tmpdir/problems_${platform}"
    local choices_file="$tmpdir/choices_${platform}"

    if [[ ! -f "$problems_file" ]]; then
        return
    fi

    local count
    count=$(wc -l < "$problems_file" | tr -d ' ')
    echo ""
    echo "=== ${count} problem GIF(s) for ${platform}/ ==="
    echo ""

    while IFS='|' read -r rel size frame_count dims over_size over_frames; do
        local issues=""
        if $over_size; then
            issues="$(( size / 1024 ))KB > $(( max_bytes / 1024 ))KB"
        fi
        if $over_frames; then
            [[ -n "$issues" ]] && issues+=", "
            issues+="${frame_count} frames > ${max_frames} max"
        fi

        echo "  $rel ($dims, $issues)"
        echo ""

        local safe_name
        safe_name=$(echo "$rel" | tr '/' '_')
        local options_file="$tmpdir/options_${platform}_${safe_name}"
        local preview_dir="$tmpdir/preview_${platform}_${safe_name}"
        echo -n "  Computing options... "
        compute_options "originals/$rel" "$max_bytes" "$options_file" "$preview_dir"
        echo "done"
        echo ""

        while IFS='|' read -r key label detail size_val fc_val; do
            local marker=" "
            if [[ "$key" != "s" ]]; then
                if [[ $size_val -le $max_bytes ]] && [[ "$max_frames" -eq 0 || "$fc_val" -le "$max_frames" ]]; then
                    marker="*"
                else
                    marker="!"
                fi
            fi
            printf "    %s %s) %s — %s\n" "$marker" "$key" "$label" "$detail"
        done < "$options_file"

        echo ""
        echo "    (* = fits constraints, ! = still over)"
        echo ""

        if $dry_run; then
            echo "    (dry run — skipping prompt)"
            echo "$rel|s" >> "$choices_file"
        else
            generate_preview_html "$rel" "$preview_dir" "$options_file" "$max_bytes" "$max_frames"
            open "$preview_dir/preview.html" 2>/dev/null
            echo "    Preview opened in browser."
            echo ""
            local choice=""
            while true; do
                read -rp "    Choose [a/b/c/d/s]: " choice < /dev/tty
                if [[ "$choice" =~ ^[abcds]$ ]]; then
                    break
                fi
                echo "    Invalid choice. Enter a, b, c, d, or s."
            done
            echo "$rel|$choice" >> "$choices_file"
            echo ""
        fi
    done < "$problems_file"
}

# ── Phase 3: Build ──

get_choice() {
    local platform="$1"
    local rel="$2"
    local choices_file="$tmpdir/choices_${platform}"

    if [[ ! -f "$choices_file" ]]; then
        echo ""
        return
    fi

    { grep "^${rel}|" "$choices_file" 2>/dev/null || true; } | tail -1 | cut -d'|' -f2
}

apply_gif_choice() {
    local file="$1"
    local dest="$2"
    local choice="$3"

    local frame_count
    frame_count=$(gif_frame_count "$file")

    case "$choice" in
        a)
            gifsicle -O3 --lossy=80 "$file" -o "$dest" 2>/dev/null
            ;;
        b)
            local frames
            frames=$(seq 0 2 $((frame_count - 1)) | sed 's/^/#/')
            gifsicle "$file" $frames -O3 -o "$dest" 2>/dev/null
            ;;
        c)
            local frames
            frames=$(seq 0 2 $((frame_count - 1)) | sed 's/^/#/')
            gifsicle "$file" $frames -O3 --lossy=80 -o "$dest" 2>/dev/null
            ;;
        d)
            local frames
            frames=$(seq 0 3 $((frame_count - 1)) | sed 's/^/#/')
            gifsicle "$file" $frames -O3 --lossy=80 -o "$dest" 2>/dev/null
            ;;
    esac
}

build_for_platform() {
    local platform="$1"
    local outdir="$2"
    local max_bytes="$3"
    local formats="$4"

    echo "=== Building $platform/ ==="
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
            local orig_size
            orig_size=$(stat -f%z "$file")
            local gif_w gif_h
            gif_w=$(gifsicle --info "$file" 2>/dev/null | awk '/logical screen/{print $3}' | cut -dx -f1)
            gif_h=$(gifsicle --info "$file" 2>/dev/null | awk '/logical screen/{print $3}' | cut -dx -f2)
            local gif_needs_resize=false
            if [[ -n "$gif_w" && -n "$gif_h" ]] && [[ "$gif_w" -gt "$MAX_DIM" || "$gif_h" -gt "$MAX_DIM" ]]; then
                gif_needs_resize=true
            fi

            local choice
            choice=$(get_choice "$platform" "$rel")

            if [[ "$choice" == "s" ]]; then
                echo "SKIP  $rel — user chose to skip"
                skipped=$((skipped + 1))
                continue
            fi

            if $dry_run; then
                if $gif_needs_resize; then
                    echo "WOULD $rel — animated GIF resize ${gif_w}x${gif_h} -> fit ${MAX_DIM}x${MAX_DIM}"
                elif [[ -n "$choice" ]]; then
                    echo "WOULD $rel — animated GIF (choice pending)"
                else
                    echo "WOULD $rel — animated GIF copy as-is (${gif_w}x${gif_h}, $(( orig_size / 1024 ))KB)"
                fi
                built=$((built + 1))
                continue
            fi

            mkdir -p "$dest_dir"

            if [[ -n "$choice" ]]; then
                apply_gif_choice "$file" "$dest" "$choice"
                if $gif_needs_resize; then
                    gifsicle --resize-fit "${MAX_DIM}x${MAX_DIM}" -O3 "$dest" -o "$dest" 2>/dev/null
                fi
                local new_size new_fc
                new_size=$(stat -f%z "$dest")
                new_fc=$(gif_frame_count "$dest")
                local orig_fc
                orig_fc=$(gif_frame_count "$file")
                echo "BUILT $rel — ${orig_fc}f -> ${new_fc}f ($(( orig_size / 1024 ))KB -> $(( new_size / 1024 ))KB)"
            elif $gif_needs_resize; then
                gifsicle --resize-fit "${MAX_DIM}x${MAX_DIM}" -O3 "$file" -o "$dest" 2>/dev/null
                local new_size
                new_size=$(stat -f%z "$dest")
                local new_gw new_gh
                new_gw=$(gifsicle --info "$dest" 2>/dev/null | awk '/logical screen/{print $3}' | cut -dx -f1)
                new_gh=$(gifsicle --info "$dest" 2>/dev/null | awk '/logical screen/{print $3}' | cut -dx -f2)
                echo "BUILT $rel — animated GIF ${gif_w}x${gif_h} -> ${new_gw}x${new_gh} ($(( new_size / 1024 ))KB)"
            else
                cp "$file" "$dest"
                echo "COPY  $rel — animated GIF (${gif_w}x${gif_h}, $(( orig_size / 1024 ))KB)"
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

# ── Run ──

echo "=== Scanning for problem GIFs ==="

if $build_discord; then
    scan_platform "discord" "$DISCORD_MAX_BYTES" 0 "$DISCORD_FORMATS"
fi
if $build_slack; then
    scan_platform "slack" "$SLACK_MAX_BYTES" "$SLACK_MAX_FRAMES" "$SLACK_FORMATS"
fi

has_problems=false
if [[ -f "$tmpdir/problems_discord" ]] || [[ -f "$tmpdir/problems_slack" ]]; then
    has_problems=true
fi

if $has_problems; then
    if $build_discord && [[ -f "$tmpdir/problems_discord" ]]; then
        prompt_for_problems "discord" "$DISCORD_MAX_BYTES" 0
    fi
    if $build_slack && [[ -f "$tmpdir/problems_slack" ]]; then
        prompt_for_problems "slack" "$SLACK_MAX_BYTES" "$SLACK_MAX_FRAMES"
    fi
else
    echo "No problems found — all GIFs fit within constraints."
fi

echo ""

if $build_discord; then
    build_for_platform "discord" "discord" "$DISCORD_MAX_BYTES" "$DISCORD_FORMATS"
fi

if $build_slack; then
    build_for_platform "slack" "slack" "$SLACK_MAX_BYTES" "$SLACK_FORMATS"
fi
