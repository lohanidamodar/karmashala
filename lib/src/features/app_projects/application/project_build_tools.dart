import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/project_build.dart';
import '../domain/project_descriptor.dart';
import 'project_build_loop.dart';

/// The `project_build` tool: what a checkout **is**, and the artifact its own
/// toolchain builds.
///
/// **One tool, and not a second device path.** Install and launch already have
/// framework-agnostic tools — `device_install_app` takes a path,
/// `device_launch_app` takes an application id — so this stops at producing
/// exactly those two strings and names them in the answer. Building a second
/// route onto the phone from here is the duplication the backlog item refuses.
///
/// **Not folded into `flutter_run`.** That tool is a Flutter lifecycle down to
/// its action names — `pubGet`, `run` with a `deviceId`, `analyze`, `test` —
/// and every sentence in its schema is about the VM service. A native Android
/// project has none of that, and adding a `build` action there would put a
/// Gradle refusal behind a name that promises Flutter. The two are separate
/// because the loops are.
class ProjectBuildTools {
  ProjectBuildTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{'project_build'};

  static bool handles(String name) => _names.contains(name);

  ProjectBuildController get _builds =>
      _container.read(projectBuildProvider.notifier);

  Future<Object?> call(String name, Map<String, dynamic> args) async {
    if (name != 'project_build') throw ArgumentError('Unknown tool: $name');
    final action = (args['action'] as String?)?.trim() ?? '';
    return switch (action) {
      'detect' => _detect(args),
      'build' => _build(args),
      'status' => _status(args),
      'stop' => _stop(args),
      '' => throw ArgumentError(
        'action is required: detect, build, status or stop.',
      ),
      _ => throw ArgumentError(
        'Unknown action "$action". Use detect, build, status or stop.',
      ),
    };
  }

  // --- Actions ---------------------------------------------------------------

  Future<Object?> _detect(Map<String, dynamic> args) async {
    final project = _project(args);
    final scanned = await _builds.scan(project);
    final reading = scanned.project;
    if (reading == null) {
      return <String, Object?>{
        'detected': false,
        'directory': project.path,
        'summary':
            scanned.note ??
            '${project.path} carries no marker Karmashala knows: no '
                'pubspec.yaml with a flutter: section, no package.json naming '
                'react-native, no settings.gradle including a '
                'com.android.application module, and no .xcodeproj. Nothing '
                'was guessed at.',
      };
    }
    return <String, Object?>{
      'detected': true,
      'directory': project.path,
      ...reading.toJson(),
    };
  }

  Future<Object?> _build(Map<String, dynamic> args) async {
    final project = _project(args);
    final target = _target(args);
    final outcome = await _builds.start(
      project,
      target,
      extraArguments: _arguments(args),
    );
    final run = outcome.run;
    return <String, Object?>{
      'preflight': outcome.preflight.toJson(),
      if (run != null) 'run': run.toJson(),
      if (run != null)
        'summary':
            '${run.command.join(' ')} is running in pane ${run.paneId}, where '
            'the developer can see it. Nothing waits for it: ask again with '
            'action "status" and paneId "${run.paneId}", and the artifact and '
            'application id come back when it has produced them.',
    };
  }

  Future<Object?> _status(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim();
    final runs = paneId == null || paneId.isEmpty
        ? _builds.runs
        : <ProjectBuildRun>[
            if (_builds.byPane(paneId) != null) _builds.byPane(paneId)!,
          ];
    if (runs.isEmpty) {
      return <String, Object?>{
        'runs': const <Object?>[],
        'summary': paneId == null || paneId.isEmpty
            ? 'Karmashala has not built anything in this session. Nothing is '
                  'claimed about builds somebody ran by hand.'
            : 'No build in pane $paneId. "status" with no paneId lists what '
                  'this app started.',
      };
    }
    return <String, Object?>{
      'runs': <Object?>[for (final run in runs) await _describe(run)],
    };
  }

  Future<Object?> _stop(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim() ?? '';
    if (paneId.isEmpty) {
      throw ArgumentError(
        'paneId is required for "stop" — a build is identified by the pane it '
        'runs in, and "status" lists them.',
      );
    }
    final stopped = await _builds.stop(paneId);
    if (stopped == null) {
      return <String, Object?>{
        'stopped': false,
        'summary':
            'No build in pane $paneId. Its id may be from a previous launch of '
            'the app; "status" lists the ones this app knows about.',
      };
    }
    return <String, Object?>{
      'stopped': true,
      'run': stopped.toJson(),
      'summary':
          'Ended the build in pane $paneId. The process was stopped rather '
          'than detached, so no Gradle daemon is left writing into build/.',
    };
  }

  // --- Shaping ---------------------------------------------------------------

