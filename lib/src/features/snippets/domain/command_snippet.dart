import '../../terminal/domain/terminal_profile.dart';

/// A command the user keeps. Delivered as **text at the prompt**; [submit] is
/// what makes it press Enter. [shellId] is the raw name, so a tag this build
/// does not know matches *no* pane rather than every pane.
class CommandSnippet {
  const CommandSnippet({
    required this.id,
    required this.label,
    required this.command,
    required this.createdAt,
    required this.updatedAt,
    this.shellId,
    this.submit = false,
  });

  final String id;

  /// What it is called in a picker.
  final String label;

  /// The command itself, always a single line — see [singleLine].
  final String command;

  /// The shell this snippet is for, by [TerminalShell.name], or null for any.
  final String? shellId;

  /// Whether picking it also presses Enter. False unless the user said so.
  final bool submit;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// [shellId] as a shell this build knows, or null — either "fits every shell"
  /// or "names one this build has never heard of"; see [hasUnknownShell].
  TerminalShell? get shell {
    for (final value in TerminalShell.values) {
      if (value.name == shellId) return value;
    }
    return null;
  }

  /// Whether the tag names a shell this build cannot resolve.
  bool get hasUnknownShell => shellId != null && shell == null;

  /// Whether this snippet belongs in a pane running [paneShellId]. Compared as
  /// strings, so an unrecognised tag matches nothing and neither party guesses.
  bool fitsShell(String? paneShellId) =>
      shellId == null || shellId == paneShellId;

  CommandSnippet copyWith({
    String? label,
    String? command,
    String? shellId,
    bool clearShell = false,
    bool? submit,
    DateTime? updatedAt,
  }) => CommandSnippet(
    id: id,
    label: label ?? this.label,
    command: command ?? this.command,
    shellId: clearShell ? null : (shellId ?? this.shellId),
    submit: submit ?? this.submit,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is CommandSnippet &&
      other.id == id &&
      other.label == label &&
      other.command == command &&
      other.shellId == shellId &&
      other.submit == submit &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(id, label, command, shellId, submit, createdAt, updatedAt);
}

/// [command] as the one line a PTY can be handed: a stored newline is a CR,
/// which a PTY reads as *run this*, whatever [CommandSnippet.submit] says.
String singleLine(String command) =>
    command.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

/// How a shell tag is written in a picker: "PowerShell", "WSL", "Any shell".
String shellTagLabel(String? shellId) => switch (shellId) {
  null => 'Any shell',
  'powerShell' => 'PowerShell',
  'commandPrompt' => 'Command Prompt',
  'wsl' => 'WSL',
  'posix' => 'POSIX shell',
  'ssh' => 'SSH',
  // A tag from a build that knew more shells than this one. Shown as itself
  // rather than hidden: the library dialog is where it gets fixed.
  final other => other,
};
