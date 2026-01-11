#!/usr/bin/env zsh
#
# Enhanced git worktree list with colors and commit details.
# Can be used standalone or as a git alias:
#   git config --global alias.wt-list '!/path/to/git-worktree-list.sh'
#
# Usage: git-worktree-list.sh [git-dir]

set -euo pipefail

git_dir="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if ! git -C "$git_dir" rev-parse --git-dir &>/dev/null; then
    echo "Error: not a git repository: $git_dir" >&2
    exit 1
fi

# Build a map of resolved paths -> symlink paths for HOME subdirectories
typeset -A symlink_map
for item in "$HOME"/*(@N); do
    resolved="${item:A}"
    symlink_map[$resolved]="$item"
done

# Normalize path: prefer symlink paths and ~ for HOME
normalize_path() {
    local path="$1"
    # Try to replace resolved symlink targets with their symlink paths
    for resolved symlink in "${(@kv)symlink_map}"; do
        if [[ "$path" = "$resolved"/* || "$path" = "$resolved" ]]; then
            path="${symlink}${path#$resolved}"
            break
        fi
    done
    echo "$path"
}

worktrees=()
worktree_path="" branch="" sha="" timestamp="" title="" date_str=""

# Colors
C_PATH=$'\e[36m'      # cyan
C_BRANCH=$'\e[32m'    # green
C_SHA=$'\e[33m'       # yellow
C_DATE=$'\e[35m'      # magenta
C_TITLE=$'\e[0;2m'    # dim
C_RESET=$'\e[0m'

# Parse porcelain output
while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
        worktree_path="${match[1]}"
    elif [[ "$line" =~ ^HEAD\ ([a-f0-9]+)$ ]]; then
        sha="${match[1]}"
    elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
        branch="${match[1]}"
    elif [[ -z "$line" && -n "$worktree_path" ]]; then
        # End of entry
        if [[ -n "$sha" ]]; then
            timestamp=$(git -C "$worktree_path" log -1 --format="%ct" 2>/dev/null || echo "0")
            title=$(git -C "$worktree_path" log -1 --format="%s" 2>/dev/null || echo "")
            date_str=$(git -C "$worktree_path" log -1 --format="%cr" 2>/dev/null || echo "")
            display_path=$(normalize_path "$worktree_path")
            worktrees+=("${timestamp}	${C_PATH}${display_path}${C_RESET}	${C_BRANCH}${branch:-detached}${C_RESET}	${C_SHA}${sha:0:12}${C_RESET}	${C_DATE}${date_str}${C_RESET}	${C_TITLE}${title}${C_RESET}")
        fi
        worktree_path="" branch="" sha=""
    fi
done < <(git -C "$git_dir" worktree list --porcelain; echo "")

# Sort by timestamp (zsh array sorting) and print with column alignment
sorted=(${(O)worktrees})
printf '%s\n' "${sorted[@]}" | cut -f2- | column -t -s $'\t'
