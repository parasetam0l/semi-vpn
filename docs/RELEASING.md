# Releasing SemiVPN

Releases are built by the **Release** GitHub Actions workflow
(`.github/workflows/release.yml`). It runs only when started by hand, signs
SemiVPN with a Developer ID certificate, has Apple notarize it, and creates a
**draft** GitHub release with `SemiVPN-<version>.dmg`, the notarized app
(macOS 14+, Apple silicon). The browser extension is inside the app, which
installs it into the folder browsers load it from and keeps it updated there.

The repository is public, so the macOS runner minutes are free.

## One-time setup

You need a paid Apple Developer Program membership (individual is fine for
Developer ID). Team: `P7V7795SS9`.

### 1. Developer ID Application certificate

Create it on the website, not in Xcode: Xcode issues it from the previous
Developer ID authority, which expires on 1 February 2027 and takes its
certificates with it.

1. Keychain Access → Certificate Assistant → **Request a Certificate From a
   Certificate Authority…** → your Apple ID e-mail and name, **Saved to
   disk**.
2. [Certificates](https://developer.apple.com/account/resources/certificates/list)
   → **+** → **Developer ID Application** → **G2 Sub-CA** → upload the
   request, download the certificate and double-click it.
3. Keychain Access → My Certificates → Control-click the new certificate
   (it expires five years from now) → **Export** → save it as
   `DeveloperID.p12` with a strong password.

### 2. App IDs

On [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list)
→ Certificates, IDs & Profiles → Identifiers, check that these capabilities
are on (Xcode turned them on for development builds already):

| Identifier | Capabilities |
| --- | --- |
| `com.semivpn.app` | Network Extensions, System Extension |
| `com.semivpn.app.TunnelProvider` | Network Extensions |

### 3. Developer ID provisioning profiles

Profiles → **+** → Distribution → **Developer ID** → Continue, then select
the App ID and the Developer ID certificate from step 1 (if there are
several, the one with the same expiry date). The profiles must contain the
certificate in the `.p12`, and their names must match `project.yml`
exactly:

| App ID | Profile name |
| --- | --- |
| `com.semivpn.app` | `SemiVPN Developer ID` |
| `com.semivpn.app.TunnelProvider` | `SemiVPN Tunnel Developer ID` |

Download both. The tunnel profile must allow the system-extension variant of
the Network Extension entitlement; this should print it:

```sh
security cms -D -i SemiVPN_Tunnel_Developer_ID.provisionprofile | grep systemextension
```

### 4. App-specific password for notarization

[account.apple.com](https://account.apple.com) → Sign-In and Security →
App-Specific Passwords → **+** (label it e.g. "SemiVPN notarization").

### 5. Repository secrets

With the [GitHub CLI](https://cli.github.com), in the repository folder.
`gh secret set NAME` without a value asks for it, so it stays out of your
shell history. `NOTARY_APPLE_ID` is your Apple ID e-mail and
`NOTARY_PASSWORD` the app-specific password from step 4:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
gh secret set DEVELOPER_ID_P12_PASSWORD
base64 -i SemiVPN_Developer_ID.provisionprofile | gh secret set APP_PROFILE_BASE64
base64 -i SemiVPN_Tunnel_Developer_ID.provisionprofile | gh secret set TUNNEL_PROFILE_BASE64
gh secret set NOTARY_APPLE_ID
gh secret set NOTARY_PASSWORD
```

These are repository secrets: only this repository's workflows can read
them, and not when started from forks. Another repository needs its own
copies (the certificate and notary values can be the same, the profiles are
per app). Then delete the exported `DeveloperID.p12`; the certificate stays
in your keychain.

## Making a release

1. GitHub → **Actions** → **Release** → **Run workflow**, enter the version
   (e.g. `1.2.0`) and run it. It takes about 15–30 minutes, most of it
   waiting for Apple's notary service.
2. GitHub → **Releases**: edit the draft's notes and **Publish** it.
   Publishing creates the `v<version>` tag. The notes have install and update
   steps and the subjects of the commits since the previous release: add a
   short summary of what changed for users and remove internal entries
   (build, docs).

If a step fails, its log says why; the xcodebuild log is attached to the run
as an artifact, and a notarization failure prints Apple's report.

## What users see

- They open the DMG and drag SemiVPN to Applications. Gatekeeper accepts it
  without warnings because it is notarized.
- On first launch macOS asks them to allow SemiVPN's network extension in
  System Settings → General → Login Items & Extensions → Network Extensions.
  Updates replace the extension without asking again (every build has a
  higher build number).

## Notes

- Builds are Apple silicon only: they link Homebrew's single-architecture
  OpenSSL. An Intel build needs a universal OpenSSL.
- The DMG window's layout is in `Packaging/dmg` (dmgbuild settings and the
  background). After changing it, redraw the background with
  `swift Scripts/dmg-background.swift` and try it with
  `Scripts/make-dmg.sh path/to/SemiVPN.app test.dmg`.
- The Developer ID certificate is valid for five years. When a certificate or
  profile is renewed, update the secrets.
