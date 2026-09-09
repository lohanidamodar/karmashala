import 'established.dart';
import 'project_descriptor.dart';
import 'project_kind.dart';

/// What Karmashala knows about each [ProjectKind], as **data**.
///
/// The list is also the detection order, and that order is load-bearing: a
/// Flutter app and a React Native app both carry an `android/` directory whose
/// module applies `com.android.application`, so either would answer to the
/// native-Android markers if it were asked first. Narrowest first.
///
/// A kind may be missing from this list. It then gets detection and nothing
/// else, which is the honest outcome for a framework nobody here has built.
const List<ProjectDescriptor> builtInProjectDescriptors = <ProjectDescriptor>[
  _flutter,
  _nativeAndroid,
  _nativeIos,
];

/// The descriptor for [kind], or null when there is none.
ProjectDescriptor? descriptorFor(ProjectKind kind) {
  for (final descriptor in builtInProjectDescriptors) {
    if (descriptor.kind == kind) return descriptor;
  }
  return null;
}

/// Flutter, re-expressed as the first descriptor.
///
/// **This changes nothing about the Flutter loop.** `FlutterLoopController`
/// still runs `pub get`, `run`, `analyze` and `test` through the visible-pane
/// opener exactly as it did, and `flutter_project.dart` still owns detection.
/// What is new is the row: the *artifact* half of Flutter — build an APK,
/// install it, launch it — was never written down anywhere, and writing it
/// down here is what makes a second framework a descriptor instead of a second
/// feature.
const _flutter = ProjectDescriptor(
  kind: ProjectKind.flutter,
  summary:
      'A pubspec.yaml with a flutter: section. The one kind with an owned '
      'lifecycle: flutter_run does pub get, launch, analyze and test.',
  liveChannel: Established<String>.measured(
    'the Dart VM service',
    evidence:
        'flutter_run passes --vmservice-out-file and AttachedApps connects to '
        'the ws:// address the app writes; flutter_reload, flutter_logs and '
        'flutter_pick_widget speak it.',
  ),
  builds: <ProjectBuildSpec>[
    ProjectBuildSpec(
      target: ProjectTarget.android,
      tool: ProjectBuildTool.flutterSdk,
      command: Established<List<String>>.measured(
        <String>['build', 'apk', '--debug'],
        evidence:
            'flutter build apk --debug, run 2026-09-09 in this checkout '
            'through the Windows toolchain: "Running Gradle task '
            '\'assembleDebug\'... 198.6s", exit 0.',
      ),
      artifact: Established<ProjectArtifact>.measured(
        ProjectArtifact(
          directory: 'build/app/outputs/flutter-apk',
          fileName: 'app-debug.apk',
        ),
        evidence:
            'The same run ended "Built build\\app\\outputs\\flutter-apk\\'
            'app-debug.apk"; the file is 205,915,659 bytes. Flutter copies it '
            'there from AGP\'s own build/app/outputs/apk/debug/.',
      ),
      applicationId: Established<ApplicationIdSource>.measured(
        ApplicationIdSource.buildOutputMetadata,
        evidence:
            'build/app/outputs/apk/debug/output-metadata.json from that run '
            'reads "applicationId": "com.popupbits.karmashala", which is the '
            'literal in android/app/build.gradle.kts.',
      ),
    ),
    ProjectBuildSpec(
      target: ProjectTarget.ios,
      tool: ProjectBuildTool.xcodebuild,
      command: Established<List<String>>.unchecked(_noMac),
      artifact: Established<ProjectArtifact>.unchecked(_noMac),
      applicationId: Established<ApplicationIdSource>.unchecked(_noMac),
    ),
  ],
);


