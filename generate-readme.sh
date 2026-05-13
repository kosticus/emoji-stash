#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

readme="# Emoji Stash

My collection of emojis and gifs for Discord and Slack.

## Usage

1. Drop original images into \`originals/\` (use subfolders to categorize)
2. Run \`./build.sh\` to generate platform-ready versions in \`discord/\` and \`slack/\`
3. Run \`./generate-readme.sh\` to update this README
4. Run \`./verify.sh discord/\` or \`./verify.sh slack/\` to check constraints
"

has_images=false
image_filter='\( -iname "*.png" -o -iname "*.gif" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.avif" \)'

title_case() {
    echo "$1" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1'
}

render_grid() {
    local dir="$1"
    local files=()

    while IFS= read -r file; do
        files+=("$file")
        has_images=true
    done < <(eval "find \"$dir\" -maxdepth 1 -type f $image_filter" | sort -f)

    [ ${#files[@]} -eq 0 ] && return 1

    local cols=6
    local col=0

    # Build header row
    local header="|"
    local separator="|"
    for (( i=0; i<cols; i++ )); do
        header+=" |"
        separator+=":---:|"
    done

    local current_header="$header"
    local current_sep="$separator"
    local current_row="|"
    local need_table_start=true

    for file in "${files[@]}"; do
        name=$(basename "$file")
        label="${name%.*}"

        if $need_table_start; then
            readme+="
${current_header}
${current_sep}"
            need_table_start=false
        fi

        current_row+=" ![${label}](${file}) |"
        col=$((col + 1))

        if [[ $col -ge $cols ]]; then
            readme+="
${current_row}"
            current_row="|"
            col=0
        fi
    done

    # Flush remaining cells
    if [[ $col -gt 0 ]]; then
        while [[ $col -lt $cols ]]; do
            current_row+=" |"
            col=$((col + 1))
        done
        readme+="
${current_row}"
    fi

    readme+="
"
    return 0
}

if [[ -d "originals" ]]; then
    # Top-level images in originals/
    top_count=0
    while IFS= read -r f; do
        top_count=$((top_count + 1))
    done < <(eval "find originals -maxdepth 1 -type f $image_filter" 2>/dev/null || true)

    if [[ "$top_count" -gt 0 ]]; then
        readme+="
## Uncategorized
"
        render_grid "originals"
    fi

    # Subdirectories in originals/
    while IFS= read -r dir; do
        dirname=$(basename "$dir")
        [[ "$dirname" == .* ]] && continue

        heading=$(title_case "$dirname")
        readme+="
## $heading
"
        render_grid "$dir" || readme="${readme%## $heading
}"
    done < <(find originals -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort -f)
fi

if [ "$has_images" = false ]; then
    readme+="
*No images yet. Drop some emojis or gifs into \`originals/\` and run \`./generate-readme.sh\`.*
"
fi

printf '%s\n' "$readme" > README.md
count=$(grep -o '!\[' README.md 2>/dev/null | wc -l | tr -d ' ')
echo "README.md generated ($count images)"
