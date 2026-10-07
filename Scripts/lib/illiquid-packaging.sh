#!/usr/bin/env bash

illiquid_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

illiquid_is_system_dependency() {
    case "$1" in
        /usr/lib/*|/System/Library/*|/Library/Apple/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

illiquid_dependency_reference_is_allowed() {
    case "$1" in
        *libmpv*|*OpenGL*) return 1 ;;
        /usr/lib/*|/System/Library/*|/Library/Apple/System/*) return 0 ;;
        @rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
        *) return 1 ;;
    esac
}

illiquid_architectures_cover() {
    local required=$1
    local actual=$2
    local architecture
    for architecture in $required; do
        case " $actual " in
            *" $architecture "*) ;;
            *) return 1 ;;
        esac
    done
}

illiquid_signing_identity() {
    local mode=$1
    local developer_identity=${2:-}
    case "$mode" in
        unsigned) printf '%s\n' '' ;;
        adhoc) printf '%s\n' '-' ;;
        developer-id)
            [[ -n "$developer_identity" ]] || return 1
            printf '%s\n' "$developer_identity"
            ;;
        *) return 1 ;;
    esac
}

illiquid_dependencies_for() {
    otool -L "$1" | sed -n '/^[[:space:]]/p' | sed -E \
        's/^[[:space:]]*//; s/[[:space:]]+\(compatibility version.*$//'
}

illiquid_rpaths_for() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { expecting_path = 1; next }
        expecting_path && $1 == "path" { print $2; expecting_path = 0 }
    '
}

illiquid_stage_dmg() {
    local app_bundle=$1
    local staging_directory=$2
    [[ "$(basename "$app_bundle")" = Illiquid.app && -d "$app_bundle" ]] || return 1
    mkdir -p "$staging_directory"
    ditto "$app_bundle" "$staging_directory/Illiquid.app"
    ln -s /Applications "$staging_directory/Applications"
    chmod 0755 "$staging_directory" "$staging_directory/Illiquid.app"
}

illiquid_process_for_executable() {
    local executable=$1
    ps -ax -o pid=,command= | awk -v executable="$executable" '
        {
            sub(/^[[:space:]]*/, "")
            process_id = $1
            sub(/^[^[:space:]]+[[:space:]]+/, "")
        }
        $0 == executable || index($0, executable " ") == 1 {
            print process_id
            exit
        }
    '
}

illiquid_launch_smoke() {
    local supplied_app_bundle=$1
    local profile_directory=$2
    local media_file=${3:-}
    local app_bundle
    app_bundle=$(
        cd -P "$(dirname "$supplied_app_bundle")"
        printf '%s/%s\n' "$PWD" "$(basename "$supplied_app_bundle")"
    )
    mkdir -p "$profile_directory"
    profile_directory=$(cd -P "$profile_directory" && pwd)
    if [[ -n "$media_file" ]]; then
        media_file=$(
            cd -P "$(dirname "$media_file")"
            printf '%s/%s\n' "$PWD" "$(basename "$media_file")"
        )
    fi
    local executable="$app_bundle/Contents/MacOS/Illiquid"
    [[ -x "$executable" ]] || return 1
    local lsregister
    lsregister=$(
        find /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework \
            -name lsregister -type f -print -quit
    )
    [[ -x "$lsregister" ]] || return 1
    "$lsregister" -f "$app_bundle"

    local open_arguments=(
        -n -g
        --env "CFFIXED_USER_HOME=$profile_directory"
        --env 'ILLIQUID_INSTALL_SMOKE=1'
        -a "$app_bundle"
    )
    [[ -z "$media_file" ]] || open_arguments+=("$media_file")
    open "${open_arguments[@]}"

    local process_id=
    local attempt
    for attempt in {1..20}; do
        process_id=$(illiquid_process_for_executable "$executable")
        [[ -z "$process_id" ]] || break
        sleep 0.25
    done
    [[ -n "$process_id" ]] || return 1
    sleep 2
    kill -0 "$process_id" 2>/dev/null || return 1
    kill -TERM "$process_id" 2>/dev/null || return 1
    for attempt in {1..40}; do
        kill -0 "$process_id" 2>/dev/null || return 0
        sleep 0.25
    done
    kill -KILL "$process_id" 2>/dev/null || true
    return 1
}
