import 'package:agent_cli/descriptors.dart';

/// The longest prompt kept for a checkpoint label; a panel shows one line.
const int kCheckpointPromptLimit = 500;

/// The argument keys whose values are paths a tool read or wrote: Claude Code's
/// `file_path`/`notebook_path`, Codex's `workdir`, and the generic `path`/`cwd`.
const Set<String> kToolPathKeys = {
  'file_path',
  'notebook_path',
  'path',
  'workdir',
  'cwd',
};

/// What hooks said about a session's current turn that its status cannot: the
/// prompt, the paths its tools named, and where the agent says it is working.
/// In memory, keyed by session row: a turn is short-lived.
class CheckpointTurnHints {
  final Map<String, String> _prompts = {};
  final Map<String, Set<String>> _paths = {};
  final Map<String, String> _cwd = {};

  void recordPrompt(String sessionId, String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    _prompts[sessionId] = trimmed.length > kCheckpointPromptLimit
        ? trimmed.substring(0, kCheckpointPromptLimit)
        : trimmed;
  }

  /// The prompt recorded for [sessionId], removed so a later turn that no hook
  /// announced cannot inherit it.
  String? takePrompt(String sessionId) => _prompts.remove(sessionId);

  /// Returns whether [path] was new for this turn.
  bool recordPath(String sessionId, String path) =>
      (_paths[sessionId] ??= <String>{}).add(path);

  Set<String> pathsOf(String sessionId) => _paths[sessionId] ?? const {};

  void clearPaths(String sessionId) => _paths.remove(sessionId);

  /// The directory the agent last said it works in, spelled for its machine.
  String? cwdOf(String sessionId) => _cwd[sessionId];

  /// Reads one hook's prompt, tool paths and working directory for
  /// [sessionId], by the agent's own hook spec — never by its id. Answers
  /// whether a tool named a path new to this turn.
  bool read(
    String sessionId, {
    required AgentHookSpec spec,
    required String event,
    required Object? payload,
  }) {
    if (spec.cwdPath.isNotEmpty) {
      final cwd = valueAt(spec.cwdPath, payload);
      if (cwd is String && cwd.trim().isNotEmpty) _cwd[sessionId] = cwd;
    }
    if (event == 'UserPromptSubmit' && spec.promptPath.isNotEmpty) {
      final prompt = valueAt(spec.promptPath, payload);
      if (prompt is String) recordPrompt(sessionId, prompt);
    }
    if (spec.toolInputPath.isEmpty) return false;
    final input = valueAt(spec.toolInputPath, payload);
    if (input is! Map) return false;
    var touched = false;
    for (final entry in input.entries) {
      final value = entry.value;
      if (value is String &&
          value.isNotEmpty &&
          kToolPathKeys.contains(entry.key)) {
        if (recordPath(sessionId, value)) touched = true;
      }
    }
    return touched;
  }

  /// Forgets [sessionId]'s hints — its row is gone.
  void forget(String sessionId) {
    _prompts.remove(sessionId);
    _paths.remove(sessionId);
    _cwd.remove(sessionId);
  }

  /// The value at [path] in a decoded JSON [payload], or null.
  static Object? valueAt(List<String> path, Object? payload) {
    var value = payload;
    for (final segment in path) {
      if (value is! Map) return null;
      value = value[segment];
    }
    return value;
  }
}
