# HarmonyOS receiver

This is a minimal HarmonyOS NEXT Stage-model tablet application. Its native protocol implementation
is dependency-free C++17 and reads the same `../shared/test-vectors` files as the Swift tests.

## Build

With the HarmonyOS command-line tools configured (the bundled `hvigorw` supplies its matching build
plugin, so no private package registry or signing certificate is needed):

```sh
hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
```

The debug HAP may be built without a private signing certificate. Installing and launching it still
requires a connected, authorized HarmonyOS tablet and the normal device deployment command.

For an unsigned CI workspace, copy `build-profile.ci.json5` to the ignored
`build-profile.json5` before running the same command. The CI profile deliberately contains no
signing configuration or certificate paths.

The native protocol tests are also host-buildable without HarmonyOS or signing:

```sh
cmake -S entry/src/main/cpp -B ../.build/harmony-host -DBUILD_PROTOCOL_TESTS=ON
cmake --build ../.build/harmony-host
ctest --test-dir ../.build/harmony-host --output-on-failure
```
