# Signing plan

## Decision (owner, 2026-11-17): unsigned for now
- **Current path: the unsigned / ad-hoc build** that CI produces (the `MeetingCardSwift-app` artifact). The caveats
  below apply to every build until this decision changes.
- **Developer ID + notarization is deferred.** No Apple Developer account has been bought, and nothing is configured:
  no Team ID, certificate, provisioning profile or entitlements. CI has no signing or notarization step, and none is to
  be added. The Developer ID section is kept as the plan for when this is revisited.

### Caveats of the unsigned build
1. **Gatekeeper on first run.** The downloaded app is quarantined. On recent macOS it has to be allowed by hand in
   System Settings → Privacy & Security → "Open Anyway" (or IT removes the quarantine attribute).
2. **Permissions re-prompted on each new build.** macOS ties the Microphone and Screen & System Audio Recording
   approvals to the exact ad-hoc build, so both are asked again after every new build.
3. **The Keychain key may travel in a backup or migration.** Without a Team ID there is no `keychain-access-groups`
   entitlement, so no data-protection keychain and no "this device only" (`ThisDeviceOnly`). The key lives in the
   login keychain. It never syncs through iCloud Keychain, but it can move to another Mac in a Time Machine backup or a
   Migration Assistant transfer.
4. **MDM may block unsigned apps.** On a managed Mac (Jamf or another MDM), IT can block the app outright (there is no
   Team ID to allow-list), remove "Open Anyway", or deny its microphone or screen-recording access. Nothing in the app
   can work around that; confirm with IT before relying on it for a demo (details below).

Why each caveat exists, and what the deferred Developer ID path would change, follows.

## Why the signature decides so much
1. **Keychain protection.** The app asks the Keychain to keep the OpenAI key "on this device only, while unlocked"
   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). macOS only honours that in the **data-protection keychain**, and an
   app may only use the data-protection keychain if its signature carries the `keychain-access-groups` entitlement.
   That entitlement is *restricted*: macOS accepts it only when an Apple-issued provisioning profile vouches for it.
2. **Gatekeeper.** A downloaded app that isn't Developer ID signed and notarized is quarantined. The user has to allow
   it by hand in System Settings, and MDM can remove that option.
3. **Privacy permissions under MDM.** IT pre-approves or locks privacy permissions with a PPPC (Privacy Preferences
   Policy Control) profile. A PPPC rule names the app by bundle ID **and** its code-signing requirement, normally
   "signed by Team ID X". An ad-hoc app has no stable signing identity (each build is identified only by its own hash),
   so IT can't write a rule that survives an update.

`KeychainStore` already handles both: it tries the data-protection keychain first (with an optional access group,
signed builds) and falls back to the login keychain when the build has no keychain entitlement (unsigned builds, today).

## MDM: what IT can do to this app
Whether a given Mac is managed is for its IT team to confirm (System Settings → Privacy & Security → Profiles lists the
installed management profiles). What a managed Mac can enforce:

| Control | How IT applies it | Effect on an unsigned / ad-hoc build | Effect on a Developer ID + notarized build |
|---|---|---|---|
| Gatekeeper policy | Configuration profile (`com.apple.systempolicy.control`, `com.apple.systempolicy.managed` with "disable override") | Can't be opened at all: "Open Anyway" is removed | Opens normally |
| Blocking unapproved software | MDM restricted-software rules or another allow-listing tool (by signing team, bundle ID or process name) | Likely blocked; it has no Team ID to allow-list | IT can allow it by Team ID |
| Microphone | PPPC profile. MDM can **deny** the mic, but can't silently grant it; the user still approves the prompt unless IT denies it | Mic may be denied for unknown apps. A rule can't target the app across updates (no stable signature) | IT can leave it user-approvable or allow-list the Team ID; the approval persists across updates |
| Screen & System Audio Recording (ScreenCaptureKit call audio) | PPPC profile: deny, or "allow standard users to approve" | May be denied outright, or standard users may be unable to approve it | IT can let standard users approve it for this Team ID / bundle ID |
| Keychain | Not normally managed, but security baselines may flag login-keychain secrets | Key stays in the login keychain (no ThisDeviceOnly) | Key in the data-protection keychain with ThisDeviceOnly |

