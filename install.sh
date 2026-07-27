#!/bin/sh

set -eu

SIGNING_KEY='AE4108FA5E91E26BE0EE331E0F5B3AD16E023091'
PUBLIC_KEY_URL='https://denialwm.github.io/denial/denial-repo-key.asc'
PACMAN_CONFIG='/etc/pacman.conf'
# Pacman expands this architecture variable when reading pacman.conf.
# shellcheck disable=SC2016
REPOSITORY_SERVER='https://denialwm.github.io/denial/$arch'

fail() {
  printf '\nError: %s\n' "$1" >&2
  exit 1
}

# Standard input contains this script when invoked through curl, so prompts
# must use the controlling terminal.
confirm() {
  printf '%s [y/N] ' "$1" > /dev/tty

  if ! IFS= read -r answer < /dev/tty; then
    return 1
  fi

  case "$answer" in
    [yY] | [yY][eE][sS])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Report whether Pacman has no Denial section, the exact supported section, or
# a conflicting section which must be reviewed instead of silently modified.
repository_config_state() {
  awk -v expected_server="$REPOSITORY_SERVER" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    {
      line = $0
      sub(/[[:space:]]*[#;].*$/, "", line)
      line = trim(line)
      if (line == "") {
        next
      }

      if (line ~ /^\[[^]]+\]$/) {
        in_denial = line == "[denial]"
        if (in_denial) {
          sections++
        }
        next
      }

      if (!in_denial) {
        next
      }

      separator = index(line, "=")
      if (separator == 0) {
        malformed++
        next
      }
      key = trim(substr(line, 1, separator - 1))
      value = trim(substr(line, separator + 1))

      if (key == "SigLevel") {
        signature_lines++
        if (value == "Required TrustedOnly") {
          valid_signature_lines++
        }
      } else if (key == "Server") {
        server_lines++
        if (value == expected_server) {
          valid_server_lines++
        }
      }
    }

    END {
      if (sections == 0) {
        print "absent"
      } else if (sections == 1 && malformed == 0 && signature_lines == 1 &&
                 valid_signature_lines == 1 && server_lines == 1 &&
                 valid_server_lines == 1) {
        print "valid"
      } else {
        print "invalid"
      }
    }
  ' "$PACMAN_CONFIG"
}

if [ ! -f /etc/arch-release ]; then
  fail 'This installer currently supports Arch Linux only.'
fi

if [ "$(uname -m)" != 'x86_64' ]; then
  fail 'Denial packages are currently available for x86-64 only.'
fi

if [ ! -r "$PACMAN_CONFIG" ]; then
  fail "Cannot read $PACMAN_CONFIG."
fi

for required_command in awk curl gpg mktemp pacman pacman-key rm sudo tee uname; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    fail "Required command not found: $required_command"
  fi
done

if ! (: </dev/tty) 2>/dev/null || ! (: >/dev/tty) 2>/dev/null; then
  fail 'Run this installer from an interactive terminal.'
fi

repository_state="$(repository_config_state)"
case "$repository_state" in
  absent | valid)
    ;;
  *)
    fail "The existing [denial] section in $PACMAN_CONFIG does not exactly match the signed Denial repository. Review it manually before continuing."
    ;;
esac

printf '\nDenial installation\n'
printf '===================\n\n'
printf 'This installer will:\n'
printf '  1. Download the Denial public key and require this full fingerprint:\n'
printf '     %s\n' "$SIGNING_KEY"

if [ "$repository_state" = 'valid' ]; then
  printf '  2. Keep the verified [denial] entry in %s.\n' "$PACMAN_CONFIG"
else
  printf '  2. Add the signed [denial] repository to %s.\n' "$PACMAN_CONFIG"
fi

printf '  3. Run a normal full system upgrade and install Denial with Pacman.\n'
printf '\nThe script uses sudo only for Pacman, its keyring, and pacman.conf.\n\n'

if ! confirm 'Continue?'; then
  printf '\nCancelled. No system changes were made.\n'
  exit 0
fi

printf '\nChecking administrator access...\n'
if ! sudo -v; then
  fail 'Administrator access is required to configure Pacman.'
fi

key_tmp="$(mktemp -d)"
cleanup() {
  if [ -n "${key_tmp:-}" ] && [ -d "$key_tmp" ]; then
    rm -rf -- "$key_tmp"
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

key_file="$key_tmp/denial-repo-key.asc"

printf '\n1/3  Downloading and verifying the Denial signing key...\n'
if ! curl \
  --proto '=https' \
  --tlsv1.2 \
  --fail \
  --silent \
  --show-error \
  --location \
  --output "$key_file" \
  "$PUBLIC_KEY_URL"; then
  fail "Could not download the Denial public key from $PUBLIC_KEY_URL."
fi

downloaded_fingerprint="$(
  gpg \
    --batch \
    --show-keys \
    --with-colons \
    --fingerprint \
    "$key_file" \
    | awk -F: '
        $1 == "pub" {
          public_keys++
        }
        $1 == "fpr" && fingerprint == "" {
          fingerprint = toupper($10)
        }
        END {
          if (public_keys != 1 || fingerprint == "") {
            exit 1
          }
          print fingerprint
        }
      '
)" || fail 'The downloaded key is not a single valid OpenPGP public key.'

if [ "$downloaded_fingerprint" != "$SIGNING_KEY" ]; then
  fail "The downloaded key fingerprint is $downloaded_fingerprint, expected $SIGNING_KEY."
fi

if ! sudo pacman-key --add "$key_file"; then
  fail 'The verified signing key could not be added to Pacman.'
fi

if ! sudo pacman-key --lsign-key "$SIGNING_KEY"; then
  fail 'The verified signing key could not be locally trusted.'
fi

if [ "$repository_state" = 'valid' ]; then
  printf '\n2/3  The signed Denial repository is already configured.\n'
else
  printf '\n2/3  Adding the signed Denial repository to %s...\n' "$PACMAN_CONFIG"
  {
    printf '\n'
    printf '[denial]\n'
    printf 'SigLevel = Required TrustedOnly\n'
    printf 'Server = %s\n' "$REPOSITORY_SERVER"
  } | sudo tee -a "$PACMAN_CONFIG" >/dev/null
fi

printf '\n3/3  Upgrading the system and installing Denial...\n'
if ! sudo pacman -Syu --needed denial; then
  fail 'Pacman could not complete the Denial installation. The signed repository remains configured.'
fi

printf '\nDenial is installed.\n'
printf 'Log out, choose Denial in your display manager, and sign in.\n\n'
