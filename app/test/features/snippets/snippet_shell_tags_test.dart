import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/snippets/domain/command_snippet.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fixtures.dart';

/// A snippet's shell tag read against the shells this build knows. The store
/// and the string rule itself are `karmashala_snippets`' tests.
void main() {
  CommandSnippet snippet({String? shellId}) => CommandSnippet(
    id: 'sn1',
    label: 'Run the tests',
    command: 'flutter test',
    shellId: shellId,
    createdAt: testTime,
    updatedAt: testTime,
  );

  test('a known tag reads as its shell; an untagged one fits every pane', () {
    expect(snippet(shellId: 'wsl').shell, TerminalShell.wsl);
    for (final shell in TerminalShell.values) {
      expect(snippet().fitsShell(shell.name), isTrue);
    }
  });

  test('a tag from a newer build matches nothing rather than everything', () {
    final future = snippet(shellId: 'nushell');
    expect(future.hasUnknownShell, isTrue);
    expect(future.shell, isNull);
    for (final shell in TerminalShell.values) {
      expect(future.fitsShell(shell.name), isFalse);
    }
    expect(shellTagLabel('nushell'), 'nushell');
  });

  test('an SSH environment contributes a real SSH pane and tag', () {
    final profiles = terminalProfilesFor([
      windowsEnv(),
      sshEnvFixture(),
      wslEnv(distro: 'Ubuntu'),
    ]);
    expect(profiles.map((p) => p.shell).toSet(), {
      TerminalShell.powerShell,
      TerminalShell.commandPrompt,
      TerminalShell.wsl,
      TerminalShell.ssh,
    });
    expect(TerminalShell.values, hasLength(5));
    expect(shellTagLabel(TerminalShell.ssh.name), 'SSH');
  });
}
