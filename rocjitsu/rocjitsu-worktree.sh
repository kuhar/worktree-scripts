#!/usr/bin/env zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0:A}"
REPO_DIR="rocm-systems"
ROCJITSUS="$HOME/rocjitsu"
ROCJITSU_DEFAULT_BRANCH="develop"
MAIN_ROCJITSU_ROOT="$ROCJITSUS/develop"
MAIN_ROCJITSU="$MAIN_ROCJITSU_ROOT/$REPO_DIR"
ROCJITSU_SOURCE_REL="$REPO_DIR/emulation/rocjitsu"

check_main_rocjitsu() {
    if [[ ! -d $MAIN_ROCJITSU ]]; then
        echo "No main RocJITsu repository in the expected place: $MAIN_ROCJITSU"
        exit 1
    fi

    local branch
    branch=$(git -C "$MAIN_ROCJITSU" branch --show-current 2>/dev/null || true)
    if [[ -n "$branch" && "$branch" != "$ROCJITSU_DEFAULT_BRANCH" ]]; then
        echo "Expected RocJITsu main state at $MAIN_ROCJITSU to be on $ROCJITSU_DEFAULT_BRANCH; found $branch"
        exit 1
    fi
}

usage() {
    echo "Usage: $SCRIPT_NAME <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  create <branch> [name]  Create a new worktree"
    echo "  remove <branch|path>    Remove an existing worktree"
    echo "  setup <root>            Set up build environment for a worktree"
    echo "  build [root|name]       Configure and build a worktree"
    echo "  list                    List worktrees with commit details"
    echo "  <other>                 Passed through to 'git worktree <other>'"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME create my-feature"
    echo "  $SCRIPT_NAME remove my-feature"
    echo "  $SCRIPT_NAME list"
}

link_cmake_presets() {
    local cmake_root="$1"
    [[ -a "$cmake_root/CMakePresets.json" ]] || ln -s "${SCRIPT_DIR}/CMakePresets.json" "$cmake_root/"
}

resolve_worktree_root() {
    local query="${1:-}"
    local candidate=""

    if [[ -z "$query" ]]; then
        local cwd="${PWD:A}"
        if [[ "$cwd" == "$ROCJITSUS" ]]; then
            echo "Error: run from a RocJITsu worktree, or pass a worktree root/name." >&2
            return 1
        elif [[ "$cwd" == "$ROCJITSUS"/* ]]; then
            local rel="${cwd#$ROCJITSUS/}"
            candidate="$ROCJITSUS/${rel%%/*}"
        else
            echo "Error: could not infer RocJITsu worktree from $cwd; pass a worktree root/name." >&2
            return 1
        fi
    elif [[ -f "$ROCJITSUS/$query/$ROCJITSU_SOURCE_REL/CMakeLists.txt" ]]; then
        candidate="$ROCJITSUS/$query"
    else
        candidate="${query:A}"
        if [[ -f "$candidate/CMakeLists.txt" && "$candidate" == */"$ROCJITSU_SOURCE_REL" ]]; then
            candidate="${candidate:h:h:h}"
        elif [[ -f "$candidate/emulation/rocjitsu/CMakeLists.txt" ]]; then
            candidate="${candidate:h}"
        fi
    fi

    if [[ ! -f "$candidate/$ROCJITSU_SOURCE_REL/CMakeLists.txt" ]]; then
        echo "Error: expected $candidate/$ROCJITSU_SOURCE_REL to be a RocJITsu checkout." >&2
        return 1
    fi

    echo "$candidate"
}

copy_main_worktree_state() {
    local worktree_root="$1"
    local main_root="$MAIN_ROCJITSU_ROOT"
    for item in marks.md .claude .cursor .peanut-review.json; do
        [[ -e "$main_root/$item" ]] && cp -r "$main_root/$item" "$worktree_root/$item"
    done
}

setup_worktree_environment() {
    local worktree_root="$1"
    local cmake_root="$worktree_root/$ROCJITSU_SOURCE_REL"

    link_cmake_presets "$cmake_root"

    echo "Setting up environment ..."
    cmd_setup "$worktree_root"
    copy_main_worktree_state "$worktree_root"
}

cmd_setup() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $SCRIPT_NAME setup <root directory>"
        exit 1
    fi

    local root_dir="$1"
    local cmake_root="$root_dir/$ROCJITSU_SOURCE_REL"
    if [[ ! -f "$cmake_root/CMakeLists.txt" ]]; then
        echo "Error: expected $root_dir/$ROCJITSU_SOURCE_REL to be a RocJITsu checkout"
        exit 1
    fi

    pushd "$root_dir"

    local build_dir="$root_dir/build"
    mkdir -p "$build_dir"
    link_cmake_presets "$cmake_root"

    echo "export CCACHE_BASEDIR=\"$root_dir\"" > .envrc
    echo "export CCACHE_NOHASHDIR=true" >> .envrc
    echo "export RJ_BUILD_DIR=\"$build_dir\"" >> .envrc
    echo "PATH_add \"$build_dir/bin\"" >> .envrc
    echo "PATH_add \"$build_dir/tests\"" >> .envrc

    ln -sf "$build_dir/compile_commands.json" "$root_dir/compile_commands.json"

    direnv allow "$root_dir" || echo "Warning: direnv allow failed; run 'direnv allow $root_dir' from a writable shell if needed."
    echo "Set up RocJITsu build environment in $root_dir"
    echo "Configure with: (cd $cmake_root && cmake --preset default)"

    popd
}