  /// One build, its log only when the log is worth reading, and the artifact
  /// only once there is one.
  Future<Map<String, Object?>> _describe(ProjectBuildRun run) async {
    final liveness = _builds.livenessOf(run.paneId);
    final failed = run.exitCode != null && run.exitCode != 0;
    final unknownEnd =
        liveness != ProjectBuildLiveness.running && run.exitCode == null;
    final worthReading =
        liveness == ProjectBuildLiveness.running || failed || unknownEnd;
    final log = worthReading
        ? _builds.tailOf(run.paneId, lines: kProjectBuildLogRows)
        : const <String>[];
    final artifact = await _builds.artifactOf(run);
    return <String, Object?>{
      ...run.toJson(),
      'liveness': liveness.name,
      if (liveness == ProjectBuildLiveness.unknown)
        'livenessNote':
            'Karmashala no longer has the pane for this build — it was '
            'closed, or the app was restarted — so whether the process is '
            'still going is unknown rather than no.',
      'artifact': <String, Object?>{
        if (artifact.path != null) 'path': artifact.path,
        if (artifact.applicationId != null)
          'applicationId': artifact.applicationId,
        'note': artifact.note,
      },
      if (artifact.path != null)
        'nextStep':
            'device_install_app with path "${artifact.path}"'
            '${artifact.applicationId == null ? '' : ', then device_launch_app '
                'with appId "${artifact.applicationId}"'}. Those are the '
            'existing device tools; there is no install or launch in this one.',
      if (log.isNotEmpty) 'log': log,
      if (!worthReading && log.isEmpty)
        'logNote':
            'Omitted: this finished cleanly. The log comes back when '
            'something failed or is still going.',
    };
  }

  // --- Arguments -------------------------------------------------------------

  List<String> _arguments(Map<String, dynamic> args) => <String>[
    for (final value in (args['arguments'] as List<Object?>? ?? const []))
      if (value != null) '$value',
  ];

  ProjectTarget _target(Map<String, dynamic> args) {
    final value = (args['target'] as String?)?.trim() ?? 'android';
    for (final target in ProjectTarget.values) {
      if (target.name == value) return target;
    }
    throw ArgumentError(
      'Unknown target "$value". Use '
      '${ProjectTarget.values.map((t) => t.name).join(' or ')}.',
    );
  }

  /// The project directory, from a checkout id and an optional sub-path.
  ///
  /// A checkout id rather than a path, the way `flutter_run` takes one: the id
  /// is what carries the environment, and a bare path would have to be guessed
  /// into one — which is the guess CLAUDE.md §17 is about.
  EnvironmentPath _project(Map<String, dynamic> args) {
    final id = (args['checkoutId'] as String?)?.trim() ?? '';
    if (id.isEmpty) {
      throw ArgumentError(
        'checkoutId is required. list_checkouts has the ids, and the id is '
        'what says which environment the commands run in.',
      );
    }
    final repository = _container.read(repositoryDaoProvider).getById(id);
    if (repository == null) {
      throw StateError('No checkout with id $id. list_checkouts has them.');
    }
    final relative = (args['projectDirectory'] as String?)?.trim() ?? '';
    if (relative.isEmpty) return repository.path;

    final environment = _container
        .read(executionEnvironmentDaoProvider)
        .getById(repository.path.environmentId);
    final context = environment != null && usesWindowsPaths(environment.kind)
        ? p.windows
        : p.posix;
    if (context.isAbsolute(relative)) {
      throw ArgumentError(
        'projectDirectory is relative to the checkout — "app" or "android", '
        'not an absolute path.',
      );
    }
    return repository.path.copyWith(
      path: context.joinAll([repository.path.path, ...relative.split('/')]),
    );
  }
}

/// The `project_build` schema, served alongside the rest.
const List<Map<String, dynamic>> projectBuildToolSchemas =
    <Map<String, dynamic>>[
      {
        'name': 'project_build',
        'description':
            'WHAT A CHECKOUT IS, AND THE ARTIFACT ITS TOOLCHAIN BUILDS. '
            '"detect" names the kind — Flutter, native Android, native iOS, '
            'React Native — with the files that said so and what Karmashala '
            'can do with it; a kind it can only spot says exactly that. '
            '"build" runs that kind\'s own build in a VISIBLE PANE in the '
            'checkout\'s own environment (flutter build apk for Flutter, the '
            'project\'s own gradlew for native Android — never a gradle on '
            'PATH) and does not wait. "status" carries the ARTIFACT PATH and '
            'the APPLICATION ID once the build has written them, read out of '
            'the build\'s own output-metadata.json. IT DOES NOT INSTALL OR '
            'LAUNCH: hand those two strings to device_install_app and '
            'device_launch_app, which is the whole device surface already. '
            'iOS and React Native are DETECTED ONLY and refuse to build, in '
            'one sentence naming why.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['detect', 'build', 'status', 'stop'],
              'description':
                  'What to do. "status" with no paneId lists everything this '
                  'app built.',
            },
            'checkoutId': {
              'type': 'string',
              'description':
                  'From list_checkouts. Required for detect and build — it is '
                  'what says which environment the commands run in, which a '
                  'bare path cannot.',
            },
            'projectDirectory': {
              'type': 'string',
              'description':
                  'A sub-project inside the checkout, relative — "android" or '
                  '"packages/mobile". Omit for a checkout that is itself the '
                  'project.',
            },
            'target': {
              'type': 'string',
              'enum': ['android', 'ios'],
              'description': 'Which device family to build for. Android by '
                  'default; iOS refuses and says why.',
            },
            'paneId': {
              'type': 'string',
              'description':
                  'Which build to ask about or stop. From a previous answer.',
            },
            'arguments': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Extra flags after the ones Karmashala spells — '
                  '"--offline", "--stacktrace".',
            },
          },
          'required': ['action'],
        },
      },
    ];
