#!/usr/bin/env zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0:A}"
REPO_DIR="rocm-systems"
ROCJITSUS="${ROCJITSUS:-$HOME/rocjitsu}"
ROCJITSU_DEFAULT_BRANCH="develop"
MAIN_ROCJITSU_ROOT="${ROCJITSU_MAIN_ROOT:-$ROCJITSUS/develop}"
MAIN_ROCJITSU="${ROCJITSU_MAIN_WORKSPACE:-$MAIN_ROCJITSU_ROOT/$REPO_DIR}"
ROCJITSU_SOURCE_REL="$REPO_DIR/emulation/rocjitsu"
REVIEW_SOURCE_ASSET_REL="emulation/rocjitsu/CMakeUserPresets.json"
REVIEW_LAUNCHER="${ROCJITSU_REVIEW_LAUNCHER:-${SCRIPT_DIR}/../../agent-workspace/rocjitsu/review-pr.sh}"
THEROCK_MULTIARCH_INDEX="https://rocm.nightlies.amd.com/whl-multi-arch/"
THEROCK_ROCM_PACKAGE="rocm[libraries,devel,device-all]"

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
    echo "  queue-setup <root> <commit>"
    echo "                          Create/update a queue-managed review worktree"
    echo "  queue-cleanup [--check] <root>"
    echo "                          Safely inspect/remove a queue-managed wrapper"
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

link_review_assets() {
    local worktree_root="$1"
    local user_presets="$worktree_root/$REPO_DIR/$REVIEW_SOURCE_ASSET_REL"

    if [[ -e "$user_presets" && ! -L "$user_presets" ]]; then
        echo "Error: refusing to replace regular file: $user_presets" >&2
        return 1
    fi
    ln -sfn "${SCRIPT_DIR}/CMakeUserPresets.json" "$user_presets"

    mkdir -p "$worktree_root/tools"
    ln -sfn "${SCRIPT_DIR}/review-tools/hipcc-asan-ubsan" \
        "$worktree_root/tools/hipcc-asan-ubsan"
    ln -sfn "${SCRIPT_DIR}/review-tools/hipcc-tsan" \
        "$worktree_root/tools/hipcc-tsan"
}

validate_review_source_assets() {
    local worktree_src_root="$1"
    local user_presets="$worktree_src_root/$REVIEW_SOURCE_ASSET_REL"
    local expected="${SCRIPT_DIR}/CMakeUserPresets.json"

    if [[ ! -e "$user_presets" && ! -L "$user_presets" ]]; then
        return 0
    fi
    if [[ ! -L "$user_presets" \
            || "$(realpath -- "$user_presets" 2>/dev/null || true)" != "${expected:A}" ]]; then
        echo "Error: unexpected managed source asset: $user_presets" >&2
        return 1
    fi
}

review_source_status() {
    local worktree_src_root="$1"
    validate_review_source_assets "$worktree_src_root" || return 1
    git -C "$worktree_src_root" status --porcelain \
        --untracked-files=all --ignore-submodules=none -- . \
        ":(exclude)$REVIEW_SOURCE_ASSET_REL"
}

is_managed_review_entry() {
    local entry="$1"
    case "${entry:t}" in
        review-pr.sh)
            [[ -L "$entry" && -f "$REVIEW_LAUNCHER" \
                && "$(realpath -- "$entry" 2>/dev/null || true)" == "${REVIEW_LAUNCHER:A}" ]]
            return $? ;;
        .review-queue.json|.review-queue.lock|.beads|.claude|.cursor|.direnv|.envrc|.cache|\
        .peanut-review.json|build|build-*|compile_commands.json|marks.md|\
        rocm-systems|tools|venv) return 0 ;;
        *) return 1 ;;
    esac
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
        [[ -e "$main_root/$item" ]] && cp -r "$main_root/$item" "$worktree_root/"
    done
}

