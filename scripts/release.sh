#!/usr/bin/env bash
#
# Release wizard for Tunnel Vision.
# Walks through: version bump → build → notarize → staple → tag → GitHub Release.
#
# Everything above the "STAGES" marker is the wizard library: do not hand-edit
# it. Author the per-step stages below the marker.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Wizard library: delightful, consistent UX, identical across every wizard.
# ──────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

TOTAL_STAGES=0

_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=()
WRITTEN_SECRET=()
SKIPPED=()

_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  You drive the browser; this wizard tells you exactly what to do and\n' "$DIM"
  printf '  captures the values you copy back. Stop any time with Ctrl-C and re-run\n'
  printf '  later, since it remembers values already saved.%s\n' "$RESET"
  pause "Ready to start?"
}

stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()  { printf '  %s\n' "$1"; }
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }

open_url() {
  local url="$1"
  printf '  %s↗ opening%s %s\n' "$GREEN" "$RESET" "$url"
  { if   command -v wslview     >/dev/null 2>&1; then wslview "$url"
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
    elif command -v xdg-open    >/dev/null 2>&1; then xdg-open "$url"
    elif command -v open        >/dev/null 2>&1; then open "$url"
    else warn "couldn't open a browser; visit it manually: $url"; fi
  } >/dev/null 2>&1 || warn "couldn't open a browser, so visit it manually: $url"
}

pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

confirm() {
  local reply=""
  printf '  %s? %s [y/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

_existing() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line=$(grep -E "^${1}=" "$ENV_FILE" | tail -n1) || return 1
  printf '%s' "${line#*=}"
}

ask() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

ask_secret() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -rs input || true
  printf '\n'
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

write_env() {
  local key="$1" value="$2" tmp
  touch "$ENV_FILE"
  tmp=$(mktemp)
  grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  WRITTEN_ENV+=("$key")
  printf '  %s✓ wrote%s %s → %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

set_secret() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s' "$value" | gh secret set "$name" >/dev/null 2>&1; then
      WRITTEN_SECRET+=("$name")
      printf '  %s✓ set%s GitHub secret %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub secret $name (set it manually: gh secret set $name)")
  warn "skipped GitHub secret $name: gh not ready; set it later"
}

set_var() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh variable set "$name" --body "$value" >/dev/null 2>&1; then
      printf '  %s✓ set%s GitHub variable %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub variable $name")
  warn "skipped GitHub variable $name, gh not ready; set it later"
}

finish() {
  _clear
  printf '\n%s%s  ✓ Setup complete%s\n' "$BOLD" "$GREEN" "$RESET"
  (( ${#WRITTEN_ENV[@]} ))    && note "wrote ${#WRITTEN_ENV[@]} value(s) to $ENV_FILE: ${WRITTEN_ENV[*]}"
  (( ${#WRITTEN_SECRET[@]} )) && note "set ${#WRITTEN_SECRET[@]} GitHub secret(s): ${WRITTEN_SECRET[*]}"
  if (( ${#SKIPPED[@]} )); then
    printf '\n'; warn "still to do by hand:"
    for s in "${SKIPPED[@]}"; do note "  - $s"; done
  fi
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────
# STAGES: author this section. One stage() per step the human takes.
# Set TOTAL_STAGES to match the stages you write.
# ──────────────────────────────────────────────────────────────────────────

TOTAL_STAGES=7

banner "Tunnel Vision release"

# ── Stage 1: version ────────────────────────────────────────────────────
stage "Version"
say "Bump the version in Info.plist. CFBundleShortVersionString is the user-facing version; CFBundleVersion is the build number."
ask VERSION "New version - e.g. 0.1.0:"
note "Will set CFBundleShortVersionString=$VERSION and bump CFBundleVersion."

# ── Stage 2: update Info.plist ─────────────────────────────────────────
stage "Update Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Support/Info.plist
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Support/Info.plist)
BUILD_NUM=$((BUILD_NUM + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" Support/Info.plist
say "Updated: CFBundleShortVersionString=$VERSION, CFBundleVersion=$BUILD_NUM"

# ── Stage 3: commit & tag ───────────────────────────────────────────────
stage "Commit & tag"
say "Committing the version bump and tagging $VERSION."
git add Support/Info.plist
git commit -m "Bump version to $VERSION"
git tag "$VERSION"
git push && git push --tags
say "Tagged and pushed $VERSION."

# ── Stage 4: build ──────────────────────────────────────────────────────
stage "Build"
say "Building the signed .app with hardened runtime."
make app
say "Built: build/TunnelVision.app"

# ── Stage 5: notarize ───────────────────────────────────────────────────
stage "Notarize"
say "Submitting to Apple for notarization. This takes a minute or two."
ask APPLE_ID "Apple ID:"
ask_secret APP_SPECIFIC_PASSWORD "App-specific password:"
APPLE_TEAM_ID=$(codesign -d -r- build/TunnelVision.app 2>&1 | sed -n 's/.*leaf\[subject.OU\] = "\([^"]*\)".*/\1/p')
note "Detected team ID: $APPLE_TEAM_ID"
cd build && ditto -c -k --keepParent TunnelVision.app TunnelVision.zip && cd ..
xcrun notarytool submit build/TunnelVision.zip \
  --apple-id "$APPLE_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait
say "Notarization accepted."

# ── Stage 6: staple & verify ────────────────────────────────────────────
stage "Staple & verify"
say "Attaching the notarization ticket and verifying."
xcrun stapler staple build/TunnelVision.app
xcrun stapler validate build/TunnelVision.app
spctl --assess --type execute build/TunnelVision.app
say "Stapled and verified."

# ── Stage 7: GitHub Release ─────────────────────────────────────────────
stage "GitHub Release"
say "Create the release on GitHub and upload the zip."
REPO=$(git remote get-url origin | sed -E 's/.*github.com[:\/](.*)\.git/\1/')
open_url "https://github.com/$REPO/releases/new?tag=$VERSION"
step "Set the tag to $VERSION - should already be selected."
step "Title: $VERSION."
step "Attach build/TunnelVision.zip."
step "Publish the release."
pause "Published?"

finish
