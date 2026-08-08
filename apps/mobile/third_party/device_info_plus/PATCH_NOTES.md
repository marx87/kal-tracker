# Coach360 compatibility patch

Upstream package: `device_info_plus` 13.2.0, distributed under the BSD
3-Clause license preserved in `LICENSE`.

Why this copy exists:

- Coach360 builds with Xcode 16.4 / iOS SDK 18.5.
- Upstream 12.4.0 through 13.2.0 directly call
  `NSProcessInfo.isiOSAppOnVision`, which is declared only by the iOS 26 SDK.
- Xcode 16.4 therefore fails at compile time even though upstream protects the
  call with an iOS 26.1 availability check.
- Version 13 is still needed because the workspace resolves `win32` 6.x.

Local change:

- `FPPDeviceInfoPlusPlugin.m` resolves `isiOSAppOnVision` with
  `NSSelectorFromString`, checks `respondsToSelector:`, and invokes the getter
  through its `IMP`. No other package behavior or public API is changed.
- `android/build.gradle.kts` respects an explicit
  `android.builtInKotlin=false` on AGP 9 and applies the Kotlin Android plugin.
  Without this, the plugin's Kotlin sources are skipped in this project.

Removal condition:

Delete this copy and restore the hosted dependency override after either the
build moves to Xcode 26+ or upstream ships an equivalent backwards-compatible
implementation. Android and iOS builds must both be rerun when removing it.
