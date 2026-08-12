#!/bin/sh

set -eu

SIGNING_KEY='AE4108FA5E91E26BE0EE331E0F5B3AD16E023091'
PUBLIC_KEY_URL='https://denialwm.github.io/denial/denial-repo-key.asc'
if [ -n "${DENIAL_SETUP_PUBLIC_KEY_URL:-}" ]; then
  PUBLIC_KEY_URL="$DENIAL_SETUP_PUBLIC_KEY_URL"
fi
OS_RELEASE="${DENIAL_SETUP_OS_RELEASE:-/etc/os-release}"
PACMAN_CONFIG="${DENIAL_SETUP_PACMAN_CONFIG:-/etc/pacman.conf}"
APT_KEYRING="${DENIAL_SETUP_APT_KEYRING:-/etc/apt/keyrings/denial.asc}"
APT_SOURCES="${DENIAL_SETUP_APT_SOURCES:-/etc/apt/sources.list.d/denial.sources}"
RPM_KEY="${DENIAL_SETUP_RPM_KEY:-/etc/pki/rpm-gpg/RPM-GPG-KEY-denial}"
DNF_REPOSITORY="${DENIAL_SETUP_DNF_REPOSITORY:-/etc/yum.repos.d/denial.repo}"
# Pacman expands this architecture variable when reading pacman.conf.
# shellcheck disable=SC2016
PACMAN_SERVER='https://denialwm.github.io/denial/$arch'
APT_SERVER='https://denialwm.github.io/denial/apt'
# DNF expands these variables when reading the repository configuration.
# shellcheck disable=SC2016
DNF_SERVER='https://denialwm.github.io/denial/rpm/fedora/$releasever/$basearch'

fail() {
  printf '\nError: %s\n' "$1" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Required command not found: $1"
  fi
}

# Standard input contains this script when invoked through curl, so prompts
# must use the controlling terminal.
confirm() {
  printf '%s [y/N] ' "$1" > /dev/tty

  if ! IFS= read -r answer < /dev/tty; then
    return 1
  fi

  case "$answer" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

os_release_value() {
  key="$1"
  awk -F= -v wanted="$key" '
    $1 == wanted {
      value = substr($0, index($0, "=") + 1)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$OS_RELEASE"
}

# Report whether Pacman has no Denial section, the exact supported section, or
# a conflicting section which must be reviewed instead of silently modified.
pacman_repository_state() {
  awk -v expected_server="$PACMAN_SERVER" '
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

exact_file_state() {
  destination="$1"
  expected="$2"

  if [ ! -e "$destination" ]; then
    printf '%s\n' absent
  elif [ -f "$destination" ] && [ ! -L "$destination" ] \
      && cmp -s -- "$destination" "$expected"; then
    printf '%s\n' valid
  else
    printf '%s\n' invalid
  fi
}

if [ "$(uname -m)" != x86_64 ]; then
  fail 'Denial packages are currently available for x86-64 only.'
fi
if [ ! -r "$OS_RELEASE" ]; then
  fail "Cannot read $OS_RELEASE."
fi

for command_name in awk cat cmp curl dirname gpg install mktemp rm sudo uname; do
  require_command "$command_name"
done

os_id="$(os_release_value ID)"
os_version="$(os_release_value VERSION_ID)"
os_codename="$(os_release_value VERSION_CODENAME)"
mode=''
suite=''
install_command=''
case "$os_id:$os_version:$os_codename" in
  arch:* | endeavouros:* | manjaro:*)
    mode='pacman'
    install_command='sudo pacman -Syu denial'
    ;;
  debian:13:* | debian:*:trixie)
    mode='apt'
    suite='trixie'
    install_command='sudo apt update && sudo apt install denial'
    ;;
  ubuntu:24.04:* | ubuntu:*:noble)
    mode='apt'
    suite='noble'
    install_command='sudo apt update && sudo apt install denial'
    ;;
  fedora:44:*)
    mode='dnf'
    install_command='sudo dnf install denial'
    ;;
  *)
    fail "Unsupported distribution: ${os_id:-unknown} ${os_version:-unknown} (${os_codename:-no-codename}). Supported: Arch, Debian 13, Ubuntu 24.04, Fedora 44."
    ;;
esac

case "$mode" in
  pacman)
    [ -r "$PACMAN_CONFIG" ] || fail "Cannot read $PACMAN_CONFIG."
    for command_name in pacman pacman-key tee; do
      require_command "$command_name"
    done
    ;;
  apt)
    require_command apt
    ;;
  dnf)
    for command_name in dnf rpmkeys; do
      require_command "$command_name"
    done
    ;;
esac

if ! (: </dev/tty) 2>/dev/null || ! (: >/dev/tty) 2>/dev/null; then
  fail 'Run this installer from an interactive terminal.'
fi

