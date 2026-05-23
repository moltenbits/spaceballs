# Distribution: Signing, Notarization, and Homebrew Cask

How to ship Spaceballs as a `.app` users can install via Homebrew without
triggering Gatekeeper warnings.

## Table of Contents

- [What "no warnings" requires](#what-no-warnings-requires)
- [One-time Apple Developer setup](#one-time-apple-developer-setup)
- [Repo changes](#repo-changes)
  - [Entitlements file](#entitlements-file)
  - [Info.plist usage strings](#infoplist-usage-strings)
  - [Makefile: real signing for release](#makefile-real-signing-for-release)
  - [Notarize + staple target](#notarize--staple-target)
  - [Verify before publishing](#verify-before-publishing)
  - [Fix `scripts/release.sh`](#fix-scriptsreleasesh)
- [Homebrew Cask](#homebrew-cask)
  - [CLI binary inside the cask](#cli-binary-inside-the-cask)
- [Suggested order of operations](#suggested-order-of-operations)
- [Troubleshooting](#troubleshooting)

---

## What "no warnings" requires

For a downloaded `.app` outside the App Store, macOS only stays quiet when
**all three** are true:

1. **Signed** with a *Developer ID Application* certificate (not ad-hoc, not a
   self-signed "dev" cert).
2. **Hardened Runtime** enabled, with entitlements declaring the
   private/protected APIs you use.
3. **Notarized** by Apple and the ticket **stapled** to the bundle (or to the
   `.dmg`/`.zip` you ship).

Miss any of these and Gatekeeper will show "cannot be opened because the
developer cannot be verified" or "Apple could not verify…".

## One-time Apple Developer setup

1. **Create a Developer ID Application certificate** at
   [developer.apple.com](https://developer.apple.com) → Certificates → "+" →
   *Developer ID Application*. Download and double-click into Keychain.
   (Skip *Developer ID Installer* — only needed for `.pkg` distribution.)
2. **Verify it's installed**:
   ```bash
   security find-identity -v -p codesigning
   ```
   should list `Developer ID Application: Your Name (TEAMID)`.
3. **Create credentials for `notarytool`** — either:
   - An **app-specific password** at [appleid.apple.com](https://appleid.apple.com), or
   - An **App Store Connect API key** (Users & Access → Integrations → Keys → "+",
     role: Developer). Preferred for CI — more reliable, can be rotated.
4. **Store credentials in the keychain** so you don't pass them every run:
   ```bash
   xcrun notarytool store-credentials "spaceballs-notary" \
       --apple-id you@example.com \
       --team-id TEAMID \
       --password APP_SPECIFIC_PASSWORD
   ```
   After this, `notarytool` calls just take `--keychain-profile spaceballs-notary`.

## Repo changes

### Entitlements file

Spaceballs uses CGS/SkyLight private symbols, AX, and CGEvent taps. Hardened
Runtime blocks dynamic-linker tricks unless you opt in. Create
`Resources/Spaceballs.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key>
  <false/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <false/>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
```

Start minimal. Only add `disable-library-validation` or
`allow-unsigned-executable-memory` if notarization rejects the bundle and the
log specifically points at it.

### Info.plist usage strings

You'll need at least:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Spaceballs uses Apple Events to control Mission Control when moving windows between Spaces.</string>
```

The Accessibility and Screen Recording prompts are driven by the system's TCC
dialogs and don't require explicit `Info.plist` keys, but Apple Events does.

### Makefile: real signing for release

Replace the ad-hoc-signed `bundle_app` macro so release builds use a real
identity, hardened runtime, secure timestamp, and entitlements:

```make
SIGN_ID ?= Developer ID Application: Your Name (TEAMID)
ENTITLEMENTS = Resources/Spaceballs.entitlements

define bundle_app
	@mkdir -p $(3)/Contents/MacOS
	@cp $(1) $(3)/Contents/MacOS/spaceballs
	@cp $(2) $(3)/Contents/Info.plist
	@codesign --force --options runtime --timestamp \
	    --entitlements $(ENTITLEMENTS) \
	    --sign "$(4)" $(3)
endef
```

Keep `make build` (debug) using ad-hoc (`-`) for fast local iteration; only
`make release` should pass the real `SIGN_ID`.

### Notarize + staple target

```make
VERSION ?= $(shell grep -o 'version = "[^"]*"' Sources/Spaceballs/Version.swift | head -1 | cut -d'"' -f2)
DIST_ZIP = dist/Spaceballs-$(VERSION).zip

notarize: release
	@mkdir -p dist
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_ZIP)
	xcrun notarytool submit $(DIST_ZIP) \
	    --keychain-profile spaceballs-notary --wait
	xcrun stapler staple $(APP_BUNDLE)
	# Re-zip after stapling so the ticket lives in the distributed artifact
	rm $(DIST_ZIP)
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_ZIP)
	shasum -a 256 $(DIST_ZIP)
```

`notarytool submit --wait` blocks until Apple finishes; if it fails, run
`xcrun notarytool log <submission-id> --keychain-profile spaceballs-notary` for
the JSON error report.

### Verify before publishing

```bash
codesign --verify --deep --strict --verbose=2 .build/Spaceballs.app
spctl -a -t exec -vv .build/Spaceballs.app    # must say: source=Notarized Developer ID
xcrun stapler validate .build/Spaceballs.app
```

If `spctl` says "source=Notarized Developer ID" → Gatekeeper will accept it
silently on a fresh Mac.

### Fix `scripts/release.sh`

The current script still references the old `spacebar` name and tarballs a
bare CLI binary — that's not what you ship in a Cask. Either delete it or
rewrite it around the `notarize` target above.

## Homebrew Cask

GUI `.app` bundles go in a **Cask**, not a Formula. Casks live in a tap repo
(create `moltenbits/homebrew-tap`, push a `Casks/spaceballs.rb` to it):

```ruby
cask "spaceballs" do
  version "1.0.0"
  sha256 "..."  # from shasum -a 256 dist/Spaceballs-1.0.0.zip

  url "https://github.com/moltenbits/spaceballs/releases/download/v#{version}/Spaceballs-#{version}.zip"
  name "Spaceballs"
  desc "Keyboard-driven window switcher for macOS Spaces"
  homepage "https://github.com/moltenbits/spaceballs"

  app "Spaceballs.app"

  zap trash: [
    "~/Library/Preferences/com.moltenbits.spaceballs.plist",
    "~/Library/Application Support/Spaceballs",
  ]
end
```

End-user install:

```bash
brew tap moltenbits/tap
brew install --cask spaceballs
```

Because the artifact is notarized + stapled, Gatekeeper opens it silently on
first launch.

### CLI binary inside the cask

Today `make install` drops `spaceballs` into `/usr/local/bin`. In a Cask,
prefer the `binary` stanza pointing into the app bundle so users get both the
GUI and CLI from a single `brew install --cask`:

```ruby
binary "#{appdir}/Spaceballs.app/Contents/MacOS/spaceballs", target: "spaceballs"
```

No separate Formula needed.

## Suggested order of operations

1. Generate the Developer ID Application cert; verify with `security find-identity`.
2. Store notarytool credentials in the keychain (`store-credentials`).
3. Add `Resources/Spaceballs.entitlements` and the Apple Events usage string.
4. Update the Makefile (`SIGN_ID`, hardened runtime, entitlements, `notarize` target).
5. Run `make notarize`; confirm `spctl` reports "source=Notarized Developer ID".
6. `gh release create v<version> dist/Spaceballs-<version>.zip` and copy the SHA.
7. Push a cask to `moltenbits/homebrew-tap`.
8. Test on a clean Mac (or remove quarantine + re-download) — no Gatekeeper prompt.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `errSecInternalComponent` during `codesign` | Keychain locked, or signing identity not trusted. Unlock keychain; re-import the WWDR intermediate. |
| `The signature does not include a secure timestamp` | Missing `--timestamp` flag on `codesign` (notarization will reject). |
| `The binary uses an SDK older than the 10.9 SDK` | Build with a current Swift toolchain. |
| `The executable does not have the hardened runtime enabled` | Missing `--options runtime` on `codesign`. |
| `library validation failed` at runtime | A loaded dylib isn't signed by you or Apple. Either sign it, or add `com.apple.security.cs.disable-library-validation` to entitlements. |
| Notarization fails on private symbols (`_SLPSSetFrontProcessWithOptions` etc.) | Notarization checks signing/runtime, not symbol references — these *are* allowed. If rejected, read the JSON log; the cause will be elsewhere. |
| Gatekeeper still warns after notarization | Forgot to staple, or zipped before stapling. Re-zip the stapled `.app`. |
