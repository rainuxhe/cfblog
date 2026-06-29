#!/bin/bash

set -euo pipefail

main() {
    local is_exist_hugo=$(command -v hugo > /dev/null; echo $?)
    if [ $is_exist_hugo -ne 0 ]; then
        echo "hugo command not found, please install hugo first."
        exit 1
    fi

    local title="${1:-}"
    if [ -z "$title" ]; then
        echo "Please provide a title for the new post."
        exit 1
    fi

    local year=$(date +%Y)
    local month=$(date +%m)
    local post_dir="post/$year/$month/$title/index.zh.md"

    hugo new $post_dir
    # 如果要添加多语言, 手动添加相应文件, 如 $title/index.zh.md, $title/index.en.md 等
}

main "$@"