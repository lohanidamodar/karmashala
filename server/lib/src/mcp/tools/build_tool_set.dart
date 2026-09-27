import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_flutter_apps/projects.dart';

import '../../flutter/checkout_project.dart';
import '../../flutter/project_builds.dart';
import 'build_tool_schemas.dart';
import 'server_tool_set.dart';

/// `project_build`, run by the server (slice 3d): what a checkout is, and the
/// artifact its toolchain builds, as a hosted run every window shows. It stops
/// at the two strings the `device_*` tools take.
class BuildToolSet extends ServerToolSet {
  const BuildToolSet({required this.builds, required this.rows});

  final ServerProjectBuilds builds;
  final CheckoutRows rows;

  @override
  List<Map<String, Object?>> get schemas => projectBuildToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() {
    if (tool != 'project_build') throw ArgumentError('Unknown tool: $tool');
    final action = (arguments['action'] as String?)?.trim() ?? '';
    return switch (action) {
      'detect' => _detect(arguments),
      'build' => _build(arguments),
      'status' => _status(arguments),
      'stop' => _stop(arguments),
      '' => throw ArgumentError(
        'action is required: detect, build, status or stop.',
      ),
      _ => throw ArgumentError(
        'Unknown action "$action". Use detect, build, status or stop.',
      ),
    };
  });

  EnvironmentPath _project(Map<String, dynamic> args) =>
      projectOfCheckout(rows, args, example: '"app" or "android"');

  Future<Object?> _detect(Map<String, dynamic> args) async {
    final project = _project(args);
    final scanned = await builds.scan(project);
    final reading = scanned.project;
    if (reading == null) {
      return {
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
    return {'detected': true, 'directory': project.path, ...reading.toJson()};
  }

  Future<Object?> _build(Map<String, dynamic> args) async {
    final project = _project(args);
    final outcome = await builds.start(
      project,
      _target(args),
      extraArguments: [
        for (final value in (args['arguments'] as List<Object?>? ?? const []))
          if (value != null) '$value',
      ],
    );
    final run = outcome.run;
    return {
      'preflight': outcome.preflight.toJson(),
      if (run != null) 'run': run.toJson(),
      if (run != null)
        'summary':
            '${run.command.join(' ')} is running on the Karmashala server in '
            'session ${run.paneId}, which every Karmashala window shows. '
            'Nothing waits for it: ask again with action "status" and paneId '
            '"${run.paneId}", and the artifact and application id come back '
            'when it has produced them.',
    };
  }

  Future<Object?> _status(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim();
    final named = paneId != null && paneId.isNotEmpty;
    final runs = named ? [?builds.byPane(paneId)] : builds.runs;
    if (runs.isEmpty) {
      return {
        'runs': const <Object?>[],
        'summary': named
            ? 'No build in session $paneId. "status" with no paneId lists '
                  'what this server started.'
            : 'Karmashala has not built anything on this server. Nothing is '
                  'claimed about builds somebody ran by hand.',
      };
    }
    return {
      'runs': [for (final run in runs) await _describe(run)],
    };
  }

  Future<Object?> _stop(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim() ?? '';
    if (paneId.isEmpty) {
      throw ArgumentError(
        'paneId is required for "stop" — a build is identified by the '
        'session it runs in, and "status" lists them.',
      );
    }
    final stopped = await builds.stop(paneId);
    if (stopped == null) {
      return {
        'stopped': false,
        'summary':
            'No build in session $paneId. "status" lists the ones this server '
            'knows about.',
      };
    }
    return {
      'stopped': true,
      'run': stopped.toJson(),
      'summary':
          'Ended the build in session $paneId. The process was stopped rather '
          'than detached, so no Gradle daemon is left writing into build/.',
    };
  }

  Future<Map<String, Object?>> _describe(ProjectBuildRun run) async {
    final liveness = builds.livenessOf(run.paneId);
    final failed = run.exitCode != null && run.exitCode != 0;
    final unknownEnd =
        liveness != ProjectBuildLiveness.running && run.exitCode == null;
    final worthReading =
        liveness == ProjectBuildLiveness.running || failed || unknownEnd;
    final log = worthReading
        ? builds.tailOf(run.paneId, lines: kProjectBuildLogRows)
        : const <String>[];
    final artifact = await builds.artifactOf(run);
    return {
      ...run.toJson(),
      'liveness': liveness.name,
      if (liveness == ProjectBuildLiveness.unknown)
        'livenessNote':
            'The server no longer holds the session for this build, so '
            'whether the process is still going is unknown rather than no.',
      'artifact': {
        'path': ?artifact.path,
        'applicationId': ?artifact.applicationId,
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

  static ProjectTarget _target(Map<String, dynamic> args) {
    final value = (args['target'] as String?)?.trim() ?? 'android';
    for (final target in ProjectTarget.values) {
      if (target.name == value) return target;
    }
    throw ArgumentError(
      'Unknown target "$value". Use '
      '${ProjectTarget.values.map((t) => t.name).join(' or ')}.',
    );
  }
}
