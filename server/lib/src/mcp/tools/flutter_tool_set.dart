import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import '../../flutter/attached_apps.dart';
import '../../flutter/checkout_project.dart';
import '../../flutter/flutter_loop.dart';
import '../../flutter/run_configurations.dart';
import 'flutter_tool_schemas.dart';
import 'server_tool_set.dart';

/// How many rows of a run come back with an answer.
const int kFlutterRunLogRows = 80;

/// `flutter_apps`, `flutter_attach`, `flutter_reload`, `flutter_logs`,
/// `flutter_pick_widget`, `flutter_run`, `flutter_run_configs` and
/// `flutter_run_config`, run by the
/// server (slice 3d): its hosted runs and the apps it is attached to. Nothing
/// is handed on.
class FlutterToolSet extends ServerToolSet {
  const FlutterToolSet({
    required this.apps,
    required this.loop,
    required this.rows,
    this.configurations,
  });

  final ServerAttachedApps apps;
  final ServerFlutterLoop loop;
  final CheckoutRows rows;

  /// The named run configurations; null on a server that keeps none.
  final FlutterRunConfigurations? configurations;

  @override
  List<Map<String, Object?>> get schemas => [
    ...flutterAppToolSchemas,
    ...flutterRunToolSchemas,
  ];

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(
    () => switch (tool) {
      'flutter_apps' => _list(),
      'flutter_attach' => _attach(arguments),
      'flutter_reload' => _reload(arguments),
      'flutter_logs' => _logs(arguments),
      'flutter_pick_widget' => _pick(arguments),
      'flutter_run' => _run(arguments, callerSessionId),
      'flutter_run_configs' => _listConfigs(arguments),
      'flutter_run_config' => _config(arguments),
      _ => throw ArgumentError('Unknown tool: $tool'),
    },
  );

  // --- flutter_apps & co -----------------------------------------------------

  Future<Object?> _list() async {
    await apps.look();
    final registry = apps.registry;
    return {
      'summary': describeRegistry(registry),
      'checkedAt': registry.lookedAt?.toIso8601String(),
      'discoveryDirectory': registry.discoveryDirectory,
      if (registry.discoveryFailure != null)
        'couldNotLook': registry.discoveryFailure,
      'apps': [for (final app in registry.apps) app.toJson()],
      if (registry.attached.isEmpty) 'howToMakeOneVisible': apps.attachHint,
    };
  }

  Future<Object?> _attach(Map<String, dynamic> args) async {
    final uri = (args['vmServiceUri'] as String?)?.trim() ?? '';
    if (uri.isEmpty) {
      throw ArgumentError(
        'vmServiceUri is required: the address "flutter run" printed, which '
        'looks like "http://127.0.0.1:53119/AbCdEf=/". ${apps.attachHint}',
      );
    }
    final app = await apps.attach(uri);
    return {
      'attached': app.toJson(),
      'summary': describeRegistry(apps.registry),
    };
  }

