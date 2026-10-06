{
  runCommand,
  package,
}:

runCommand "denial-path-contract" { } ''
  test -x ${package}/bin/denial-session
  test -x ${package}/bin/deniald
  test -x ${package}/bin/denial-settings
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