work_tmp="$(mktemp -d)"
cleanup() {
  if [ -n "${work_tmp:-}" ] && [ -d "$work_tmp" ]; then
    rm -rf -- "$work_tmp"
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expected_config="$work_tmp/repository.conf"
case "$mode" in
  pacman)
    {
      printf '[denial]\n'
      printf 'SigLevel = Required TrustedOnly\n'
      printf 'Server = %s\n' "$PACMAN_SERVER"
    } >"$expected_config"
    repository_state="$(pacman_repository_state)"
    configuration_name="[denial] entry in $PACMAN_CONFIG"
    ;;
  apt)
    {
      printf 'Types: deb\n'
      printf 'URIs: %s\n' "$APT_SERVER"
      printf 'Suites: %s\n' "$suite"
      printf 'Components: main\n'
      printf 'Architectures: amd64\n'
      printf 'Signed-By: %s\n' "$APT_KEYRING"
    } >"$expected_config"
    repository_state="$(exact_file_state "$APT_SOURCES" "$expected_config")"
    configuration_name="$APT_SOURCES"
    ;;
  dnf)
    {
      printf '[denial]\n'
      printf 'name=Denial public alpha\n'
      printf 'baseurl=%s\n' "$DNF_SERVER"
      printf 'enabled=1\n'
      printf 'gpgcheck=1\n'
      printf 'repo_gpgcheck=1\n'
      printf 'gpgkey=file://%s\n' "$RPM_KEY"
      printf 'skip_if_unavailable=0\n'
    } >"$expected_config"
    repository_state="$(exact_file_state "$DNF_REPOSITORY" "$expected_config")"
    configuration_name="$DNF_REPOSITORY"
    ;;
esac

case "$repository_state" in
  absent | valid) ;;
  *)
    fail "The existing Denial repository configuration at $configuration_name is not the exact supported configuration. Review it manually before continuing."
    ;;
esac

printf '\nDenial repository setup\n'
printf '=======================\n\n'
printf 'This setup will:\n'
printf '  1. Download the Denial public key and require this full fingerprint:\n'
printf '     %s\n' "$SIGNING_KEY"
if [ "$repository_state" = valid ]; then
  printf '  2. Keep the verified repository configuration at %s.\n' \
    "$configuration_name"
else
  printf '  2. Add the signed repository configuration at %s.\n' \
    "$configuration_name"
fi
printf '\nNo packages will be installed. After setup, run this yourself:\n'
printf '\n  %s\n' "$install_command"
printf '\nThe script uses sudo only to trust the verified key and configure the repository.\n\n'

if ! confirm 'Continue?'; then
  printf '\nCancelled. No system changes were made.\n'
  exit 0
fi

printf '\nChecking administrator access...\n'
if ! sudo -v; then
  fail 'Administrator access is required to configure the package manager.'
fi

key_file="$work_tmp/denial-repo-key.asc"
printf '\n1/2  Downloading and verifying the Denial signing key...\n'
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

case "$mode" in
  pacman)
    sudo pacman-key --add "$key_file" \
      || fail 'The verified signing key could not be added to Pacman.'
    sudo pacman-key --lsign-key "$SIGNING_KEY" \
      || fail 'The verified signing key could not be locally trusted.'
    if [ "$repository_state" = valid ]; then
      printf '\n2/2  The signed Denial repository is already configured.\n'
    else
      printf '\n2/2  Adding the signed Denial repository to %s...\n' \
        "$PACMAN_CONFIG"
      {
        printf '\n'
        cat "$expected_config"
      } | sudo tee -a "$PACMAN_CONFIG" >/dev/null
    fi
    ;;
  apt)
    sudo install -d -m 0755 "$(dirname -- "$APT_KEYRING")" \
      "$(dirname -- "$APT_SOURCES")"
    sudo install -m 0644 "$key_file" "$APT_KEYRING"
    if [ "$repository_state" = valid ]; then
      printf '\n2/2  The signed Denial repository is already configured.\n'
    else
      printf '\n2/2  Adding the signed Denial repository to %s...\n' \
        "$APT_SOURCES"
      sudo install -m 0644 "$expected_config" "$APT_SOURCES"
    fi
    ;;
  dnf)
    sudo install -d -m 0755 "$(dirname -- "$RPM_KEY")" \
      "$(dirname -- "$DNF_REPOSITORY")"
    sudo install -m 0644 "$key_file" "$RPM_KEY"
    sudo rpmkeys --import "$RPM_KEY" \
      || fail 'The verified signing key could not be imported into RPM.'
    if [ "$repository_state" = valid ]; then
      printf '\n2/2  The signed Denial repository is already configured.\n'
    else
      printf '\n2/2  Adding the signed Denial repository to %s...\n' \
        "$DNF_REPOSITORY"
      sudo install -m 0644 "$expected_config" "$DNF_REPOSITORY"
    fi
    ;;
esac

printf '\nDenial repository setup is complete. No packages were installed.\n'
printf '\nInstall Denial when ready:\n'
printf '\n  %s\n\n' "$install_command"
printf 'The package manager will install denial-flutter-engine as a required dependency.\n\n'
