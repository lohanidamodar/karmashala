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
      command: Established<List<String>>.unchecked(_noMac),
      artifact: Established<ProjectArtifact>.unchecked(_noMac),
      applicationId: Established<ApplicationIdSource>.unchecked(_noMac),
    ),
  ],
);

/// The one sentence every iOS field carries, here and in the native iOS
/// descriptor. Written once so the two cannot drift apart.
const String _noMac =
    'Unchecked: building for iOS needs a Mac, and release-build.yml has no '
    'macOS job, so nobody has run this. Detection works; the build is refused '
    'rather than offered as a button nobody ran.';
