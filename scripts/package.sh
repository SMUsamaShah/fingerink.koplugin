#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$repo_root/dist"}
staging_dir=$(mktemp -d)
archive_path="$output_dir/fingerink.koplugin.zip"
temporary_archive="$staging_dir/fingerink.koplugin.zip"

metadata_version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$repo_root/fingerink.koplugin/_meta.lua")
version_file=$(tr -d '\r\n' < "$repo_root/VERSION")
test -n "$metadata_version"
test "$metadata_version" = "$version_file" || {
    echo "VERSION ($version_file) does not match fingerink.koplugin/_meta.lua ($metadata_version)." >&2
    exit 1
}

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT INT TERM

mkdir -p "$output_dir" "$staging_dir/fingerink.koplugin"
for file in _meta.lua main.lua ink_bar.lua ink_capture.lua ink_pdf.lua \
    ink_render.lua ink_store.lua ink_transform.lua pluginupdater.lua; do
    cp "$repo_root/fingerink.koplugin/$file" \
        "$staging_dir/fingerink.koplugin/$file"
done

(
    cd "$staging_dir"
    zip -qr "$temporary_archive" fingerink.koplugin
)
mv "$temporary_archive" "$archive_path"

echo "Created $archive_path"
