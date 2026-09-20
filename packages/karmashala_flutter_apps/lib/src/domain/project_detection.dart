import 'flutter_project.dart';
import 'built_in_projects.dart';
import 'gradle_project.dart';
import 'package_json.dart';
import 'project_descriptor.dart';
import 'project_kind.dart';

/// Reads one file inside the project, or null. [relativePath] is always
/// forward-slash separated, so every environment decides on the same strings.
typedef ProjectFileReader = String? Function(String relativePath);

/// The entry names directly inside [relativeDirectory] — files and
/// directories both, no paths. Empty when the directory is not there.
typedef ProjectEntryLister = List<String> Function(String relativeDirectory);

/// What a directory turned out to be, and why. Pure: deciding what a checkout
/// holds is a question about text, not about a filesystem.
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

  /// The files and lines that said so — what a person needs to disagree.
  final List<String> evidence;

  /// The Gradle module that carries `com.android.application`, as Gradle
  /// spells it: `:app`. Null for every kind but native Android.
  final String? androidModule;

  /// The first shared Xcode scheme. Null for every kind but native iOS.
  final String? iosScheme;

  /// What is known about this kind beyond how to spot it, or null when a kind
  /// gets detection and nothing else.
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

/// What kind of app project sits at a directory, or null when none does (§19).
/// Narrowest first: Flutter and React Native both carry an `android/` too.
ProjectReading? detectProject({
  required String directoryName,
  required ProjectFileReader read,
  ProjectEntryLister? list,
}) {
  final flutter = _readFlutter(directoryName: directoryName, read: read);
  if (flutter != null) return flutter;
  final native = _readReactNative(directoryName: directoryName, read: read);
  if (native != null) return native;
  final android = _readNativeAndroid(directoryName: directoryName, read: read);
  if (android != null) return android;
  return _readNativeIos(directoryName: directoryName, read: read, list: list);
}

/// The files [detectProject] reads before it knows what it is looking at —
/// named so the scanner fetches exactly these: a bounded handful, not a walk.
const List<String> kProjectRootFiles = <String>[
  'pubspec.yaml',
  'package.json',
  'settings.gradle.kts',
  'settings.gradle',
  'gradle/libs.versions.toml',
  '../pubspec.yaml',
];

/// The build scripts for [modules], both spellings, in preference order.
List<String> gradleModuleScriptPaths(List<String> modules) => <String>[
  for (final module in modules)
    for (final name in const <String>['build.gradle.kts', 'build.gradle'])
      '${module.replaceFirst(':', '').replaceAll(':', '/')}/$name',
];

/// Why a Gradle directory is still not a project we build, or null: `android/`
/// in a Flutter checkout has every native marker and needs its own answer.
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
/// or React Native above or around it — both of those carry one too.
ProjectReading? _readNativeAndroid({
  required String directoryName,
  required ProjectFileReader read,
}) {
  // No pubspec.yaml: one here would already have been answered above unless it
  // is a plain Dart package, which is not a shape worth guessing at.
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

/// React Native or Expo, from `package.json`. Asked before native Android: its
/// `android/` answers those markers, and a bare build drops the JS bundle.
ProjectReading? _readReactNative({
  required String directoryName,
  required ProjectFileReader read,
}) {
  final contents = read('package.json');
  if (contents == null) return null;
  final reading = readPackageJson(contents);
  if (!reading.isReactNative) return null;
  return ProjectReading(
    kind: ProjectKind.reactNative,
    name: reading.name ?? directoryName,
    evidence: <String>[
      'package.json declares '
          '${<String>[for (final item in reading.evidence) item.name].join(', ')}',
    ],
  );
}

/// Native iOS: an Xcode project with, where there is one, a shared scheme.
/// Asked last — a Flutter `ios/` has a `Runner.xcodeproj` and shared scheme.
ProjectReading? _readNativeIos({
  required String directoryName,
  required ProjectFileReader read,
  ProjectEntryLister? list,
}) {
  if (read('pubspec.yaml') != null || read('package.json') != null) return null;
  if (_parentIsFlutter(read)) return null;
  // No listing, no answer: an Xcode project is a directory and its schemes are
  // files inside it, so a file read alone cannot see them (§19).
  if (list == null) return null;

  final entries = list('');
  // `Flutter/` beside the project is what `flutter create` puts in `ios/`, so a
  // directory with it is the iOS half of somebody's Flutter app.
  if (entries.contains('Flutter')) return null;

  final projects = <String>[
    for (final entry in entries)
      if (entry.endsWith('.xcodeproj')) entry,
  ]..sort();
  if (projects.isEmpty) return null;
  final project = projects.first;

  // Sorted, so "the first shared scheme" is the same answer every time.
  final schemes = <String>[
    for (final entry in list('$project/xcshareddata/xcschemes'))
      if (entry.endsWith('.xcscheme'))
        entry.substring(0, entry.length - '.xcscheme'.length),
  ]..sort();

  return ProjectReading(
    kind: ProjectKind.nativeIos,
    name: project.substring(0, project.length - '.xcodeproj'.length),
    iosScheme: schemes.isEmpty ? null : schemes.first,
    evidence: <String>[
      if (entries.any((entry) => entry.endsWith('.xcworkspace')))
        '$project is here, beside a workspace'
      else
        '$project is here',
      if (schemes.isEmpty)
        'no shared scheme under $project/xcshareddata/xcschemes, so there is '
            'nothing for xcodebuild -scheme to name'
      else
        'shared schemes: ${schemes.join(', ')}',
    ],
  );
}

/// Whether the directory above is a Flutter project — the second signal, for a
/// host module whose settings script no longer names Flutter.
bool _parentIsFlutter(ProjectFileReader read) {
  final parent = read('../pubspec.yaml');
  return parent != null && readPubspec(parent).isFlutter;
}

/// Flutter, read through `readPubspec` rather than beside it: a second copy of
/// that decision could disagree with it and nobody would know which was wrong.
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
