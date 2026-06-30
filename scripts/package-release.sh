#!/usr/bin/env bash
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

BUNDLE_ID="${CODEX_BALANCE_BUNDLE_ID:-net.nexita.codeapi-balance}"
LABEL="${CODEX_BALANCE_LAUNCHD_LABEL:-com.codexlocaltools.codex-balance}"
ARCH="$(uname -m)"
PLATFORM="macos-${ARCH}"
PACKAGE_NAME="codex-auth-tools-${VERSION}-${PLATFORM}"
DIST_DIR="$ROOT/dist/release"
WORK_DIR="$DIST_DIR/work-$VERSION"
PACKAGE_ROOT="$WORK_DIR/$PACKAGE_NAME"
APP_BUNDLE="$PACKAGE_ROOT/CodexBalance.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
ZIP_PATH="$DIST_DIR/$PACKAGE_NAME.zip"

rm -rf "$WORK_DIR" "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$PACKAGE_ROOT/bin" "$PACKAGE_ROOT/lib/codex-ac" "$PACKAGE_ROOT/train-themes"

cd "$ROOT/codex-balance"
swift build -c release >/dev/null
BUILT_BIN="$(swift build -c release --show-bin-path)/CodexBalance"

install -m 755 "$BUILT_BIN" "$APP_CONTENTS/MacOS/CodexBalance"
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

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
  codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null
fi

cd "$ROOT"
cp -R codex-balance/Assets/train-themes/. "$PACKAGE_ROOT/train-themes/"
install -m 700 codex-auth/lib/codex-ac.py "$PACKAGE_ROOT/lib/codex-ac/codex-ac.py"
install -m 700 codex-auth/lib/list.mjs "$PACKAGE_ROOT/lib/codex-ac/list.mjs"
install -m 700 codex-auth/bin/codex-ac "$PACKAGE_ROOT/bin/codex-ac"
ln -s codex-ac "$PACKAGE_ROOT/bin/ca"
cp LICENSE README.md SECURITY.md "$PACKAGE_ROOT/"
cp scripts/uninstall-codex-balance.sh "$PACKAGE_ROOT/uninstall-codex-balance.sh"
chmod +x "$PACKAGE_ROOT/uninstall-codex-balance.sh"

git rev-parse HEAD > "$PACKAGE_ROOT/COMMIT"
printf '%s\n' "$VERSION" > "$PACKAGE_ROOT/VERSION"
cat > "$PACKAGE_ROOT/README-RELEASE.txt" <<README
Codex Auth Tools $VERSION ($PLATFORM)

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

After install:
  ca --help
  ca ll

Notes:
- This package does not contain any account, token, cookie, or local auth snapshot.
- CodexBalance reads the active local Codex auth from ~/.codex/auth.json.
- The app is ad-hoc signed for local installation. It is not notarized.
README

cat > "$PACKAGE_ROOT/install.sh" <<'INSTALL'
#!/usr/bin/env bash
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
INSTALL_AUTH=1
INSTALL_BALANCE=1
START_BALANCE=1

usage() {
  cat <<USAGE
Usage: ./install.sh [--auth-only] [--balance-only] [--no-start]

Options:
  --auth-only     Install only ca / codex-ac.
  --balance-only  Install only CodexBalance.app and LaunchAgent.
  --no-start      Install CodexBalance.app but do not start/restart LaunchAgent.
USAGE
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

install_auth() {
  local lib_dir="$PREFIX/lib/codex-ac"
  local bin_dir="$PREFIX/bin"
  mkdir -p "$lib_dir" "$bin_dir"
  install -m 700 "$ROOT/lib/codex-ac/codex-ac.py" "$lib_dir/codex-ac.py"
  install -m 700 "$ROOT/lib/codex-ac/list.mjs" "$lib_dir/list.mjs"
  install -m 700 "$ROOT/bin/codex-ac" "$bin_dir/codex-ac"
  ln -sf "$bin_dir/codex-ac" "$bin_dir/ca"
  printf 'Installed codex-auth to %s\n' "$PREFIX"
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
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  unload_balance
  if [[ -d "$APP_BUNDLE" ]]; then
    mv "$APP_BUNDLE" "$APP_BUNDLE.bak.$ts"
  fi
  if [[ -x "$LEGACY_BIN" ]]; then
    cp "$LEGACY_BIN" "$LEGACY_BIN.bak.$ts"
  fi
  /usr/bin/ditto "$ROOT/CodexBalance.app" "$APP_BUNDLE"
  rm -rf "$TRAIN_THEMES"
  mkdir -p "$TRAIN_THEMES"
  /usr/bin/ditto "$ROOT/train-themes" "$TRAIN_THEMES"
  xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
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

(
  cd "$PACKAGE_ROOT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
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
  shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
)

printf 'Package: %s\n' "$ZIP_PATH"
printf 'Checksum: %s\n' "$ZIP_PATH.sha256"
