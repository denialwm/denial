{
  runCommand,
  package,
  pluginManager,
}:

runCommand "denial-path-contract" { } ''
  test -x ${package}/bin/denial-session
  test -x ${package}/bin/deniald
  test -x ${package}/bin/denial-settings
  test ! -e ${package}/bin/denial-plugin-manager
  test -x ${pluginManager}/bin/denial-plugins
  test -f ${pluginManager}/lib/denial/plugin-build-kit/kit.json
  test ! -e ${pluginManager}/lib/denial/plugin-build-kit/flutter/bin/cache/dart-sdk
  cmp ${pluginManager}/lib/denial/plugin-build-kit/runtime/.denial-ui-source.json \
    ${package}/lib/denial/flutter/.denial-ui-source.json
  ${pluginManager}/bin/denial-plugins --brief status > plugin-status.json
  grep --fixed-strings '"buildKitAvailable": true' plugin-status.json
  grep --fixed-strings '"available": true' plugin-status.json
  grep --fixed-strings 'package_prefix=' ${package}/bin/.denial-session-wrapped
  grep --fixed-strings 'DEFAULT_BUNDLE="$package_prefix/lib/denial/flutter"' \
    ${package}/bin/.denial-session-wrapped
  ! grep --recursive --fixed-strings '/usr/bin/denial' \
    ${package}/share/wayland-sessions \
    ${package}/share/applications \
    ${package}/share/dbus-1/services \
    ${package}/lib/systemd/user

  test_root="$TMPDIR/output-config"
  config_home="$test_root/config"
  state_home="$test_root/state"
  source_config="$test_root/declarative-outputs.conf"
  mkdir -p "$config_home/denial" "$state_home"
  printf 'eDP-1=0,0\n' >"$source_config"
  ln -s "$source_config" "$config_home/denial/outputs.conf"
  output_state="$(
    HOME="$test_root/home" \
      XDG_CONFIG_HOME="$config_home" \
      XDG_STATE_HOME="$state_home" \
      ${package}/bin/denial-session --print-output-config
  )"
  test "$output_state" = "$state_home/denial/outputs.conf"
  grep -Fqx 'eDP-1=0,0' "$output_state"

  printf 'runtime-change\n' >"$output_state"
  HOME="$test_root/home" \
    XDG_CONFIG_HOME="$config_home" \
    XDG_STATE_HOME="$state_home" \
    ${package}/bin/denial-session --print-output-config >/dev/null
  grep -Fqx 'runtime-change' "$output_state"

  rm "$output_state"
  HOME="$test_root/home" \
    XDG_CONFIG_HOME="$config_home" \
    XDG_STATE_HOME="$state_home" \
    ${package}/bin/denial-session --print-output-config >/dev/null
  grep -Fqx 'eDP-1=0,0' "$output_state"

  printf 'eDP-1=120,0\n' >"$source_config"
  HOME="$test_root/home" \
    XDG_CONFIG_HOME="$config_home" \
    XDG_STATE_HOME="$state_home" \
    ${package}/bin/denial-session --print-output-config >/dev/null
  grep -Fqx 'eDP-1=120,0' "$output_state"
  touch $out
''
