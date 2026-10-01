/// `flutter run`'s build mode. Debug is the only one that hot reloads.
enum FlutterBuildMode {
  debug,
  profile,
  release;

  static FlutterBuildMode? fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// A refusal of a configuration as written: the sentence says what to fix.
class FlutterRunConfigurationInvalid implements Exception {
  const FlutterRunConfigurationInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A named way to launch one project — flavor, entrypoint, defines, build
/// mode and a default device — kept per project so every worktree shares it.
class FlutterRunConfiguration {
  const FlutterRunConfiguration({
    required this.id,
    required this.projectId,
    required this.name,
    this.projectDirectory,
    this.target,
    this.flavor,
    this.buildMode = FlutterBuildMode.debug,
    this.dartDefines = const [],
    this.dartDefineFiles = const [],
    this.deviceId,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String projectId;
  final String name;

  /// The sub-project inside a checkout, relative ("app"); null for the root.
  final String? projectDirectory;

  /// The entrypoint, relative to the project: `lib/main_dev.dart`.
  final String? target;
  final String? flavor;
  final FlutterBuildMode buildMode;

  /// `KEY=VALUE` pairs, each one `--dart-define`.
  final List<String> dartDefines;

  /// Paths, relative to the project, each one `--dart-define-from-file`.
  final List<String> dartDefineFiles;

  /// What to run on when the caller names no device.
  final String? deviceId;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  static const int nameLimit = 60;

  /// Throws [FlutterRunConfigurationInvalid] for anything flutter would
  /// reject or that would read as two flags.
  void validate() {
    if (projectId.trim().isEmpty) {
      throw const FlutterRunConfigurationInvalid(
        'A run configuration belongs to a project; none was named.',
      );
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > nameLimit) {
      throw const FlutterRunConfigurationInvalid(
        'A run configuration needs a name of 1–$nameLimit characters.',
      );
    }
    for (final define in dartDefines) {
      final cut = define.indexOf('=');
      if (cut <= 0) {
        throw FlutterRunConfigurationInvalid(
          '"$define" is not a dart-define: write KEY=VALUE.',
        );
      }
    }
    for (final (label, value) in [
      ('flavor', flavor),
      ('target', target),
      ('deviceId', deviceId),
      ('projectDirectory', projectDirectory),
      for (final file in dartDefineFiles) ('dart-define file', file),
    ]) {
      if (value == null) continue;
      if (value.trim().isEmpty || value.trim().startsWith('-')) {
        throw FlutterRunConfigurationInvalid(
          '$label "$value" is empty or starts with "-", which flutter would '
          'read as a flag.',
        );
      }
    }
  }

  /// The `flutter run` flags this configuration spells, with [explicit]
  /// appended. An explicit build mode, flavor or target replaces this one's
  /// rather than reaching flutter twice; defines from both are kept.
  List<String> runArguments({List<String> explicit = const []}) {
    bool given(List<String> flags) => explicit.any(
      (arg) =>
          flags.contains(arg) || flags.any((flag) => arg.startsWith('$flag=')),
    );
    final explicitMode = given(const [
      '--debug',
      '--profile',
      '--release',
      '--jit-release',
    ]);
    return [
      if (!explicitMode && buildMode != FlutterBuildMode.debug)
        '--${buildMode.name}',
      if (flavor case final flavor? when !given(const ['--flavor'])) ...[
        '--flavor',
        flavor,
      ],
      if (target case final target? when !given(const ['-t', '--target'])) ...[
        '--target',
        target,
      ],
      for (final define in dartDefines) '--dart-define=$define',
      for (final file in dartDefineFiles) '--dart-define-from-file=$file',
      ...explicit,
    ];
  }

  FlutterRunConfiguration copyWith({
    String? id,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => FlutterRunConfiguration(
    id: id ?? this.id,
    projectId: projectId,
    name: name,
    projectDirectory: projectDirectory,
    target: target,
    flavor: flavor,
    buildMode: buildMode,
    dartDefines: dartDefines,
    dartDefineFiles: dartDefineFiles,
    deviceId: deviceId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'projectId': projectId,
    'name': name,
    'projectDirectory': ?projectDirectory,
    'target': ?target,
    'flavor': ?flavor,
    'buildMode': buildMode.name,
    'dartDefines': dartDefines,
    'dartDefineFiles': dartDefineFiles,
    'deviceId': ?deviceId,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  static FlutterRunConfiguration fromJson(Map<String, Object?> json) {
    String? text(String key) {
      final value = (json[key] as String?)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    List<String> list(String key) => [
      for (final value in (json[key] as List<Object?>? ?? const []))
        if (value is String && value.trim().isNotEmpty) value.trim(),
    ];

    return FlutterRunConfiguration(
      id: json['id'] as String? ?? '',
      projectId: json['projectId'] as String? ?? '',
      name: (json['name'] as String? ?? '').trim(),
      projectDirectory: text('projectDirectory'),
      target: text('target'),
      flavor: text('flavor'),
      buildMode:
          FlutterBuildMode.fromName(json['buildMode']) ??
          FlutterBuildMode.debug,
      dartDefines: list('dartDefines'),
      dartDefineFiles: list('dartDefineFiles'),
      deviceId: text('deviceId'),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }

  /// One line naming what the configuration changes.
  String describe() {
    final parts = [
      buildMode.name,
      if (flavor != null) 'flavor $flavor',
      ?target,
      if (dartDefines.isNotEmpty) '${dartDefines.length} define(s)',
      if (dartDefineFiles.isNotEmpty) dartDefineFiles.join(', '),
      if (deviceId != null) 'on $deviceId',
      if (projectDirectory != null) 'in $projectDirectory',
    ];
    return parts.join(' · ');
  }
}