cmd_build() {
    if [[ $# -gt 1 ]]; then
        echo "Usage: $SCRIPT_NAME build [root directory|worktree name]"
        exit 1
    fi

    local worktree_root
    worktree_root=$(resolve_worktree_root "${1:-}") || exit 1

    local cmake_root="$worktree_root/$ROCJITSU_SOURCE_REL"
    link_cmake_presets "$cmake_root"

    cd "$cmake_root"
    cmake --preset default
    cmake --build --preset default --target all
}

cmd_create() {
    check_main_rocjitsu

    if [[ $# -lt 1 ]]; then
        echo "Usage: $SCRIPT_NAME create <branch name> [tree name]"
        echo ""
        echo "Create a worktree based off of [branch name], creating it if"
        echo "it doesn't exist. The worktree is created at ~/rocjitsu/[tree name]/$REPO_DIR"
        echo "where [tree name] defaults to <branch name> with path components"
        echo "removed."
        exit 1
    fi

    local branch="$1"
    local worktree_name
    if [[ $# -lt 2 ]]; then
        worktree_name="${1:t}"
    else
        worktree_name="$2"
    fi

    local worktree_root="$ROCJITSUS/$worktree_name"
    local worktree_src_root="$worktree_root/$REPO_DIR"
    if [[ -d "$worktree_root" ]]; then
        echo "Will not overwrite existing worktree: $worktree_root"
        exit 1
    fi

    cd "$MAIN_ROCJITSU"

    if ! git show-ref --quiet --heads "$branch"; then
        echo "Creating branch $branch from $(git rev-parse --abbrev-ref HEAD)"
        git branch "$branch"
    fi

    printf "Creating worktree...\n  - Branch: %s\n  - Path: %s\n" "$branch" "$worktree_root"

    mkdir -p "$worktree_root"
    git worktree add "$worktree_src_root" "$branch"

    setup_worktree_environment "$worktree_root"

    echo "Created worktree ${worktree_name} at ${worktree_root}"
}

cmd_list() {
    check_main_rocjitsu
    exec "${SCRIPT_DIR:h}/git-worktree-list.sh" "$MAIN_ROCJITSU"
}

cmd_remove() {
    check_main_rocjitsu

    if [[ $# -ne 1 ]]; then
        echo "Usage: $SCRIPT_NAME remove <branch or path>"
        echo ""
        echo "Remove the worktree for the named branch or path, including the"
        echo "out-of-tree build environment."
        exit 1
    fi

    local branch_or_path="$1"
    local worktree_path

    cd "$MAIN_ROCJITSU"
    if git check-ref-format --branch "$branch_or_path" 2>/dev/null >/dev/null \
            && git worktree list --porcelain | grep -q "^branch refs/heads/$branch_or_path"; then
        worktree_path=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch_or_path" | head -1 | cut -d ' ' -f 2)
    elif [[ -d "$branch_or_path" ]] && [[ -f "$branch_or_path/.git" ]]; then
        worktree_path="${branch_or_path:a}"
    elif [[ -d "$branch_or_path/$REPO_DIR" ]] && [[ -f "$branch_or_path/$REPO_DIR/.git" ]]; then
        worktree_path="$branch_or_path/$REPO_DIR"
        worktree_path="${worktree_path:a}"
    elif [[ -f "$ROCJITSUS/$branch_or_path/$REPO_DIR/.git" ]]; then
        worktree_path="$ROCJITSUS/$branch_or_path/$REPO_DIR"
    else
        echo "Could not find worktree for branch/path: $branch_or_path"
        exit 1
    fi

    if [[ ! -d "$worktree_path" ]]; then
        echo "Somehow, $worktree_path doesn't exist. Can't happen."
        exit 2
    fi

    local worktree_env="${worktree_path:h}"
    cd "$worktree_path"
    echo "Removing worktree ${worktree_path}"

    cd "$MAIN_ROCJITSU"
    echo "Removing worktree $worktree_path ..."
    git worktree remove "$worktree_path"

    echo "Removing build and environment in ${worktree_env}..."
    rm -rf -- "${worktree_env}/build" "${worktree_env}/.direnv" "${worktree_env}/.envrc" \
              "${worktree_env}/.cache" "${worktree_env}/venv" \
              "${worktree_env}/compile_commands.json" "${worktree_env}/marks.md" \
              "${worktree_env}/.claude" "${worktree_env}/.cursor" \
              "${worktree_env}/.peanut-review.json" || true
    rmdir "${worktree_env}" || (echo "There's still something in the worktree" && ls -la "${worktree_env}")
    echo "Removed worktree $branch_or_path at $worktree_env"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    create)
        cmd_create "$@"
        ;;
    remove)
        cmd_remove "$@"
        ;;
    setup)
        cmd_setup "$@"
        ;;
    build)
        cmd_build "$@"
        ;;
    list)
        cmd_list "$@"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        check_main_rocjitsu
        exec git -C "$MAIN_ROCJITSU" worktree "$command" "$@"
        ;;
esac
