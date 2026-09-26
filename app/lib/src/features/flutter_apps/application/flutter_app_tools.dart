import 'package:riverpod/riverpod.dart';

import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'attached_apps.dart';

/// The `flutter_*` tools: what an agent can ask about, and do to, the running
/// app. Nothing dispatches to a session; an error is reported when asked for.
class FlutterAppTools {
  FlutterAppTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling, when one is. Unused today, carried so a rule
  /// about which app a session means has somewhere to be read from.
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'flutter_apps',
    'flutter_attach',
    'flutter_reload',
    'flutter_logs',
    'flutter_pick_widget',
  };

  static bool handles(String name) => _names.contains(name);

  AttachedApps get _apps => _container.read(attachedAppsProvider.notifier);
  FlutterAppRegistry get _registry => _container.read(attachedAppsProvider);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'flutter_apps' => _list(),
        'flutter_attach' => _attach(args),
        'flutter_reload' => _reload(args),
        'flutter_logs' => _logs(args),
        'flutter_pick_widget' => _pick(args),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// Looks, then reports — including reporting that it found nothing, and what
  /// to do about that.
  Future<Object?> _list() async {
    await _apps.look();
    final registry = _registry;
    return <String, Object?>{
      'summary': describeRegistry(registry),
      'checkedAt': registry.lookedAt?.toIso8601String(),
      'discoveryDirectory': registry.discoveryDirectory,
      if (registry.discoveryFailure != null)
        'couldNotLook': registry.discoveryFailure,
      'apps': <Object?>[for (final app in registry.apps) app.toJson()],
      // The remedy travels with the empty answer: an agent that cannot see an
      // app needs the flag, not the news.
      if (registry.attached.isEmpty) 'howToMakeOneVisible': _apps.attachHint,
    };
  }

  Future<Object?> _attach(Map<String, dynamic> args) async {
    final uri = (args['vmServiceUri'] as String?)?.trim() ?? '';
    if (uri.isEmpty) {
      throw ArgumentError(
        'vmServiceUri is required: the address "flutter run" printed, which '
        'looks like "http://127.0.0.1:53119/AbCdEf=/". ${_apps.attachHint}',
      );
    }
    final app = await _apps.attach(uri);
    return <String, Object?>{
      'attached': app.toJson(),
      'summary': describeRegistry(_registry),
    };
  }

  Future<Object?> _reload(Map<String, dynamic> args) async {
    final id = (args['appId'] as String?)?.trim();
    final fullRestart = args['fullRestart'] == true;
    final app = _apps.requireApp(id?.isEmpty ?? true ? null : id);
    if (fullRestart) {
      await _apps.hotRestart(app.id);
    } else {
      await _apps.hotReload(app.id);
    }
    // What a success here does *not* mean: only that the reload reached the VM.
    // A widget that failed to rebuild reports itself on `flutter_logs`.
    return <String, Object?>{
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
    final id = (args['appId'] as String?)?.trim();
    final limit = ((args['limit'] as num?)?.round() ?? 100).clamp(1, 1000);
    final onlyErrors = args['errorsOnly'] == true;
    final app = _apps.requireApp(id?.isEmpty ?? true ? null : id);
    final records = _apps.console(
      app.id,
      limit: limit,
      sources: onlyErrors
          ? const <AppLogSource>{AppLogSource.stderr, AppLogSource.flutterError}
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
      <String>[
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
    final id = (args['appId'] as String?)?.trim();
    final seconds = ((args['timeoutSeconds'] as num?)?.round() ?? 120).clamp(
      1,
      600,
    );
    final app = _apps.requireApp(id?.isEmpty ?? true ? null : id);
    final selection = await _apps.pickWidget(
      app.id,
      timeout: Duration(seconds: seconds),
    );
    final locations = app.widgetLocations;
    return _text(
      <String>[
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
        _asJsonLines(selection.toJson()),
      ].join('\n'),
    );
  }

  static String _asJsonLines(Map<String, Object?> json) => <String>[
    for (final entry in json.entries)
      '${entry.key}: ${entry.value is Map ? _flatten(entry.value! as Map) : entry.value}',
  ].join('\n');

  static String _flatten(Map<Object?, Object?> map) =>
      map.entries.map((entry) => '${entry.key}=${entry.value}').join(', ');

  /// Prose, as a content block: a console tail JSON-encoded into one string is
  /// unreadable and costs several times the tokens.
  static Map<String, Object?> _text(String body) => <String, Object?>{
    '_mcpContent': <Object?>[
      <String, Object?>{'type': 'text', 'text': body},
    ],
  };
}

/// The `flutter_*` schemas, served alongside the rest.
const List<Map<String, dynamic>> flutterAppToolSchemas = <Map<String, dynamic>>[
  {
    'name': 'flutter_apps',
    'description':
        'Every running Flutter app Karmashala can reach, with an id to '
        'name it by, whether it can be hot reloaded and whether its build '
        'carries widget source locations. LOOK HERE FIRST: an app id lasts '
        'only as long as the "flutter run" that produced it. An empty list '
        'comes back with the exact flag to add so the next run is visible '
        '— Karmashala does not start the app and will never rewrite a '
        'command you typed. "We have not looked", "no app is running" and '
        '"an address nothing answers on" are three different answers here.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'flutter_attach',
    'description':
        'Attach to a running app by the address "flutter run" printed — '
        'the line "A Dart VM Service on … is available at: '
        'http://127.0.0.1:PORT/TOKEN=/". Use it when flutter_apps shows '
        'nothing because the run had no --vmservice-out-file. Attaching '
        'twice to the same app is the same as attaching once.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'vmServiceUri': {
          'type': 'string',
          'description':
              'The printed http:// address or the ws://…/ws one. Both are '
              'accepted.',
        },
      },
      'required': ['vmServiceUri'],
    },
  },
  {
    'name': 'flutter_reload',
    'description':
        'Hot reload the running app so an edit takes effect, or hot '
        'restart it. A SUCCESS HERE MEANS THE RELOAD REACHED THE VM AND '
        'NOTHING MORE: a widget that then failed to rebuild reports itself '
        'on flutter_logs, so read that next. Requires a "flutter run" '
        'still attached to the app — the recompile comes from the tool, '
        'not from the VM service, and an app nothing is driving says so '
        'instead of failing obscurely. fullRestart re-runs main() and '
        'the app loses the state it had.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'appId': {
          'type': 'string',
          'description':
              'From flutter_apps. Optional when exactly one app is '
              'attached; refused rather than guessed when two are.',
        },
        'fullRestart': {
          'type': 'boolean',
          'description':
              'Hot restart instead of hot reload. Re-runs main() and '
              'discards the app state. Default false.',
        },
      },
    },
  },
  {
    'name': 'flutter_logs',
    'description':
        'The running app\'s debug console: its stdout and stderr, its '
        'dart:developer log() records and every exception the framework '
        'caught, in one list oldest-first. This is where a runtime error '
        'lives — you do not need the developer to paste a stack trace. '
        'Lines marked "before attach" were replayed out of the VM service '
        'buffer and are history rather than now. An empty tail means the '
        'app has said nothing SINCE THE ATTACH, which is not the same as '
        'it having said nothing at all.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'appId': {
          'type': 'string',
          'description':
              'From flutter_apps. Optional when only one is attached.',
        },
        'limit': {
          'type': 'number',
          'description':
              'How many of the newest lines (default 100, max 1000).',
        },
        'errorsOnly': {
          'type': 'boolean',
          'description':
              'Only stderr and caught exceptions. Use it when hunting a '
              'failure in a chatty app.',
        },
      },
    },
  },
  {
    'name': 'flutter_pick_widget',
    'description':
        'Ask the developer to point at a widget in the running app: it '
        'goes into Flutter\'s own widget-select mode, they tap the thing '
        'they mean — on the desktop window or on the mirrored phone — and '
        'the widget and the file, line and column it was written at come '
        'back. Use it when they say "this button" or "that padding" and '
        'you cannot tell which one they mean. BLOCKS until they tap or the '
        'timeout passes. A build compiled without --track-widget-creation '
        '(profile, release) names the widget and cannot name a line, and '
        'says so rather than showing nothing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'appId': {
          'type': 'string',
          'description':
              'From flutter_apps. Optional when only one is attached.',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description': 'How long to wait for a tap (default 120, max 600).',
        },
      },
    },
  },
];
