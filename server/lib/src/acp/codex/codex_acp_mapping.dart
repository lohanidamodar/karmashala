import 'package:agent_cli/stream.dart' show webSearchResultLines;
import 'package:karmashala_acp/karmashala_acp.dart' show JsonMap;
import 'package:path/path.dart' as p;

/// Where the Codex wire shapes below were read: the TypeScript and JSON
/// Schema `codex app-server generate-ts` / `generate-json-schema` printed, and
/// a live session of the same binary.
const String kCodexAppServerProtocolSource = 'codex-cli 0.160.0 app-server v2';

/// One of the ACP modes the bridge offers: an approval policy and a sandbox,
/// as `thread/start` and `turn/start` take them.
typedef CodexMode = ({
  String id,
  String name,
  String description,
  String approvalPolicy,
  String sandboxType,
});

/// The ids are the ones the codex-acp adapter offered, so a stored choice
/// and the descriptor's permission axis still name a mode that exists.
const List<CodexMode> kCodexModes = [
  (
    id: 'read-only',
    name: 'Read-only',
    description: 'Reads and proposes; asks before changing anything.',
    approvalPolicy: 'on-request',
    sandboxType: 'readOnly',
  ),
  (
    id: 'workspace-write',
    name: 'Workspace write',
    description: 'Writes inside the workspace; asks before anything outside.',
    approvalPolicy: 'on-request',
    sandboxType: 'workspaceWrite',
  ),
  (
    id: 'agent',
    name: 'Agent',
    description: 'Runs without asking, inside the sandbox.',
    approvalPolicy: 'never',
    sandboxType: 'workspaceWrite',
  ),
  (
    id: 'agent-full-access',
    name: 'Agent, full access',
    description: 'Runs without asking and without a sandbox.',
    approvalPolicy: 'never',
    sandboxType: 'dangerFullAccess',
  ),
];

CodexMode? codexModeById(String id) {
  for (final mode in kCodexModes) {
    if (mode.id == id) return mode;
  }
  return null;
}

/// The mode a thread's own approval policy and sandbox amount to.
CodexMode codexModeOf(Object? approvalPolicy, JsonMap? sandbox) {
  final never = approvalPolicy == 'never';
  return switch (sandbox?['type']) {
    'readOnly' => kCodexModes[0],
    'dangerFullAccess' => kCodexModes[3],
    _ => never ? kCodexModes[2] : kCodexModes[1],
  };
}

/// ACP's `modes` for [current].
JsonMap codexModeState(CodexMode current) => {
  'currentModeId': current.id,
  'availableModes': [
    for (final mode in kCodexModes)
      {'id': mode.id, 'name': mode.name, 'description': mode.description},
  ],
};

/// The `sandboxPolicy` a turn takes for [mode]: the thread's own [current]
/// policy when it is already of that kind, so its writable roots and network
/// setting survive.
JsonMap codexSandboxPolicy(CodexMode mode, JsonMap? current) {
  if (current != null && current['type'] == mode.sandboxType) return current;
  return switch (mode.sandboxType) {
    'readOnly' => {'type': 'readOnly', 'networkAccess': false},
    'dangerFullAccess' => {'type': 'dangerFullAccess'},
    _ => {
      'type': 'workspaceWrite',
      'writableRoots': <String>[],
      'networkAccess': false,
      'excludeTmpdirEnvVar': false,
      'excludeSlashTmp': false,
    },
  };
}

const String kCodexModelOption = 'model';
const String kCodexEffortOption = 'reasoning_effort';

/// ACP config options for the model and its reasoning effort, from
/// `model/list`'s entries. A current model the list hides is still offered.
List<JsonMap> codexConfigOptions(
  List<JsonMap> models,
  String? model,
  String? effort,
) {
  final shown = [
    for (final m in models)
      if (m['hidden'] != true || m['model'] == model) m,
  ];
  final current = shown.where((m) => m['model'] == model).firstOrNull;
  final efforts = [
    for (final e in _objects(current?['supportedReasoningEfforts']))
      if (e['reasoningEffort'] case final String value) (value, e),
  ];
  return [
    if (model != null)
      {
        'id': kCodexModelOption,
        'name': 'Model',
        'type': 'select',
        'category': 'model',
        'currentValue': model,
        'options': [
          if (current == null) {'value': model, 'name': model},
          for (final m in shown)
            if (m['model'] case final String value)
              _dropNulls({
                'value': value,
                'name': m['displayName'] is String ? m['displayName'] : value,
                'description': m['description'],
              }),
        ],
      },
    if (efforts.isNotEmpty)
      {
        'id': kCodexEffortOption,
        'name': 'Reasoning effort',
        'type': 'select',
        'category': 'thought_level',
        'currentValue':
            effort ?? current?['defaultReasoningEffort'] ?? efforts.first.$1,
        'options': [
          for (final (value, e) in efforts)
            _dropNulls({
              'value': value,
              'name': _capitalised(value),
              'description': e['description'],
            }),
        ],
      },
  ];
}