The practical consequence: on a managed Mac the unsigned build may simply not run, or run without mic or call audio,
and nothing in the app can work around that. A Developer ID build would give IT something concrete to approve.

## Current path: unsigned / ad-hoc build (what CI produces)
CI builds `MeetingCardSwift-app` on every run. It works for a demo on an unmanaged Mac, or on a managed Mac where IT
explicitly allows it. Its limits:
- **Gatekeeper "Open Anyway".** The downloaded app is quarantined. On recent macOS it has to be allowed in System
  Settings → Privacy & Security → "Open Anyway", or have its quarantine attribute removed by IT. Under MDM that option
  can be disabled.
- **No data-protection keychain, no ThisDeviceOnly.** The key lives in the login keychain. It never syncs through iCloud
  Keychain, but it can move to another Mac in a Time Machine backup or a Migration Assistant transfer. Adding
  `keychain-access-groups` to an ad-hoc or self-signed build gets it killed at launch (measured below).
- **Possible MDM block.** MDM can block it outright (no Team ID to allow-list), deny its microphone or screen-recording
  access, or prevent a standard user from approving them. IT can't write a PPPC rule that survives updates.
- **Re-prompts after every update.** macOS ties privacy approvals to the exact ad-hoc build, so Mic and Screen & System
  Audio Recording are asked again after each new build.
- **Not notarized,** so it can't be distributed normally or through an MDM self-service catalog without an exception.

A self-signed certificate (instead of ad-hoc) gives a stable identity, which avoids the re-prompts. It is still not
trusted by Gatekeeper, not notarizable, and still can't carry `keychain-access-groups`.

## Deferred: Developer ID + notarization (not bought or configured)
Nothing in this section has been done. It is the plan if the unsigned decision is revisited; until then CI gets no
signing or notarization step.

**Account.** Apple Developer Program, US$99 per year:
- Individual enrollment needs an Apple ID with two-factor authentication and a legal name.
- Organization enrollment also needs a D-U-N-S number and someone with authority to sign for the organization.
- An existing organization account can be used instead; the app then shares that organization's Team ID, which its IT
  may already allow-list.

**What it gives:**
- A Team ID.
- A *Developer ID Application* certificate, created by the team's Account Holder.
- A *Developer ID* provisioning profile for an explicit App ID. The profile authorizes
  `keychain-access-groups = [<TEAMID>.<bundle id>]` (plus `com.apple.application-identifier` and
  `com.apple.developer.team-identifier`). Embedded as `Contents/embedded.provisionprofile`, it lets the app launch and
  store the key in the data-protection keychain with ThisDeviceOnly.

**Notarization:**
- Sign with the hardened runtime and a secure timestamp (`codesign --options runtime --timestamp`). The entitlements
  include `com.apple.security.device.audio-input`, which the hardened runtime requires for mic access.
- Run `xcrun notarytool submit … --wait`, then `xcrun stapler staple`. Gatekeeper then opens the app like any other.

**Upkeep:**
- Developer ID certificates last 5 years; the membership renews yearly.
- Notarized builds keep running if the membership lapses, but no new builds can be signed.
- Privacy approvals persist across updates because the signing identity stays the same.

**Steps, if this is revisited:**
1. **Account.** Use an existing organization account if one is available; otherwise enroll at
   developer.apple.com/programs.
2. **Identifiers.** In Certificates, Identifiers & Profiles, register an explicit App ID for the app's bundle ID
   (`com.slatz.meetingcard.swift`). The Account Holder creates a *Developer ID Application* certificate, and the team
   creates a *Developer ID* provisioning profile for that App ID.
