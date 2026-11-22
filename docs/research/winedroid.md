# Browser-based Android previews

Research snapshot, 21–22 November 2026.

**Decision: defer Winedroid integration.** It can preview selected Android apps
whose Java or Kotlin code stays within its implemented framework APIs. Its web
runtime cannot execute the native Android libraries that PopupBits Flutter APKs
need. The Twoyi Web demo from the follow-up link booted Android 13 in a browser.
Its public page has no APK import control, so it remains a candidate for a
separate evaluation once that workflow is available.

## Winedroid

- **Source and maturity.** [sohzm/winedroid](https://github.com/sohzm/winedroid)
  identifies the project as experimental and development as intermittent. I
  inspected [commit 4b535a0](https://github.com/sohzm/winedroid/tree/4b535a045dae841beb9c04348a68f24d5190f031).
  The public GitHub snapshot showed one commit, a small open issue queue, and
  [no published releases](https://github.com/sohzm/winedroid/releases). The
  [AppDB](https://winedroid.soham.sh/appdb/) lists six apps, four rated Bronze.
  The hosted demo loaded a WASM asset from a directory labelled 12 August
  2026. The deployed build and the inspected source revision have no verified
  correspondence.
- **Runtime.** Rust code parses the APK manifest and resources and interprets
  DEX directly. It supplies its own class loading, objects, method dispatch,
  Android framework calls and lifecycle scheduling. It does not boot Android
  or run ART/Dalvik. Implemented paths include activities, main-thread tasks,
  views, layout, resources, menus and Canvas drawing. Compose can only execute
  as guest bytecode with the Android primitives it needs. Missing calls can
  return default values in best-effort mode, so a visible frame alone does
  not establish compatibility. Desktop has a Cranelift JIT. The Emscripten
  browser build uses the interpreter. [Architecture](https://github.com/sohzm/winedroid/blob/main/docs/architecture.md)
- **Native code and Flutter.** The source inventories guest ABIs and names
  possible ELF/Bionic backends, but marks native execution as unsupported.
  The browser would need to run guest machine code, resolve Android ELF and
  Bionic symbols, and connect JNI to its managed runtime. I found
  `libflutter.so` for ARM64, ARMv7 and x86-64 in existing Aakar debug and
  Sandesh release APKs. Sandesh also has the AOT Dart payload in `libapp.so`
  for those ABIs. Changing APK ABI or moving the APK to the current desktop
  runtime does not supply the missing engine support.
  [Native backend selection](https://github.com/sohzm/winedroid/blob/main/src/native_runtime.rs)
  · [Flutter build documentation](https://docs.flutter.dev/deployment/android)
- **Graphics and input.** Skia rasterizes the implemented Android UI. The
  browser host presents the pixels through a Canvas 2D context. That path
  does not supply Android EGL/GLES or Vulkan through WebGL or WebGPU. The
  host maps canvas pointer, wheel and keyboard events into the runtime.
  Android IME, multitouch and accessibility semantics were not established.
  The demo FAQ reports a roughly 12 MB runtime and a slower interpreter on
  the web. I did not measure sustained frame rate or phone performance.
  [Browser host code](https://github.com/sohzm/winedroid/blob/main/web/library_winedroid.js)
  · [Demo FAQ](https://winedroid.soham.sh/demo/)
- **Storage, network and services.** The browser accepts local file selection,
  drop or paste. The inspected loader copies the bytes to Emscripten's
  filesystem and passes that file to the runtime. Browser app data is lost
  on reload. Desktop uses a host prefix and its Java HTTP GET path invokes
  host `curl`. That path does not establish browser networking support.
  General app networking, Android sensors and Google Play services have no
  verified browser support. Files visible under `/storage/emulated/0` in the
  demo belong to the guest filesystem.
  [Browser loader](https://github.com/sohzm/winedroid/blob/main/web/app.js)
  · [HTTP implementation](https://github.com/sohzm/winedroid/blob/main/src/dex_run/builtins/java_net.rs)

## Browser observations

I used Karmashala's browser tools to open the public demo. Its shared CDP
connection dropped, so I repeated the test with an isolated Windows headless
Chrome profile. On the first headless pass, all five samples were still on
the loading screen at the seven-second check. With up to 30 seconds allowed
per sample, all five rendered. These are point-in-time observations of the
[hosted demo](https://winedroid.soham.sh/demo/).

| Sample | Observed in the browser |
| --- | --- |
| OpenCalc | Rendered the calculator keypad and display. |
| Meditation Timer | Rendered two presets and an Add control. |
| Little File Explorer | Rendered the emulated storage directory tree. |
| Weather Overview | Rendered the forecast UI, with `null` readings and no forecast. |
| Currency | Rendered currency rows and showed an update date of 11 February 2026. Live updates were not verified. |

I also selected two local PopupBits APKs after the WASM runtime initialized
and CDP had taken the test tab offline. Neither reached a running screen.

| APK | Observed result |
| --- | --- |
| Astrology Calc Wear debug, 28.9 MB | The Android Wear build entered DEX execution, then failed in `DayActivity.<init>()` while calling AndroidX. The dialog truncated the nested error. This APK ships `libandroidx.graphics.path.so`, so it is not a DEX-only control. I did not identify a DEX-only PopupBits APK in the local build outputs. |
| Sandesh Flutter release, 86.5 MB | The loader reported that it could not find `onCreate` on `com.popupbits.sandesh.MainActivity`. The observed failure occurred in activity startup. The independent native-engine limitation would remain even if that lookup were fixed. |

## License and trust boundary

Winedroid is **GPL-3.0-only**. Apache-2.0 code can be part of a GPLv3-covered
combined work. Distributing GPLv3 runtime code as part of a combined product
under Karmashala's existing Apache-2.0-only terms would not satisfy that
license model. Linking to the upstream site leaves distribution to upstream.
A separately installed and loosely coupled runtime could be evaluated on its
own distribution terms. Packaging a separate executable or using a JS
boundary alone does not settle whether the result is a combined work.
Mirroring the binaries would also bring GPL distribution and source
obligations. [Winedroid license](https://github.com/sohzm/winedroid/blob/main/LICENSE)
· [Apache Software Foundation compatibility guidance](https://www.apache.org/licenses/GPL-compatibility.html)

Browser execution inherits the browser sandbox and the runtime origin's
capabilities. The page can read every APK the user selects there. Isolation
for a future integration would require a dedicated origin and disposable
browser profile, explicit per-file selection, bounded resource usage and no
access to Karmashala's host bridge, authenticated tabs, workspace or device
credentials. A managed preview needs an egress policy and a defined storage
lifetime. Desktop runtime execution would instead require OS-level isolation
for untrusted APKs because it can interact with the host filesystem and
network.

## Karmashala options

Karmashala's [browser tools](../../server/lib/src/mcp/tools/browser_tool_set.dart)
drive a Chrome page through CDP. Its
[device tools](../../server/lib/src/mcp/tools/device_tool_set.dart) use a
separate device service. A running browser canvas provides a screenshot
surface, but its DOM does not describe the Android view hierarchy.

| Option | Feasibility and effort | Compatibility, license and security |
| --- | --- | --- |
| A. Browser pane preview | Low effort to open the upstream page and select a file manually. A reliable APK action would additionally need a supported loader API, clear compatibility errors, and client-specific file selection. Server and CI hosts still need a compatible browser or a client-side execution path. | Only compatible managed-code apps benefit. Flutter/native, Play services and sensors fail or remain unavailable. Link-only keeps the runtime upstream. A private build should remain under user control in an isolated preview. |
| B. Browser runtime as a device | High effort. Add a distinct transport with capability discovery, frame capture, coordinate mapping, pointer and text injection, and session cleanup. A useful UI dump needs an upstream structured view export. CDP screenshots and taps can work at the canvas level. | Android device semantics such as ADB install, logcat, hardware inputs and sensors cannot be assumed. Flutter and Play services remain blocked. A stable protocol with an independently distributed runtime is the starting point for license review. The bridge should expose only preview operations, without arbitrary host access. |
| C. Share a web preview | Low effort to share the public sample page. Medium to high for individual builds. It needs an APK fetch/import contract, artifact storage with authorization and expiry, pinned runtime assets, and compatibility feedback. | A share link cannot fix native, Play services or sensor gaps. Sending an APK to a storage service is a separate disclosure from opening an upstream link. Self-hosting the runtime for share links requires GPL distribution review and isolation from app and account origins. |
| D. Defer | Keep current Android hardware and emulator workflows. Revisit once a browser runtime can install and launch a representative Flutter release APK, reports unsupported calls clearly, and exposes a versioned import and input contract. Add a view-tree contract before offering device tooling. | No dependency or new APK trust boundary is needed today. An upstream release and documented redistribution policy would make both integration and security review repeatable. |

Option D is the recommendation. A browser shortcut would mostly duplicate
the existing ability to open a URL and would not preview the APKs Karmashala
needs to support. Phase 2 was skipped.

## Twoyi Web

The supplied short link redirected to [run.twoyi.app](https://run.twoyi.app/).
The served page describes an Android 13 image whose ARM64 code runs through
Twoyi's WASM translation runtime. It requires a cross-origin-isolated context
for WASM threads and uses WebGL2 for GLES. That architecture makes Android
native code a more credible prospect than Winedroid's DEX-only browser
runtime. Native libraries from a newly installed APK, Flutter graphics,
Google Play services, sensors, and guest networking still need direct
verification in the web product.

I started the public GPU boot in an isolated Windows headless Chrome tab.
Cross-origin isolation and WebGL2 were available. The page had downloaded
915 MB by the last download progress reading. The boot log showed the
WebGL2 graphics host at about 30 seconds, then Android's
`sys.boot_completed=1` at about 55 seconds. The overlay disappeared.
The served HTML estimates about 1 GB on first boot and comments that a
booted tab needs about 2.6 GB of WASM memory. The memory figure is upstream's,
and no mobile measurement was made. The public UI had no APK file input or
documented APK installation route. I verified the boot, with Flutter
installation and launch still untested.

The served HTML has an Apache-2.0 SPDX header. That header alone does not
establish redistribution rights for the WASM runtime, AOT packs, or Android
image. The older [MPL-2.0 Twoyi Android repository](https://github.com/twoyi/twoyi)
describes a separate mobile project and cannot establish the web build's
license. The public Twoyi Web link is suitable for evaluating the stock
system. A Karmashala prototype should wait for a supported local APK import
path, a representative Flutter smoke test, and documented licensing for the
components it would use.
