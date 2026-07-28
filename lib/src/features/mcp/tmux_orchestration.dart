/// One tmux window: a labelled shell in [cwd] running [command].
class TmuxWindow {
  const TmuxWindow({
    required this.label,
    required this.cwd,
    required this.command,
  });

  final String label;
  final String cwd;
  final String command;
}

/// Builds a bash script that (re)creates a single tmux session with one window
/// per entry in [windows] and attaches to it. Written to a file and run as
/// `bash <file>` so nothing has to survive shell-quoting through the terminal
/// launcher.
///
/// A stale session of the same name is killed first so re-running is idempotent.
/// Returns an empty string when [windows] is empty.
String buildTmuxScript(String sessionName, List<TmuxWindow> windows) {
  if (windows.isEmpty) return '';
  final buffer = StringBuffer()
    ..writeln('#!/usr/bin/env bash')
    ..writeln('tmux kill-session -t ${_qq(sessionName)} 2>/dev/null || true');
  for (var i = 0; i < windows.length; i++) {
    final window = windows[i];
    final verb = i == 0
        ? 'new-session -d -s ${_qq(sessionName)}'
        : 'new-window -t ${_qq(sessionName)}';
    buffer.writeln(
      'tmux $verb -n ${_qq(window.label)} -c ${_qq(window.cwd)} '
      '${_qq(window.command)}',
    );
  }
  buffer.writeln('tmux attach -t ${_qq(sessionName)}');
  return buffer.toString();
}

/// A tmux-safe window/session name: lowercase, non-alphanumerics collapsed to
/// dashes, trimmed. tmux treats `.` and `:` specially in target names.
String tmuxSafeName(String raw, {String fallback = 'session'}) {
  final cleaned = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return cleaned.isEmpty ? fallback : cleaned;
}

/// Single-quotes a value for POSIX shells, escaping embedded single quotes.
String _qq(String value) => "'${value.replaceAll("'", r"'\''")}'";
