import '../sessions/session_subagents.dart' show boundedText;

/// The most of one name or value a summary quotes.
const int _maxQuoted = 120;

/// How a summary turns an id into a name a person knows. Each answers null for
/// what it cannot find, and the summary then says the id.
final class BotCallNames {
  const BotCallNames({this.session, this.terminal, this.checkout});

  final String? Function(String sessionId)? session;
  final String? Function(String tabOrPaneId)? terminal;
  final String? Function(String repositoryId)? checkout;
}

/// **The tool and its target in plain words**: what a person says Yes to. A
/// sentence for each tool the catalogue calls destructive, and for any other
/// a readable line of its plain values, so a new tool reads properly before
/// anyone writes it one. Never raw JSON: "Show the call" has the arguments.
String botApprovalSummary(
  String tool,
  Map<String, dynamic> arguments, {
  BotCallNames names = const BotCallNames(),
}) {
  String? text(String key) => switch (arguments[key]) {
    final String value when value.trim().isNotEmpty => value.trim(),
    final num value => '$value',
    _ => null,
  };
  String quoted(String? value) => "'${_cut(value ?? '')}'";
  String session() {
    final id = text('sessionId');
    if (id == null) return 'this session';
    final title = names.session?.call(id);
    return title == null ? 'session ${_cut(id)}' : 'session ${quoted(title)}';
  }

  String terminal(String key) {
    final id = text(key);
    if (id == null) return 'a terminal';
    final title = names.terminal?.call(id);
    return title == null
        ? 'the terminal ${_cut(id)}'
        : 'the terminal ${quoted(title)}';
  }

  String named(String word, String key) {
    final id = text(key);
    return id == null ? 'a $word' : 'the $word ${_cut(id)}';
  }

  final sentence = switch (tool) {
    'session_end' => 'End ${session()}',
    'delegation_detach' => 'Detach ${session()} from the bot',
    'session_fork_from_checkpoint' => 'Fork ${session()} from a checkpoint',
    'session_rewind' => switch (text('turnIndex')) {
      final turn? => 'Rewind ${session()} to turn $turn',
      null => 'Rewind ${session()}',
    },
    'session_answer' => switch (text('decision') ?? text('option')) {
      final answer? => 'Answer ${session()}: ${_cut(answer)}',
      null => 'Answer ${session()}',
    },
    'terminal_close' =>
      '${arguments['kill'] == true ? 'Force close' : 'Close'} '
          '${terminal('tabId')}',
    'terminal_run' => switch (text('command')) {
      final command? => 'Run ${quoted(command)} in ${terminal('paneId')}',
      null => 'Run a command in ${terminal('paneId')}',
    },
    'snippet_insert' => 'Insert a snippet into ${terminal('paneId')}',
    'worktree_remove' => switch (text('repositoryId')) {
      final id? => switch (names.checkout?.call(id)) {
        final name? => 'Remove the worktree ${quoted(name)}',
        null => 'Remove the worktree ${_cut(id)}',
      },
      null => 'Remove a worktree',
    },
    'checkpoint_restore' => 'Restore the files of ${named('checkpoint', 'id')}',
    'todo_delete' => 'Delete ${named('to-do', 'id')}',
    'note_delete' => 'Delete ${named('note', 'id')}',
    'inbox_dismiss' => 'Dismiss ${named('inbox item', 'id')}',
    'device_tap' => switch ((text('x'), text('y'))) {
      (final x?, final y?) => 'Tap the device at $x, $y',
      _ => 'Tap the device',
    },
    'device_tap_element' => switch (text('text') ?? text('resourceId')) {
      final target? => 'Tap ${quoted(target)} on the device',
      null => 'Tap an element on the device',
    },
    'device_type' => switch (text('text')) {
      final words? => 'Type ${quoted(words)} on the device',
      null => 'Type on the device',
    },
    'device_key' => switch (text('key')) {
      final key? => 'Press ${quoted(key)} on the device',
      null => 'Press a key on the device',
    },
    'device_stop_emulator' => 'Stop the emulator',
    'device_install_app' => switch (text('path')) {
      final path? => 'Install ${quoted(path)} on the device',
      null => 'Install an app on the device',
    },
    'device_terminate_app' => switch (text('appId')) {
      final app? => 'Stop the app ${quoted(app)} on the device',
      null => 'Stop an app on the device',
    },
    'device_app_permission' => switch (text('appId')) {
      final app? => 'Change a permission of the app ${quoted(app)}',
      null => 'Change an app permission on the device',
    },
    'device_clear_app_data' => switch (text('appId')) {
      final app? => 'Clear the data of the app ${quoted(app)}',
      null => 'Clear an app data on the device',
    },
    'browser_click' => switch (text('selector') ?? text('text')) {
      final target? => 'Click ${quoted(target)} in the browser',
      null => 'Click in the browser',
    },
    'browser_key' => switch (text('key')) {
      final key? => 'Press ${quoted(key)} in the browser',
      null => 'Press a key in the browser',
    },
    'browser_evaluate' => switch (text('expression')) {
      final code? => 'Run ${quoted(code)} in the browser',
      null => 'Run a script in the browser',
    },
    'flutter_reload' =>
      arguments['fullRestart'] == true
          ? 'Restart the Flutter app'
          : 'Hot reload the Flutter app',
    _ => null,
  };
  return sentence ?? _generic(tool, arguments);
}

/// [tool] in words, then what its plain values are. What has no short form
/// (a list, a map) is counted and left to "Show the call".
String _generic(String tool, Map<String, dynamic> arguments) {
  final words = tool.replaceAll('_', ' ');
  final title = words.isEmpty
      ? 'A tool call'
      : '${words[0].toUpperCase()}${words.substring(1)}';
  final plain = <String>[];
  var more = 0;
  for (final MapEntry(:key, :value) in arguments.entries) {
    switch (value) {
      case final String text when text.trim().isNotEmpty:
        plain.add('${_keyWords(key)} ${_cut(text.trim())}');
      case num() || bool():
        plain.add('${_keyWords(key)} $value');
      case null || String():
        break;
      default:
        more++;
    }
  }
  if (more > 0) plain.add('and $more more in the call');
  return plain.isEmpty ? title : '$title: ${plain.join(', ')}';
}

/// `checkoutId` as `checkout id`.
String _keyWords(String key) => key
    .replaceAllMapped(RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}')
    .replaceAll('_', ' ');

String _cut(String value) =>
    boundedText(value.replaceAll(RegExp(r'\s+'), ' '), _maxQuoted).$1;
