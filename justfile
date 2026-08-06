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

archive: generate
    @test -n "{{signing_identity}}" || { echo "Set KEEPY_UPPY_SIGNING_IDENTITY (see README)"; exit 1; }
    @test -n "{{team_id}}" || { echo "Set KEEPY_UPPY_TEAM_ID (see README)"; exit 1; }
    xcodebuild archive \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Release \
        -archivePath "{{archive_path}}" \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGN_IDENTITY="{{signing_identity}}" \
        DEVELOPMENT_TEAM="{{team_id}}"

export: archive
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

notarize: dmg
    @test -n "{{notary_profile}}" || { echo "Set KEEPY_UPPY_NOTARY_PROFILE (see README)"; exit 1; }
    xcrun notarytool submit "{{dmg_path}}" \
        --keychain-profile "{{notary_profile}}" \
        --wait
    xcrun stapler staple "{{dmg_path}}"
