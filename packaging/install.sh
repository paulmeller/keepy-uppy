#!/bin/bash
#
# One command to put Keepy Uppy on a Mac you are not sitting in front of:
#
#   curl -fsSL https://raw.githubusercontent.com/paulmeller/keepy-uppy/main/packaging/install.sh | bash
#
# Downloads the latest notarized release, verifies it, installs it to
# /Applications and registers the background services. Prints what it did.
#
# **What this does NOT do is hide the privilege boundary.** Installing the
# daemon needs an administrator, and `setup` is what asks — through
# SMAppService, so the prompt comes from macOS rather than from a script asking
# you to type a password into a pipe. If that trade is not one you want to make
# from a `curl`, every step below is a command you can run yourself, and the
# README lists them.
#
# Deliberately refuses to run as root: `setup` registers a *per-user* agent
# alongside the daemon, and one registered by root belongs to root. A sudo'd
# install would look like it worked and then watch nothing.

set -euo pipefail

REPO="paulmeller/keepy-uppy"
APP="Keepy Uppy.app"
DEST="/Applications"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "don't run this with sudo — it registers a per-user agent, and root's is not yours. Run it as you; macOS will ask for an administrator when it needs one."

case "$(uname -s)" in
  Darwin) ;;
  *) fail "macOS only." ;;
esac

# 13.0 is the floor, and it is not arbitrary: SMAppService (the whole
# daemon-registration path) and MenuBarExtra both arrived in Ventura.
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "needs macOS 13 or later; this is $(sw_vers -productVersion)."

say "Finding the latest release…"
asset=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | awk -F'"' '/browser_download_url.*\.dmg/ {print $4; exit}')
[ -n "$asset" ] || fail "could not find a .dmg on the latest release."
version=$(printf '%s' "$asset" | awk -F/ '{print $(NF-1)}')
say "Downloading $version…"

tmp=$(mktemp -d)
# Clean up whatever stage we die at, including a mounted image.
cleanup() {
  [ -n "${mnt:-}" ] && hdiutil detach "$mnt" -quiet 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

curl -fsSL -o "$tmp/keepy-uppy.dmg" "$asset"

# Gatekeeper's own answer, before anything is copied. `spctl` here is not
# decoration: it is the difference between "this file downloaded" and "Apple
# notarized this build", and a script that installs an app to /Applications
# should be the thing that checks, not the thing that assumes.
mnt="$tmp/mnt"
mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$tmp/keepy-uppy.dmg" >/dev/null
[ -d "$mnt/$APP" ] || fail "that disk image does not contain $APP."

say "Checking the signature…"

# TWO checks, because notarization alone does not say *whose* app this is.
#
# `spctl` answers "Apple notarized this and Gatekeeper would run it", which is
# true of every notarized Developer ID app in the world. On its own it would
# accept any such app that happened to be named "Keepy Uppy.app" in a release
# asset — and this script then runs that app's `setup`, which asks for an
# administrator. That is a straight path from "the download was swapped" to
# "root", so the identity has to be pinned as well.
#
# The requirement below is the one the app's own XPC services pin, and the same
# shape `codesign --requirements` embeds: Apple's root, this bundle identifier,
# and this team's leaf certificate. `codesign -R` is the check rather than a
# grep of `codesign -dv` output, because a requirement is evaluated by the same
# code that enforces one, and string-matching a human-readable dump is how you
# get fooled by a bundle id that merely *contains* the right text.
spctl -a -vvv -t install "$mnt/$APP" 2>&1 | grep -q "source=Notarized Developer ID" \
  || fail "the downloaded app is not notarized — refusing to install it."

codesign --verify --strict -R \
  '=anchor apple generic and identifier "au.com.workwireless.keepy-uppy" and certificate leaf[subject.OU] = "2F2JR84D4V"' \
  "$mnt/$APP" 2>/dev/null \
  || fail "the downloaded app is notarized but is not Keepy Uppy signed by its own team — refusing to install it."

if [ -e "$DEST/$APP" ]; then
  say "Replacing the copy already in $DEST…"
  # Stop the old one first. `reset` hands the machine's sleep behaviour back
  # before unregistering; skipping it can strand SleepDisabled with nothing
  # left running that could clear it. Failure here is not fatal — a half
  # installed or already-unregistered copy is exactly when it cannot succeed —
  # but it must be *tried*.
  "$DEST/$APP/Contents/MacOS/keepy-uppy" reset >/dev/null 2>&1 || true
  rm -rf "$DEST/$APP"
fi

say "Installing to $DEST…"
cp -R "$mnt/$APP" "$DEST/"

say "Registering the background services…"
say "(macOS will ask for an administrator — that is the daemon being installed.)"
"$DEST/$APP/Contents/MacOS/keepy-uppy" setup

cat <<EOF

$version installed.

  keepy-uppy status          what this Mac is doing
  keepy-uppy on --for 8h     keep it awake, lid closed

If \`keepy-uppy\` is not on your PATH yet, either open the app and use
Settings → CLI & Advanced, or link it yourself:

  sudo ln -sf "$DEST/$APP/Contents/MacOS/keepy-uppy" /usr/local/bin/keepy-uppy

EOF
