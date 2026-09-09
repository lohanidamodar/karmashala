import '../../flutter_apps/domain/flutter_project.dart';
import 'built_in_projects.dart';
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
  return null;
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
