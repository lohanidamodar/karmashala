import 'package:agent_cli/stream.dart' show claudeWebSearchText, spillToolImage;
import 'package:karmashala_acp/karmashala_acp.dart' show JsonMap;
import 'package:path/path.dart' as p;

/// [value] as a JSON object, or null.
JsonMap? jsonObject(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

/// The JSON objects in [value], when it is a list.
List<JsonMap> jsonObjects(Object? value) => [
  if (value is List)
    for (final item in value) ?jsonObject(item),
];

/// Claude Code's tools as ACP sees a tool call: its kind, a title a person
/// reads, the files it touches, and an edit's diffs.
abstract final class ClaudeTools {
  /// The tools whose work is a plan, written as one rather than as calls.
  static const planTools = {'TodoWrite', 'TaskCreate', 'TaskUpdate'};

  /// The tools that start a subagent.
  static const subagentTools = {'Agent', 'Task'};

  static String kind(String name) => switch (name) {
    'Read' || 'NotebookRead' => 'read',
    'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => 'edit',
    'Bash' || 'PowerShell' || 'BashOutput' || 'KillShell' => 'execute',
    'Glob' || 'Grep' || 'LS' || 'ToolSearch' => 'search',
    'WebFetch' || 'WebSearch' => 'fetch',
    'Agent' || 'Task' => 'think',
    'ExitPlanMode' || 'EnterPlanMode' => 'switch_mode',
    _ => 'other',
  };

  static String title(String name, JsonMap input) {
    String? field(String key) => switch (input[key]) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => null,
    };
    final path = field('file_path') ?? field('notebook_path');
    return switch (name) {
      'Read' => 'Read ${path ?? 'a file'}',
      'Edit' || 'MultiEdit' || 'NotebookEdit' => 'Edit ${path ?? 'a file'}',
      'Write' => 'Write ${path ?? 'a file'}',
      'Bash' || 'PowerShell' =>
        _firstLine(field('command')) ?? field('description') ?? name,
      'Glob' => 'Find ${field('pattern') ?? 'files'}',
      'Grep' => 'grep ${field('pattern') ?? ''}'.trim(),
      'WebFetch' => 'Fetch ${field('url') ?? 'a page'}',
      'WebSearch' => 'Search the web: ${field('query') ?? ''}'.trim(),
      'Agent' || 'Task' => field('description') ?? 'Subagent',
      'ExitPlanMode' => 'Ready to code?',
      'Skill' => 'Skill ${field('skill') ?? field('name') ?? ''}'.trim(),
      _ => name,
    };
  }

  /// The files [name] touches, with the line a read starts at.
  static List<JsonMap>? locations(String name, JsonMap input) {
    final path = input['file_path'] ?? input['notebook_path'];
    if (path is! String || path.isEmpty) return null;
    final offset = input['offset'];
    return [
      {'path': path, if (name == 'Read' && offset is int) 'line': offset},
    ];
  }

  /// An edit's diffs, as ACP `diff` content; empty for anything else. The
  /// hunk Claude was given, not the whole file: the tool input is all a
  /// diff can be built from before the edit runs.
  static List<JsonMap> diffs(String name, JsonMap input) {
    final path = input['file_path'];
    if (path is! String) return const [];
    JsonMap diff(Object? oldText, Object? newText) => {
      'type': 'diff',
      'path': path,
      'oldText': oldText is String ? oldText : null,
      'newText': newText is String ? newText : '',
    };
    return switch (name) {
      'Edit' => [diff(input['old_string'], input['new_string'])],
      'Write' => [diff(null, input['content'])],
      'MultiEdit' => [
        for (final edit in jsonObjects(input['edits']))
          diff(edit['old_string'], edit['new_string']),
      ],
      _ => const [],
    };
  }

  /// A tool result's `content` as text: a string, or its blocks' words. An
  /// image is no words: see [images].
  static String resultText(Object? content) => switch (content) {
    final String text => text,
    final List<Object?> blocks => [
      for (final block in jsonObjects(blocks))
        if (block['type'] != 'image')
          switch (block['type']) {
            'text' => '${block['text'] ?? ''}',
            'tool_reference' => '${block['tool_name'] ?? ''}',
            final other => '[$other]',
          },
    ].join('\n'),
    _ => '',
  };

  /// [resultText], unless the structured [toolUseResult] says it better: a
  /// WebSearch's text holds its links as raw JSON.
  static String resultTextOf(Object? content, Object? toolUseResult) =>
      claudeWebSearchText(toolUseResult) ?? resultText(content);

  /// A tool result's images, each written to a file and linked as ACP
  /// `resource_link` content: the bytes are far too large for a row.
  static List<JsonMap> images(Object? content) => [
    for (final block in jsonObjects(content))
      if (block['type'] == 'image')
        if (jsonObject(block['source']) case final source?)
          if (source['data'] case final String data)
            if (spillToolImage(data, mimeType: '${source['media_type']}')
                case final path?)
              {
                'type': 'content',
                'content': {
                  'type': 'resource_link',
                  'uri': Uri.file(path).toString(),
                  'name': p.basename(path),
                  'mimeType': ?source['media_type'],
                },
              },
  ];

  /// ACP text content.
  static JsonMap text(String text) => {
    'type': 'content',
    'content': {'type': 'text', 'text': text},
  };

  /// A plan entry's status from a todo's or a task's.
  static String planStatus(Object? status) => switch (status) {
    'completed' => 'completed',
    'in_progress' => 'in_progress',
    _ => 'pending',
  };

  static String? _firstLine(String? text) {
    if (text == null) return null;
    final line = text.split('\n').first.trim();
    return line.isEmpty ? null : line;
  }
}
