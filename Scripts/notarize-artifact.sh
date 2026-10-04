#!/usr/bin/env bash
set -euo pipefail

# Credentials live in the ephemeral CI keychain; no passwords are passed here.
[[ $# = 1 ]] || { echo 'Usage: notarize-artifact.sh APP_OR_DMG' >&2; exit 1; }
artifact=$1
: "${ILLIQUID_NOTARY_PROFILE:?Notarization requires ILLIQUID_NOTARY_PROFILE}"
arguments=(--keychain-profile "$ILLIQUID_NOTARY_PROFILE")
[[ -z "${ILLIQUID_NOTARY_KEYCHAIN:-}" ]] || arguments+=(--keychain "$ILLIQUID_NOTARY_KEYCHAIN")
receipt_directory="$(dirname "$artifact")/notarization"
mkdir -p "$receipt_directory"
temporary=
temporary_directory=
cleanup() {
    [[ -z "$temporary" ]] || rm -f -- "$temporary"
    [[ -z "$temporary_directory" ]] || rmdir "$temporary_directory"
}
trap cleanup EXIT
case "$artifact" in
    *.app)
        [[ -d "$artifact" ]] || { echo 'Application is missing' >&2; exit 1; }
        codesign --verify --deep --strict "$artifact"
        temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/illiquid-notary.XXXXXX")
        temporary="$temporary_directory/Illiquid.zip"
        ditto -c -k --keepParent "$artifact" "$temporary"
        submission=$temporary
        name=app
        ;;
    *.dmg)
        [[ -f "$artifact" ]] || { echo 'DMG is missing' >&2; exit 1; }
        codesign --verify --strict "$artifact"
        submission=$artifact
        name=dmg
        ;;
    *) echo 'Only an app or DMG may be notarized' >&2; exit 1 ;;
esac
xcrun notarytool submit "$submission" "${arguments[@]}" --output-format json \
    > "$receipt_directory/$name-submission.json"
identifier=$(python3 - "$receipt_directory/$name-submission.json" <<'PY'
import json, sys, uuid
print(uuid.UUID(json.load(open(sys.argv[1]))['id']))
PY
)
wait_result=0
xcrun notarytool wait "$identifier" "${arguments[@]}" --timeout 20m --output-format json \
    > "$receipt_directory/$name-result.json" || wait_result=$?
xcrun notarytool log "$identifier" "${arguments[@]}" "$receipt_directory/$name-log.json" || true
python3 - "$receipt_directory/$name-result.json" "$wait_result" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if sys.argv[2] != '0' or result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept notarization; inspect the notarization receipts')
print('Apple notarization accepted:', result['id'])
PY
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
if [[ "$name" = app ]]; then
    spctl --assess --type execute --verbose=4 "$artifact"
else
    spctl --assess --type open --context context:primary-signature --verbose=4 "$artifact"
fi
