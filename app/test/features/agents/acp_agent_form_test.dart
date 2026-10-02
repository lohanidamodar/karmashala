import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_form.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_providers.dart';

/// The custom ACP agent form's rules, and the registry platform key.
void main() {
  group('acpAgentFormRefusal', () {
    test('refuses a blank name first, then a blank command, in words', () {
      expect(
        acpAgentFormRefusal(name: '  ', command: 'x', environment: ''),
        'Give the agent a name.',
      );
      expect(
        acpAgentFormRefusal(name: 'A', command: ' ', environment: ''),
        'Say which command runs it.',
      );
      expect(
        acpAgentFormRefusal(name: 'A', command: 'x', environment: 'KEY'),
        'Environment line 1 needs KEY=value.',
      );
      expect(
        acpAgentFormRefusal(name: 'A', command: 'x', environment: 'K=v'),
        isNull,
      );
    });
  });

  group('parseEnvironmentLines', () {
    test('one KEY=value per line, blank lines skipped, later = kept', () {
      final parsed = parseEnvironmentLines('A=1\r\n\n  B = x=y \nC=');
      expect(parsed.refusal, isNull);
      expect(parsed.env, {'A': '1', 'B': 'x=y', 'C': ''});
    });

    test('names the line that is not KEY=value', () {
      expect(
        parseEnvironmentLines('A=1\nbroken').refusal,
        'Environment line 2 needs KEY=value.',
      );
      expect(
        parseEnvironmentLines('=value').refusal,
        'Environment line 1 needs KEY=value.',
      );
    });

    test('round-trips through the form text', () {
      const env = {'A': '1', 'B': 'two words'};
      expect(parseEnvironmentLines(formatEnvironmentLines(env)).env, env);
    });
  });

  group('acpRegistryPlatformFor', () {
    test('reads the registry key off the Dart build string', () {
      expect(
        acpRegistryPlatformFor(
          operatingSystem: 'windows',
          version: '3.9.0 (stable) (Tue Aug 12 2026) on "windows_x64"',
        ),
        'windows-x86_64',
      );
      expect(
        acpRegistryPlatformFor(
          operatingSystem: 'macos',
          version: '3.9.0 (stable) on "macos_arm64"',
        ),
        'darwin-aarch64',
      );
      expect(
        acpRegistryPlatformFor(
          operatingSystem: 'linux',
          version: '3.9.0 (stable) on "linux_x64"',
        ),
        'linux-x86_64',
      );
    });

    test('an unreadable build string still names the OS', () {
      expect(
        acpRegistryPlatformFor(operatingSystem: 'linux', version: '?'),
        'linux-x86_64',
      );
    });
  });
}
