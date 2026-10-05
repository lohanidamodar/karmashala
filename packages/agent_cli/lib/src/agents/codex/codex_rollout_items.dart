/// What a Codex rollout's `event_msg/item_completed` items say a turn did,
/// as tool rows: the record code mode (`exec`) leaves of each step its
/// script took.
library;

import '../../sessions/tool_activity.dart';
import '../../sessions/tool_images.dart';
import 'codex_file_edits.dart';

/// The custom tools that run a script of other tool calls.
const Set<String> kCodexCodeModeTools = {'exec', 'js'};

/// The tools a code-mode [script] calls, in order, or null when it calls
/// none. The script itself is never a subject: it is JavaScript.
String? codexScriptSubject(Object? script) {
  if (script is! String) return null;
  final names = {for (final m in _toolCall.allMatches(script)) m[1]!};
  return names.isEmpty ? null : names.join(', ');
}

final RegExp _toolCall = RegExp(r'\btools\.([A-Za-z_]\w*)\s*\(');

/// The row a completed [item] draws, or null for one that is no tool call:
/// messages and reasoning, which the response items already carry, and a
/// sleep.
ToolActivity? codexItemActivity(Map<dynamic, dynamic> item) =>
    switch (item['type']) {
      'CommandExecution' => _command(item),
      'FileChange' => _fileChange(item),
      'ImageView' => _image('view_image', item['path']),
      'McpToolCall' => _mcpCall(item),
      'WebSearch' => _webSearch(item),
      'Extension' => switch (item['kind']) {
        'image_gen.generation' => _generatedImage(item),
        'web.search' => _webSearch(item),
        _ => null,
      },
      _ => null,
    };

ToolActivity _command(Map<dynamic, dynamic> item) {
  final parsed = item['parsed_cmd'];
  final inner = [
    if (parsed is List)
      for (final step in parsed)
        if (step is Map && step['cmd'] is String) step['cmd'] as String,
  ];
  final code = item['exit_code'];
  final failed =
      (code is int && code != 0) ||
      item['status'] == 'failed' ||
      item['status'] == 'declined';
  final said = _text(item['aggregated_output']) ?? _text(item['stderr']);
  final exit = code is int && code != 0 ? 'Exit code $code' : null;
  return _activity(
    name: 'exec_command',
    subject: inner.isEmpty ? _commandLine(item['command']) : inner.join(' && '),
    output: [?exit, ?said].join('\n'),
    isError: failed,
  );
}

/// The command an argv runs inside the shell it was wrapped in.
String? _commandLine(Object? command) {
  if (command is String) return _text(command);
  if (command is! List) return null;
  final argv = [for (final part in command) '$part'];
  final flag = argv.indexWhere(_commandFlags.contains);
  final run = flag < 0 ? argv : argv.sublist(flag + 1);
  return _text(run.join(' '));
}

const Set<String> _commandFlags = {'-Command', '-c', '-lc', '/c', '/C'};

ToolActivity _fileChange(Map<dynamic, dynamic> item) {
  final (edits, cut) = boundedToolEdits(codexChangeEdits(item['changes']));
  final failed = item['status'] == 'failed' || item['status'] == 'declined';
  return ToolActivity(
    name: 'apply_patch',
    subject: edits.firstOrNull?.path,
    edits: edits,
    editsTruncated: cut,
    output: failed ? _text(item['stderr']) ?? _text(item['stdout']) : null,
    isError: failed,
  );
}

ToolActivity _image(String name, Object? path) {
  final file = _text(path);
  return ToolActivity(
    name: name,
    subject: file,
    imagePath: file != null && looksLikeImagePath(file) ? file : null,
  );
}

ToolActivity _generatedImage(Map<dynamic, dynamic> item) {
  final saved = _image('image_gen', item['savedPath']);
  final prompt = _text(item['revisedPrompt']);
  final failure = item['failure'];
  return ToolActivity(
    name: saved.name,
    subject: prompt?.split('\n').first ?? saved.subject,
    imagePath: saved.imagePath,
    output: failure == null ? null : _text('$failure'),
    isError: failure != null,
  );
}

ToolActivity _mcpCall(Map<dynamic, dynamic> item) {
  final result = item['result'];
  final content = result is Map ? result['content'] : null;
  final said = [
    if (content is List)
      for (final block in content)
        if (block is Map && block['text'] is String) block['text'] as String,
  ].join('\n');
  final error = item['error'];
  final image = [
    if (content is List)
      for (final block in content)
        if (block is Map && block['type'] == 'image' && block['data'] is String)
          block,
  ].firstOrNull;
  return _activity(
    name: 'mcp__${item['server']}__${item['tool']}',
    subject: toolSubjectEntryFor(item['arguments'])?.value,
    output: said.isEmpty && error != null ? '$error' : said,
    isError:
        item['status'] == 'failed' ||
        (result is Map && result['isError'] == true),
    imagePath: image == null
        ? null
        : spillToolImage(
            image['data'] as String,
            mimeType: image['mimeType'] is String
                ? image['mimeType'] as String
                : null,
          ),
  );
}

/// A `web_search_call` response item, or any Codex web search: what it
/// searched or opened, and the results when it kept them.
ToolActivity codexWebSearchActivity(Map<dynamic, dynamic> item) =>
    _webSearch(item);

ToolActivity _webSearch(Map<dynamic, dynamic> item) {
  final action = item['action'];
  final queries = action is Map ? action['queries'] : null;
  final query =
      _text(item['query']) ??
      (action is Map ? _text(action['query']) ?? _text(action['url']) : null) ??
      (queries is List && queries.isNotEmpty
          ? _text('${queries.first}')
          : null);
  return _activity(
    name: 'web_search',
    subject: query,
    output: webSearchResultLines(item['results']),
  );
}

ToolActivity _activity({
  required String name,
  String? subject,
  required String output,
  bool isError = false,
  String? imagePath,
}) {
  final (bounded, cut) = boundedToolOutput(output.trimRight());
  return ToolActivity(
    name: name,
    subject: subject,
    imagePath: imagePath,
    output: bounded.isEmpty ? null : bounded,
    outputTruncated: cut,
    isError: isError,
  );
}

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}
