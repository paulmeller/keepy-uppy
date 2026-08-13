app_name := "Keepy Uppy"
scheme := "Keepy Uppy"
project := "Keepy Uppy.xcodeproj"
derived_data := "build"
app_path := derived_data + "/Build/Products/Debug/" + app_name + ".app"
archive_path := derived_data + "/" + app_name + ".xcarchive"
export_path := derived_data + "/export"
dmg_path := derived_data + "/" + app_name + ".dmg"
# env_var_or_default, NOT env_var: just evaluates top-level assignments
# eagerly when the justfile loads, and env_var() aborts on a missing
# variable — plain env_var() here would break EVERY recipe (including
# `just build` and `just test`) on any machine without signing credentials
# exported. The signing recipes guard for empty values themselves.
signing_identity := env_var_or_default("KEEPY_UPPY_SIGNING_IDENTITY", "")
team_id := env_var_or_default("KEEPY_UPPY_TEAM_ID", "")
notary_profile := env_var_or_default("KEEPY_UPPY_NOTARY_PROFILE", "")
cask_tap := env_var_or_default("KEEPY_UPPY_CASK_TAP", "../homebrew-tap")

generate:
    xcodegen generate

build: generate
    xcodebuild build \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Debug \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGN_IDENTITY=-

test: generate
    xcodebuild test \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGN_IDENTITY=-

run: build
    open "{{app_path}}"

# Both credentials are validated *before* the source file is touched, so a
# missing one aborts with a clean tree. The `trap ... EXIT` is installed
# before the substitution and runs on normal exit, a failing `xcodebuild`,
# and an interrupt alike — an end-of-recipe restore line only runs after
# success, which is exactly the gap that used to leave a real Team ID sitting
# in a tracked, committable file. This recipe used to depend on a separate
# `teamid` recipe (substitute) and rely on `export` calling a separate
# `restore-teamid` (restore) after `xcodebuild -exportArchive`; both are
# folded in here since `-exportArchive` repackages an already-built archive
# and never rereads Shared/SigningRequirement.swift, so nothing downstream
# needs the substitution to still be present once `archive`'s own
# `xcodebuild` call has finished.
# Substitutes the real Team ID into the signing requirement, archives, and restores the placeholder on every exit path.
# Bumps the build number stamped into all four targets.
#
# CFBundleVersion is what macOS uses to order builds *within* one marketing
# version, so two notarized builds sharing a number are indistinguishable to
# the system — and to anyone reporting a bug against "0.1.0". `notarize`
# depends on this, so every build that actually leaves this machine gets its
# own number; `archive` deliberately does not, since it is also the local
# signing smoke test and shouldn't churn a tracked file every run.
#
# It edits project.yml, which is tracked. That is the point: unlike the Team
# ID substitution below, this change is meant to be committed, so the number
# keeps climbing across releases instead of resetting.
bump:
    #!/usr/bin/env bash
    set -euo pipefail
    current=$(grep -oE 'CURRENT_PROJECT_VERSION: "[0-9]+"' project.yml \
        | grep -oE '[0-9]+' | sort -n | tail -1)
    next=$((current + 1))
    # Rewrites every target's value to the same number, so the four cannot
    # drift apart even if one is edited by hand.
    sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[0-9]+\"/CURRENT_PROJECT_VERSION: \"$next\"/g" project.yml
    echo "build number $current -> $next  (commit project.yml with the release)"

archive: generate
    #!/usr/bin/env bash
    set -euo pipefail
    test -n "{{signing_identity}}" || { echo "Set KEEPY_UPPY_SIGNING_IDENTITY (see README)"; exit 1; }
    test -n "{{team_id}}" || { echo "Set KEEPY_UPPY_TEAM_ID (see README)"; exit 1; }
    trap 'git checkout -- Shared/SigningRequirement.swift' EXIT
    sed -i '' 's/REPLACE_WITH_TEAM_ID/{{team_id}}/g' Shared/SigningRequirement.swift
    xcodebuild archive \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Release \
        -archivePath "{{archive_path}}" \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGN_IDENTITY="{{signing_identity}}" \
        DEVELOPMENT_TEAM="{{team_id}}"

export: archive
    rm -rf "{{export_path}}"
    sed "s/KEEPY_UPPY_TEAM_ID/{{team_id}}/" packaging/ExportOptions.plist > "{{derived_data}}/ExportOptions.plist"
    xcodebuild -exportArchive \
        -archivePath "{{archive_path}}" \
        -exportPath "{{export_path}}" \
        -exportOptionsPlist "{{derived_data}}/ExportOptions.plist"

dmg: export
    rm -f "{{dmg_path}}"
    hdiutil create -volname "{{app_name}}" \
        -srcfolder "{{export_path}}/{{app_name}}.app" \
        -ov -format UDZO \
        "{{dmg_path}}"

notarize: bump dmg
    @test -n "{{notary_profile}}" || { echo "Set KEEPY_UPPY_NOTARY_PROFILE (see README)"; exit 1; }
    xcrun notarytool submit "{{dmg_path}}" \
        --keychain-profile "{{notary_profile}}" \
        --wait
    xcrun stapler staple "{{dmg_path}}"
    @echo "shipped $(plutil -extract CFBundleShortVersionString raw "{{export_path}}/{{app_name}}.app/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw "{{export_path}}/{{app_name}}.app/Contents/Info.plist"))"

# Point the Homebrew cask at a release that is already published:
# `just cask v0.1.1`.
#
# Hashes the *published* asset rather than the one in {{derived_data}}. A
# sha256 taken from the local build is right only for as long as the two
# stay byte-identical, and nothing enforces that they do — hashing what
# users will actually download is the only version of this that cannot
# drift silently. `curl -f` is what turns a wrong tag into a failure here
# rather than a cask nobody can install.
#
# Deliberately NOT chained to `notarize`. That recipe staples a DMG; it
# does not publish one. The URL written here doesn't exist until the
# release has been created, and a cask pointing at a 404 is worse than a
# cask one version behind.
cask tag:
    #!/usr/bin/env bash
    set -euo pipefail
    cask="{{cask_tap}}/Casks/keepy-uppy.rb"
    test -f "$cask" || { echo "no cask at $cask — set KEEPY_UPPY_CASK_TAP"; exit 1; }
    url="https://github.com/paulmeller/keepy-uppy/releases/download/{{tag}}/Keepy.Uppy.dmg"
    tmp="$(mktemp -t keepy-uppy-cask)"
    trap 'rm -f "$tmp"' EXIT
    echo "hashing $url"
    curl -fsSL -o "$tmp" "$url"
    sha="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    version="$(echo '{{tag}}' | sed 's/^v//')"
    sed -i '' -e "s|^  version \".*\"$|  version \"$version\"|" \
              -e "s|^  sha256 \".*\"$|  sha256 \"$sha\"|" "$cask"
    echo "cask -> $version"
    echo "        $sha"
    echo "commit and push {{cask_tap}} to publish it"
