# Worktree helper functions - source this file in your shell config.

_WORKTREE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" &>/dev/null && pwd)"
_WORKTREE_KNOWN_PROJECTS=$("${_WORKTREE_SCRIPT_DIR}/worktree.sh" projects)

_wt_is_project() {
    echo "$_WORKTREE_KNOWN_PROJECTS" | grep -qx "$1"
}

wt() {
    local project=""

    # Check for optional project flag.
    if _wt_is_project "${1:-}"; then
        project="$1"
        shift
    fi

    local cmd="${1:-}"

    case "$cmd" in
        br)
            shift
            local dir
            dir=$("${_WORKTREE_SCRIPT_DIR}/worktree.sh" $project "$@" list | fzf --ansi | awk '{print $1}')
            [[ -n "$dir" ]] && cd "$dir"
            ;;
        root)
            shift
            local root_dir
            root_dir=$("${_WORKTREE_SCRIPT_DIR}/worktree.sh" $project "$@" root) && cd "$root_dir"
            ;;
        *)
            "${_WORKTREE_SCRIPT_DIR}/worktree.sh" $project "$@"
            ;;
    esac
}
