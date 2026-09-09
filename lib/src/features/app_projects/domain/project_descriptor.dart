import 'established.dart';
import 'project_kind.dart';

/// A device family a project can be built for.
///
/// Deliberately not "platform": the question this answers is which of the
/// fourteen framework-agnostic `device_*` tools the artifact can be handed to,
/// and those speak `adb` and `simctl`. A desktop build is a real thing and has
/// no place here, because nothing installs it onto a device.
enum ProjectTarget {
  android('Android'),
  ios('iOS');

  const ProjectTarget(this.label);

  final String label;
}

/// Where an application id comes from.
///
/// Three sources, and the order is the order of preference — which is the
/// order of how much of it is *ours*.
enum ApplicationIdSource {
  /// `output-metadata.json`, which the Android Gradle Plugin writes beside the
  /// APK it just produced. It carries `applicationId` and `outputFile`, so the
  /// build's own record answers both questions and nothing here parses a build
  /// script or spawns a second tool.
  buildOutputMetadata(
    'output-metadata.json beside the artifact',
  ),

  /// An `applicationId` literal in the module's build script. The only source
  /// available **before** a build, so it is what detection reports — and it
  /// reads a literal only, because `applicationId = "$flavour"` is a value
  /// Gradle computes and we would be guessing at.
  moduleBuildScript(
    'the applicationId literal in the module build script',
  ),

  /// `CFBundleIdentifier` out of the built `.app` bundle's `Info.plist`, which
  /// is what `device_install_app` already reads back on iOS.
  bundleInfoPlist('CFBundleIdentifier in the built bundle'),
  ;

  const ApplicationIdSource(this.label);

  final String label;
}


/// Which program runs a [ProjectBuildSpec.command], resolved per environment.
///
/// **The second kind is what made this a field.** With only Flutter in the
/// table the tool was implicit — there was one — and the controller could
/// assume it. `gradlew` is the second, and it is not a name on PATH but a file
/// *in the project*: the descriptor has to say which of the two it wants, or
/// the code that runs it is guessing.
enum ProjectBuildTool {
  /// The Flutter SDK found for that environment by `FlutterSdkReadings`,
  /// which is where CLAUDE.md §17's refusal lives.
  flutterSdk('the Flutter SDK for that environment'),

  /// The `gradlew` wrapper **in the project**. Never a `gradle` on PATH: the
  /// wrapper is how a project pins the Gradle it was written for, and building
  /// with another one is building something else.
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
  /// works for a Windows checkout and a distribution alike; the caller joins
  /// it with that environment's own context.
  final String directory;

  final String fileName;

  String get path => '$directory/$fileName';

  @override
  String toString() => path;
}

/// One target's build: the command, the artifact, and the application id.
///
/// Every field is an [Established] rather than a value, because a descriptor
/// that cannot say *how it knows* is a guess with a nice shape. The iOS spec
/// below is the case that proves it earns its keep: it is complete, readable,
/// reviewable — and every field says nobody ran it.
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

  /// Whether this app can build for this target at all.
  ///
  /// False leaves [refusal] as the whole answer: a button nobody ran is worse
  /// than no button.
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

/// Everything Karmashala knows about one [ProjectKind] beyond how to spot it.
///
/// Shaped after `AgentDescriptor` in `built_in_agents.dart`, and for the same
/// reason: a second framework should be a row of data rather than a second
/// feature. What differs is that every field here carries how it was
/// established, because a build command is a claim about somebody's machine
/// and an agent's flag list is a claim about a binary we can run.
class ProjectDescriptor {
  const ProjectDescriptor({
    required this.kind,
    required this.summary,
    required this.builds,
    required this.liveChannel,
  });

  final ProjectKind kind;

  /// One line: what this kind is, as a person reads it.
  final String summary;

  final List<ProjectBuildSpec> builds;

  /// Tier 3 from the backlog item: the channel that talks to the app while it
  /// runs, and the honest absence where there is none.
  ///
  /// [EstablishedState.absent] and [EstablishedState.unchecked] are different
  /// answers here and the difference is the point. Native Android has no live
  /// channel — that is Android, not our blind spot. React Native has Metro and
  /// the Hermes inspector and nobody here has run either.
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