  static String? _id(Map<String, dynamic> args) {
    final id = (args['appId'] as String?)?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  Future<Object?> _reload(Map<String, dynamic> args) async {
    final fullRestart = args['fullRestart'] == true;
    final app = apps.requireApp(_id(args));
    if (fullRestart) {
      await apps.hotRestart(app.id);
    } else {
      await apps.hotReload(app.id);
    }
    // Only that the reload reached the VM; a failed rebuild is on the logs.
    return {
      'appId': app.id,
      'kind': fullRestart ? 'hotRestart' : 'hotReload',
      'accepted': true,
      'note': fullRestart
          ? 'main() ran again and the app lost the state it had. Any error the '
                'restart produced is on flutter_logs, not here.'
          : 'The sources were recompiled and reassembled. Any error the '
                'rebuild produced is on flutter_logs, not here.',
    };
  }

  Future<Object?> _logs(Map<String, dynamic> args) async {
    final limit = ((args['limit'] as num?)?.round() ?? 100).clamp(1, 1000);
    final onlyErrors = args['errorsOnly'] == true;
    final app = apps.requireApp(_id(args));
    final records = apps.console(
      app.id,
      limit: limit,
      sources: onlyErrors
          ? const {AppLogSource.stderr, AppLogSource.flutterError}
          : null,
    );
    if (records.isEmpty) {
      return _text(
        'The app has said nothing${onlyErrors ? ' on stderr and nothing has been thrown' : ''} '
        'since Karmashala attached to it '
        '(${app.label ?? app.id}). That is not the same as it having said '
        'nothing at all: only what arrived after the attach, plus whatever the '
        'VM service still had buffered, is here.',
      );
    }
    return _text(
      [
        'Debug console for ${app.label ?? app.id}, oldest first. Lines marked '
            '"before attach" were replayed out of the VM service buffer and '
            'are history, not now.',
        '',
        for (final record in records) _renderLine(record),
      ].join('\n'),
    );
  }

  static String _renderLine(AppLogRecord record) {
    final origin = switch (record.source) {
      AppLogSource.stdout => 'out',
      AppLogSource.stderr => 'err',
      AppLogSource.developerLog =>
        record.loggerName?.isNotEmpty == true
            ? 'log ${record.loggerName}'
            : 'log',
      AppLogSource.flutterError => 'ERROR',
      AppLogSource.lifecycle => '--',
    };
    final age = record.beforeAttach ? ' (before attach)' : '';
    final detail = record.detail == null
        ? ''
        : '\n${record.detail!.split('\n').map((line) => '    $line').join('\n')}';
    return '[$origin]$age ${record.message}$detail';
  }

  Future<Object?> _pick(Map<String, dynamic> args) async {
    final seconds = ((args['timeoutSeconds'] as num?)?.round() ?? 120).clamp(
      1,
      600,
    );
    final app = apps.requireApp(_id(args));
    final selection = await apps.pickWidget(
      app.id,
      timeout: Duration(seconds: seconds),
    );
    final locations = app.widgetLocations;
    return _text(
      [
        'The developer pointed at this widget in the running app. Flutter '
            'hit-tested the tap and chose the nearest widget written in this '
            'project.',
        selection.toPromptText(),
        if (locations == WidgetLocationSupport.absent)
          'This build was compiled without --track-widget-creation, so no '
              'widget in it carries a source location. Run it in debug mode to '
              'get one.',
        if (locations == WidgetLocationSupport.unknown)
          'Whether this build carries widget locations could not be '
              'established, so the absence of a line below is not evidence '
              'either way.',
        '',
        [
          for (final entry in selection.toJson().entries)
            '${entry.key}: ${entry.value is Map ? (entry.value! as Map).entries.map((e) => '${e.key}=${e.value}').join(', ') : entry.value}',
        ].join('\n'),
      ].join('\n'),
    );
  }

  /// Prose, as a content block: a console tail JSON-encoded into one string
  /// is unreadable and costs several times the tokens.
  static Map<String, Object?> _text(String body) => {
    '_mcpContent': [
      {'type': 'text', 'text': body},
    ],
  };

  // --- flutter_run -------------------------------------------------------------

  Future<Object?> _run(Map<String, dynamic> args, String? caller) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final configured = (args['configuration'] as String?)?.trim() ?? '';
    if (configured.isNotEmpty && action != 'run') {
      throw ArgumentError(
        'configuration applies to action "run" only; $action takes its flags '
        'in arguments.',
      );
    }
    return switch (action) {
      'run' => _launch(args, caller),
      'stop' => _stop(args),
      'status' => _status(args),
      'pubGet' => _start(args, FlutterCommandKind.pubGet, caller),
      'analyze' => _start(args, FlutterCommandKind.analyze, caller),
      'test' => _start(args, FlutterCommandKind.test, caller),
      '' => throw ArgumentError(
        'action is required: run, stop, status, pubGet, analyze or test.',
      ),
      _ => throw ArgumentError(
        'Unknown action "$action". Use run, stop, status, pubGet, analyze or '
        'test.',
      ),
    };
  }

