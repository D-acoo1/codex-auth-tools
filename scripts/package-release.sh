#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(date +v%Y.%m.%d)"
fi
if [[ ! "$VERSION" =~ ^v[0-9][0-9A-Za-z._-]*$ ]]; then
  printf 'Version must start with v, got: %s\n' "$VERSION" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Release packaging is supported only on macOS.\n' >&2
  exit 1
fi
if [[ ! -x /usr/bin/codesign ]]; then
  printf 'Required macOS tool is missing: /usr/bin/codesign\n' >&2
  exit 1
fi
if [[ ! -x /usr/bin/strip ]]; then
  printf 'Required macOS tool is missing: /usr/bin/strip\n' >&2
  exit 1
fi

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD)"
SOURCE_STATUS="$(git -C "$ROOT" status --porcelain --untracked-files=normal)"
if [[ -n "$SOURCE_STATUS" ]]; then
  if [[ "${ALLOW_DIRTY_RELEASE:-0}" != "1" ]]; then
    printf 'Release packaging requires a clean Git worktree.\n' >&2
    printf 'Commit or stash these changes, or set ALLOW_DIRTY_RELEASE=1 only for a disposable local test package:\n' >&2
    printf '%s\n' "$SOURCE_STATUS" >&2
    exit 1
  fi
  SOURCE_COMMIT="${SOURCE_COMMIT}-dirty"
  printf 'Warning: building a non-publishable dirty test package (%s).\n' "$SOURCE_COMMIT" >&2
fi

BUNDLE_ID="${CODEX_BALANCE_BUNDLE_ID:-net.nexita.codeapi-balance}"
LABEL="${CODEX_BALANCE_LAUNCHD_LABEL:-com.codexlocaltools.codex-balance}"
ARCH="$(uname -m)"
PLATFORM="macos-${ARCH}"
PACKAGE_NAME="codex-auth-tools-${VERSION}-${PLATFORM}"
DIST_DIR="${DIST_DIR:-$ROOT/dist/release}"
WORK_DIR="$DIST_DIR/work-$VERSION"
PACKAGE_ROOT="$WORK_DIR/$PACKAGE_NAME"
APP_BUNDLE="$PACKAGE_ROOT/CodexBalance.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
ZIP_PATH="$DIST_DIR/$PACKAGE_NAME.zip"

rm -rf "$WORK_DIR" "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$PACKAGE_ROOT/bin" "$PACKAGE_ROOT/lib/codex-ac" "$PACKAGE_ROOT/train-themes"

