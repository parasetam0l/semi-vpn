# Releasing SemiVPN

Releases are built by the **Release** GitHub Actions workflow
(`.github/workflows/release.yml`). It runs only when started by hand, signs
SemiVPN with a Developer ID certificate, has Apple notarize it, and creates a
**draft** GitHub release with:

- `SemiVPN-<version>.dmg`: the notarized app (macOS 14+, Apple silicon)
- `SemiVPN-BrowserExtension-<version>.zip`: the browser extension

The repository is public, so the macOS runner minutes are free.

## One-time setup

You need a paid Apple Developer Program membership (individual is fine for
Developer ID). Team: `P7V7795SS9`.

### 1. Developer ID Application certificate

1. Xcode → Settings → Accounts → select your Apple ID → your team →
   **Manage Certificates…** → **+** → **Developer ID Application**.
2. In the same list, Control-click the new certificate → **Export
   Certificate…** → save it as `DeveloperID.p12` with a strong password.

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
the App ID and the Developer ID certificate from step 1. The names must
match `project.yml` exactly:

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
shell history:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
gh secret set DEVELOPER_ID_P12_PASSWORD
base64 -i SemiVPN_Developer_ID.provisionprofile | gh secret set APP_PROFILE_BASE64
base64 -i SemiVPN_Tunnel_Developer_ID.provisionprofile | gh secret set TUNNEL_PROFILE_BASE64
gh secret set NOTARY_APPLE_ID     # your Apple ID e-mail
gh secret set NOTARY_PASSWORD     # the app-specific password
```

Then delete the exported `DeveloperID.p12`; the certificate stays in your
keychain. Secrets are not available to workflows started from forks.

## Making a release

1. GitHub → **Actions** → **Release** → **Run workflow**, enter the version
   (e.g. `1.2.0`) and run it. It takes about 15–30 minutes, most of it
   waiting for Apple's notary service.
2. GitHub → **Releases**: review the draft (notes are generated from the
   commits since the previous release) and **Publish** it. Publishing
   creates the `v<version>` tag.

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
- The Developer ID certificate is valid for five years. When a certificate or
  profile is renewed, update the secrets.
