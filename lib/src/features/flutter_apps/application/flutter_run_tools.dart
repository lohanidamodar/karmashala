import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'attached_apps.dart';
import 'flutter_loop.dart';

/// How many rows of a pane come back with an answer — enough for a Gradle
/// failure, small enough that a healthy status call is a few hundred tokens.
const int kFlutterRunLogRows = 80;

/// The `flutter_run` tool: one lifecycle for a Flutter project, one tool rather
/// than six because they share a preflight and a set of refusals.
class FlutterRunTools {
  FlutterRunTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling. It is what the device claim is taken in the
  /// name of, so a refusal can say who is holding the phone.
  final String? callerSessionId;

  static const Set<String> _names = <String>{'flutter_run'};

  static bool handles(String name) => _names.contains(name);

  FlutterLoopController get _loop =>
      _container.read(flutterLoopProvider.notifier);

  Future<Object?> call(String name, Map<String, dynamic> args) async {
    if (name != 'flutter_run') throw ArgumentError('Unknown tool: $name');
    final action = (args['action'] as String?)?.trim() ?? '';
    return switch (action) {
      'run' => _run(args),
      'stop' => _stop(args),
      'status' => _status(args),
      'pubGet' => _start(args, FlutterCommandKind.pubGet),
      'analyze' => _start(args, FlutterCommandKind.analyze),
      'test' => _start(args, FlutterCommandKind.test),
      '' => throw ArgumentError(
        'action is required: run, stop, status, pubGet, analyze or test.',
      ),
      _ => throw ArgumentError(
        'Unknown action "$action". Use run, stop, status, pubGet, analyze or '
        'test.',
      ),
    };
  }

  // --- Actions ---------------------------------------------------------------

  Future<Object?> _run(Map<String, dynamic> args) async {
    final project = _project(args);
    final device = (args['deviceId'] as String?)?.trim() ?? '';
    if (device.isEmpty) {
      throw ArgumentError(
        'deviceId is required for action "run" — the id "flutter devices" '
        'prints, which is an adb serial for a phone and a word like "windows", '
        '"macos" or "chrome" for the others. list_devices has the attached '
        'ones.',
      );
    }
    final outcome = await _loop.run(
      project: project,
      deviceId: device,
      sessionId: callerSessionId,
      extraArguments: _arguments(args),
    );
    return _answer(outcome.preflight, outcome.run);
  }

  Future<Object?> _start(
    Map<String, dynamic> args,
    FlutterCommandKind kind,
  ) async {
    final project = _project(args);
    final outcome = kind == FlutterCommandKind.pubGet
        ? await _loop.pubGet(project)
        : await _loop.gate(project, kind, extraArguments: _arguments(args));
    return _answer(outcome.preflight, outcome.run);
  }

  Future<Object?> _stop(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim();
    final run = paneId == null || paneId.isEmpty
        ? _onlyLiveRun()
        : _loop.byPane(paneId);
    if (run == null) {
      return <String, Object?>{
        'stopped': false,
        'preflight': const FlutterPreflight.clear().toJson(),
        'summary': paneId == null || paneId.isEmpty
            ? 'Nothing Karmashala started is still running, so there was '
                  'nothing to stop.'
            : 'No run in pane $paneId. Its id may be from a previous launch of '
                  'the app; "status" lists the ones this app knows about.',
      };
    }
    final stopped = await _loop.stop(run.paneId);
    return <String, Object?>{
      'stopped': true,
      'run': _describe(stopped ?? run, includeLog: false, endedByUs: true),
      'summary':
          'Ended flutter ${run.kind.label} in pane ${run.paneId}. The process '
          'was stopped rather than detached, so nothing is left running on the '
          'device.',
    };
  }

  Future<Object?> _status(Map<String, dynamic> args) async {
    final paneId = (args['paneId'] as String?)?.trim();
    if (paneId != null && paneId.isNotEmpty) {
      // Re-reads the address file and attaches if it now can — the one place
      // that is done, and only because somebody asked.
      final run = await _loop.refresh(paneId);
      if (run == null) {
        return <String, Object?>{
          'runs': const <Object?>[],
          'summary':
              'No run in pane $paneId. "status" with no paneId lists what this '
              'app started.',
        };
      }
      return <String, Object?>{
        'run': _describe(run, includeLog: true),
        'attachedApps': _appsSummary(),
      };
    }
    final runs = _loop.runs;
    if (runs.isEmpty) {
      return <String, Object?>{
        'runs': const <Object?>[],
        'summary':
            'Karmashala has not started anything for a Flutter project in this '
            'session. Nothing is claimed about runs somebody started by hand — '
            'flutter_apps is where those appear.',
      };
    }
    // Refreshed, so a run whose app is up but was never asked about attaches
    // here rather than reporting as "not attached yet" forever.
    for (final run in runs.toList(growable: false)) {
      if (run.kind == FlutterCommandKind.run && run.vmServiceUri == null) {
        await _loop.refresh(run.paneId);
      }
    }
    return <String, Object?>{
      'runs': <Object?>[
        for (final run in _loop.runs) _describe(run, includeLog: false),
      ],
      'attachedApps': _appsSummary(),
    };
  }

  // --- Shaping ---------------------------------------------------------------

  Map<String, Object?> _answer(
    FlutterPreflight preflight,
    FlutterCommandRun? run,
  ) => <String, Object?>{
    'preflight': preflight.toJson(),
    if (run != null) 'run': _describe(run, includeLog: false),
    if (run != null)
      'summary':
          'flutter ${run.kind.label} is running in pane ${run.paneId}, where '
          'the developer can see it. Nothing waits for it: ask again with '
          'action "status" and paneId "${run.paneId}".',
  };

