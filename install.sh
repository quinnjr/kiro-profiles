#!/bin/sh
# install.sh — Install kiro-profile.sh into the XDG data directory and print
# the line to add to your shell rc file.
#
#   ./install.sh
#
# Idempotent: re-running copies the current kiro-profile.sh and VERSION over
# the installed copies. Does NOT modify your .bashrc / .zshrc — it only tells
# you what to add.

set -eu

# Directory this script lives in (the repo checkout). Set CDPATH to empty for
# the duration of the cd so a user's CDPATH can't redirect it.
CDPATH=''
_src_dir=$(cd -- "$(dirname -- "$0")" && pwd)

_install_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/kiro-profile"

if [ ! -f "${_src_dir}/kiro-profile.sh" ]; then
    printf 'install: kiro-profile.sh not found next to install.sh (looked in %s)\n' "$_src_dir" >&2
    exit 1
fi

mkdir -p "$_install_dir"
cp -f "${_src_dir}/kiro-profile.sh" "${_install_dir}/kiro-profile.sh"
if [ -f "${_src_dir}/VERSION" ]; then
    cp -f "${_src_dir}/VERSION" "${_install_dir}/VERSION"
fi

printf 'Installed kiro-profile.sh to: %s\n' "${_install_dir}/kiro-profile.sh"
printf '\n'
printf 'Add this line to your ~/.zshrc or ~/.bashrc:\n\n'
# shellcheck disable=SC2016  # the ${XDG_DATA_HOME:-...} must print literally
printf '    . "${XDG_DATA_HOME:-$HOME/.local/share}/kiro-profile/kiro-profile.sh"\n\n'
printf 'Then reload your shell (source ~/.zshrc) and create your first profile:\n\n'
printf '    kiro-profile create --init work\n'
printf '    kiro-profile use work\n'
printf '    kiro-cli login\n'
