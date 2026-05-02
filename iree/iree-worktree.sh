#!/usr/bin/env zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0:A}"
REPO_DIR="iree"
IREES="$HOME/iree"
MAIN_IREE="$IREES/main/$REPO_DIR"

check_main_iree() {
    if [[ ! -d $MAIN_IREE ]]; then
        echo "No main IREE repository in the expected place"
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
    echo "  setup-review <pr> [name] [--build] [--test]"
    echo "                          Create and prepare a GitHub PR review checkout"
    echo "  list                    List worktrees with commit details"
    echo "  <other>                 Passed through to 'git worktree <other>'"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME create my-feature"
    echo "  $SCRIPT_NAME setup-review 24093 --build --test"
    echo "  $SCRIPT_NAME remove my-feature"
    echo "  $SCRIPT_NAME list"
}

slugify_review_component() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

normalize_iree_pr_ref() {
    local pr_ref="$1"
    if [[ "$pr_ref" =~ 'github\.com/iree-org/iree/pull/([0-9]+)' ]]; then
        echo "$match[1]"
    else
        echo "$pr_ref"
    fi
}

default_review_name() {
    local author_slug
    local branch_slug
    author_slug=$(slugify_review_component "$1")
    branch_slug=$(slugify_review_component "$2")
    if [[ -n "$author_slug" && -n "$branch_slug" ]]; then
        echo "review-${author_slug}-${branch_slug}"
    else
        echo "review-pr-$3"
    fi
}

link_cmake_presets() {
    [[ -a CMakeUserPresets.json ]] || ln -s "${SCRIPT_DIR}/CMakeUserPresets.json" .
}

update_top_level_submodules() {
    git submodule --quiet init
    # Note: this doesn't create recursive submodules but it's fine since Torch
    # uses our copies.
    git config --file .gitmodules --name-only --get-regexp path | cut -f2 -d. | \
        parallel --jobs 16 "echo 'Creating quasi-worktree of {}' && git submodule update --reference '$MAIN_IREE/{}' '{}'"
}

copy_main_worktree_state() {
    local worktree_root="$1"
    local main_root="$IREES/main"
    for item in marks.md .claude .cursor; do
        [[ -e "$main_root/$item" ]] && cp -r "$main_root/$item" "$worktree_root/$item"
    done
}

write_peanut_review_config() {
    local worktree_root="$1"
    cat > "$worktree_root/.peanut-review.json" <<EOF
{
  "reviewRoot": "$HOME/reviews",
  "workspaceRoot": ".",
  "repoRelative": "$REPO_DIR",
  "reviewAgentTimeoutSeconds": 900,
  "agents": [
    {"name": "vera", "model": "openai/gpt-5.5", "persona": "vera.md", "runner": "opencode"},
    {"name": "irene", "model": "openai/gpt-5.5", "persona": "irene.md", "runner": "opencode"},
    {"name": "petra", "model": "openai/gpt-5.4-mini", "persona": "petra.md", "runner": "opencode"},
    {"name": "soren", "model": "openai/gpt-5.4-mini", "persona": "soren.md", "runner": "opencode"}
  ]
}
EOF
}

setup_worktree_environment() {
    local worktree_root="$1"
    local worktree_src_root="$worktree_root/$REPO_DIR"

    cd "$worktree_src_root"
    link_cmake_presets
    update_top_level_submodules

    echo "Creating virtual environment ..."
    cmd_setup "$worktree_root"
    copy_main_worktree_state "$worktree_root"
    write_peanut_review_config "$worktree_root"
}

configure_review_build() {
    local worktree_root="$1"
    local preset="${IREE_REVIEW_CMAKE_PRESET:-default}"

    cd "$worktree_root/$REPO_DIR"
    source "$worktree_root/venv/bin/activate"
    cmake --preset "$preset"
}

