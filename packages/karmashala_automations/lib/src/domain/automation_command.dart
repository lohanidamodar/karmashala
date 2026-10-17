import 'package:agent_cli/process.dart' show EnvironmentPath;

/// Which shell a command first step runs in. Only Windows has a choice; WSL,
/// SSH, macOS and Linux run it in the user's login shell there.
enum AutomationShell {
  powershell('powershell', 'PowerShell'),

  /// Values are read as `!NAME!`: cmd re-reads a `%NAME%` value as syntax.
  cmd('cmd', 'cmd'),
  login('login', 'Login shell');

  const AutomationShell(this.storedName, this.label);

  final String storedName;
  final String label;

  static AutomationShell fromStored(String? stored) => values.firstWhere(
    (shell) => shell.storedName == stored,
    orElse: () => AutomationShell.login,
  );
}

/// A shell command an automation runs as its first step instead of starting
/// an agent. Its text is never filled: values reach it as environment
/// variables only.
class AutomationCommand {
  const AutomationCommand({
    required this.text,
    this.shell = AutomationShell.login,
  });

  final String text;
  final AutomationShell shell;

  /// Why it cannot be saved, or null.
  String? get refusal {
    if (text.trim().isEmpty) return 'Say what command to run.';
    if (text.contains('{{')) {
      return 'A command never has variables put into it. Read them from the '
          'environment instead, as "\$KARMASHALA_AUTOMATION".';
    }
    if (shell == AutomationShell.cmd && _percentValue.hasMatch(text)) {
      return 'In cmd, read a value as !KARMASHALA_…!, never %KARMASHALA_…%: '
          'cmd reads a %…% value back as part of the command.';
    }
    return null;
  }

  AutomationCommand copyWith({String? text, AutomationShell? shell}) =>
      AutomationCommand(text: text ?? this.text, shell: shell ?? this.shell);

  Map<String, Object?> toJson() => {'text': text, 'shell': shell.storedName};

  /// Null for anything but a command object.
  static AutomationCommand? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String) return null;
    return AutomationCommand(
      text: text,
      shell: AutomationShell.fromStored(json['shell'] as String?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationCommand && other.text == text && other.shell == shell;

  @override
  int get hashCode => Object.hash(text, shell);

  @override
  String toString() => 'command(${shell.storedName})';
}

final RegExp _percentValue = RegExp('%KARMASHALA_', caseSensitive: false);

/// [folder] as JSON, or null.
Map<String, Object?>? folderToJson(EnvironmentPath? folder) => folder == null
    ? null
    : {'environmentId': folder.environmentId, 'path': folder.path};

/// Null for anything but a folder object with both halves.
EnvironmentPath? folderFromJson(Object? json) {
  if (json is! Map) return null;
  final environmentId = json['environmentId'];
  final path = json['path'];
  if (environmentId is! String || path is! String || environmentId.isEmpty) {
    return null;
  }
  return EnvironmentPath(environmentId: environmentId, path: path);
}

/// The home folder, which a new folder automation starts in.
const String kHomeFolder = '~';