/// Native Android: a Gradle build whose settings script includes a module
/// applying `com.android.application`.
///
/// **Measured against a project made for the measurement, because this
/// machine has none.** Every Android project on this disk is a Flutter app —
/// including this repository's own `android/`, which is a Flutter *host
/// module*: its settings script `includeBuild`s `flutter_tools/gradle`,
/// applies `dev.flutter.flutter-plugin-loader`, reads `flutter.sdk` out of
/// `local.properties`, and ships no `gradlew` or `gradlew.bat` at all, because
/// Flutter drives Gradle through its own tooling. So it is not a usable native
/// fixture, and `gradleSettingsIsFlutterHost` exists to keep it out of this
/// path rather than build somebody's Flutter app behind their back.
///
/// A throwaway minimal native project was built instead, through the Windows
/// toolchain, and deleted after. The evidence on each field is that run.
const _nativeAndroid = ProjectDescriptor(
  kind: ProjectKind.nativeAndroid,
  summary:
      'A settings.gradle(.kts) including a module that applies '
      'com.android.application, with no pubspec.yaml beside it.',
  liveChannel: Established<String>.absent(
    'Android has no live debug channel beyond logcat, which device_logcat '
    'already reads. A Flutter app has the VM service because Dart runs one; '
    'there is no native equivalent to half-build here.',
  ),
  builds: <ProjectBuildSpec>[
    ProjectBuildSpec(
      target: ProjectTarget.android,
      tool: ProjectBuildTool.gradleWrapper,
      command: Established<List<String>>.measured(
        <String>['${ProjectBuildSpec.modulePlaceholder}:assembleDebug'],
        evidence:
            'gradlew.bat :app:assembleDebug, run 2026-09-09 through the '
            'Windows toolchain against a minimal AGP 9.0.1 / Gradle 9.1.0 '
            'project: "BUILD SUCCESSFUL in 32s", 32 tasks executed, exit 0.',
      ),
      artifact: Established<ProjectArtifact>.measured(
        ProjectArtifact(
          directory:
              '${ProjectBuildSpec.modulePlaceholder}/build/outputs/apk/debug',
          fileName: '${ProjectBuildSpec.modulePlaceholder}-debug.apk',
        ),
        evidence:
            'That run left app/build/outputs/apk/debug/app-debug.apk, 5,811 '
            'bytes. The file name is only expected: AGP names the APK after '
            'the module\'s archives base name, so the metadata beside it is '
            'read for the real one.',
      ),
      applicationId: Established<ApplicationIdSource>.measured(
        ApplicationIdSource.buildOutputMetadata,
        evidence:
            'output-metadata.json from that run reads "applicationId": '
            '"com.popupbits.nativeprobe" and "outputFile": "app-debug.apk". '
            'Crossed against the applicationId literal in app/build.gradle.kts '
            'and against aapt dump badging on the APK: all three agree, so the '
            'file the build already wrote is used and no second tool is '
            'spawned. That APK then installed and launched on an emulator by '
            'that id, through the same adb the device tools run.',
      ),
    ),
    // No iOS spec at all, rather than an unchecked one. An Android project has
    // no iOS target — writing a row that says "unchecked" would claim there is
    // something here nobody got round to.
  ],
);


/// Native iOS: an Xcode project with a shared scheme, and **every field
/// unchecked on purpose**.
///
/// The shape is written out in full — the scheme `xcodebuild` would be pointed
/// at, the simulator artifact it would leave, the `Info.plist` key the bundle
/// id comes out of — because a spec that cannot be read cannot be reviewed,
/// and the day somebody has a Mac this is what they check against. It is in
/// `sketch` rather than in `value`, so nothing can run it and the UI has
/// nothing to offer. **No button nobody ran.**
///
/// Detection works, and that alone is worth having: the fourteen `device_*`
/// tools drive a simulator already, so an iOS checkout that says what it is
/// can still be installed onto one from an artifact built by hand.
const _nativeIos = ProjectDescriptor(
  kind: ProjectKind.nativeIos,
  summary:
      'An .xcodeproj with a shared scheme, and no pubspec.yaml or '
      'package.json beside it. Detected only — nothing here can build it.',
  liveChannel: Established<String>.absent(
    'iOS has no live debug channel beyond the device log, which the device '
    'tools already read. A Flutter app has the VM service because Dart runs '
    'one; there is no native equivalent to half-build here.',
  ),
  builds: <ProjectBuildSpec>[
    ProjectBuildSpec(
      target: ProjectTarget.ios,
      tool: ProjectBuildTool.xcodebuild,
      command: Established<List<String>>.unchecked(
        _noMac,
        sketch:
            'xcodebuild -scheme <the first shared scheme detection found> '
            '-sdk iphonesimulator -configuration Debug -derivedDataPath build',
      ),
      artifact: Established<ProjectArtifact>.unchecked(
        _noMac,
        sketch:
            'build/Build/Products/Debug-iphonesimulator/<scheme>.app — a '
            'directory rather than a file, which is what device_install_app '
            'already takes on iOS.',
      ),
      applicationId: Established<ApplicationIdSource>.unchecked(
        _noMac,
        sketch:
            'CFBundleIdentifier out of the built bundle, which is what '
            'device_install_app reads back and reports today. simctl install '
            'then simctl launch is the pair after it — both already behind '
            'device_install_app and device_launch_app.',
      ),
    ),
  ],
);

/// The one sentence every iOS field carries, here and in the native iOS
/// descriptor. Written once so the two cannot drift apart.
const String _noMac =
    'Unchecked: building for iOS needs a Mac, and release-build.yml has no '
    'macOS job, so nobody has run this. Detection works; the build is refused '
    'rather than offered as a button nobody ran.';
