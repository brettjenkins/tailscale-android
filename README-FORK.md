# Tailscale Android — unofficial fork builds

This repo auto-builds an **unofficial** fork of the Tailscale Android client. Every
6 hours it tracks upstream `tailscale/tailscale-android` `main`, layers a few extra
patches (see [`.github/fork-patches.txt`](.github/fork-patches.txt) — e.g. launcher
shortcuts to connect/disconnect), builds a debug APK signed with a stable key, and
publishes it to [Releases](../../releases).

> Not affiliated with or endorsed by Tailscale Inc. Use at your own risk.

## Install

1. **Uninstall the official Tailscale app first.** This fork uses the same
   `applicationId` (`com.tailscale.ipn`) signed with a different key, so Android will
   not let both coexist or update one from the other.
2. Download the latest `tailscale-fork-signed.apk` from the [Releases page](../../releases).
3. Allow "install unknown apps" for your browser/file manager, then install.

## Auto-updates (recommended)

Use [Obtainium](https://github.com/ImranR98/Obtainium): add this repo as an app source.
Obtainium watches the Releases here and installs new builds automatically — pairing
well with the 6-hourly cadence.

> Because the signing key differs from the Play Store build, you cannot switch between
> this fork and the official app without uninstalling/reinstalling (which clears local
> app state, including your login).

## How it works

- The fork's patches are **not** stored on `main`; they are listed by commit SHA in
  `.github/fork-patches.txt` and re-applied onto a fresh `upstream/main` checkout on
  every build. Adding another change or someone else's unmerged PR is a one-line edit.
- If upstream changes collide with a patch, that build ships **without** the patch and
  opens a `fork-conflict` issue; the patch is never silently dropped.

## Security

This is a VPN client. Builds are produced unattended by GitHub Actions and signed with
a key held only as a repository secret. The build/test gate must pass before anything is
published. Still — it's an unofficial fork; if you need vendor guarantees, use the
official app.
