#!/bin/zsh
# MeetingCardSwift: regenerate the Xcode project, test, Release build, sign, install.
#   scripts/build.sh          test + build + sign + install to ~/Applications/MeetingCardSwift.app
#   scripts/build.sh test     xcodegen + xcodebuild test only
#   scripts/build.sh build    test + build + sign (no install)
#   --test-id (with any mode, e.g. scripts/build.sh build --test-id): the test identity. Bundle id
#     com.slatz.meetingcard.swift.test, named "MeetingCard (Test)" (permission prompts, System
#     Settings), so its UserDefaults domain, Keychain item (com.slatz.meetingcard.swift.test.openai),
#     privacy grants, log and Application Support dir (MeetingCardSwift-Test) are its own. Release
#     build in build/dd-test; installs to ~/Applications/MeetingCardSwift-Test.app, which is never
#     registered as a login item.
#     Mac hand checks use it (docs/MAC_DEMO_CHECKS.md).
# Tests include the ListenMoreKit package (swift test); SKIP_KIT_TESTS=1 skips them.
# Never launches the app.
# Signing: $SIGN_IDENTITY if set, else a Keychain identity named "Local Self-Signed" if present,
# else ad-hoc ("-"). NO hardened runtime (no Team ID: library validation would reject our own
# embedded framework; nothing to notarize). A stable identity keeps the login-item approval across
# rebuilds; ad-hoc works but macOS may treat each rebuild as a new app.
# Needs: Xcode, xcodegen ($XCODEGEN, else on PATH, else ~/.local/bin/xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build   # fresh checkouts have no build/ (gitignored); the test log below lives in it
TEST_ID=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --test-id) TEST_ID=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) ARGS+=("$a") ;;
  esac
done
MODE="${ARGS[1]:-install}"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then ID="$SIGN_IDENTITY"
elif [[ "$(security find-identity -v -p codesigning 2>/dev/null || true)" == *'"Local Self-Signed"'* ]]; then ID="Local Self-Signed"
else ID="-"; fi
DEST="$HOME/Applications/MeetingCardSwift.app"
DD="build/dd"
RELEASE_DD="$DD"; IDENTITY=()
if (( TEST_ID )); then
  DEST="$HOME/Applications/MeetingCardSwift-Test.app"
  RELEASE_DD="build/dd-test"
  IDENTITY=(MEETINGCARD_APP_ID=com.slatz.meetingcard.swift.test "MEETINGCARD_APP_NAME=MeetingCard (Test)")
fi
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo "$HOME/.local/bin/xcodegen")}"
[[ -x "$XCODEGEN" ]] || { echo "xcodegen not found: brew install xcodegen (or set XCODEGEN)" >&2; exit 1; }

"$XCODEGEN" generate --quiet
xcodebuild -project MeetingCardSwift.xcodeproj -scheme MeetingCardSwift -derivedDataPath "$DD" test \
  >build/test.log 2>&1 || { grep -E "error:|failed" build/test.log | head -40; echo "TESTS FAILED (build/test.log)"; exit 1; }
grep -E "Executed [0-9]+ tests" build/test.log | tail -1
# The call-coach Kit (its live OpenAI tests skip unless LISTEN_MORE_LIVE=1).
if [[ "${SKIP_KIT_TESTS:-0}" != 1 ]]; then
  (cd Packages/ListenMoreKit && swift test --scratch-path ../../build/kit) >build/kit-test.log 2>&1 \
    || { grep -E "error:|failed" build/kit-test.log | head -40; echo "KIT TESTS FAILED (build/kit-test.log)"; exit 1; }
  grep -E "Executed [0-9]+ tests" build/kit-test.log | tail -1
fi
[[ "$MODE" == test ]] && exit 0

xcodebuild -project MeetingCardSwift.xcodeproj -scheme MeetingCardSwift -configuration Release \
  -derivedDataPath "$RELEASE_DD" build "${IDENTITY[@]}" >build/build.log 2>&1 || { grep -E "error:" build/build.log | head -40; exit 1; }
APP="$RELEASE_DD/Build/Products/Release/MeetingCardSwift.app"
# Inside-out: framework first, then the app (no --deep).
codesign -f -s "$ID" "$APP/Contents/Frameworks/MeetingCardCore.framework"
codesign -f -s "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
[[ "$MODE" == build ]] && { echo "built $APP (signed: $ID)"; exit 0; }

if pgrep -f "${DEST:t}/Contents/MacOS/MeetingCardSwift" >/dev/null; then
  echo "${DEST:t:r} is running; quit it first (this script never kills it)." >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
codesign --verify --strict --verbose=2 "$DEST"
echo "installed $DEST (not launched)"
