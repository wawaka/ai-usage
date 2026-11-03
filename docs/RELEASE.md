# Releasing AI Usage

Releases are built and published by GitHub Actions (`.github/workflows/release.yml`) when you push a
`v*` tag. Users install with Homebrew from the tap:

```sh
brew install --cask wawaka/tap/ai-usage
```

- [1. One-time setup](#1-one-time-setup) (optional once done)
- [2. Every release](#2-every-release)
- [3. Once a year: renew the certificate](#3-once-a-year-renew-the-certificate)
- [4. Troubleshooting](#4-troubleshooting)
- [5. Later: a paid Developer ID](#5-later-a-paid-developer-id)

## How it fits together

| Piece | Where | Purpose |
|---|---|---|
| `VERSION` | this repo | Release version; the tag must be `v<VERSION>` |
| `release.yml` | this repo | Tests, signs, zips, publishes the release, updates the cask |
| `Scripts/package_app.sh` | this repo | Builds, signs (`SIGN_IDENTITY`) and zips the app |
| `Scripts/write_cask.sh` | this repo | Generates `Casks/ai-usage.rb` |
| `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` | repo secrets | Apple Development certificate + key |
| `TAP_TOKEN` | repo secret | Lets the workflow push to the tap |
| `wawaka/homebrew-tap` | separate repo | Holds `Casks/ai-usage.rb` |

**Why sign with an Apple Development certificate?** The app reads Keychain items (Claude Code's
login, its own saved accounts). When a user answers *Always Allow*, Keychain remembers the app by its
Team ID if the signature has one, and otherwise by the hash of that exact build. With an ad-hoc
signature every update would be a "new app" and ask again; with a Team ID the approval survives
updates. The free Apple Development certificate has a Team ID.

It isn't notarized (that needs the paid Developer ID), so the cask clears the quarantine flag after
install and Gatekeeper doesn't block the first launch. Apple intends Apple Development certificates
for development only: fine while the app is small, see [section 5](#5-later-a-paid-developer-id)
for when it isn't.

## 1. One-time setup

> **Optional once done.** Skip this section if the secrets and the tap already exist
> (`gh secret list` shows `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` and `TAP_TOKEN`).

All commands run on your Mac, from the repo directory, with `gh` logged in.

### 1.1 Get an Apple Development certificate

Free with any Apple ID; no paid membership.

1. Sign in once at <https://developer.apple.com/account> and accept the agreement. (Without this,
   Xcode says "Failed to retrieve development teams".)
2. Xcode → Settings → Accounts → add the Apple ID → **Manage Certificates…** → **+** →
   **Apple Development**.
3. Check it:
   ```sh
   security find-identity -v -p codesigning | grep "Apple Development"
   ```

`Scripts/dev_rebuild_and_relaunch.sh` uses the same certificate for local builds.

### 1.2 Store it as repo secrets

1. Keychain Access → **login** → **My Certificates** → right-click **Apple Development: …** →
   **Export…** → format `.p12`, save as `~/Desktop/AppleDevelopment.p12`, set a password.
   (Export it from *My Certificates* so the private key is included.)
2. Upload, then delete the file:
   ```sh
   base64 -i ~/Desktop/AppleDevelopment.p12 | gh secret set MACOS_CERT_P12
   gh secret set MACOS_CERT_PASSWORD          # paste the .p12 password
   rm ~/Desktop/AppleDevelopment.p12
   ```

Anyone holding this key can sign apps that users' Keychain treats as AI Usage. Keep it only in the
secret, and don't commit the `.p12`.

### 1.3 Create the Homebrew tap

```sh
gh repo create wawaka/homebrew-tap --public --description "Homebrew casks"
```

The name must start with `homebrew-` for `brew install --cask wawaka/tap/…` to work. The workflow
creates `Casks/ai-usage.rb` on the first release. To use another repo, set the
`HOMEBREW_TAP_REPO` variable (`gh variable set HOMEBREW_TAP_REPO --body owner/homebrew-name`).

### 1.4 Let the workflow push to the tap

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** →
   Generate: repository access **Only select repositories** → `wawaka/homebrew-tap`; permissions
   **Contents: Read and write**. Pick an expiry and note it.
2. ```sh
   gh secret set TAP_TOKEN                    # paste the token
   ```

Without `TAP_TOKEN` a release still publishes; the tap step is skipped with a warning.

## 2. Every release

1. **Bump the version** in `VERSION` (each tag can be released once; `v1.0.0` exists already):
   ```sh
   echo 1.0.1 > VERSION
   git commit -am "Release 1.0.1"
   ```
2. **Tag and push** (the tag must equal `v` + `VERSION`, or the workflow stops):
   ```sh
   git tag v$(cat VERSION)
   git push origin main v$(cat VERSION)
   ```
3. **Watch it** (about 5–10 minutes):
   ```sh
   gh run watch $(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')
   ```
4. **Check the result:**
   ```sh
   gh release view v$(cat VERSION)                       # zip attached
   brew update && brew info --cask wawaka/tap/ai-usage   # new version
   brew upgrade --cask ai-usage                          # or: brew install --cask wawaka/tap/ai-usage
   codesign -dv "/Applications/AI Usage.app" 2>&1 | grep TeamIdentifier   # a 10-character ID
   ```

Release notes are generated from the commits since the previous tag; edit them on the release page
afterwards if you like.

## 3. Once a year: renew the certificate

Apple Development certificates are valid for one year (Keychain Access shows the expiry date). Before
it expires, create a new one in Xcode (step 1.1) and replace the secrets (step 1.2). The Team ID
stays the same, so users aren't asked for Keychain access again. Installed copies keep working after
the old certificate expires, because releases are signed with a timestamp.

If you forget, the next release fails at *Import the signing certificate* or at signing; nothing
broken gets published.

Also renew `TAP_TOKEN` before it expires (step 1.4).

## 4. Troubleshooting

| Failure | Fix |
|---|---|
| *tag … doesn't match VERSION* | Delete the tag (`git push --delete origin vX; git tag -d vX`), fix `VERSION`, tag again |
| *MACOS_CERT_P12 secret is not set* / *no valid … identity* | Redo step 1.2; export from *My Certificates* so the key is included |
| `security import` fails | Wrong `MACOS_CERT_PASSWORD`, or the base64 got mangled: redo step 1.2 |
| *no Team ID in the signature* | The `.p12` isn't an Apple Development or Developer ID certificate |
| Tap push fails (403) | `TAP_TOKEN` expired or lacks *Contents: write* on the tap: step 1.4 |
| Re-run a failed release | `gh run rerun <id>`, or delete and re-push the tag; the release step replaces the zip |
| Users still asked for Keychain access after an update | Check the release's `TeamIdentifier` (section 2, step 4) is the same as before |

## 5. Later: a paid Developer ID

If the app gets real users, join the Apple Developer Program ($99/year) and:

1. Create a **Developer ID Application** certificate and put it in the same secrets (step 1.2); the
   workflow accepts either kind.
2. Add notarization: create an app-specific password, store a `notarytool` profile on the runner and
   pass `NOTARY_PROFILE` to `Scripts/package_app.sh`, which already notarizes and staples when it is set.
3. Drop the quarantine `postflight` from `Scripts/write_cask.sh`; a notarized app doesn't need it.

The app's signing identity changes at that update, so users allow Keychain access once more.