  Future<Object?> _launch(Map<String, dynamic> args, String? caller) async {
    final resolved = resolveConfiguredRun(
      rows: rows,
      configurations: configurations,
      checkoutId: (args['checkoutId'] as String?)?.trim() ?? '',
      configuration: args['configuration'] as String?,
      projectDirectory: args['projectDirectory'] as String?,
      deviceId: args['deviceId'] as String?,
      explicit: _arguments(args),
    );
    final device = resolved.deviceId ?? '';
    if (device.isEmpty) {
      throw ArgumentError(
        'deviceId is required for action "run" — the id "flutter devices" '
        'prints, which is an adb serial for a phone and a word like "windows", '
        '"macos" or "chrome" for the others. list_devices has the attached '
        'ones${resolved.configuration == null ? '' : '; configuration '
                  '"${resolved.configuration!.name}" names no default device'}.',
      );
    }
    final outcome = await loop.run(
      project: resolved.project,
      deviceId: device,
      sessionId: caller,
      extraArguments: resolved.arguments,
    );
    return {
      ..._answer(outcome.preflight, outcome.run),
      if (resolved.configuration case final configuration?)
        'configuration': configuration.name,
    };
  }

  // --- flutter_run_configs & flutter_run_config -------------------------------

  /// The store and the project [args]' checkout belongs to.
  (FlutterRunConfigurations, String) _projectConfigs(
    Map<String, dynamic> args,
  ) {
    final store =
        configurations ??
        (throw StateError('This server keeps no run configurations.'));
    final checkoutId = (args['checkoutId'] as String?)?.trim() ?? '';
    // Validated through the one path that words the refusal.
    projectOfCheckout(rows, {'checkoutId': checkoutId});
    return (store, rows.repository(checkoutId)!.projectId);
  }

  Future<Object?> _listConfigs(Map<String, dynamic> args) async {
    final (store, projectId) = _projectConfigs(args);
    final all = store.list(projectId: projectId);
    return {
      'projectId': projectId,
      'configurations': [
        for (final configuration in all)
          {...configuration.toJson(), 'flags': configuration.runArguments()},
      ],
      if (all.isEmpty)
        'summary':
            'This project has no run configurations. flutter_run_config '
            'action "save" creates one.',
    };
  }

  Future<Object?> _config(Map<String, dynamic> args) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    if (action == 'list') {
      throw ArgumentError(
        'Listing is flutter_run_configs, which needs no operator grant.',
      );
    }
    final (store, projectId) = _projectConfigs(args);
    String name() {
      final value = (args['name'] as String?)?.trim() ?? '';
      if (value.isEmpty) throw ArgumentError('name is required for $action.');
      return value;
    }

    switch (action) {
      case 'save':
        List<String> strings(String key) => [
          for (final value in (args[key] as List<Object?>? ?? const []))
            if (value != null && '$value'.trim().isNotEmpty) '$value'.trim(),
        ];
        String? text(String key) {
          final value = (args[key] as String?)?.trim();
          return value == null || value.isEmpty ? null : value;
        }

        final existing = store.named(projectId, name());
        final mode = text('buildMode');
        final saved = store.save(
          FlutterRunConfiguration(
            id: existing?.id ?? '',
            projectId: projectId,
            name: name(),
            projectDirectory: text('projectDirectory'),
            target: text('target'),
            flavor: text('flavor'),
            buildMode: mode == null
                ? FlutterBuildMode.debug
                : FlutterBuildMode.fromName(mode) ??
                      (throw ArgumentError(
                        'buildMode is debug, profile or release.',
                      )),
            dartDefines: strings('dartDefines'),
            dartDefineFiles: strings('dartDefineFiles'),
            deviceId: text('deviceId'),
          ),
        );
        return {
          'saved': saved.toJson(),
          'flags': saved.runArguments(),
          'summary': existing == null
              ? 'Saved "${saved.name}". Run it with flutter_run action "run" '
                    'and configuration "${saved.name}".'
              : 'Replaced "${saved.name}" with exactly these fields.',
        };
      case 'delete':
        final existing =
            store.named(projectId, name()) ??
            (throw StateError(
              'No run configuration "${name()}" in this project.',
            ));
        store.delete(existing.id);
        return {'deleted': existing.name};
      default:
        throw ArgumentError('action is save or delete.');
    }
  }

  Future<Object?> _start(
    Map<String, dynamic> args,
    FlutterCommandKind kind,
    String? caller,
  ) async {
    final project = projectOfCheckout(rows, args);
    final outcome = kind == FlutterCommandKind.pubGet
        ? await loop.pubGet(project)
        : await loop.gate(
            project,
            kind,
            extraArguments: _arguments(args),
            sessionId: caller,
          );
    return _answer(outcome.preflight, outcome.run);
  }

  Future<Object?> _stop(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim();
    final named = paneId != null && paneId.isNotEmpty;
    final run = named ? loop.byPane(paneId) : _onlyLiveRun();
    if (run == null) {
      return {
        'stopped': false,
        'preflight': const FlutterPreflight.clear().toJson(),
        'summary': named
            ? 'No run in session $paneId. "status" lists the ones this server '
                  'knows about.'
            : 'Nothing Karmashala started is still running, so there was '
                  'nothing to stop.',
      };
    }
    final stopped = await loop.stop(run.paneId);
    return {
      'stopped': true,
      'run': _describe(stopped ?? run, includeLog: false),
      'summary':
          'Ended flutter ${run.kind.label} in session ${run.paneId}. The '
          'process was stopped rather than detached, so nothing is left '
          'running on the device.',
    };
  }

  Future<Object?> _status(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim();
    if (paneId != null && paneId.isNotEmpty) {
      // Reads the address file again and attaches if it now can — only
      // because somebody asked.
      final run = await loop.refresh(paneId);
      if (run == null) {
        return {
          'runs': const <Object?>[],
          'summary':
              'No run in session $paneId. "status" with no paneId lists what '
              'this server started.',
        };
      }
      return {'run': _describe(run, includeLog: true), 'attachedApps': _apps()};
    }
    if (loop.runs.isEmpty) {
      return {
        'runs': const <Object?>[],
        'summary':
            'Karmashala has not started anything for a Flutter project on this '
            'server. Nothing is claimed about runs somebody started by hand — '
            'flutter_apps is where those appear.',
      };
    }
    for (final run in loop.runs) {
      if (run.kind == FlutterCommandKind.run && run.vmServiceUri == null) {
        await loop.refresh(run.paneId);
      }
    }
    return {
      'runs': [for (final run in loop.runs) _describe(run, includeLog: false)],
      'attachedApps': _apps(),
    };
  }

  Map<String, Object?> _answer(
    FlutterPreflight preflight,
    FlutterCommandRun? run,
  ) => {
    'preflight': preflight.toJson(),
    if (run != null) 'run': _describe(run, includeLog: false),
    if (run != null)
      'summary':
          'flutter ${run.kind.label} is running on the Karmashala server in '
          'session ${run.paneId}, which every Karmashala window shows. Nothing '
          'waits for it: ask again with action "status" and paneId '
          '"${run.paneId}".',
  };

  /// One run, and its log only when the log is worth reading.
  Map<String, Object?> _describe(
    FlutterCommandRun run, {
    required bool includeLog,
  }) {
    final liveness = loop.livenessOf(run.paneId);
    final failed = run.exitCode != null && run.exitCode != 0;
    final unknownEnd =
        liveness != FlutterRunLiveness.running && run.exitCode == null;
    final worthReading =
        liveness == FlutterRunLiveness.running || failed || unknownEnd;
    final log = includeLog && worthReading
        ? loop.tailOf(run.paneId, lines: kFlutterRunLogRows)
        : const <String>[];
    return {
      ...run.toJson(),
      'liveness': liveness.name,
      if (liveness == FlutterRunLiveness.unknown)
        'livenessNote':
            'The server no longer holds the session for this run, so whether '
            'the process is still going is unknown rather than no.',
      if (log.isNotEmpty) 'log': log,
      if (includeLog && !worthReading)
        'logNote':
            'Omitted: this finished cleanly. The log is returned when '
            'something failed or is still going.',
      if (includeLog && worthReading && log.isEmpty)
        'logNote': 'The session is gone, so there is nothing left to read.',
    };
  }

  Map<String, Object?> _apps() {
    final registry = apps.registry;
    return {
      'summary': describeRegistry(registry),
      'ids': [for (final app in registry.attached) app.id],
    };
  }

  static List<String> _arguments(Map<String, dynamic> args) => [
    for (final value in (args['arguments'] as List<Object?>? ?? const []))
      if (value != null) '$value',
  ];

  /// The one live run; null for none and for two — stopping the wrong app is
  /// worse than being asked which.
  FlutterCommandRun? _onlyLiveRun() {
    final live = [
      for (final run in loop.runs)
        if (loop.livenessOf(run.paneId) == FlutterRunLiveness.running) run,
    ];
    return live.length == 1 ? live.single : null;
  }
}
