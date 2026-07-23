# P1 real macOS validation

Automated integration tests are opt-in because they visibly add and remove a display:

```sh
RUN_VIRTUAL_DISPLAY_INTEGRATION=1 VD_CYCLES=1 \
  swift test --filter VirtualDisplayProviderTests/testRealDisplayCreateDestroyWhenExplicitlyEnabled

RUN_VIRTUAL_DISPLAY_INTEGRATION=1 VD_CYCLES=50 \
  swift test --filter VirtualDisplayProviderTests/testRealDisplayCreateDestroyWhenExplicitlyEnabled

RUN_VIRTUAL_DISPLAY_INTEGRATION=1 \
  swift test --filter VirtualDisplayProviderTests/testRealOriginPersistenceWhenExplicitlyEnabled
```

The first command validates the public current mode is 1280×800 logical / 2560×1600 pixels at
60 Hz. The 50-cycle command validates online registration, non-mirroring, non-zero bounds, release
within five seconds, and safe same-serial reuse only after release. macOS 26 may return no public
mode list after the first rapid recreation in one process, so mode validation runs independently.

Manual UI checks that cannot be asserted reliably from XCTest:

1. Run `swift run SecondDisplayMacApp` and select **Create Test Display**.
2. Open System Settings → Displays and confirm **Second Display Diagnostic** is an independent display.
3. Open TextEdit and drag its window onto the new desktop.
4. Move the display to the left in Displays, destroy it, create it again, and confirm its position.
5. Select **Destroy Test Display** and confirm it disappears within five seconds.

Never run these checks in unattended CI. No private API type may be referenced outside the shim
target, and display configuration changes use `.forSession` rather than permanent persistence.

