import 'established.dart';
import 'project_kind.dart';

/// A device family a project can be built for. Not "platform": the question is
/// which `device_*` tool the artifact goes to, so a desktop build is not here.
enum ProjectTarget {
  android('Android'),
  ios('iOS');

  const ProjectTarget(this.label);

  final String label;
}

/// Where an application id comes from, in order of preference — which is the
/// order of how much of it is ours.
enum ApplicationIdSource {
  /// `output-metadata.json`, written by AGP beside the APK: it carries both
  /// `applicationId` and `outputFile`, so nothing here parses a build script.
  buildOutputMetadata(
    'output-metadata.json beside the artifact',
  ),

  /// An `applicationId` literal in the module's build script — the only source
  /// available before a build. A literal only: `"$flavour"` is Gradle's to say.
  moduleBuildScript(
    'the applicationId literal in the module build script',
  ),

  /// `CFBundleIdentifier` from the built `.app` bundle's `Info.plist`, which is
  /// what `device_install_app` already reads back on iOS.
  bundleInfoPlist('CFBundleIdentifier in the built bundle'),
  ;

  const ApplicationIdSource(this.label);

  final String label;
}


/// Which program runs a [ProjectBuildSpec.command]. A field, not an assumption,
/// because `gradlew` is a file in the project rather than a name on PATH.
enum ProjectBuildTool {
  /// The Flutter SDK found for that environment by `FlutterSdkReadings`, where
  /// CLAUDE.md §17's refusal lives.
  flutterSdk('the Flutter SDK for that environment'),

  /// The `gradlew` wrapper in the project, never a `gradle` on PATH: the
  /// wrapper is how a project pins the Gradle it was written for.
  gradleWrapper('the project\'s own gradlew'),

  /// `xcodebuild`, which exists only on a Mac.
  xcodebuild('xcodebuild'),

  /// The project's own package script, run through its package manager.
  packageScript('the project\'s package script'),
  ;

  const ProjectBuildTool(this.label);

  final String label;
}

/// Where a build's artifact lands, relative to the project directory.
class ProjectArtifact {
  const ProjectArtifact({required this.directory, required this.fileName});

  /// Forward-slash separated and relative to the project, so one spelling
  /// works for a Windows checkout and a distribution alike.
  final String directory;

  final String fileName;

  String get path => '$directory/$fileName';

  @override
  String toString() => path;
}

/// One target's build. Every field is an [Established] rather than a value: a
/// descriptor that cannot say how it knows is a guess with a nice shape.
class ProjectBuildSpec {
  const ProjectBuildSpec({
    required this.target,
    required this.tool,
    required this.command,
    required this.artifact,
    required this.applicationId,
  });

  final ProjectTarget target;

  /// What runs [command]. Resolved to a real executable per environment, and
  /// never guessed at from a bare name.
  final ProjectBuildTool tool;

  /// The argv, run **in the project directory**. May contain
  /// [modulePlaceholder], which detection fills in.
  final Established<List<String>> command;

  final Established<ProjectArtifact> artifact;

  final Established<ApplicationIdSource> applicationId;

  /// Stands in for the Gradle module detection found, so one const spec covers
  /// `:app`, `:mobile` and whatever somebody called theirs.
  static const String modulePlaceholder = '<module>';

  /// Whether this app can build for this target at all; false leaves [refusal]
  /// as the whole answer, because a button nobody ran is worse than no button.
  bool get isRunnable => command.isMeasured && artifact.isMeasured;

  /// The one sentence the UI and the tool refuse with. Empty when runnable.
  String get refusal => isRunnable ? '' : command.refusal;

  /// [command] with [modulePlaceholder] resolved, or null when unchecked.
  List<String>? commandFor({String? module}) {
    final argv = command.value;
    if (argv == null) return null;
    if (module == null) return List<String>.unmodifiable(argv);
    return List<String>.unmodifiable(<String>[
      for (final part in argv) part.replaceAll(modulePlaceholder, module),
    ]);
  }

  /// [artifact] with [modulePlaceholder] resolved, or null when unchecked.
  ProjectArtifact? artifactFor({String? module}) {
    final found = artifact.value;
    if (found == null) return null;
    if (module == null) return found;
    return ProjectArtifact(
      directory: found.directory.replaceAll(modulePlaceholder, module),
      fileName: found.fileName.replaceAll(modulePlaceholder, module),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'target': target.name,
    'tool': tool.name,
    'toolNote': tool.label,
    'command': command.toJson(),
    'artifact': artifact.toJson(),
    'applicationId': applicationId.toJson(),
    'runnable': isRunnable,
    if (!isRunnable) 'refusal': refusal,
  };
}

/// Everything known about one [ProjectKind] beyond how to spot it — a row of
/// data, with every field carrying how it was established.
class ProjectDescriptor {
  const ProjectDescriptor({
    required this.kind,
    required this.summary,
    required this.builds,
    required this.liveChannel,
  });

  final ProjectKind kind;

  final String summary;

  final List<ProjectBuildSpec> builds;

  /// The channel that talks to the app while it runs: [EstablishedState.absent]
  /// is "Android has none", [EstablishedState.unchecked] "nobody ran Metro".
  final Established<String> liveChannel;

  ProjectBuildSpec? buildFor(ProjectTarget target) {
    for (final spec in builds) {
      if (spec.target == target) return spec;
    }
    return null;
  }

  /// The targets this app can actually build for, which may be none.
  List<ProjectTarget> get runnableTargets => <ProjectTarget>[
    for (final spec in builds)
      if (spec.isRunnable) spec.target,
  ];

  bool get canBuild => runnableTargets.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'label': kind.label,
    'summary': summary,
    'builds': <Object?>[for (final spec in builds) spec.toJson()],
    'liveChannel': liveChannel.toJson(),
  };
}
