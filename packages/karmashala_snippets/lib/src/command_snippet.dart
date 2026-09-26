/// A command the user keeps. Delivered as **text at the prompt**; [submit] is
/// what makes it press Enter. [shellId] is the raw shell name, so a tag this
/// build does not know matches *no* pane rather than every pane.
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
  final String label;

  /// Always a single line — see [singleLine].
  final String command;
  final String? shellId;
  final bool submit;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether this snippet belongs in a pane running [paneShellId]. Compared as
  /// strings, so an unrecognised tag matches nothing.
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

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'command': command,
    'shell': shellId,
    'submit': submit,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Throws [FormatException] on a row out of shape.
  static CommandSnippet fromJson(Map<String, Object?> json) {
    final id = json['id'], label = json['label'], command = json['command'];
    final shell = json['shell'], submit = json['submit'];
    final created = DateTime.tryParse('${json['createdAt']}');
    final updated = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String ||
        label is! String ||
        command is! String ||
        (shell != null && shell is! String) ||
        (submit != null && submit is! bool) ||
        created == null ||
        updated == null) {
      throw const FormatException('not a command snippet');
    }
    return CommandSnippet(
      id: id,
      label: label,
      command: command,
      shellId: shell as String?,
      submit: submit as bool? ?? false,
      createdAt: created.toUtc(),
      updatedAt: updated.toUtc(),
    );
  }

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

/// The table's order: oldest first, then by id.
int compareSnippets(CommandSnippet a, CommandSnippet b) {
  final byCreated = a.createdAt.compareTo(b.createdAt);
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

/// Why a snippet with [label] and [command] cannot be kept, or null.
String? snippetProblem({required String label, required String command}) {
  if (label.trim().isEmpty) return 'A snippet needs a label.';
  if (singleLine(command).isEmpty) return 'A snippet needs a command.';
  return null;
}
