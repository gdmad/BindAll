#!/usr/bin/env bash
# Runs the GitHub CLI inside the project's minimal container (see .devcontainer/Dockerfile),
# mounted on the repo. Use it for releases when `gh` is not installed on the host.
#
# One-time auth (pick one):
#   .devcontainer/gh.sh auth login          # interactive
#   export GH_TOKEN=ghp_xxx                  # or a token in the environment (forwarded in)
#
# Example:
#   .devcontainer/gh.sh release create v0.2.1 .release/BindAll-0.2.1.dmg \
#       --title "BindAll 0.2.1" --notes-file notes.md
set -euo pipefail

cd "$(dirname "$0")/.."
IMAGE=bindall-gh

docker build -q -t "$IMAGE" .devcontainer >/dev/null

mkdir -p "$HOME/.config/gh"

# Allocate a TTY only when attached to one (so `auth login` is interactive, but CI/non-interactive
# calls still work).
TTY=()
[ -t 0 ] && TTY=(-it)

exec docker run --rm ${TTY[@]+"${TTY[@]}"} \
  -v "$PWD":/workspace -w /workspace \
  -v "$HOME/.config/gh":/root/.config/gh \
  -e GH_TOKEN \
  "$IMAGE" gh "$@"
