#!/usr/bin/env zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
IREES="$HOME/iree"
MAIN_IREE="$IREES/main/src"

check_main_iree() {
    if [[ ! -d $MAIN_IREE ]]; then
        echo "No main IREE repository in the expected place"
        exit 1
    fi
}

usage() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  create <branch> [name]  Create a new worktree"
    echo "  remove <branch|path>    Remove an existing worktree"
    echo "  setup <root>            Set up build environment for a worktree"
    echo "  list                    List worktrees with commit details"
    echo "  <other>                 Passed through to 'git worktree <other>'"
    echo ""
    echo "Examples:"
    echo "  $0 create my-feature"
    echo "  $0 remove my-feature"
    echo "  $0 list"
}

cmd_setup() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 setup <root directory>"
        exit 1
    fi

    local root_dir="$1"
    if [[ ! -d "$root_dir/src/compiler" ]]; then
        echo "Error: expected $root_dir to heuristically be an IREE checkout"
        exit 1
    fi

    pushd "$root_dir"
    python3.12 -m venv venv
    source venv/bin/activate
    pip install -r "$root_dir/src/runtime/bindings/python/iree/runtime/build_requirements.txt"

    local build_dir="$root_dir/build"
    mkdir -p "$build_dir"

    echo "export CCACHE_BASEDIR=\"$root_dir\"" > .envrc
    echo "export CCACHE_NOHASHDIR=1" >> .envrc
    echo "export CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime" >> .envrc
    echo "source \"$root_dir/venv/bin/activate\"" >> .envrc
    echo "source \"$build_dir/.env\" && export PYTHONPATH" >> .envrc
    echo "PATH_add \"$build_dir/tools\"" >> .envrc

    eval "$(direnv export zsh)"

    ln -sf "$build_dir/compile_commands.json" "$root_dir/compile_commands.json"
    ln -sf "$build_dir/tablegen_compile_commands.yaml" "$root_dir/tablegen_compile_commands.yaml"

    direnv allow "$root_dir"
    echo "Set up IREE build environment in $root_dir"

    popd
}

cmd_create() {
    check_main_iree

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 create <branch name> [tree name]"
        echo ""
        echo "Create a worktree based off of [branch name], creating it if"
        echo "it doesn't exist. The worktree is created at ~/iree/[tree name]/src"
        echo "where [tree name] defaults to <branch name> with the stacking PR bits"
        echo "removed. It then sets up submodules to copy off of the main checkout."
        exit 1
    fi

    local branch="$1"
    local worktree_name
    if [[ $# -lt 2 ]]; then
        worktree_name="${1:t}"
    else
        worktree_name="$2"
    fi

    local worktree_root="$IREES/$worktree_name"
    local worktree_src_root="$worktree_root/src"
    if [[ -d "$worktree_root" ]]; then
        echo "Will not overwrite existing worktree: $worktree_root"
        exit 1
    fi

    cd "$MAIN_IREE"

    if ! git show-ref --quiet --heads "$branch"; then
        echo "Creating branch $branch from $(git rev-parse --abbrev-ref HEAD)"
        git branch "$branch"
    fi

    printf "Creating worktree ...\n  - Branch: %s\n -- Path: %s\n" "$branch" "$worktree_root"

    mkdir -p "$worktree_root"
    git worktree add "$worktree_src_root" "$branch"

    cd "$worktree_src_root"

    [[ -a CMakeUserPresets.json ]] || ln -s "${SCRIPT_DIR}/CMakeUserPresets.json" .

    git submodule --quiet init
    # Note: this doesn't create recursive submodules but it's fine since Torch
    # uses our copies
    git config --file .gitmodules --name-only --get-regexp path | cut -f2 -d. | \
        parallel --jobs 16 "echo 'Creating quasi-worktree of {}' && git submodule update --reference '$MAIN_IREE/{}' '{}'"

    echo "Creating virtual environment ..."
    cmd_setup "$worktree_root"

    echo "Created worktree ${worktree_name} at ${worktree_root}"
}

cmd_list() {
    check_main_iree
    exec "${SCRIPT_DIR:h}/git-worktree-list.sh" "$MAIN_IREE"
}

cmd_remove() {
    check_main_iree

    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 remove <branch or path>"
        echo ""
        echo "Remove the worktree for the named branch (or if no such branch"
        echo "at the given path), getting rid of submodules and the build environment."
        exit 1
    fi

    local branch_or_path="$1"
    local worktree_path

    cd "$MAIN_IREE"
    if git check-ref-format --branch "$branch_or_path" 2>/dev/null >/dev/null \
            && git worktree list --porcelain | grep -q "^branch refs/heads/$branch_or_path"; then
        worktree_path=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch_or_path" | head -1 | cut -d ' ' -f 2)
    elif [[ -d "$branch_or_path" ]] && [[ -f "$branch_or_path/.git" ]]; then
        worktree_path="${branch_or_path:a}"
    elif [[ -d "$branch_or_path/src" ]] && [[ -f "$branch_or_path/src/.git" ]]; then
        worktree_path="$branch_or_path/src"
        worktree_path="${worktree_path:a}"
    elif [[ -f "$IREES/$branch_or_path/src/.git" ]]; then
        worktree_path="$IREES/$branch_or_path/src"
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
    echo "Unregistering submodules..."
    git submodule deinit --all --force
    echo "Deleting submodule checkouts..."
    rm -rf "$(git rev-parse --git-dir)/modules" || true

    cd "$MAIN_IREE"
    echo "Removing worktree $worktree_path ..."
    # Now that we've cleaned out the submodules, no need for force
    git worktree remove "$worktree_path"

    echo "Removing build and environment in ${worktree_env} ..."
    rm -rf -- "${worktree_env}/build" "${worktree_env}/.direnv" "${worktree_env}/.envrc" \
              "${worktree_env}/.cache" "${worktree_env}/venv" \
              "${worktree_env}/compile_commands.json" "${worktree_env}/tablegen_compile_commands.yaml" || true
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
    list)
        cmd_list "$@"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        check_main_iree
        exec git -C "$MAIN_IREE" worktree "$command" "$@"
        ;;
esac
