#!/bin/zsh
# Xcode run-script phase (ENGINEERING §3.3): install the Rust binary and resources into Mapo.app.
# The binary goes to Contents/Helpers, never Contents/MacOS: APFS is case-insensitive, so MacOS/mapo
# would be MacOS/Mapo. It is written to a temp file and renamed so a running daemon keeps its inode.
set -euo pipefail

root="${SRCROOT:?}/.."
profile="${MAPO_PROFILE:-debug}"
contents="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
src="$root/target/$profile/mapo"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "$identity" ]] && identity="-"

if [[ ! -x "$src" ]]; then
    echo "error: $src is missing; run 'just build', which builds the Rust side first" >&2
    exit 1
fi

mkdir -p "$contents/Helpers" "$contents/Resources/bin"
tmp="$contents/Helpers/.mapo.tmp.$$"
cp "$src" "$tmp"
codesign --force --sign "$identity" --options runtime --timestamp=none "$tmp"
mv -f "$tmp" "$contents/Helpers/mapo"

for dir in shell-integration terminfo; do
    if [[ -d "$root/resources/$dir" ]]; then
        rsync -a --delete "$root/resources/$dir/" "$contents/Resources/$dir/"
    fi
done
if [[ -d "$root/plugin" ]]; then
    rsync -a --delete "$root/plugin/" "$contents/Resources/claude-plugin/"
fi

ln -sfn ../../Helpers/mapo "$contents/Resources/bin/mapo"