repair_therock_amdllvm_shim() {
    local rocm_root="$1"
    local shim="$rocm_root/bin/amdllvm"
    local target="../lib/llvm/bin/amdllvm"

    if [[ -x "$rocm_root/lib/llvm/bin/amdllvm" && ( ! -L "$shim" || "$(readlink "$shim")" != "$target" ) ]]; then
        rm -f "$shim"
        ln -s "$target" "$shim"
    fi
}

prepend_colon_path() {
    local var_name="$1"
    local entry="$2"
    local current="${(P)var_name:-}"

    if [[ ":$current:" != *":$entry:"* ]]; then
        export "$var_name=$entry${current:+:$current}"
    fi
}

activate_therock_environment() {
    local worktree_root="$1"

    source "$worktree_root/venv/bin/activate"
    export ROCM_PATH="$(rocm-sdk path --root)"
    repair_therock_amdllvm_shim "$ROCM_PATH"
    export ROCM_HOME="$ROCM_PATH"
    export CMAKE_PREFIX_PATH="$(rocm-sdk path --cmake)"
    export CCACHE_BASEDIR="$worktree_root"
    export CCACHE_NOHASHDIR=true

    local rocm_bin rocm_lib rocm_llvm_lib rocm_sysdeps_lib
    rocm_bin="$(rocm-sdk path --bin)"
    rocm_lib="$ROCM_PATH/lib"
    rocm_llvm_lib="$ROCM_PATH/lib/llvm/lib"
    rocm_sysdeps_lib="$ROCM_PATH/lib/rocm_sysdeps/lib"

    prepend_colon_path PATH "$rocm_bin"
    prepend_colon_path LD_LIBRARY_PATH "$rocm_sysdeps_lib"
    prepend_colon_path LD_LIBRARY_PATH "$rocm_llvm_lib"
    prepend_colon_path LD_LIBRARY_PATH "$rocm_lib"
}

setup_worktree_environment() {
    local worktree_root="$1"
    local cmake_root="$worktree_root/$ROCJITSU_SOURCE_REL"

    link_cmake_presets "$cmake_root"

    echo "::group::Environment setup"
    cmd_setup "$worktree_root"
    copy_main_worktree_state "$worktree_root"
    echo "::endgroup::"
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

    typeset -F SECONDS
    local start_time=$SECONDS
    echo "::group::Create Python environment"
    uv venv --python 3.12 venv
    source venv/bin/activate
    echo "::endgroup::"
    echo "::group::Install TheRock SDK"
    uv pip install --upgrade --pre --index-url "$THEROCK_MULTIARCH_INDEX" "$THEROCK_ROCM_PACKAGE"
    echo "::endgroup::"
    echo "::group::Install Python dependencies"
    uv pip install -e "$cmake_root/lib/python" pytest
    echo "::endgroup::"
    echo "::group::Initialize SDK"
    rocm-sdk init
    local rocm_root rocm_cmake rocm_bin
    rocm_root=$(rocm-sdk path --root)
    repair_therock_amdllvm_shim "$rocm_root"
    rocm_cmake=$(rocm-sdk path --cmake)
    rocm_bin=$(rocm-sdk path --bin)
    local elapsed=$((SECONDS - start_time))
    printf "TheRock venv setup and package installation took %.3fs\n" "$elapsed"

    echo "::endgroup::"
    echo "::group::Configure workspace"
    local build_dir="$root_dir/build"
    mkdir -p "$build_dir"
    link_cmake_presets "$cmake_root"

    if [[ "${ROCJITSU_SKIP_BEADS:-0}" == 1 ]]; then
        echo "Skipping beads workspace initialization for managed review wrapper."
    elif command -v br >/dev/null 2>&1; then
        [[ -d "$root_dir/.beads" ]] || br init
    else
        echo "Warning: br not found; skipping beads workspace initialization."
    fi

    echo "export CCACHE_BASEDIR=\"$root_dir\"" > .envrc
    echo "export CCACHE_NOHASHDIR=true" >> .envrc
    echo "source \"$root_dir/venv/bin/activate\"" >> .envrc
    echo "export ROCM_PATH=\"$rocm_root\"" >> .envrc
    echo "export ROCM_HOME=\"$rocm_root\"" >> .envrc
    echo "export CMAKE_PREFIX_PATH=\"$rocm_cmake\"" >> .envrc
    echo "export LD_LIBRARY_PATH=\"$rocm_root/lib:$rocm_root/lib/llvm/lib:$rocm_root/lib/rocm_sysdeps/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"" >> .envrc
    echo "export RJ_BUILD_DIR=\"$build_dir\"" >> .envrc
    echo "PATH_add \"$rocm_bin\"" >> .envrc
    echo "PATH_add \"$build_dir/bin\"" >> .envrc
    echo "PATH_add \"$build_dir/tests\"" >> .envrc

    ln -sf "$build_dir/compile_commands.json" "$root_dir/compile_commands.json"

    direnv allow "$root_dir" || echo "Warning: direnv allow failed; run 'direnv allow $root_dir' from a writable shell if needed."
    echo "Set up RocJITsu build environment in $root_dir"
    echo "Configure with: (cd $cmake_root && cmake --preset default)"

    popd
    echo "::endgroup::"
}