/// The effort [models] supports for [model] that is closest to [wanted]:
/// [wanted] itself when offered, else the model's default.
String? codexEffortFor(List<JsonMap> models, String? model, String? wanted) {
  final entry = models.where((m) => m['model'] == model).firstOrNull;
  if (entry == null) return wanted;
  final offered = [
    for (final e in _objects(entry['supportedReasoningEfforts']))
      e['reasoningEffort'],
  ];
  if (wanted != null && offered.contains(wanted)) return wanted;
  final fallback = entry['defaultReasoningEffort'];
  return fallback is String ? fallback : null;
}

/// ACP prompt content as Codex `UserInput`s.
List<JsonMap> codexInput(List<JsonMap> prompt) => [
  for (final block in prompt)
    switch (block['type']) {
      'image' => {
        'type': 'image',
        'url': block['uri'] is String && block['data'] == null
            ? block['uri']
            : 'data:${block['mimeType'] ?? 'image/png'};base64,'
                  '${block['data'] ?? ''}',
      },
      'resource_link' => _text('${block['uri'] ?? block['name'] ?? ''}'),
      'resource' => _text(_embedded(block['resource'])),
      _ => _text('${block['text'] ?? ''}'),
    },
];

JsonMap _text(String text) => {
  'type': 'text',
  'text': text,
  'text_elements': const <Object?>[],
};

String _embedded(Object? resource) {
  if (resource is! Map) return '';
  final uri = resource['uri'] ?? '';
  final text = resource['text'];
  return text is String ? '$uri\n```\n$text\n```' : '$uri';
}

/// The ACP tool call fields for a Codex item, or null for an item that is
/// not a tool (messages, reasoning, compaction). Codex's own fields ride in
/// `_meta.codex`.
JsonMap? codexToolCall(JsonMap item, {required String cwd}) {
  final id = item['id'];
  if (id is! String) return null;
  final type = item['type'];
  final JsonMap? fields = switch (type) {
    'commandExecution' => _command(item, cwd),
    'fileChange' => _fileChange(item, cwd),
    'mcpToolCall' => _mcpToolCall(item),
    'dynamicToolCall' => _dynamicToolCall(item),
    'webSearch' => _webSearch(item),
    'imageView' => {
      'title': 'View ${item['path']}',
      'kind': 'read',
      'locations': [
        {'path': _absolute('${item['path']}', cwd)},
      ],
      'rawInput': {'path': item['path']},
    },
    'imageGeneration' => {
      'title': 'Generate an image',
      'kind': 'other',
      'rawInput': {'prompt': item['revisedPrompt']},
      if (item['savedPath'] is String)
        'locations': [
          {'path': item['savedPath']},
        ],
    },
    'collabAgentToolCall' => {
      'title': 'Agent: ${item['tool']}',
      'kind': 'other',
      'rawInput': _dropNulls({
        'tool': item['tool'],
        'prompt': item['prompt'],
        'model': item['model'],
        'receiverThreadIds': item['receiverThreadIds'],
      }),
    },
    _ => null,
  };
  if (fields == null) return null;
  return _dropNulls({
    'toolCallId': id,
    ...fields,
    'status': codexToolStatus(item['status']),
    '_meta': {
      'codex': {
        'itemType': type,
        for (final key in const ['durationMs', 'processId', 'source'])
          if (item[key] != null) key: item[key],
        if (type == 'collabAgentToolCall') 'agentsStates': item['agentsStates'],
      },
    },
  });
}

/// An item status in ACP's words; a declined command or patch failed.
String? codexToolStatus(Object? status) => switch (status) {
  'inProgress' => 'in_progress',
  'completed' => 'completed',
  'failed' || 'declined' => 'failed',
  null => null,
  _ => status is String ? 'in_progress' : null,
};

