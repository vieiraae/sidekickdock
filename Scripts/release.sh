#!/bin/bash
# Builds, signs, notarises and packages SidekickDock for distribution outside the App Store.
#
# The Mac App Store is not a route for this app: it resolves private SkyLight symbols and
# drives other applications through the Accessibility API, and neither survives the sandbox.
# Developer ID with notarisation is the supported path for a utility like this.
#
#   ./Scripts/release.sh              build and notarise at the current version
#   ./Scripts/release.sh 1.1          set the marketing version first, bumping the build number
#   ./Scripts/release.sh --dry-run    do everything except submit to Apple
#
# One-time setup, storing an app-specific password from appleid.apple.com:
#
#   xcrun notarytool store-credentials sidekickdock-notary \
#     --apple-id you@example.com --team-id 8229P7U5PR --password xxxx-xxxx-xxxx-xxxx
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/SidekickDock.app"
DIST="$ROOT/build/dist"
PLIST="$ROOT/Resources/Info.plist"
PROFILE="${NOTARY_PROFILE:-sidekickdock-notary}"

DRY_RUN=0
VERSION=""
for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    -*) echo "Unknown option: $argument" >&2; exit 2 ;;
    *) VERSION="$argument" ;;
  esac
done

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"; }

# --- Signing identity -------------------------------------------------------------------

# Notarisation checks the signature came from a Developer ID certificate, so the self-signed
# identity used for everyday builds cannot be used here.
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
  | grep "Developer ID Application:" | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')}"

if [ -z "$IDENTITY" ]; then
  cat >&2 <<'MESSAGE'
No "Developer ID Application" certificate found in the keychain.

Create one in Xcode (Settings > Accounts > Manage Certificates > + > Developer ID
Application), or download it from developer.apple.com/account/resources/certificates.
MESSAGE
  exit 1
fi
TEAM_ID="$(sed -n 's/.*(\(.*\))$/\1/p' <<<"$IDENTITY")"

# --- Version ----------------------------------------------------------------------------

if [ -n "$VERSION" ]; then
  # The build number has to increase on every submission, so it is derived rather than typed.
  BUILD=$(( $(plist_get CFBundleVersion) + 1 ))
  plist_set CFBundleShortVersionString "$VERSION"
  plist_set CFBundleVersion "$BUILD"
  echo "==> Version set to $VERSION ($BUILD) — remember to commit Resources/Info.plist"
fi
VERSION="$(plist_get CFBundleShortVersionString)"
DMG="$DIST/SidekickDock-$VERSION.dmg"

echo "==> Releasing SidekickDock $VERSION ($(plist_get CFBundleVersion))"
echo "    Identity: $IDENTITY"
[ "$DRY_RUN" = 1 ] && echo "    Dry run: nothing will be submitted to Apple"

# --- Build ------------------------------------------------------------------------------

# Hardened runtime and a secure timestamp are both preconditions for notarisation. No
# entitlements are needed: the app is not sandboxed, and Accessibility and Screen Recording
# are granted by the user at run time rather than declared here.
SIGN_IDENTITY="$IDENTITY" SIGN_TIMESTAMP="--timestamp" "$ROOT/Scripts/build.sh" release

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

submit() {
  local target="$1"
  if [ "$DRY_RUN" = 1 ]; then
    echo "    (dry run) would submit $(basename "$target")"
    return
  fi
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MESSAGE

No notarytool credentials found under the profile "$PROFILE". Store them once with:

  xcrun notarytool store-credentials $PROFILE \\
    --apple-id you@example.com --team-id $TEAM_ID --password xxxx-xxxx-xxxx-xxxx

The password is an app-specific password from appleid.apple.com, not your Apple ID password.
MESSAGE
    exit 1
  fi
  xcrun notarytool submit "$target" --keychain-profile "$PROFILE" --wait
}

# --- Notarise the app -------------------------------------------------------------------

# The app is notarised and stapled in its own right, not only inside the disk image. Without
# its own ticket it would need to reach Apple to be verified the first time it runs, so a
# machine that is offline — or behind a filtering proxy — would refuse to open it.
echo "==> Notarising the app"
ditto -c -k --keepParent "$APP" "$DIST/SidekickDock.zip"
submit "$DIST/SidekickDock.zip"

if [ "$DRY_RUN" = 0 ]; then
  xcrun stapler staple "$APP"
fi
rm -f "$DIST/SidekickDock.zip"

# --- Package ----------------------------------------------------------------------------

echo "==> Building disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -volname "SidekickDock" -srcfolder "$STAGE" -ov -format ULFO "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# The disk image is notarised too, so Gatekeeper approves it at mount time rather than
# showing the unidentified-developer warning before the user reaches the app inside.
echo "==> Notarising the disk image"
submit "$DMG"

if [ "$DRY_RUN" = 0 ]; then
  xcrun stapler staple "$DMG"

  echo "==> Verifying the result"
  spctl --assess --type exec --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "==> Ready: $DMG"