3. **Build settings** (one-time engineering):
   - Embed the profile.
   - Set entitlements `keychain-access-groups = [<TEAMID>.com.slatz.meetingcard.swift]` and
     `com.apple.security.device.audio-input`.
   - Turn on the hardened runtime.
   - Switch the key store to
     `KeychainStore(service: "com.slatz.meetingcard.swift.openai", accessGroup: "<TEAMID>.com.slatz.meetingcard.swift")`.
4. **CI signing (not added; only after the decision changes).** Store the certificate (.p12) and an App Store Connect
   API key as GitHub secrets, then add a signing job that runs `codesign`, `notarytool submit --wait` and
   `stapler staple`, and uploads the notarized build as the artifact.
5. **MDM (IT).** Before a demo on a managed Mac, hand IT:
   - the Team ID;
   - the bundle ID;
   - the designated requirement (`codesign -d -r- MeetingCardSwift.app`).

   IT then allow-lists the app and pushes a PPPC profile that lets the user approve Microphone and Screen & System
   Audio Recording (or leaves them user-approvable). IT can also deploy the notarized build through self service, so
   nothing is downloaded by hand.
6. **Key migration.** On first run of the signed build, re-enter the OpenAI key once (it moves from the login keychain
   to the data-protection keychain), then delete the old login-keychain item.

## Runner experiment results (CI macOS runner, macOS 26.7.2 build 25G332, Apple silicon)
An earlier CI experiment (not part of this repository) built a small probe that writes a dummy item with
ThisDeviceOnly, signed it seven ways, and ran each one:

| # | Build | Exit | Result |
|---|---|---|---|
| 1 | Ad-hoc (linker default), no entitlements, login keychain | 0 | Item written, but the "this device only" class is **not stored** (`kSecAttrAccessible` comes back absent) |
| 2 | Ad-hoc, no entitlements, data-protection keychain | 3 | **Refused**: `errSecMissingEntitlement` (-34018) |
| 3 | Ad-hoc + `keychain-access-groups` | 137 | **Killed at launch** (SIGKILL) |
| 4 | Ad-hoc + hardened runtime + `keychain-access-groups` | 137 | **Killed at launch** |
| 5 | Ad-hoc `.app` bundle (bundle ID = group) + `keychain-access-groups` | 137 | **Killed at launch** |
| 6 | Self-signed code-signing certificate (untrusted) + `keychain-access-groups` | 137 | **Killed at launch** |
| 7 | Self-signed certificate **trusted for code signing** in the System keychain + `keychain-access-groups` | 137 | **Killed at launch** |

The kernel log names the reason for the self-signed builds:
`AMFI: When validating …/p_self: Code has restricted entitlements, but the validation of its code signature failed.`
In short: without an Apple developer team and a provisioning profile there is no way to get the protection, and
trusting a home-made certificate does not change that. The runner isn't MDM-managed, so the MDM controls above are
not part of this experiment.

## Options compared

| | Unsigned / ad-hoc (current) | Developer ID + notarization (deferred) | Free personal team (not recommended) |
|---|---|---|---|
| Cost | $0 | US$99/yr (or $0 under an existing organization account) | $0 |
| Key "this device only" enforced | **No** (login keychain) | Yes | Yes |
| Launches with `keychain-access-groups` | **No, killed** (measured) | Yes (with profile) | Yes (with profile) |
| Opens without "Open Anyway" | No | Yes (notarized) | No (can't be notarized) |
| MDM can allow-list it / write a lasting PPPC rule | **No** (no stable identity) | Yes (Team ID) | Only the personal team, which IT is unlikely to accept |
| Upkeep | Re-approve permissions after each build | Yearly renewal | Re-sign every 7 days in Xcode |

**Free personal team (Apple Development).** Any Apple ID in Xcode can sign with restricted entitlements, so the
data-protection keychain works. But:
- free provisioning profiles expire after **7 days**, after which macOS won't launch the app until it is re-signed in
  Xcode on that Mac;
- the build can't be notarized;
- it needs Xcode and a personal Apple ID on the Mac, which is a poor fit for a managed work Mac.

It wasn't tested here because it needs an interactive Apple ID sign-in.
