# Releasing to TestFlight

`.github/workflows/release.yml` builds a signed App Store archive and uploads
it to TestFlight. It runs on every tag matching `v*`, or by hand from the
**Actions** tab (**Release to TestFlight → Run workflow**). The build number
is the GitHub run number, so it always increases; the marketing version comes
from `project.yml`.

```sh
git tag v1.0.0 && git push origin v1.0.0
```

The first step of the workflow checks that every secret below is set and
fails with a clear message if one is missing, so nothing is built until the
configuration is complete.

## Secrets

Add these under **Settings → Secrets and variables → Actions → Secrets**.

### Shared team credentials (already provisioned)

These identify the Apple Developer *team*, not this app, and are the same
across every repository the team signs. They are pushed centrally and should
not be created by hand here.

| Name | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Team ID. |
| `ASC_KEY_ID` | Key ID of a team-scoped App Store Connect API key. |
| `ASC_ISSUER_ID` | Issuer ID for that key. |
| `ASC_PRIVATE_KEY_BASE64` | The key's `.p8` file, base64-encoded. |

The API key is used only to upload the build to TestFlight, which the
**Developer** role allows. It is *not* used to create certificates or
profiles (that would need an Admin key), which is why the app-specific
material below has to be provided.

The macOS Developer ID certificate and notarisation credentials that come
with the same bundle (`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`) are not
used: Developer ID signing and notarisation are for apps distributed
outside the App Store on macOS, and an iOS TestFlight build must be signed
with an **Apple Distribution** certificate and App Store provisioning
profiles instead.

### App-specific signing material (needed once)

| Name | What it is |
| --- | --- |
| `IOS_DISTRIBUTION_CERT_P12_BASE64` | An **Apple Distribution** certificate with its private key, exported as `.p12` and base64-encoded. See below. |
| `IOS_DISTRIBUTION_CERT_PASSWORD` | The password chosen when exporting the `.p12`. |
| `IOS_APP_PROFILE_BASE64` | App Store provisioning profile for `me.byjp.SembleShare`, base64-encoded. |
| `IOS_EXTENSION_PROFILE_BASE64` | App Store provisioning profile for `me.byjp.SembleShare.ShareExtension`, base64-encoded. |

There is no keychain-password secret: the workflow generates one with
`openssl rand` for the temporary keychain it creates and deletes within the
job. The profile names are read from the profiles themselves.

### Distribution certificate (`IOS_DISTRIBUTION_CERT_P12_BASE64`, `IOS_DISTRIBUTION_CERT_PASSWORD`)

1. In Xcode, **Settings → Accounts → (your team) → Manage Certificates…**,
   click **+** and choose **Apple Distribution**. (Or create one in the
   [developer portal](https://developer.apple.com/account/resources/certificates/list)
   from a CSR made in Keychain Access.)
2. Open **Keychain Access**, find the *Apple Distribution: …* certificate
   under *My Certificates*, expand it so the private key is included,
   right-click → **Export…**, format *Personal Information Exchange (.p12)*,
   and set a password. That password is `IOS_DISTRIBUTION_CERT_PASSWORD`.
3. Encode it: `base64 -i Certificates.p12 | pbcopy` and paste as
   `IOS_DISTRIBUTION_CERT_P12_BASE64`.

Distribution certificates expire after a year; when one does, repeat this
and update the secret. An Apple Distribution certificate is team-wide, so
the same one can sign every iOS app of the team.

### Provisioning profiles

Both profiles must be of type **App Store Connect** (distribution) and must
be regenerated whenever the certificate or the App ID's capabilities change.

1. Make sure the two App IDs exist with **App Groups** and **Keychain
   Sharing** enabled, and the app group assigned, as described in
   [SETUP.md](SETUP.md).
2. In [Profiles](https://developer.apple.com/account/resources/profiles/list),
   click **+**, choose **App Store Connect**, pick the app's App ID, select
   the distribution certificate from step 1, and give it a name. Download it.
3. Repeat for the extension's App ID.
4. Encode each: `base64 -i "Add_to_Semble_App_Store.mobileprovision" | pbcopy`
   → `IOS_APP_PROFILE_BASE64`, and the same for the extension.

The workflow installs the profiles into both locations Xcode 16 and older
tooling look in, named by their UUID, and exports each profile's name for the
Fastfile, which writes the team, manual signing and the profile name into
each target with
[`update_code_signing_settings`](https://docs.fastlane.tools/actions/update_code_signing_settings/)
before archiving.

## What the workflow does

1. Checks that every secret above is present.
2. Selects the latest stable Xcode, installs XcodeGen, and installs fastlane
   with `bundle install` (cached).
3. Creates a temporary keychain, imports the certificate, and installs the
   two profiles, following GitHub's guide
   [Installing an Apple certificate on macOS runners for Xcode development](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/xcode).
4. Runs `bundle exec fastlane ios beta` (see `fastlane/Fastfile`), which
   regenerates the project, configures manual signing per target, archives
   with `CURRENT_PROJECT_VERSION` set to the run number, exports with
   `export_method: app-store`, authenticates with the API key and uploads
   with `upload_to_testflight`. It does not wait for Apple's processing.
5. Records keyless build provenance for the `.ipa` with
   [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance),
   so anyone can verify which commit and workflow produced a given build
   (`gh attestation verify SembleShare.ipa --owner jphastings`).
6. Uploads the `.ipa` and dSYMs as a workflow artefact and deletes the
   temporary keychain and profiles, even if a previous step failed.

Once App Store Connect finishes processing (usually 5–15 minutes) the build
appears under **TestFlight**. The first build of a new version needs to be
added to a tester group by hand; later builds of the same version inherit it.

## Running the lane locally

You can run the same lane on a Mac with the certificate and profiles in your
login keychain and the environment variables exported:

```sh
bundle install
export APPLE_TEAM_ID=… APP_PROFILE_NAME=… EXTENSION_PROFILE_NAME=… \
       APP_STORE_CONNECT_API_KEY_ID=… APP_STORE_CONNECT_API_ISSUER_ID=… \
       APP_STORE_CONNECT_API_KEY_BASE64=$(base64 -i AuthKey.p8)
bundle exec fastlane ios beta
```

Without `GITHUB_RUN_NUMBER` the build number falls back to a UTC timestamp.

## Further reading

- [fastlane docs](https://docs.fastlane.tools): [`build_app`](https://docs.fastlane.tools/actions/build_app/),
  [`app_store_connect_api_key`](https://docs.fastlane.tools/actions/app_store_connect_api_key/),
  [`upload_to_testflight`](https://docs.fastlane.tools/actions/upload_to_testflight/)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [TestFlight](https://developer.apple.com/testflight/) and
  [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
