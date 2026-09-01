#!/usr/bin/env bash
#
# Helper for the fork auto-build workflow. Keeps the YAML readable and the
# logic runnable locally. Subcommands: integrate | set-version | sign.
#
# This repo is a public fork of a VPN client. Nothing secret lives here — all
# credentials are passed in via the environment from GitHub secrets.
set -euo pipefail

UPSTREAM_URL="https://github.com/tailscale/tailscale-android.git"
# Overridable: the integrate step checks out upstream/main (which doesn't contain
# the fork-CI files), so the workflow stages this list into $RUNNER_TEMP first.
PATCHES_FILE="${PATCHES_FILE:-.github/fork-patches.txt}"

out() { # write a key=value to $GITHUB_OUTPUT if present, else stdout
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; else echo "OUT: $1"; fi
}

read_patches() { grep -vE '^[[:space:]]*(#|$)' "$PATCHES_FILE" || true; }

# ---------------------------------------------------------------------------
# integrate: check out upstream/main fresh and layer the fork patches on top.
# Conflicting patches are SKIPPED and recorded — never silently dropped.
# Produces: applied.txt, skipped.txt, and outputs upstream_sha/upstream_short/skipped.
# ---------------------------------------------------------------------------
integrate() {
  git remote add upstream "$UPSTREAM_URL" 2>/dev/null || git remote set-url upstream "$UPSTREAM_URL"
  git fetch --quiet upstream main
  # Make every fork branch tip reachable so bare-SHA patches can be cherry-picked.
  git fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*' || true

  local upstream_sha upstream_short
  upstream_sha="$(git rev-parse upstream/main)"
  upstream_short="$(git rev-parse --short upstream/main)"
  git checkout --quiet -B build-int upstream/main

  # cherry-pick creates commits; CI runners have no git identity by default.
  git config user.email "fork-ci@users.noreply.github.com"
  git config user.name "fork-ci"

  : >applied.txt
  : >skipped.txt
  local had_skip=false

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue

    # Resolve the ref to an ordered (oldest-first) list of commits to apply:
    #   owner:branch -> EVERY commit on that branch not already in upstream/main,
    #                   so a multi-commit feature branch is applied in full (not
    #                   just its tip -- that silently dropped earlier commits).
    #   bare SHA     -> exactly that one commit.
    # An unreachable/unknown ref is a reported ERROR, never a silent no-op --
    # that would drop a patch without warning.
    local commits
    if [[ "$ref" == *:* ]]; then
      # owner:branch -- the patch branch lives on this fork (origin). Fetch it
      # into a stable remote-tracking ref and resolve via that, never FETCH_HEAD
      # (which a failed fetch would leave pointing at upstream/main).
      local branch="${ref#*:}"
      git fetch --quiet origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" || true
      if ! git rev-parse --verify --quiet "origin/${branch}^{commit}" >/dev/null; then
        echo "${ref} — ERROR: ref not found / not reachable" >>skipped.txt
        echo "::error::Fork patch ${ref} could not be resolved — not applied"
        had_skip=true
        continue
      fi
      commits="$(git rev-list --reverse "upstream/main..origin/${branch}")"
      if [ -z "$commits" ]; then
        echo "${ref} (already in upstream — no-op)" >>applied.txt
        continue
      fi
    else
      # Bare SHA: make sure the object is present (GitHub serves reachable SHAs).
      git fetch --quiet origin "$ref" 2>/dev/null || true
      if ! commits="$(git rev-parse --verify --quiet "${ref}^{commit}")"; then
        echo "${ref} — ERROR: ref not found / not reachable" >>skipped.txt
        echo "::error::Fork patch ${ref} could not be resolved — not applied"
        had_skip=true
        continue
      fi
    fi

    # Apply each resolved commit in order. A conflicting commit is aborted and
    # recorded; earlier commits from the same branch stay applied (and are
    # reported), so a partial branch is never shipped silently.
    local commit
    for commit in $commits; do
      # Tag branch entries with the short SHA so a multi-commit branch's report
      # lines stay distinct; the "owner:branch" prefix is kept intact so the
      # resolver's branch-name extraction in fork-release.yml still matches.
      local label="$ref"
      [[ "$ref" == *:* ]] && label="${ref} (${commit:0:9})"

      local cprc=0
      git cherry-pick -x "$commit" >cp.out 2>&1 || cprc=$?
      if [ "$cprc" -eq 0 ]; then
        echo "$(git rev-parse --short HEAD) $(git log -1 --format=%s)" >>applied.txt
      elif git diff --name-only --diff-filter=U | grep -q .; then
        local files
        files="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
        git cherry-pick --abort 2>/dev/null || true
        echo "${label} — conflicts in: ${files}" >>skipped.txt
        echo "::warning::Fork patch ${label} skipped (conflicts in: ${files})"
        had_skip=true
      elif grep -qiE "is now empty|nothing to commit" cp.out; then
        # Genuinely empty: the change is already present upstream. A real no-op.
        git cherry-pick --skip 2>/dev/null || git cherry-pick --abort 2>/dev/null || true
        echo "${label} (already in upstream — no-op)" >>applied.txt
      else
        # Any other failure (e.g. tooling error) -- report, never silently drop.
        git cherry-pick --abort 2>/dev/null || true
        echo "${label} — ERROR: $(tr '\n' ' ' <cp.out | head -c 160)" >>skipped.txt
        echo "::error::Fork patch ${label} cherry-pick failed — not applied"
        had_skip=true
      fi
      rm -f cp.out
    done
  done < <(read_patches)

  out "upstream_sha=${upstream_sha}"
  out "upstream_short=${upstream_short}"
  $had_skip && out "skipped=true" || out "skipped=false"
}

