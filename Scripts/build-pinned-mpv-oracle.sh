#!/bin/zsh
set -euo pipefail

expected_revision="94335ab87ab225ca3e36e0faeac831639d3e1d4e"
source_dir="${MPV_ORACLE_SOURCE_DIR:-/tmp/superplayr-reference-src/mpv}"
build_dir="${MPV_ORACLE_BUILD_DIR:-${source_dir}/build-oracle}"

if [[ ! -d "${source_dir}/.git" ]]; then
    print -u2 "Pinned mpv checkout is missing: ${source_dir}"
    exit 1
fi
actual_revision="$(git -C "${source_dir}" rev-parse HEAD)"
if [[ "${actual_revision}" != "${expected_revision}" ]]; then
    print -u2 "mpv checkout mismatch: expected ${expected_revision}, got ${actual_revision}"
    exit 1
fi

meson_command=()
if [[ -n "${MESON_BIN:-}" ]]; then
    meson_command=("${MESON_BIN}")
elif command -v meson >/dev/null 2>&1; then
    meson_command=("$(command -v meson)")
elif python3 -c 'import mesonbuild' >/dev/null 2>&1; then
    meson_command=(python3 -m mesonbuild.mesonmain)
else
    print -u2 "Meson is required to build the pinned mpv oracle"
    exit 1
fi

if [[ -d "${build_dir}" ]]; then
    "${meson_command[@]}" setup --reconfigure "${build_dir}" "${source_dir}" \
        --buildtype=release -Dlibmpv=false -Dmanpage-build=disabled \
        -Dhtml-build=disabled -Dmacos-media-player=disabled -Dswift-build=disabled
else
    "${meson_command[@]}" setup "${build_dir}" "${source_dir}" \
        --buildtype=release -Dlibmpv=false -Dmanpage-build=disabled \
        -Dhtml-build=disabled -Dmacos-media-player=disabled -Dswift-build=disabled
fi
ninja -C "${build_dir}" mpv

binary="${build_dir}/mpv"
if [[ ! -x "${binary}" ]]; then
    print -u2 "Pinned mpv build did not produce ${binary}"
    exit 1
fi
print "revision=${actual_revision}"
print "binary=${binary}"
print "sha256=$(shasum -a 256 "${binary}" | awk '{print $1}')"
"${meson_command[@]}" configure "${build_dir}"
