import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The block a ConPTY child is started with, asserted without spawning: the
/// same function `ConPtyLauncher` builds its `CreateProcessW` block from.
void main() {
  test('a removed name is withheld from what serve itself inherited', () {
    final entries = conPtyEnvironmentEntries(
      base: const {
        'SystemRoot': r'C:\Windows',
        'anthropic_api_key': 'inherited by serve',
        'Path': r'C:\Windows\System32',
      },
      request: const PtySpawnRequest(
        argv: ['claude.exe'],
        environment: {'TERM': 'xterm-256color'},
        removedEnvironment: {'ANTHROPIC_API_KEY'},
      ),
    );
    // Windows names are case-insensitive, so the lower-case spelling is the
    // same variable and goes with it.
    expect(
      entries.where((e) => e.toLowerCase().startsWith('anthropic')),
      isEmpty,
    );
    expect(entries, contains(r'SystemRoot=C:\Windows'));
    expect(entries, contains('TERM=xterm-256color'));
  });

  test('removals come before overrides, so a supplied name survives', () {
    final entries = conPtyEnvironmentEntries(
      base: const {'ANTHROPIC_API_KEY': 'inherited'},
      request: const PtySpawnRequest(
        argv: ['claude.exe'],
        environment: {'ANTHROPIC_API_KEY': 'from settings'},
        removedEnvironment: {'ANTHROPIC_API_KEY'},
      ),
    );
    expect(entries, ['ANTHROPIC_API_KEY=from settings']);
  });

  test(
    'an override replaces a differently cased name and the block is sorted',
    () {
      final entries = conPtyEnvironmentEntries(
        base: const {'Path': 'old', 'b': '2', 'A': '1'},
        request: const PtySpawnRequest(
          argv: ['x'],
          environment: {'PATH': 'new'},
        ),
      );
      expect(entries, ['A=1', 'b=2', 'PATH=new']);
    },
  );
}
