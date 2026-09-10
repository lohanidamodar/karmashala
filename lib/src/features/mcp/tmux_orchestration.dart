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

/// Builds a bash script that opens one tmux window per entry in [windows] in a
/// tmux session named [sessionName], then attaches to it. Run as `bash <file>`
/// so nothing has to survive shell-quoting through the terminal launcher.
///
/// **Non-destructive**: an existing session of that name is left running and the
/// windows are appended with `-d`, so no attached client's focus moves.
String buildTmuxScript(String sessionName, List<TmuxWindow> windows) {
  if (windows.isEmpty) return '';
  final session = _qq(sessionName);
  final buffer = StringBuffer()
    ..writeln('#!/usr/bin/env bash')
    ..writeln('if tmux has-session -t $session 2>/dev/null; then');
  // Existing session: append each window without stealing focus (-d), so the
  // running tabs are untouched.
  for (final window in windows) {
    buffer.writeln(
      '  tmux new-window -d -t $session -n ${_qq(window.label)} '
      '-c ${_qq(window.cwd)} ${_qq(window.command)}',
    );
  }
  buffer.writeln('else');
  for (var i = 0; i < windows.length; i++) {
    final window = windows[i];
    final verb = i == 0
        ? 'new-session -d -s $session'
        : 'new-window -t $session';
    buffer.writeln(
      '  tmux $verb -n ${_qq(window.label)} -c ${_qq(window.cwd)} '
      '${_qq(window.command)}',
    );
  }
  buffer
    ..writeln('fi')
    ..writeln('tmux attach -t $session');
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
