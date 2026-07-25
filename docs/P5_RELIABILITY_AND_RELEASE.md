# P5 Reliability and Release

## Implementation status

| Task | Status | Evidence |
|---|---|---|
| T501 fast reconnect | Implemented; 100-cycle soak remains | Host retains the display for at most 10 seconds, rebuilds transport/capture/encoder, and rejects a non-IDR first frame. Harmony retries automatically for 10 seconds. |
| T502 sleep/wake | Implemented, real-cycle validation required | Workspace sleep invalidates the active generation and all media objects; wake creates a new generation. Display removal callbacks trigger bounded recovery. |
| T503 diagnostics | Implemented | The app shows capability, mode, bitrate, RTT, video queue, recovery count and recent error; it supports display self-test, redacted JSON export and error-code copy. |
| T504 compatibility | Implemented | A bundled manifest blocks denied builds before backend creation. Unknown builds remain experimental. CI produces a review-only candidate report. |
| T505 distribution | Ad-hoc public distribution implemented | DMG packaging verifies the ad-hoc signature, bundle identity, image integrity and persistent-helper absence. Developer ID and `notarytool` remain supported as an optional future upgrade. |

## Compatibility smoke

Run capability-only CI mode:

```sh
python3 tools/macos_compatibility_smoke.py
```

On a Mac runner authorized for Screen Recording, run the private-display stages:

```sh
RUN_PRIVATE_DISPLAY_SMOKE=1 python3 tools/macos_compatibility_smoke.py
```

The JSON report records OS version/build, architecture, every stage duration and a suggested
manifest entry. A report never edits the shipped manifest automatically. New builds therefore stay
`experimental` until a human reviews successful create/enumerate/capture/destroy evidence.

## macOS distribution signing

The current public Release workflow uses ad-hoc signing:

```sh
MACOS_SIGN_IDENTITY=- INSTALL_LOCAL_PAIRING_IDENTITY=0 tools/package_macos_dmg.sh
REQUIRE_ADHOC=1 tools/verify_macos_distribution.sh
```

This proves bundle integrity but does **not** establish an Apple developer identity, pass standard
Gatekeeper assessment or claim Apple notarization. Release notes and build metadata must retain
that disclosure.

Developer ID signing and notarization remain available as an optional future upgrade:

```sh
MACOS_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="second-display-notary" \
tools/package_macos_dmg.sh

REQUIRE_GATEKEEPER=1 REQUIRE_NOTARIZATION=1 tools/verify_macos_distribution.sh
```

Record the actual notary submission ID and result here before changing the release workflow to
claim Developer ID trust on a clean distribution machine.

The bundle identifier remains `com.cuihua.cloud.display.macos`. The app installs no LaunchAgent,
daemon, XPC service or privileged helper; stopping/termination synchronously releases the virtual
display. Pairing credentials are user data under Application Support and are not an executable
residue.

## Latest local validation (2026-07-23)

- HarmonyOS device `FMR0223B23057624` connected at its negotiated 2720×1260 / 120 FPS mode.
- A 2-second receiver interruption recovered on the same virtual display ID (`182`).
- After a separate disconnect, display ID `181` remained online immediately and was absent after
  12 seconds, proving the retention timeout releases it.
- Debug Swift tests passed 96 tests with 3 opt-in integration skips; Release passed 97 tests with
  3 skips. The Harmony host C++ protocol suite passed.
- Private-display compatibility smoke passed on macOS build `25F84` / arm64, including
  create-enumerate-destroy and capture-encode stages.
- The ad-hoc DMG passed image integrity, code-signature, stable bundle ID and no-helper checks.
  Gatekeeper and notarization intentionally remain unclaimed until a Developer ID submission and a
  clean-machine install are performed.
