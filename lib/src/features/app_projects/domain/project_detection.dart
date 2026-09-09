import '../../flutter_apps/domain/flutter_project.dart';
import 'built_in_projects.dart';
import 'gradle_project.dart';
import 'project_descriptor.dart';
import 'project_kind.dart';

/// Reads one file inside the project, or answers null when it is not there or
/// could not be read.
///
/// [relativePath] is always forward-slash separated and relative to the
/// project directory. The caller joins it with its own environment's path
/// context, so a Windows checkout and a distribution hand the same decision
/// the same strings.
typedef ProjectFileReader = String? Function(String relativePath);

/// The entry names directly inside [relativeDirectory] — files and
/// directories both, no paths. Empty when the directory is not there.
typedef ProjectEntryLister = List<String> Function(String relativeDirectory);

/// What a directory turned out to be, and why.
///
/// **Pure, and that is the point** — the same reason `flutterProjectsIn` is.
/// Deciding what a checkout holds is a question about text; finding the text
/// is a question about a filesystem that may be a distribution or another
/// machine.
class ProjectReading {
  const ProjectReading({
    required this.kind,
    required this.name,
    required this.evidence,
    this.androidModule,
    this.iosScheme,
  });

  final ProjectKind kind;

  /// The project's own name where it declares one, else the directory's.
  final String name;

  /// The files and lines that said so, in the order they were read. What a
  /// person needs to disagree with the verdict.
  final List<String> evidence;

  /// The Gradle module that carries `com.android.application`, as Gradle
  /// spells it: `:app`. Null for every kind but native Android.
  final String? androidModule;

  /// The first shared Xcode scheme. Null for every kind but native iOS.
  final String? iosScheme;

  /// What is known about this kind beyond how to spot it, **or null**: a kind
  /// with no descriptor gets detection and nothing else.
  ProjectDescriptor? get descriptor => descriptorFor(kind);

  /// The module directory, relative to the project: `:app` is `app/`.
  String? get androidModuleDirectory =>
      androidModule?.replaceFirst(':', '').replaceAll(':', '/');

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'label': kind.label,
    'name': name,
    'evidence': evidence,
    if (androidModule != null) 'androidModule': androidModule,
    if (iosScheme != null) 'iosScheme': iosScheme,
    'descriptor': descriptor?.toJson(),
    if (descriptor == null)
      'descriptorNote':
          'Karmashala can spot a ${kind.label} project and nothing more. '
          'There is no build command, artifact or application id for it here, '
          'because nobody has run its toolchain from this app.',
  };
}

/// What kind of app project sits at a directory, or **null when none does** —
/// which is not "an empty project" (§19).
///
/// The order below is the whole subtlety. A Flutter app and a React Native app
/// each carry an `android/` whose module applies `com.android.application`, so
/// asked in the wrong order every one of them would answer to the native
/// Android markers. Narrowest first, and each later kind refuses what an
/// earlier one claimed.
ProjectReading? detectProject({
  required String directoryName,
  required ProjectFileReader read,
  ProjectEntryLister? list,
}) {
  final flutter = _readFlutter(directoryName: directoryName, read: read);
  if (flutter != null) return flutter;
  final android = _readNativeAndroid(directoryName: directoryName, read: read);
  if (android != null) return android;
  return null;
}

/// The files [detectProject] reads before it knows what it is looking at.
///
/// Named so the scanner fetches exactly these and no more: a detection is a
/// bounded handful of reads, not a walk. The module scripts are a second round
/// — which ones to read is a question only the settings script can answer.
const List<String> kProjectRootFiles = <String>[
  'pubspec.yaml',
  'package.json',
  'settings.gradle.kts',
  'settings.gradle',
  'gradle/libs.versions.toml',
  '../pubspec.yaml',
];

/// The build scripts to read for [modules], both spellings, in the order they
/// are preferred.
List<String> gradleModuleScriptPaths(List<String> modules) => <String>[
  for (final module in modules)
    for (final name in const <String>['build.gradle.kts', 'build.gradle'])
      '${module.replaceFirst(':', '').replaceAll(':', '/')}/$name',
];