# ---------------------------------------------------------------------------
# set-version: inject a strictly-increasing versionCode before the build.
# Date-based YYMMDDHH is globally monotonic, well above the committed value and
# far below Android's 2,100,000,000 cap. versionName is left to the build
# (it carries the upstream Tailscale version, which is what we want).
# ---------------------------------------------------------------------------
set_version() {
  local code
  code="$(date -u +%y%m%d%H)"
  sed -i "s/versionCode .*/versionCode ${code}/" android/build.gradle
  echo "versionCode set to ${code}"
  out "version_code=${code}"
}

# ---------------------------------------------------------------------------
# sign: re-sign the freshly built debug APK with the stable fork keystore so
# installs update in place across builds. Secrets come from the environment.
# ---------------------------------------------------------------------------
sign() {
  : "${SIGNING_KEYSTORE_BASE64:?}" "${SIGNING_KEYSTORE_PASSWORD:?}" "${SIGNING_KEY_ALIAS:?}" "${SIGNING_KEY_PASSWORD:?}"
  local bt ks
  bt="$(ls -d "${ANDROID_SDK_ROOT:?}"/build-tools/*/ | sort -V | tail -1)"
  ks="${RUNNER_TEMP:-/tmp}/fork.jks"
  echo "$SIGNING_KEYSTORE_BASE64" | base64 -d >"$ks"
  trap "rm -f '$ks'" EXIT

  "${bt}zipalign" -p -f 4 tailscale-debug.apk tailscale-aligned.apk
  "${bt}apksigner" sign \
    --ks "$ks" \
    --ks-pass "pass:${SIGNING_KEYSTORE_PASSWORD}" \
    --ks-key-alias "${SIGNING_KEY_ALIAS}" \
    --key-pass "pass:${SIGNING_KEY_PASSWORD}" \
    --out tailscale-fork-signed.apk \
    tailscale-aligned.apk
  "${bt}apksigner" verify --verbose tailscale-fork-signed.apk
  echo "signed: tailscale-fork-signed.apk"
}

case "${1:-}" in
  integrate)   integrate ;;
  set-version) set_version ;;
  sign)        sign ;;
  *) echo "usage: $0 {integrate|set-version|sign}" >&2; exit 2 ;;
esac
