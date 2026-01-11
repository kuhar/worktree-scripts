#!/usr/bin/env zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"

# =============================================================================
# Project Configuration
# To add a new project, append to this array: PROJECT_NAME ROOT_DIR
# =============================================================================
typeset -A PROJECTS
PROJECTS=(
    iree "$HOME/iree"
    llvm "$HOME/llvm"
)

# =============================================================================
# Helper Functions
# =============================================================================

# List all known project names
list_projects() {
    printf '%s\n' "${(k)PROJECTS[@]}"
}

# Check if a string is a known project name
is_project() {
    [[ -n "${PROJECTS[$1]:-}" ]]
}

# Get project root directory
get_project_root() {
    echo "${PROJECTS[$1]}"
}

# Get project worktree script
get_project_script() {
    echo "${SCRIPT_DIR}/$1/$1-worktree.sh"
}

# Detect project from current working directory
detect_project() {
    local cwd="${PWD:A}"
    for proj in "${(k)PROJECTS[@]}"; do
        local root="${PROJECTS[$proj]:A}"
        if [[ "$cwd" = "$root"/* || "$cwd" = "$root" ]]; then
            echo "$proj"
            return
        fi
    done
}

usage() {
    local proj_list="${(j:|:)${(k)PROJECTS[@]}}"
    echo "Usage: $0 [${proj_list}] <command> [args...]"
    echo ""
    echo "Dispatches to project-specific worktree scripts based on current directory."
    echo ""
    echo "Projects: ${(j:, :)${(k)PROJECTS[@]}}"
    echo ""
    echo "Commands:"
    echo "  projects                List known projects"
    echo "  root                    Print project root directory"
    echo "  create <branch> [name]  Create a new worktree"
    echo "  remove <branch|path>    Remove an existing worktree"
    echo "  setup <root>            Set up build environment for a worktree"
    echo "  list                    List all worktrees"
    echo "  <other>                 Passed through to 'git worktree <other>'"
}

# =============================================================================
# Main
# =============================================================================

# Handle 'projects' command before project detection
if [[ "${1:-}" == "projects" ]]; then
    list_projects
    exit 0
fi

# Check for explicit project flag
project=""
if [[ $# -ge 1 ]] && is_project "$1"; then
    project="$1"
    shift
fi

# Auto-detect if not explicitly set
if [[ -z "$project" ]]; then
    project=$(detect_project)
fi

if [[ -z "$project" ]]; then
    echo "Error: Could not detect project from current directory."
    echo "Run from within a project directory, or specify: ${(j:, :)${(k)PROJECTS[@]}}"
    echo ""
    usage
    exit 1
fi

# Handle built-in commands
case "${1:-}" in
    root)
        get_project_root "$project"
        exit 0
        ;;
esac

# Dispatch to project-specific script
exec "$(get_project_script "$project")" "$@"
