#!/usr/bin/env bash

# SwiftPM places the selected binary framework beside the app executable.
# Copy the complete versioned framework, including helpers, resources and links.
illiquid_embed_sparkle() {
    local binary_directory=$1 app_bundle=$2
    local source="$binary_directory/Sparkle.framework"
    [[ -f "$source/Sparkle" ]] || { printf 'Sparkle.framework is missing: %s\n' "$source" >&2; return 1; }
    ditto "$source" "$app_bundle/Contents/Frameworks/Sparkle.framework"
    local notice_directory="$app_bundle/Contents/Resources/Licenses/ThirdParty/Sparkle"
    mkdir -p "$notice_directory"
    ditto "$repository_root/Licenses/ThirdParty/Sparkle/LICENSE" "$notice_directory/LICENSE"
    [[ -L "$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/Current" ]] || return 1
    [[ -x "$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" ]] || return 1
}

# Frameworks and helper bundles must be signed after their contained binaries.
# Preserve Sparkle helper sandbox entitlements when changing signing identity.
illiquid_sign_nested_code() {
    local frameworks=$1
    shift
    local nested_code
    while IFS= read -r -d '' nested_code; do
        codesign "$@" --preserve-metadata=entitlements "$nested_code" || return 1
    done < <(find "$frameworks" -depth \
        \( -type f ! -name '*.cstemp' \( -name '*.dylib' -o -perm -111 \) \
        -o -type d \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) \) -print0)
}