JsonMap _command(JsonMap item, String cwd) {
  final actions = _objects(item['commandActions']);
  final inner = [
    for (final a in actions)
      if (a['command'] case final String command) command,
  ];
  final kinds = {for (final a in actions) a['type']};
  final kind = actions.isEmpty || kinds.contains('unknown')
      ? 'execute'
      : kinds.length == 1 && kinds.single == 'read'
      ? 'read'
      : 'search';
  final output = item['aggregatedOutput'];
  final command = codexInnerCommand('${item['command'] ?? ''}');
  final exitCode = item['exitCode'];
  final said = [
    if (exitCode is int && exitCode != 0) 'Exit code $exitCode',
    if (output is String && output.isNotEmpty) output,
  ].join('\n');
  return {
    'title': inner.isEmpty ? command : inner.join(' && '),
    'kind': kind,
    'rawInput': _dropNulls({
      'command': command,
      'commandLine': command == item['command'] ? null : item['command'],
      'cwd': item['cwd'],
      'commandActions': actions.isEmpty ? null : actions,
    }),
    'locations': [
      for (final a in actions)
        if (a['path'] case final String path) {'path': _absolute(path, cwd)},
    ],
    if (output is String || said.isNotEmpty)
      'content': [codexTextContent(said)],
    if (exitCode != null) 'rawOutput': {'exitCode': exitCode},
  };
}

/// The command a Codex command line runs inside the shell it was wrapped in
/// (`powershell.exe -Command '…'`, `bash -lc '…'`, `cmd /c …`); the line
/// itself when it is no such wrapper.
String codexInnerCommand(String commandLine) {
  final match = _shellWrapper.firstMatch(commandLine.trim());
  if (match == null) return commandLine;
  final arg = (match.group(1) ?? match.group(2) ?? match.group(3)!).trim();
  if (arg.length >= 2 && arg.startsWith("'") && arg.endsWith("'")) {
    final body = arg.substring(1, arg.length - 1);
    // PowerShell doubles a quote inside one; a POSIX shell closes and reopens.
    return body.replaceAll(r"'\''", "'").replaceAll("''", "'");
  }
  if (arg.length >= 2 && arg.startsWith('"') && arg.endsWith('"')) {
    // Joined POSIX-style, so a double-quoted body escapes these four.
    return arg
        .substring(1, arg.length - 1)
        .replaceAllMapped(RegExp(r'\\([\\"$`])'), (m) => m[1]!);
  }
  return arg;
}

/// A shell, by its file name with any directory before it (quoted or not),
/// then the flag that hands it a command, which one group holds.
final _shellWrapper = RegExp(
  r'''^"?(?:[^"]*[\\/])?(?:powershell|pwsh)(?:\.exe)?"?\s+(?:-\w+\s+)*?-(?:Command|c)\s+(.+)$'''
  r'''|^"?(?:[^"]*[\\/])?(?:ba|z)?sh(?:\.exe)?"?\s+-l?c\s+(.+)$'''
  r'''|^"?(?:[^"]*[\\/])?cmd(?:\.exe)?"?\s+/[cC]\s+(.+)$''',
  caseSensitive: false,
  dotAll: true,
);

JsonMap _fileChange(JsonMap item, String cwd) {
  final changes = _objects(item['changes']);
  final paths = [for (final c in changes) _absolute('${c['path']}', cwd)];
  return {
    'title': changes.isEmpty
        ? 'Edit files'
        : 'Edit ${[for (final c in changes) p.basename('${c['path']}')].join(', ')}',
    'kind': 'edit',
    'rawInput': {'changes': changes},
    'locations': [
      for (final path in paths) {'path': path},
    ],
    'content': [for (final c in changes) codexDiffContent(c, cwd)],
  };
}

JsonMap _mcpToolCall(JsonMap item) {
  final result = item['result'];
  final error = item['error'];
  return {
    'title': '${item['server']}: ${item['tool']}',
    'name': item['tool'],
    'kind': item['readOnlyHint'] == true ? 'read' : 'other',
    'rawInput': item['arguments'],
    if (result is Map)
      'content': [
        for (final block in _objects(result['content']))
          if (block['type'] == 'text')
            codexTextContent('${block['text']}')
          else
            {'type': 'content', 'content': block},
      ],
    if (error is Map) 'content': [codexTextContent('${error['message']}')],
    if (result is Map && result['structuredContent'] != null)
      'rawOutput': result['structuredContent'],
  };
}

