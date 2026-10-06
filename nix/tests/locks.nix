{
  runCommand,
  yq-go,
  jq,
  source,
  flutterSource,
}:

runCommand "denial-nix-lock-consistency"
  {
    nativeBuildInputs = [
      yq-go
      jq
    ];
  }
  ''
    check_pub_lock() {
      source_lock="$1"
      generated_lock="$2"
      source_hash="$(sha256sum "$source_lock" | cut -d ' ' -f 1)"
      expected_hash="$(jq -er .source_sha256 "$generated_lock")"
      test "$source_hash" = "$expected_hash"
      yq -o=json '.' "$source_lock" | jq --sort-keys . >source.json
      jq 'del(.source_sha256)' "$generated_lock" | jq --sort-keys . >generated.json
      cmp source.json generated.json
    }

    source_lock_hash="$(sha256sum \
      ${source}/prebuilt/flutter-engine/SOURCE_LOCK.json | cut -d ' ' -f 1)"
    engine_revision="$(tr -d '\n' < \
      ${source}/prebuilt/flutter-engine/linux-x64-release/ENGINE_REVISION)"
    jq -e \
      --arg engine_revision "$engine_revision" \
      --arg fake 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
      --arg source_hash "$source_lock_hash" \
      --slurpfile source_lock ${source}/prebuilt/flutter-engine/SOURCE_LOCK.json \
      '.schema_version == 1
        and .source_lock_sha256 == $source_hash
        and .flutter.revision == $source_lock[0].flutter.revision
        and .skia.revision == $source_lock[0].skia.revision
        and .depot_tools.revision == $source_lock[0].depot_tools.revision
        and .engine.revision == $engine_revision
        and ([
          .flutter.hash,
          .depot_tools.hash,
          .engine.source_hash,
          .dart.hash,
          .swiftshader.hash,
          .material_fonts.hash
        ] | all(. != $fake and test("^sha256-[A-Za-z0-9+/]{43}=$")))' \
      ${source}/nix/flutter-engine-lock.json >/dev/null

    jq -e '
      .schema_version == 1
      and .name == "denial"
      and .uri == "https://denial.cachix.org"
      and .public_key ==
        "denial.cachix.org-1:wd8YTnvPmugFrtdMJWtR1XdVknR3/g2nmBJkT+vAruo="
    ' ${source}/nix/cachix-cache.json >/dev/null
    grep --fixed-strings \
      'extra-substituters = [ "https://denial.cachix.org" ];' \
      ${source}/flake.nix >/dev/null
    grep --fixed-strings \
      '"denial.cachix.org-1:wd8YTnvPmugFrtdMJWtR1XdVknR3/g2nmBJkT+vAruo="' \
      ${source}/flake.nix >/dev/null

    check_pub_lock \
      ${source}/dart_shell/pubspec.lock \
      ${source}/nix/dart_shell-pubspec-lock.json
    check_pub_lock \
      ${source}/settings_app/pubspec.lock \
      ${source}/nix/settings_app-pubspec-lock.json
    flutter_pubspec_hash="$(sha256sum \
      ${flutterSource}/packages/flutter_tools/pubspec.yaml | cut -d ' ' -f 1)"
    test "$flutter_pubspec_hash" = "$(jq -er .source_pubspec_sha256 \
      ${source}/nix/flutter-pubspec-lock.json)"
    test "$(jq -er .flutter_revision \
      ${source}/nix/flutter-pubspec-lock.json)" = "$(jq -er .flutter.revision \
      ${source}/prebuilt/flutter-engine/SOURCE_LOCK.json)"
    touch $out
  ''