/// Why a directory that carries Gradle is still not a project we build, when
/// there is something specific to say. Null when there is not.
///
/// This exists because the generic "no marker Karmashala knows" is *wrong* for
/// the most likely case on a Flutter machine: pointing at `android/` inside a
/// Flutter checkout. That directory has every native Android marker and is the
/// Android half of the app one level up, so the refusal has to say which.
String? notAProjectNote({required ProjectFileReader read}) {
  final settings = read('settings.gradle.kts') ?? read('settings.gradle');
  if (settings == null) return null;
  if (!gradleSettingsIsFlutterHost(settings) && !_parentIsFlutter(read)) {
    return null;
  }
  return 'This is the Android half of a Flutter project, not a native Android '
      'project: its settings script reaches into the Flutter SDK '
      '(dev.flutter.flutter-plugin-loader, includeBuild of '
      'flutter_tools/gradle, flutter.sdk from local.properties). Building it '
      'directly would build somebody else\'s app behind their back, and it '
      'usually has no gradlew of its own because Flutter drives Gradle through '
      'its own tooling. Point at the Flutter project one directory up.';
}

/// Native Android: a Gradle build with an application module, and no Flutter
/// or React Native above or around it.
///
/// The two exclusions are not decoration. Every Android project on the
/// machine this was written for is a Flutter host module, and a React Native
/// project carries an `android/` that looks exactly like this one.
ProjectReading? _readNativeAndroid({
  required String directoryName,
  required ProjectFileReader read,
}) {
  // The item's own rule: `settings.gradle` with an app module, **no
  // pubspec.yaml**. A pubspec here would already have been answered above
  // unless it is a plain Dart package, and a plain Dart package that also
  // holds an Android app is not a shape worth guessing at.
  if (read('pubspec.yaml') != null) return null;
  final settings = read('settings.gradle.kts') ?? read('settings.gradle');
  if (settings == null) return null;
  if (gradleSettingsIsFlutterHost(settings) || _parentIsFlutter(read)) {
    return null;
  }

  final catalog = gradlePluginCatalog(read('gradle/libs.versions.toml') ?? '');
  final modules = gradleIncludedModules(settings);
  for (final module in modules) {
    final directory = module.replaceFirst(':', '').replaceAll(':', '/');
    final script =
        read('$directory/build.gradle.kts') ?? read('$directory/build.gradle');
    if (script == null) continue;
    final moduleReading = readGradleModule(script);
    // A Flutter host module can be included by a settings script that says
    // nothing about Flutter itself, so the module is checked too.
    if (moduleReading.isFlutterHostModule) return null;
    if (!moduleReading.appliesAndroidApplication(catalog: catalog)) continue;
    return ProjectReading(
      kind: ProjectKind.nativeAndroid,
      name: gradleRootProjectName(settings) ?? directoryName,
      androidModule: module,
      evidence: <String>[
        'settings script includes ${modules.join(', ')}',
        '$directory build script applies com.android.application',
        if (moduleReading.applicationId != null)
          'applicationId "${moduleReading.applicationId}" is a literal in that '
              'script; the build\'s own output-metadata.json is read for the '
              'one that shipped',
        if (moduleReading.applicationId == null)
          'no applicationId literal in that script, so it is read from the '
              'build\'s own output-metadata.json and is unknown until there '
              'is a build',
      ],
    );
  }
  return null;
}

/// Whether the directory **above** this one is a Flutter project.
///
/// The second, independent signal that an `android/` belongs to somebody. It
/// catches a host module whose settings script has been rewritten and no
/// longer names Flutter — which `flutter create` does not produce, but a
/// person editing one can.
bool _parentIsFlutter(ProjectFileReader read) {
  final parent = read('../pubspec.yaml');
  return parent != null && readPubspec(parent).isFlutter;
}

/// Flutter, read through `readPubspec` rather than beside it.
///
/// **The seam is only real if this is not a second copy.** Everything about
/// what makes a pubspec a Flutter project — the two independent signals, the
/// deliberate refusal to parse YAML, what the scan does not see — is already
/// decided in `flutter_project.dart` and pinned by its own tests. This calls
/// it. If the two ever disagreed, one of them would be wrong and nobody would
/// know which.
ProjectReading? _readFlutter({
  required String directoryName,
  required ProjectFileReader read,
}) {
  final contents = read('pubspec.yaml');
  if (contents == null) return null;
  final reading = readPubspec(contents);
  if (!reading.isFlutter) return null;
  return ProjectReading(
    kind: ProjectKind.flutter,
    name: reading.name?.isNotEmpty == true ? reading.name! : directoryName,
    evidence: <String>[
      'pubspec.yaml: ${<String>[for (final e in reading.evidence) e.name].join(', ')}',
      if (!reading.isRunnable)
        'No top-level flutter: section, so this is a package or a plugin '
            'rather than an app.',
    ],
  );
}