copy_tracked_tree() {
  local source_prefix="$1"
  local target_root="$2"
  local path relative destination copied
  copied=0
  while IFS= read -r -d '' path; do
    case "$path" in
      "$source_prefix"/*) ;;
      *) continue ;;
    esac
    relative="${path#"$source_prefix/"}"
    destination="$target_root/$relative"
    mkdir -p "$(dirname "$destination")"
    if [[ -L "$ROOT/$path" ]]; then
      cp -P "$ROOT/$path" "$destination"
    else
      cp -p "$ROOT/$path" "$destination"
    fi
    copied=$((copied + 1))
  done < <(git -C "$ROOT" ls-files -z -- "$source_prefix")
  if [[ "$copied" -eq 0 ]]; then
    printf 'No Git-tracked release files found under: %s\n' "$source_prefix" >&2
    exit 1
  fi
}

cd "$ROOT/codex-balance"
SWIFT_PATH_MAP="$ROOT=codex-auth-tools"
SWIFT_SCRATCH="$WORK_DIR/swift-build"
SWIFT_BUILD_PATH_MAP="$WORK_DIR=codex-auth-tools-build"
swift build -c release --scratch-path "$SWIFT_SCRATCH" \
  -Xswiftc -file-prefix-map -Xswiftc "$SWIFT_PATH_MAP" \
  -Xswiftc -debug-prefix-map -Xswiftc "$SWIFT_PATH_MAP" \
  -Xswiftc -file-prefix-map -Xswiftc "$SWIFT_BUILD_PATH_MAP" \
  -Xswiftc -debug-prefix-map -Xswiftc "$SWIFT_BUILD_PATH_MAP" >/dev/null
BUILT_BIN="$(swift build -c release --scratch-path "$SWIFT_SCRATCH" --show-bin-path)/CodexBalance"

install -m 755 "$BUILT_BIN" "$APP_CONTENTS/MacOS/CodexBalance"
/usr/bin/strip -S "$APP_CONTENTS/MacOS/CodexBalance"
for forbidden_path in "$ROOT" "$DIST_DIR" "/Users/" "/Volumes/" "/var/folders/"; do
  if LC_ALL=C grep -aFq "$forbidden_path" "$APP_CONTENTS/MacOS/CodexBalance"; then
    printf 'Release binary contains a local build path: %s\n' "$forbidden_path" >&2
    exit 1
  fi
done
cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexBalance</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>CodexBalance</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION#v}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null

cd "$ROOT"
copy_tracked_tree "codex-balance/Assets/train-themes" "$PACKAGE_ROOT/train-themes"
install -m 700 codex-auth/lib/codex-ac.py "$PACKAGE_ROOT/lib/codex-ac/codex-ac.py"
install -m 700 codex-auth/lib/list.mjs "$PACKAGE_ROOT/lib/codex-ac/list.mjs"
install -m 700 codex-auth/bin/codex-ac "$PACKAGE_ROOT/bin/codex-ac"
install -m 700 codex-auth/bin/codex-ac "$PACKAGE_ROOT/bin/ca"
cp LICENSE README.md SECURITY.md CONTRIBUTING.md "$PACKAGE_ROOT/"
copy_tracked_tree "assets" "$PACKAGE_ROOT/assets"
copy_tracked_tree "docs" "$PACKAGE_ROOT/docs"
cp scripts/uninstall-codex-balance.sh "$PACKAGE_ROOT/uninstall-codex-balance.sh"
cp scripts/uninstall-codex-auth.sh "$PACKAGE_ROOT/uninstall-codex-auth.sh"
chmod +x "$PACKAGE_ROOT/uninstall-codex-balance.sh" "$PACKAGE_ROOT/uninstall-codex-auth.sh"

printf '%s\n' "$SOURCE_COMMIT" > "$PACKAGE_ROOT/COMMIT"
printf '%s\n' "$VERSION" > "$PACKAGE_ROOT/VERSION"
cat > "$PACKAGE_ROOT/README-RELEASE.txt" <<README
Codex Auth Tools $VERSION ($PLATFORM)

Source commit: $SOURCE_COMMIT

Included:
- CodexBalance.app: macOS menu bar quota widget.
- ca / codex-ac: local Codex account manager.
- train-themes: animation assets used by CodexBalance.
- install.sh: installs both tools without requiring Xcode or Swift.

Install:
  unzip $PACKAGE_NAME.zip
  cd $PACKAGE_NAME
  ./install.sh

Install only one component:
  ./install.sh --balance-only
  ./install.sh --auth-only

Default install locations:
- CodexBalance.app: ~/Library/Application Support/CodexBalance/CodexBalance.app
- CodexBalance LaunchAgent: ~/Library/LaunchAgents/$LABEL.plist
- ca / codex-ac: ~/.local/bin
- codex-ac support files: ~/.local/lib/codex-ac
- codex-ac keepalive: ~/Library/LaunchAgents/com.codexlocaltools.codex-auth-keepalive.plist

After install:
  ca --help
  ca ll

Notes:
- This package does not contain any account, token, cookie, or local auth snapshot.
- CodexBalance reads the active local Codex auth from ~/.codex/auth.json.
- Saved ChatGPT accounts are checked every 24 hours and renewed only near expiry.
- install.sh verifies the exact internal SHA256SUMS file set, rejects symbolic links, and verifies the app signature before changing an existing installation.
- The app is ad-hoc signed for integrity checking only. It is not notarized and the signature does not identify a developer.
- A source commit ending in -dirty marks a disposable local test package and must not be published.
README

cat > "$PACKAGE_ROOT/install.sh" <<'INSTALL'
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
APP_SUPPORT="$HOME/Library/Application Support/CodexBalance"
LOG_DIR="$HOME/Library/Logs/CodexBalance"
APP_BUNDLE="$APP_SUPPORT/CodexBalance.app"
LEGACY_BIN="$APP_SUPPORT/CodexBalance"
TRAIN_THEMES="$APP_SUPPORT/train-themes"
LABEL="${CODEX_BALANCE_LAUNCHD_LABEL:-com.codexlocaltools.codex-balance}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AUTH_KEEPALIVE_LABEL="${CODEX_AUTH_KEEPALIVE_LABEL:-com.codexlocaltools.codex-auth-keepalive}"
AUTH_KEEPALIVE_PLIST="$HOME/Library/LaunchAgents/$AUTH_KEEPALIVE_LABEL.plist"
AUTH_LOG_DIR="$HOME/Library/Logs/CodexAuth"
INSTALL_AUTH=1
INSTALL_BALANCE=1
START_BALANCE=1

usage() {
  cat <<USAGE
Usage: ./install.sh [--auth-only] [--balance-only] [--no-start]

Options:
  --auth-only     Install only ca / codex-ac.
  --balance-only  Install only CodexBalance.app and LaunchAgent.
  --no-start      Install files but do not load or restart either LaunchAgent.
USAGE
}

verify_package() {
  local actual_manifest expected_manifest symlink_path
  if [[ ! -f "$ROOT/SHA256SUMS" ]]; then
    printf 'Package integrity manifest is missing: %s\n' "$ROOT/SHA256SUMS" >&2
    exit 1
  fi
  symlink_path="$(/usr/bin/find "$ROOT" -type l -print -quit)"
  if [[ -n "$symlink_path" ]]; then
    printf 'Package integrity verification failed: symbolic links are not allowed.\n' >&2
    exit 1
  fi
  expected_manifest="$(/bin/cat "$ROOT/SHA256SUMS")"
  if ! actual_manifest="$(
    cd "$ROOT"
    /usr/bin/find . -type f ! -path './SHA256SUMS' -print0 \
      | /usr/bin/sort -z \
      | /usr/bin/xargs -0 /usr/bin/shasum -a 256
  )"; then
    printf 'Package integrity manifest could not be recalculated.\n' >&2
    exit 1
  fi
  if [[ "$actual_manifest" != "$expected_manifest" ]]; then
    printf 'Package integrity verification failed; no files were installed.\n' >&2
    exit 1
  fi
  if [[ "$INSTALL_BALANCE" == "1" ]]; then
    if [[ ! -x /usr/bin/codesign ]]; then
      printf 'Required macOS tool is missing: /usr/bin/codesign\n' >&2
      exit 1
    fi
    if ! /usr/bin/codesign --verify --deep --strict "$ROOT/CodexBalance.app" >/dev/null 2>&1; then
      printf 'CodexBalance.app signature verification failed; no files were installed.\n' >&2
      exit 1
    fi
  fi
  if [[ "$INSTALL_BALANCE" == "1" ]]; then
    printf 'Verified package integrity and app signature.\n'
  else
    printf 'Verified package integrity.\n'
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-only) INSTALL_BALANCE=0 ;;
    --balance-only) INSTALL_AUTH=0 ;;
    --no-start) START_BALANCE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

verify_package

install_auth() {
  local lib_dir="$PREFIX/lib/codex-ac"
  local bin_dir="$PREFIX/bin"
  local python_bin codex_bin node_bin path_value tmp_plist
  mkdir -p "$lib_dir" "$bin_dir"
  install -m 700 "$ROOT/lib/codex-ac/codex-ac.py" "$lib_dir/codex-ac.py"
  install -m 700 "$ROOT/lib/codex-ac/list.mjs" "$lib_dir/list.mjs"
  install -m 700 "$ROOT/bin/codex-ac" "$bin_dir/codex-ac"
  ln -sf "$bin_dir/codex-ac" "$bin_dir/ca"
  python_bin="$(command -v python3 || true)"
  if [[ -z "$python_bin" ]]; then
    printf 'python3 is required by codex-ac.\n' >&2
    exit 1
  fi
  codex_bin="${CODEX_BIN:-$(command -v codex || true)}"
  node_bin="$(command -v node || true)"
  path_value="$bin_dir:$(dirname "$python_bin")"
  if [[ -n "$node_bin" ]]; then
    path_value="$path_value:$(dirname "$node_bin")"
  fi
  path_value="$path_value:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$(dirname "$AUTH_KEEPALIVE_PLIST")" "$AUTH_LOG_DIR"
  if [[ "$START_BALANCE" == "1" && "${CODEX_AUTH_KEEPALIVE_NO_START:-0}" != "1" ]]; then
    local state attempt
    state=""
    for ((attempt = 0; attempt < 120; attempt++)); do
      state="$(launchctl print "gui/$(id -u)/$AUTH_KEEPALIVE_LABEL" 2>/dev/null || true)"
      [[ "$state" != *"state = running"* ]] && break
      sleep 1
    done
    if [[ "$state" == *"state = running"* ]]; then
      printf 'Keepalive is still running; installation stopped to avoid interrupting token renewal.\n' >&2
      exit 1
    fi
    launchctl bootout "gui/$(id -u)/$AUTH_KEEPALIVE_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)" "$AUTH_KEEPALIVE_PLIST" 2>/dev/null || true
  fi
  tmp_plist="$AUTH_KEEPALIVE_PLIST.tmp.$$"
  "$python_bin" - "$tmp_plist" "$AUTH_KEEPALIVE_LABEL" "$bin_dir/codex-ac" "$AUTH_LOG_DIR" "$path_value" "$codex_bin" <<'PY'
import os
import plistlib
import sys

dst, label, executable, log_dir, path_value, codex_bin = sys.argv[1:]
environment = {"PATH": path_value}
if codex_bin:
    environment["CODEX_BIN"] = codex_bin
payload = {
    "Label": label,
    "ProgramArguments": [executable, "keepalive", "--quiet"],
    "RunAtLoad": True,
    "StartInterval": 86400,
    "LimitLoadToSessionType": "Aqua",
    "ProcessType": "Background",
    "ThrottleInterval": 300,
    "StandardOutPath": os.path.join(log_dir, "keepalive.stdout.log"),
    "StandardErrorPath": os.path.join(log_dir, "keepalive.stderr.log"),
    "EnvironmentVariables": environment,
}
with open(dst, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
os.chmod(dst, 0o644)
PY
  plutil -lint "$tmp_plist" >/dev/null
  mv "$tmp_plist" "$AUTH_KEEPALIVE_PLIST"
  if [[ "$START_BALANCE" == "1" && "${CODEX_AUTH_KEEPALIVE_NO_START:-0}" != "1" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$AUTH_KEEPALIVE_PLIST"
  fi
  printf 'Installed codex-auth to %s\n' "$PREFIX"
  printf 'Keepalive LaunchAgent: %s (checks every 24 hours)\n' "$AUTH_KEEPALIVE_PLIST"
  printf 'Commands: %s/bin/ca --help, %s/bin/ca ll\n' "$PREFIX" "$PREFIX"
}

unload_balance() {
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  while IFS= read -r candidate_plist; do
    [[ "$candidate_plist" == "$PLIST" ]] && continue
    local candidate_bin candidate_label
    candidate_bin="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$candidate_plist" 2>/dev/null || true)"
    case "$candidate_bin" in
      "$APP_BUNDLE/Contents/MacOS/CodexBalance"|"$LEGACY_BIN") ;;
      *) continue ;;
    esac
    candidate_label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$candidate_plist" 2>/dev/null || true)"
    if [[ -n "$candidate_label" ]]; then
      launchctl bootout "gui/$(id -u)/$candidate_label" 2>/dev/null || true
    fi
    launchctl bootout "gui/$(id -u)" "$candidate_plist" 2>/dev/null || true
    rm -f "$candidate_plist"
  done < <(find "$HOME/Library/LaunchAgents" -maxdepth 1 -type f \( -iname '*codex*balance*.plist' -o -iname '*CodexBalance*.plist' \) -print 2>/dev/null)
}

install_balance() {
  mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$HOME/Library/LaunchAgents"
  local ts staged_app backup_app
  ts="$(date +%Y%m%d-%H%M%S)"
  staged_app="$APP_SUPPORT/.CodexBalance.app.install.$$"
  backup_app=""
  rm -rf "$staged_app"
  /usr/bin/ditto "$ROOT/CodexBalance.app" "$staged_app"
  if ! /usr/bin/codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1; then
    rm -rf "$staged_app"
    printf 'Copied CodexBalance.app failed signature verification; the existing installation was not changed.\n' >&2
    exit 1
  fi
  unload_balance
  if [[ -d "$APP_BUNDLE" ]]; then
    backup_app="$APP_BUNDLE.bak.$ts"
    mv "$APP_BUNDLE" "$backup_app"
  fi
  if [[ -x "$LEGACY_BIN" ]]; then
    cp "$LEGACY_BIN" "$LEGACY_BIN.bak.$ts"
  fi
  mv "$staged_app" "$APP_BUNDLE"
  if ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    rm -rf "$APP_BUNDLE"
    if [[ -n "$backup_app" && -d "$backup_app" ]]; then
      mv "$backup_app" "$APP_BUNDLE"
    fi
    printf 'Installed CodexBalance.app failed signature verification; the previous installation was restored.\n' >&2
    exit 1
  fi
  rm -rf "$TRAIN_THEMES"
  mkdir -p "$TRAIN_THEMES"
  /usr/bin/ditto "$ROOT/train-themes" "$TRAIN_THEMES"
  xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BUNDLE/Contents/MacOS/CodexBalance</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST
  if [[ "$START_BALANCE" == "1" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  fi
  printf 'Installed CodexBalance: %s\n' "$APP_BUNDLE"
  printf 'LaunchAgent: %s\n' "$PLIST"
}

if [[ "$INSTALL_AUTH" == "1" ]]; then
  install_auth
fi
if [[ "$INSTALL_BALANCE" == "1" ]]; then
  install_balance
fi
INSTALL
chmod +x "$PACKAGE_ROOT/install.sh"

LOCAL_PATH_REPORT="$WORK_DIR/local-path-report.txt"
if LC_ALL=C grep -RInaE '/Users/|/Volumes/|/var/folders/' "$PACKAGE_ROOT" > "$LOCAL_PATH_REPORT"; then
  printf 'Release package contains a local machine path:\n' >&2
  cat "$LOCAL_PATH_REPORT" >&2
  exit 1
fi
PACKAGE_SYMLINK="$(/usr/bin/find "$PACKAGE_ROOT" -type l -print -quit)"
if [[ -n "$PACKAGE_SYMLINK" ]]; then
  printf 'Release package contains an unsupported symbolic link: %s\n' "$PACKAGE_SYMLINK" >&2
  exit 1
fi

(
  cd "$PACKAGE_ROOT"
  /usr/bin/find . -type f ! -path './SHA256SUMS' -print0 \
    | /usr/bin/sort -z \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > SHA256SUMS
)

mkdir -p "$DIST_DIR"
(
  cd "$WORK_DIR"
  if command -v zip >/dev/null 2>&1; then
    zip -qry -X "$ZIP_PATH" "$PACKAGE_NAME"
  else
    /usr/bin/ditto -c -k --keepParent "$PACKAGE_NAME" "$ZIP_PATH"
  fi
)
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
)

printf 'Package: %s\n' "$ZIP_PATH"
printf 'Checksum: %s\n' "$ZIP_PATH.sha256"