cmd_queue_setup() {
    check_main_rocjitsu

    if [[ $# -ne 2 ]]; then
        echo "Usage: $SCRIPT_NAME queue-setup <wrapper root> <commit>" >&2
        exit 1
    fi

    local supplied_root="$1"
    local worktree_root="${supplied_root:A}"
    local commit="$2"
    local worktree_src_root="$worktree_root/$REPO_DIR"
    local marker="$worktree_root/.review-queue.json"
    local configured_root="${REVIEW_QUEUE_ROOT:-}"
    local expected_token="${REVIEW_QUEUE_OWNER_TOKEN:-}"

    if [[ -z "$configured_root" || -z "$expected_token" ]]; then
        echo "Error: missing REVIEW_QUEUE_ROOT or REVIEW_QUEUE_OWNER_TOKEN" >&2
        exit 1
    fi
    configured_root="${configured_root:A}"
    if [[ -L "$supplied_root" || "${worktree_root:h}" != "$configured_root" ]]; then
        echo "Error: wrapper is not a direct managed-root child" >&2
        exit 1
    fi

    if [[ ! -f "$marker" || ! -f "$worktree_root/.review-queue.lock" ]]; then
        echo "Error: missing review-queue ownership files in $worktree_root" >&2
        exit 1
    fi
    local marker_token marker_protocol
    marker_token="$(jq -r '.owner_token // empty' "$marker" 2>/dev/null || true)"
    marker_protocol="$(jq -r '.protocol // empty' "$marker" 2>/dev/null || true)"
    if [[ "$marker_protocol" != 1 || "$marker_token" != "$expected_token" ]]; then
        echo "Error: review-queue ownership marker does not match" >&2
        exit 1
    fi
    if ! git -C "$MAIN_ROCJITSU" cat-file -e "${commit}^{commit}"; then
        echo "Error: commit is unavailable in the main RocJITsu repository: $commit" >&2
        exit 1
    fi

    echo "::group::Checkout"
    if [[ ! -e "$worktree_src_root" ]]; then
        local entry name
        for entry in "$worktree_root"/*(DN); do
            name="${entry:t}"
            case "$name" in
                .review-queue.json|.review-queue.lock) ;;
                *)
                    echo "Error: new managed wrapper contains unknown entry: $entry" >&2
                    exit 1
                    ;;
            esac
        done
        git -C "$MAIN_ROCJITSU" worktree add --detach "$worktree_src_root" "$commit"
    else
        if ! git -C "$worktree_src_root" rev-parse --show-toplevel >/dev/null 2>&1; then
            echo "Error: invalid managed RocJITsu worktree: $worktree_src_root" >&2
            exit 1
        fi
        local main_common child_common source_status
        main_common="$(git -C "$MAIN_ROCJITSU" rev-parse --path-format=absolute --git-common-dir)"
        child_common="$(git -C "$worktree_src_root" rev-parse --path-format=absolute --git-common-dir)"
        if [[ "${main_common:A}" != "${child_common:A}" ]]; then
            echo "Error: managed worktree belongs to a different repository" >&2
            exit 1
        fi
        source_status="$(review_source_status "$worktree_src_root")" || exit 1
        if [[ -n "$source_status" ]]; then
            echo "Error: tracked or untracked changes block managed worktree refresh" >&2
            print -r -- "$source_status" >&2
            exit 1
        fi
        git -C "$worktree_src_root" switch --detach "$commit"
        copy_main_worktree_state "$worktree_root"
    fi

    echo "::endgroup::"
    if [[ ! -x "$worktree_root/venv/bin/rocm-sdk" \
            || ! -d "$worktree_root/build" || ! -f "$worktree_root/.envrc" ]]; then
        ROCJITSU_SKIP_BEADS=1 setup_worktree_environment "$worktree_root"
    fi

    link_cmake_presets "$worktree_src_root/emulation/rocjitsu"
    link_review_assets "$worktree_root"
    echo "Prepared queue-managed RocJITsu wrapper at $worktree_root"
}

cleanup_review_json() {
    local safe="$1"
    local reason="$2"
    local bytes="${3:-0}"
    jq -cn --argjson safe "$safe" --arg reason "$reason" --argjson bytes "$bytes" \
        '{safe:$safe,reason:$reason,reclaimable_bytes:$bytes}'
}

cleanup_review_preflight() {
    local supplied_root="$1"
    local worktree_root="${supplied_root:A}"
    local configured_root="${REVIEW_QUEUE_ROOT:-}"
    local expected_token="${REVIEW_QUEUE_OWNER_TOKEN:-}"
    CLEANUP_REASON=""
    CLEANUP_BYTES=0

    if [[ -z "$configured_root" || -z "$expected_token" ]]; then
        CLEANUP_REASON="missing REVIEW_QUEUE_ROOT or REVIEW_QUEUE_OWNER_TOKEN"
        return 1
    fi
    configured_root="${configured_root:A}"
    if [[ -L "$supplied_root" || "${worktree_root:h}" != "$configured_root" ]]; then
        CLEANUP_REASON="wrapper is not a direct managed-root child"
        return 1
    fi
    if [[ ! -d "$worktree_root" ]]; then
        CLEANUP_REASON="wrapper directory is missing"
        return 1
    fi
    local marker="$worktree_root/.review-queue.json"
    local marker_token marker_protocol
    if [[ ! -f "$marker" ]]; then
        CLEANUP_REASON="ownership marker is missing"
        return 1
    fi
    marker_token="$(jq -r '.owner_token // empty' "$marker" 2>/dev/null || true)"
    marker_protocol="$(jq -r '.protocol // empty' "$marker" 2>/dev/null || true)"
    if [[ "$marker_protocol" != 1 || "$marker_token" != "$expected_token" ]]; then
        CLEANUP_REASON="ownership marker does not match"
        return 1
    fi
    if [[ ! -f "$worktree_root/.review-queue.lock" ]]; then
        CLEANUP_REASON="wrapper lock file is missing"
        return 1
    fi
    exec {CLEANUP_LOCK_FD}<>"$worktree_root/.review-queue.lock"
    if ! flock -n "$CLEANUP_LOCK_FD"; then
        CLEANUP_REASON="wrapper ownership lock is active"
        return 1
    fi

    local entry name
    for entry in "$worktree_root"/*(DN); do
        name="${entry:t}"
        if ! is_managed_review_entry "$entry"; then
            CLEANUP_REASON="unknown top-level entry: $name"
            return 1
        fi
    done

    local worktree_src_root="$worktree_root/$REPO_DIR"
    if [[ ! -e "$worktree_src_root" && ! -L "$worktree_src_root" ]]; then
        CLEANUP_BYTES="$(du -sb -- "$worktree_root" | awk '{print $1}')"
        return 0
    fi
    if [[ -L "$worktree_src_root" || ! -d "$worktree_src_root" ]] \
            || ! git -C "$worktree_src_root" rev-parse --show-toplevel >/dev/null 2>&1; then
        CLEANUP_REASON="managed RocJITsu worktree is missing or invalid"
        return 1
    fi
    local main_common child_common worktree_status
    main_common="$(git -C "$MAIN_ROCJITSU" rev-parse --path-format=absolute --git-common-dir)"
    child_common="$(git -C "$worktree_src_root" rev-parse --path-format=absolute --git-common-dir)"
    if [[ "${main_common:A}" != "${child_common:A}" ]]; then
        CLEANUP_REASON="managed worktree belongs to a different repository"
        return 1
    fi
    if ! worktree_status="$(review_source_status "$worktree_src_root")"; then
        CLEANUP_REASON="managed source assets do not match"
        return 1
    fi
    if [[ -n "$worktree_status" ]]; then
        CLEANUP_REASON="source worktree has tracked or untracked changes"
        return 1
    fi
    CLEANUP_BYTES="$(du -sb -- "$worktree_root" | awk '{print $1}')"
    return 0
}

cmd_queue_cleanup() {
    check_main_rocjitsu

    local check_only=0
    if [[ "${1:-}" == "--check" ]]; then
        check_only=1
        shift
    fi
    if [[ $# -ne 1 ]]; then
        echo "Usage: $SCRIPT_NAME queue-cleanup [--check] <wrapper root>" >&2
        exit 1
    fi
    local supplied_root="$1"
    if ! cleanup_review_preflight "$supplied_root"; then
        if [[ "$check_only" == 1 ]]; then
            cleanup_review_json false "$CLEANUP_REASON" "$CLEANUP_BYTES"
            return 0
        fi
        echo "Cleanup blocked: $CLEANUP_REASON" >&2
        return 1
    fi
    if [[ "$check_only" == 1 ]]; then
        cleanup_review_json true "safe to recycle" "$CLEANUP_BYTES"
        return 0
    fi

    local worktree_root="${supplied_root:A}"
    local worktree_src_root="$worktree_root/$REPO_DIR"
    if [[ -d "$worktree_src_root" ]]; then
        validate_review_source_assets "$worktree_src_root" || return 1
        rm -f -- "$worktree_src_root/$REVIEW_SOURCE_ASSET_REL"
        # Preflight rejects source and submodule changes. Git still requires
        # --force to remove a clean worktree containing initialized submodules.
        git -C "$MAIN_ROCJITSU" worktree remove --force "$worktree_src_root"
    fi
    local entry name
    for entry in "$worktree_root"/*(DN); do
        name="${entry:t}"
        if [[ "$name" == "$REPO_DIR" ]]; then
            echo "Cleanup stopped: managed source survived git worktree remove" >&2
            return 1
        elif is_managed_review_entry "$entry"; then
            rm -rf -- "$entry"
        else
            echo "Cleanup stopped after worktree removal: unexpected entry $entry" >&2
            return 1
        fi
    done
    rmdir -- "$worktree_root"
    echo "Removed queue-managed RocJITsu wrapper at $worktree_root"
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

    activate_therock_environment "$worktree_root"

    cd "$cmake_root"
    cmake --preset default \
        -DROCM_PATH:PATH="$ROCM_PATH" \
        -DCMAKE_PREFIX_PATH:PATH="$CMAKE_PREFIX_PATH" \
        -DCMAKE_INSTALL_PREFIX:PATH="$ROCM_PATH" \
        -DHIPCC_EXECUTABLE:FILEPATH="$ROCM_PATH/bin/hipcc" \
        -DHSA_RUNTIME64:FILEPATH="$ROCM_PATH/lib/libhsa-runtime64.so" \
        -DROCMINFO_EXECUTABLE:FILEPATH="$ROCM_PATH/bin/rocminfo" \
        -DROCM_AGENT_ENUM:FILEPATH="$ROCM_PATH/bin/rocm_agent_enumerator" \
        -DAMDCXX:FILEPATH="$ROCM_PATH/bin/amdclang++"
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
    queue-setup)
        cmd_queue_setup "$@"
        ;;
    queue-cleanup)
        cmd_queue_cleanup "$@"
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
