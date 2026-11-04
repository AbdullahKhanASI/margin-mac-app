# Releasing Margin

Releases are built and published by GitHub Actions ([`.github/workflows/release.yml`](../.github/workflows/release.yml)).
[`install.sh`](../install.sh) always installs the newest release, so publishing one updates everyone who reruns it.

## Cut a release

1. Set the version in `Resources/Info.plist`:
   - `CFBundleShortVersionString`: the version, e.g. `2.1.0`
   - `CFBundleVersion`: increase by one
2. Optionally write release notes in `docs/releases/v<version>.md`. Without that file, GitHub generates notes from the
   merged pull requests.
3. Merge to `main`, then tag and push:

   ```bash
   git tag v2.1.0
   git push origin v2.1.0
   ```

The workflow checks the tag matches `CFBundleShortVersionString`, runs the tests, builds and signs
`Margin.app`, zips it as `Margin-v<version>.zip`, and publishes the release.

**Betas:** anything after a dash in the tag is kept in the zip name and marks the release as a pre-release. With
`2.1.0` in Info.plist, the tag `v2.1.0-beta` publishes `Margin-v2.1.0-beta.zip` as a pre-release.

**Rebuild an existing tag:** run the *Release* workflow from the Actions tab and enter the tag. If the release already
exists, its zip is replaced.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs `swift test` and `./build.sh release` on every pull
request and every push to `main`, and keeps the built zip as a workflow artifact for 14 days.

## Signing and notarization (optional)

Without any secrets, release builds are signed ad-hoc. They work, but macOS warns on first launch, and the Accessibility
permission has to be granted again after each update (the install script resets the old entry for you).

To ship a Developer ID–signed, notarized build, add these repository secrets under
**Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | Your *Developer ID Application* certificate and private key, exported from Keychain Access as a `.p12`, then base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `APPLE_ID` | The Apple ID of your developer account |
| `APPLE_TEAM_ID` | Your 10-character team ID |
| `APPLE_APP_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID |

With the certificate secrets, the app is signed with Developer ID and a secure timestamp. With all five, it's also
notarized and stapled, so it opens without a warning.

## Local release build

```bash
./build.sh release                                # build/Margin-v<version>.zip
MARGIN_VERSION_SUFFIX=-beta ./build.sh release    # build/Margin-v<version>-beta.zip
```