JsonMap _dynamicToolCall(JsonMap item) {
  final output = _objects(item['contentItems']);
  return {
    'title': item['tool'],
    'name': item['tool'],
    'kind': 'other',
    'rawInput': item['arguments'],
    if (output.isNotEmpty)
      'content': [
        for (final o in output)
          if (o['type'] == 'inputText') codexTextContent('${o['text']}'),
      ],
  };
}

JsonMap _webSearch(JsonMap item) {
  final action = item['action'];
  final url = action is Map ? action['url'] : null;
  final query = item['query'];
  final results = webSearchResultLines(item['results']);
  return {
    'title': url is String
        ? 'Open $url'
        : 'Search the web${query is String && query.isNotEmpty ? ': $query' : ''}',
    'kind': 'fetch',
    'rawInput': _dropNulls({'query': query, 'action': action}),
    if (results.isNotEmpty) 'content': [codexTextContent(results)],
  };
}

JsonMap codexTextContent(String text) => {
  'type': 'content',
  'content': {'type': 'text', 'text': text},
};

/// One Codex file change as ACP diff content. Codex sends a file's content
/// for an add or delete and a unified diff for an update; an update's
/// before and after are its hunks, not the whole file, and the diff itself
/// stays in `_meta.codex.unifiedDiff`.
JsonMap codexDiffContent(JsonMap change, String cwd) {
  final kind = change['kind'];
  final type = kind is Map ? kind['type'] : kind;
  final movedTo = kind is Map ? kind['move_path'] : null;
  final diff = '${change['diff'] ?? ''}';
  final path = _absolute(
    movedTo is String ? movedTo : '${change['path']}',
    cwd,
  );
  final (String? oldText, String newText) = switch (type) {
    'add' => _isUnified(diff) ? (null, _side(diff, '+')) : (null, diff),
    'delete' => _isUnified(diff) ? (_side(diff, '-'), '') : (diff, ''),
    _ => (_side(diff, '-'), _side(diff, '+')),
  };
  return {
    'type': 'diff',
    'path': path,
    'oldText': oldText,
    'newText': newText,
    '_meta': {
      'codex': _dropNulls({
        'kind': type,
        'unifiedDiff': type == 'update' ? diff : null,
        'movedFrom': movedTo is String
            ? _absolute('${change['path']}', cwd)
            : null,
      }),
    },
  };
}

bool _isUnified(String diff) =>
    diff.startsWith('@@') || diff.contains('\n@@') || diff.startsWith('--- ');

/// One side of a unified diff's hunks: context lines and the lines [mark]
/// (`-` for before, `+` for after) adds.
String _side(String diff, String mark) {
  final out = <String>[];
  var inHunk = false;
  for (final line in diff.split('\n')) {
    if (line.startsWith('@@')) {
      inHunk = true;
      continue;
    }
    if (!inHunk || line.startsWith(r'\')) continue;
    if (line.startsWith(' ')) {
      out.add(line.substring(1));
    } else if (line.startsWith(mark)) {
      out.add(line.substring(1));
    } else if (line.isEmpty) {
      continue;
    }
  }
  return out.join('\n');
}

/// The ACP plan entries for a Codex `turn/plan/updated`.
List<JsonMap> codexPlanEntries(Object? plan) => [
  for (final step in _objects(plan))
    {
      'content': '${step['step'] ?? ''}',
      'priority': 'medium',
      'status': switch (step['status']) {
        'inProgress' => 'in_progress',
        'completed' => 'completed',
        _ => 'pending',
      },
    },
];

/// Codex's version out of its `initialize` user agent
/// (`<client>/0.160.0 (Windows …)`).
String? codexVersionOf(Object? userAgent) {
  if (userAgent is! String) return null;
  final match = RegExp(r'/(\d+\.\d+\.\d+[^\s;)]*)').firstMatch(userAgent);
  return match?.group(1);
}

String _absolute(String path, String cwd) {
  if (path.isEmpty || cwd.isEmpty) return path;
  if (p.windows.isAbsolute(path) || p.posix.isAbsolute(path)) return path;
  final windows = cwd.contains(r'\') || RegExp('^[A-Za-z]:').hasMatch(cwd);
  return windows ? p.windows.join(cwd, path) : p.posix.join(cwd, path);
}

String _capitalised(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

List<JsonMap> _objects(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) item.cast<String, Object?>(),
];

JsonMap _dropNulls(JsonMap json) => {
  for (final entry in json.entries)
    if (entry.value != null) entry.key: entry.value,
};
