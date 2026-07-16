#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

VADER_SHA=429b669e6158be3a9fc110799607c232e6ed8e29
if [ ! -d ".test/vader.vim" ]; then
  echo "Cloning vader.vim into .test/vader.vim..."
  mkdir -p .test
  git clone https://github.com/junegunn/vader.vim.git .test/vader.vim
  git -C .test/vader.vim checkout -q "$VADER_SHA"
fi

VIM_CMD="${VIM_CMD:-vim}"
TEST_FILES="${*:-test/*.vader}"

VIM_FLAGS=("-Nu" "test/vimrc" "-U" "NONE" "-i" "NONE")
if [ ! -t 1 ] || [ -n "$CI" ] || [ -n "$VADER_HEADLESS" ]; then
  VIM_FLAGS=("-Es" "${VIM_FLAGS[@]}")
  export VADER_OUTPUT_FILE=/dev/stdout
fi

echo "Running Vader tests using $VIM_CMD on $TEST_FILES..."
"$VIM_CMD" "${VIM_FLAGS[@]}" -c "Vader! $TEST_FILES"
