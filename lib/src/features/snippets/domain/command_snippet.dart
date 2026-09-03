import '../../terminal/domain/terminal_profile.dart';

/// A command the user keeps, so that picking it is cheaper than retyping it.
///
/// ## Typed, not run
///
/// A snippet is delivered into a pane as **text at the prompt**, and [submit]
/// is what the user has to say to make it press Enter as well. The default is
/// false and it is the whole safety story of the feature: a library of saved
/// commands is exactly where `git reset --hard`, `rm -rf build` and
/// `docker system prune -af` accumulate, and it is picked from a fuzzy-matched
/// keyboard list where the wrong row is one arrow key away. Typing leaves the
/// last and cheapest gate — a human reading the line — in place, and costs the
/// user one keystroke.
///
/// It also makes trailing arguments free, which is why this pass ships no
/// templating: a snippet stored as `git checkout ` is typed, the caret is left
/// where the shell put it, and the branch name is the next thing the user
/// types. See `snippet_insertion.dart` for what a placeholder would have to
/// cost instead.
///
/// ## The shell tag
///
/// [shellId] names the shell this snippet is written for — `powerShell`,
/// `commandPrompt`, `wsl`, `posix` — or is null for one that fits anywhere.
/// It is stored as the *name string* rather than as a decoded [TerminalShell]
/// on purpose: a tag this build does not recognise must match **no** pane
/// rather than every pane, and an enum decoded with a fallback cannot express
/// that. A `wsl2` tag written by a future version is therefore invisible in a
/// PowerShell pane instead of appearing in it, and the library dialog still
/// lists it so it can be fixed.
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

  /// [shellId] as a shell this build knows, or null — which means *either*
  /// "fits every shell" or "names one this build has never heard of". The two
  /// are told apart by [hasUnknownShell]; nothing that filters needs to,
  /// because both answers make the same rows fit.
  TerminalShell? get shell {
    for (final value in TerminalShell.values) {
      if (value.name == shellId) return value;
    }
    return null;
  }

  /// Whether the tag names a shell this build cannot resolve.
  bool get hasUnknownShell => shellId != null && shell == null;

  /// Whether this snippet belongs in a pane running [paneShellId].
  ///
  /// Compared as strings, so an unrecognised tag matches nothing. A null tag
  /// matches everything; a pane whose own shell could not be determined
  /// (`paneShellId == null`) is offered only the untagged ones, which is the
  /// same rule read from the other side — neither party guesses.
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

/// [command] as the one line a PTY can be handed.
///
/// A stored newline would be a *submit* the user never asked for: a PTY reads
/// CR as "run this", so a two-line snippet typed into a shell runs its first
/// line whatever [CommandSnippet.submit] says. Every writer goes through here
/// — the dialog, the MCP tool — so there is one place that rule lives, and the
/// escape hatch for a genuinely multi-line command is the shell's own (`;`,
/// `&&`, a script file), which the user writes deliberately.
String singleLine(String command) =>
    command.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

/// How a shell tag is written in a picker: "PowerShell", "WSL", "Any shell".
String shellTagLabel(String? shellId) => switch (shellId) {
  null => 'Any shell',
  'powerShell' => 'PowerShell',
  'commandPrompt' => 'Command Prompt',
  'wsl' => 'WSL',
  'posix' => 'POSIX shell',
  // A tag from a build that knew more shells than this one. Shown as itself
  // rather than hidden: the library dialog is where it gets fixed.
  final other => other,
};
