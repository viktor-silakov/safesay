#!/bin/zsh -f
set -euo pipefail

project=${0:A:h}
bin_directory="$HOME/.local/bin"
zshenv="${ZDOTDIR:-$HOME}/.zshenv"
path_marker='# safesay: add ~/.local/bin to PATH'

swift build -c release --package-path "$project"
build_directory=$(swift build -c release --package-path "$project" --show-bin-path)
mkdir -p "$bin_directory"
/usr/bin/install -m 755 "$build_directory/safesay" "$bin_directory/safesay"
"$bin_directory/safesay" --reload-agent

if ! /usr/bin/grep -Fqx -- "$path_marker" "$zshenv" 2>/dev/null; then
    mkdir -p "${zshenv:h}"
    cat >> "$zshenv" <<'ZSHENV'

# safesay: add ~/.local/bin to PATH
if [[ ":${PATH:-}:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin${PATH:+:$PATH}"
fi
ZSHENV
fi

print -r -- "Installed $bin_directory/safesay. PATH is configured for new zsh sessions."