cmd_setup() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $SCRIPT_NAME setup <root directory>"
        exit 1
    fi

    local root_dir="$1"
    if [[ ! -d "$root_dir/$REPO_DIR/compiler" ]]; then
        echo "Error: expected $root_dir to heuristically be an IREE checkout"
        exit 1
    fi

    pushd "$root_dir"

    typeset -F SECONDS
    local start_time=$SECONDS
    uv venv --python 3.12 venv
    source venv/bin/activate
    uv pip install -r "$root_dir/$REPO_DIR/runtime/bindings/python/iree/runtime/build_requirements.txt"
    local elapsed=$((SECONDS - start_time))
    printf "Venv setup and package installation took %.3fs\n" "$elapsed"

    local build_dir="$root_dir/build"
    mkdir -p "$build_dir"

    echo "export CCACHE_BASEDIR=\"$root_dir\"" > .envrc
    echo "source \"$root_dir/venv/bin/activate\"" >> .envrc
    echo "source \"$build_dir/.env\" && export PYTHONPATH" >> .envrc
    echo "PATH_add \"$build_dir/tools\"" >> .envrc

    eval "$(direnv export zsh)"

    ln -sf "$build_dir/compile_commands.json" "$root_dir/compile_commands.json"
    ln -sf "$build_dir/tablegen_compile_commands.yml" "$root_dir/tablegen_compile_commands.yml"

    direnv allow "$root_dir" || echo "Warning: direnv allow failed; run 'direnv allow $root_dir' from a writable shell if needed."
    echo "Set up IREE build environment in $root_dir"

    popd
}