  /// One run, and its log only when the log is worth reading. [endedByUs] is
  /// the one case where an absent pane is not a blind spot.
  Map<String, Object?> _describe(
    FlutterCommandRun run, {
    required bool includeLog,
    bool endedByUs = false,
  }) {
    final liveness = _loop.livenessOf(run.paneId);
    final failed = run.exitCode != null && run.exitCode != 0;
    final unknownEnd =
        liveness != FlutterRunLiveness.running && run.exitCode == null;
    final worthReading =
        liveness == FlutterRunLiveness.running || failed || unknownEnd;
    final log = includeLog && worthReading
        ? _loop.tailOf(run.paneId, lines: kFlutterRunLogRows)
        : const <String>[];
    return <String, Object?>{
      ...run.toJson(),
      'liveness': liveness.name,
      if (liveness == FlutterRunLiveness.unknown)
        'livenessNote': endedByUs
            ? 'Karmashala ended this run, so its pane is gone. That is why '
                  'there is no liveness to read, not a blind spot.'
            : 'Karmashala no longer has the pane for this run — it was closed, '
                  'or the app was restarted — so whether the process is still '
                  'going is unknown rather than no.',
      if (log.isNotEmpty) 'log': log,
      if (includeLog && !worthReading)
        'logNote':
            'Omitted: this finished cleanly. The log is returned when '
            'something failed or is still going.',
      if (includeLog && worthReading && log.isEmpty)
        'logNote': 'The pane is gone, so there is nothing left to read.',
    };
  }

  /// What the five `flutter_*` tools can see, so an agent knows the loop is
  /// closed without a second call.
  Map<String, Object?> _appsSummary() {
    final registry = _container.read(attachedAppsProvider);
    return <String, Object?>{
      'summary': describeRegistry(registry),
      'ids': <String>[for (final app in registry.attached) app.id],
    };
  }

  // --- Arguments -------------------------------------------------------------

  List<String> _arguments(Map<String, dynamic> args) => <String>[
    for (final value in (args['arguments'] as List<Object?>? ?? const []))
      if (value != null) '$value',
  ];

  /// The project directory, from a checkout id and an optional sub-path. An id
  /// rather than a path: the id is what carries the environment (§17).
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
        'projectDirectory is relative to the checkout — "app" or '
        '"packages/mobile", not an absolute path.',
      );
    }
    return repository.path.copyWith(
      path: context.joinAll([repository.path.path, ...relative.split('/')]),
    );
  }

  /// The one live run, when there is exactly one; null for none and for two,
  /// because stopping the wrong app is worse than being asked which.
  FlutterCommandRun? _onlyLiveRun() {
    final live = <FlutterCommandRun>[
      for (final run in _loop.runs)
        if (_loop.livenessOf(run.paneId) == FlutterRunLiveness.running) run,
    ];
    return live.length == 1 ? live.single : null;
  }
}

/// The `flutter_run` schema, served alongside the rest.
const List<Map<String, dynamic>> flutterRunToolSchemas = <Map<String, dynamic>>[
  {
    'name': 'flutter_run',
    'description':
        'THE FLUTTER LOOP: resolve a checkout\'s dependencies, launch it '
        'on a device, and run its gates — in visible panes, in that '
        'checkout\'s own environment, with the right SDK. A launch ATTACHES '
        'THE APP BY ITSELF, so flutter_apps, flutter_reload, flutter_logs '
        'and flutter_pick_widget are live the moment it starts and you '
        'never call flutter_attach. Actions: "pubGet" (a fresh worktree has '
        'no .dart_tool and nothing else will work until it does), "run" '
        '(needs deviceId), "status", "stop", "analyze", "test". Every '
        'answer carries a PREFLIGHT line naming the problem and the fix — '
        'no SDK in that environment, no .dart_tool, a device somebody else '
        'is driving. THE LOG COMES BACK ONLY WHEN SOMETHING FAILED OR IS '
        'STILL GOING; a gate that passed is a verdict, not a transcript. '
        'One run per device, refused by name. analyze and test record a '
        'verdict you can read back with verification_get.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['run', 'stop', 'status', 'pubGet', 'analyze', 'test'],
          'description':
              'What to do. "status" with no paneId lists everything this '
              'app started.',
        },
        'checkoutId': {
          'type': 'string',
          'description':
              'From list_checkouts. Required for run, pubGet, analyze and '
              'test — it is what says which environment the commands run '
              'in, which a bare path cannot.',
        },
        'projectDirectory': {
          'type': 'string',
          'description':
              'A sub-project inside the checkout, relative — "app" or '
              '"packages/mobile". Omit for a checkout that is itself the '
              'Flutter project.',
        },
        'deviceId': {
          'type': 'string',
          'description':
              'Required for "run": the id "flutter devices" prints — an '
              'adb serial for a phone, or "windows", "macos", "chrome". '
              'list_devices has the attached ones.',
        },
        'paneId': {
          'type': 'string',
          'description':
              'Which run to ask about or stop. From a previous answer. '
              'Optional for "stop" when exactly one thing is running.',
        },
        'arguments': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Extra flags for the command, after the ones Karmashala '
              'spells — "--profile", "--exclude-tags=live-ssh,live-wsl".',
        },
      },
      'required': ['action'],
    },
  },
];
