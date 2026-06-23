# Worktree Scripts

Scripts for managing git worktrees for IREE, LLVM, and RocJITsu projects.

Based on https://github.com/krzysz00/amd-scripts.

## Prerequisites

**Required for scripts:**

- `zsh` — scripts are written in zsh
- `fzf` — for interactive worktree browsing (`wt br`)
- `direnv` — for automatic environment activation
- `parallel` — for IREE's parallel submodule initialization

The included CMake presets assume project-specific Clang versions, `ninja`,
`ccache`, and `mold` to be installed, but you can modify them based on your
environment.

## Installation

Source the setup script in your shell configuration (`.bashrc`, `.zshrc`, or `.bash_aliases`):

```bash
source "path/to/worktree-scripts/worktree_setup.sh"
```

This provides the `wt` shell function.
Alternatively, you can use `worktree.sh` directly (e.g., symlink it to `~/.local/bin/wt`).

## Usage

### Shell Function (`wt`)

The `wt` function wraps `worktree.sh` and adds shell-specific commands that require `cd`.

```bash
# Project is auto-detected from current directory.
wt <command> [args...]

# Or specify project explicitly.
wt iree <command> [args...]
wt llvm <command> [args...]
wt rocjitsu <command> [args...]
```

Project-specific build commands can be run from inside a matching worktree:

```bash
wt build
wt rocjitsu build gfx1250
```

#### Shell-specific commands

These commands are handled by the shell function (not `worktree.sh`) because they need to change your current directory:

```bash
# Browse worktrees with fzf and cd to selection.
wt br
wt iree br
wt llvm br
wt rocjitsu br

# cd to project root (~/iree, ~/llvm, or ~/rocjitsu).
wt root
wt iree root
wt llvm root
wt rocjitsu root
```

Sample `wt br` output (uses fzf for interactive selection):

```
  ~/iree/gfx1250/src             gfx1250             6d742a14  2 weeks ago  [GlobalOpt] Fix rank-reduced permutation in Sin··
  ~/iree/ci-macos-integrate/src  ci-macos-integrate  e815f3c4  8 days ago   [CI] Do not schedule-only jobs on integrates
  ~/iree/main/src                main                29a992ec  2 days ago   [Dispatch Creation] Move two flags to pipeline ··
▌ ~/iree/test12/src              test12              29a992ec  2 days ago   [Dispatch Creation] Move two flags to pipeline ··
  4/4 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
>
```

### Script Commands

These commands are passed to `worktree.sh` and the project-specific scripts:

```bash
# List known projects.
wt projects

# List all worktrees with commit details.
wt list

# Create a new worktree.
wt create <branch> [name]

# Remove a worktree and its local setup artifacts.
wt remove <branch|path>

# Set up build environment for an existing worktree.
wt setup <root>

# Any other command is passed to git worktree.
wt prune
wt repair
```

## Example Workflows

### Setting up IREE from scratch

```bash
# Clone main IREE repository
mkdir -p ~/iree/main
git clone https://github.com/iree-org/iree.git ~/iree/main/src
cd ~/iree/main/src
git submodule update --init

# Set up build environment
wt iree setup ~/iree/main

# Configure and build
cd ~/iree/main/src
cmake --preset default
cmake --build --preset default
```

### Creating a new IREE worktree

```bash
# Create worktree for a new feature branch
wt iree create my-feature

# This will:
# - Create branch 'my-feature' if it doesn't exist
# - Create worktree at ~/iree/my-feature/src
# - Initialize submodules (using main as reference for speed)
# - Set up Python venv and direnv
# - Link CMakeUserPresets.json
```

### Building with CMake presets

After creating a worktree, it comes with `CMakeUserPresets.json` linked:

```bash
cd ~/iree/my-feature/src

# Configure with default preset (RelWithDebInfo)
cmake --preset default

# Or use other presets
cmake --preset debug

# Build
cmake --build --preset default

# Build only compiler tools
cmake --build --preset compiler
```

### Setting up RocJITsu from scratch

```bash
# Clone main rocm-systems repository for RocJITsu work.
mkdir -p ~/rocjitsu/develop
git clone https://github.com/ROCm/rocm-systems.git ~/rocjitsu/develop/rocm-systems

# Set up the out-of-tree build environment, TheRock ROCm wheels, and Python tools.
wt rocjitsu setup ~/rocjitsu/develop

# Configure and build RocJITsu. The default preset uses ccache and mold,
# with ccache path hashing set up for reuse across RocJITsu worktrees.
wt rocjitsu build ~/rocjitsu/develop
```

RocJITsu worktrees live under `~/rocjitsu/<name>/rocm-systems`, with the build
tree at `~/rocjitsu/<name>/build`. The RocJITsu setup does not initialize
`rocm-systems` submodules; it is scoped to `emulation/rocjitsu`. It creates a
per-worktree Python venv and installs the newest TheRock multi-arch ROCm SDK
wheels with `rocm[libraries,devel,device-all]`, plus editable `amdisa` and
`pytest`. It also initializes Beads in the workspace root when `br` is
available. Setup writes `.envrc` with `ROCM_PATH`, `ROCM_HOME`,
`CMAKE_PREFIX_PATH`, the TheRock SDK `bin` directory on `PATH`, and
`LD_LIBRARY_PATH` for TheRock runtime libraries. `wt rocjitsu build` also passes
those paths back into CMake so stale caches do not fall back to `/opt/rocm` or
`/usr/bin/hipcc`.

## Adding a New Project

Edit `worktree.sh` and add your project to the `PROJECTS` array:

```zsh
PROJECTS=(
    iree "$HOME/iree"
    llvm "$HOME/llvm"
    rocjitsu "$HOME/rocjitsu"
    myproject "$HOME/myproject"  # Add your project here.
)
```

Then create the project-specific script at `myproject/myproject-worktree.sh`.
