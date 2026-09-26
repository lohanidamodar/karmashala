import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_terminal_core/profiles.dart';

export 'package:karmashala_snippets/karmashala_snippets.dart'
    show CommandSnippet, singleLine;

/// A snippet's tag read as a shell this build knows.
extension SnippetShell on CommandSnippet {
  /// Null for "fits every shell" or a tag this build has never heard of — see
  /// [hasUnknownShell].
  TerminalShell? get shell {
    for (final value in TerminalShell.values) {
      if (value.name == shellId) return value;
    }
    return null;
  }

  bool get hasUnknownShell => shellId != null && shell == null;
}

/// How a shell tag is written in a picker: "PowerShell", "WSL", "Any shell".
String shellTagLabel(String? shellId) => switch (shellId) {
  null => 'Any shell',
  'powerShell' => 'PowerShell',
  'commandPrompt' => 'Command Prompt',
  'wsl' => 'WSL',
  'posix' => 'POSIX shell',
  'ssh' => 'SSH',
  // A tag from a newer build: shown as itself, fixed in the library dialog.
  final other => other,
};
