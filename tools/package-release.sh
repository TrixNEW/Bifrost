#!/usr/bin/env sh
# Packages zig-out and .deps/native into dist/bifrost-<tag>-linux-x86_64.tar.gz with every license it ships
set -eu

cd "$(dirname "$0")/.."
tag=${1:?usage: package-release.sh <tag>}
name=bifrost-$tag-linux-x86_64
out=dist/$name
rm -rf "$out"
mkdir -p "$out/bin" "$out/lib" "$out/config" "$out/licenses"

install -m 755 zig-out/bin/bifrost "$out/bin/bifrost"
cp -P .deps/native/lib/*.so* "$out/lib/"
cp config/bifrost.toml "$out/config/"
cp LICENSE NOTICE README.md "$out/"
printf '#!/bin/sh\ncd "$(dirname "$0")"\nLD_LIBRARY_PATH=$PWD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} exec ./bin/bifrost "$@"\n' >"$out/run.sh"
chmod 755 "$out/run.sh"

native=.deps/nethernet-zig/.deps
for pair in libdatachannel:libdatachannel libjuice:libdatachannel/deps/libjuice usrsctp:libdatachannel/deps/usrsctp \
    plog:libdatachannel/deps/plog mbedtls:mbedtls; do
    dir=$native/${pair#*:}
    mkdir -p "$out/licenses/${pair%%:*}"
    found=0
    for file in "$dir"/LICENSE* "$dir"/COPYING* "$dir"/NOTICE*; do
        [ -f "$file" ] && cp "$file" "$out/licenses/${pair%%:*}/" && found=1
    done
    [ "$found" = 1 ] || { echo "no license file in $dir" >&2; exit 1; }
done

# Zig packages compiled into the binary; tracy is only fetched for profiling builds
# Packages can vendor others (bedwire carries libdeflate), and those are named after their own directory
for dir in zig-pkg/*/; do
    [ -d "$dir/profiler" ] && continue
    pkg=$(basename "$dir")
    pkg=${pkg%%-[0-9]*}
    find "${dir%/}" -maxdepth 3 -type f \( -name 'LICENSE*' -o -name 'COPYING*' -o -name 'NOTICE*' \) | while read -r file; do
        owner=$(dirname "$file")
        name=$pkg
        [ "$owner" = "${dir%/}" ] || name=$(basename "$owner")
        mkdir -p "$out/licenses/$name"
        cp "$file" "$out/licenses/$name/"
    done
done
zio=$(sed -n 's/.*lalinsky\/zio#\([0-9a-f]\{40\}\).*/\1/p' build.zig.zon)
mkdir -p "$out/licenses/zio"
curl -fsSL --proto '=https' --retry 3 -o "$out/licenses/zio/LICENSE" "https://raw.githubusercontent.com/lalinsky/zio/$zio/LICENSE"
# Same license as Bifrost, but their packages leave the file out
for pkg in bedwire; do
    [ -d "$out/licenses/$pkg" ] || { mkdir -p "$out/licenses/$pkg" && cp LICENSE "$out/licenses/$pkg/LICENSE"; }
done

tar -C dist -czf "dist/$name.tar.gz" "$name"
(cd dist && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
echo "dist/$name.tar.gz"