cmd_create() {
    check_main_iree

    if [[ $# -lt 1 ]]; then
        echo "Usage: $SCRIPT_NAME create <branch name> [tree name]"
        echo ""
        echo "Create a worktree based off of [branch name], creating it if"
        echo "it doesn't exist. The worktree is created at ~/iree/[tree name]/$REPO_DIR"
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
    local worktree_src_root="$worktree_root/$REPO_DIR"
    if [[ -d "$worktree_root" ]]; then
        echo "Will not overwrite existing worktree: $worktree_root"
        exit 1
    fi

    cd "$MAIN_IREE"

    if ! git show-ref --quiet --heads "$branch"; then
        echo "Creating branch $branch from $(git rev-parse --abbrev-ref HEAD)"
        git branch "$branch"
    fi

    printf "Creating worktree...\n  - Branch: %s\n -- Path: %s\n" "$branch" "$worktree_root"

    mkdir -p "$worktree_root"
    git worktree add "$worktree_src_root" "$branch"

    setup_worktree_environment "$worktree_root"

    echo "Created worktree ${worktree_name} at ${worktree_root}"
}

cmd_setup_review() {
    check_main_iree

    local do_build=false
    local do_test=false
    local pr_arg=""
    local worktree_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build)
                do_build=true
                ;;
            --test)
                do_build=true
                do_test=true
                ;;
            -h|--help|help)
                echo "Usage: $SCRIPT_NAME setup-review <pr-url-or-number> [review-name] [--build] [--test]"
                echo ""
                echo "Creates ~/iree/[review-name]/iree, checks out the PR, syncs top-level"
                echo "submodules, creates the venv, and configures CMake. --test implies --build."
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Unknown setup-review option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$pr_arg" ]]; then
                    pr_arg="$1"
                elif [[ -z "$worktree_name" ]]; then
                    worktree_name="$1"
                else
                    echo "Unexpected setup-review argument: $1"
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$pr_arg" ]]; then
        echo "Usage: $SCRIPT_NAME setup-review <pr-url-or-number> [review-name] [--build] [--test]"
        exit 1
    fi

    local pr_ref
    pr_ref=$(normalize_iree_pr_ref "$pr_arg")

    local pr_fields
    pr_fields=$(gh pr view "$pr_ref" --repo iree-org/iree --json number,author,baseRefName,headRefName,title,url --jq '[.number, .author.login, .baseRefName, .headRefName, .title, .url] | @tsv')

    local pr_number pr_author pr_base_ref pr_head_ref pr_title pr_url
    IFS=$'\t' read -r pr_number pr_author pr_base_ref pr_head_ref pr_title pr_url <<< "$pr_fields"
    if [[ -z "$worktree_name" ]]; then
        worktree_name=$(default_review_name "$pr_author" "$pr_head_ref" "$pr_number")
    fi

    local worktree_root="$IREES/$worktree_name"
    local worktree_src_root="$worktree_root/$REPO_DIR"
    if [[ -d "$worktree_root" ]]; then
        echo "Will not overwrite existing worktree: $worktree_root"
        exit 1
    fi
    if git -C "$MAIN_IREE" show-ref --quiet --heads "$worktree_name"; then
        echo "Will not overwrite existing branch: $worktree_name"
        exit 1
    fi

    echo "Setting up IREE review:"
    echo "  - PR: #${pr_number} ${pr_title}"
    echo "  - URL: ${pr_url}"
    echo "  - Base: origin/${pr_base_ref}"
    echo "  - Worktree: ${worktree_root}"
    echo "  - Local branch: ${worktree_name}"

    cd "$MAIN_IREE"
    git fetch origin "$pr_base_ref"
    mkdir -p "$worktree_root"
    git worktree add --detach "$worktree_src_root" "origin/$pr_base_ref"

    cd "$worktree_src_root"
    gh pr checkout "$pr_number" --repo iree-org/iree --branch "$worktree_name"
    setup_worktree_environment "$worktree_root"

    echo "Configuring build with CMake preset ${IREE_REVIEW_CMAKE_PRESET:-default} ..."
    configure_review_build "$worktree_root"

    if $do_build; then
        echo "Building all iree-test-deps ..."
        (cd "$worktree_root/build" && ninja all iree-test-deps)
    fi

    if $do_test; then
        local ctest_jobs="${IREE_REVIEW_CTEST_JOBS:-16}"
        local ctest_exclude="${IREE_REVIEW_CTEST_EXCLUDE:-cuda|metal|hip/cts}"
        echo "Running ctest -j${ctest_jobs} excluding ${ctest_exclude} ..."
        (cd "$worktree_root/build" && source "$worktree_root/venv/bin/activate" && ctest -j"$ctest_jobs" --output-on-failure -E "$ctest_exclude")
    fi

    echo "Review worktree ready at ${worktree_src_root}"
    echo "Suggested peanut-review start:"
    echo "  (cd ${worktree_root} && peanut-review start ${pr_number})"
}

cmd_list() {
    check_main_iree
    exec "${SCRIPT_DIR:h}/git-worktree-list.sh" "$MAIN_IREE"
}

cmd_remove() {
    check_main_iree

    if [[ $# -ne 1 ]]; then
        echo "Usage: $SCRIPT_NAME remove <branch or path>"
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
    elif [[ -d "$branch_or_path/$REPO_DIR" ]] && [[ -f "$branch_or_path/$REPO_DIR/.git" ]]; then
        worktree_path="$branch_or_path/$REPO_DIR"
        worktree_path="${worktree_path:a}"
    elif [[ -f "$IREES/$branch_or_path/$REPO_DIR/.git" ]]; then
        worktree_path="$IREES/$branch_or_path/$REPO_DIR"
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

    echo "Removing build and environment in ${worktree_env}..."
    rm -rf -- "${worktree_env}/build" "${worktree_env}/.direnv" "${worktree_env}/.envrc" \
              "${worktree_env}/.cache" "${worktree_env}/venv" \
              "${worktree_env}/compile_commands.json" "${worktree_env}/tablegen_compile_commands.yml" \
              "${worktree_env}/marks.md" "${worktree_env}/.claude" "${worktree_env}/.cursor" || true
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
    setup-review)
        cmd_setup_review "$@"
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
