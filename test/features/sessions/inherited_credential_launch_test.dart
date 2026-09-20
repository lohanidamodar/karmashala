import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/launch.dart';

/// Stands in for a real key. Nothing here may print it.
const _key = 'sk-ant-the-value-nothing-may-print';

const _stripped = {'ANTHROPIC_API_KEY'};

AgentPaneLaunch _claudePane({Set<String> removed = _stripped}) =>
    AgentPaneLaunch(
      agentId: 'claude',
      executable: r'C:\bin\claude.exe',
      sessionId: 's1',
      removedEnvironment: removed,
    );

void main() {
  group('the decision reaches the process', () {
    for (final entry in const <String, LaunchContext>{
      'a Windows-native pane': LaunchContext.windowsNative(),
      'a PowerShell pane': LaunchContext.powerShell(),
      'a cmd.exe pane': LaunchContext.commandPrompt(),
      'a POSIX pane': LaunchContext.posix(shell: '/bin/zsh'),
    }.entries) {
      test('${entry.key} carries the removal', () {
        final launch = agentPtyLaunchFor(
          _claudePane(),
          context: entry.value,
        );

        expect(launch.removedEnvironment, _stripped);
      });
    }

    test('a launch that decided nothing removes nothing', () {
      final launch = agentPtyLaunchFor(
        _claudePane(removed: const {}),
        context: const LaunchContext.windowsNative(),
      );

      expect(
        launch.removedEnvironment,
        isEmpty,
        reason: 'no decision must be byte-identical to before this existed',
      );
    });
  });

  group('the child environment', () {
    test('does not carry a key that was stripped', () {
      final env = ptyChildEnvironment(
        host: const {'ANTHROPIC_API_KEY': _key, 'Path': r'C:\Windows'},
        removed: _stripped,
        hostIsWindows: true,
      );

      expect(env.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(env.values, isNot(contains(_key)));
      expect(env['Path'], r'C:\Windows', reason: 'nothing else moved');
    });

    test('carries a key that was left alone', () {
      final env = ptyChildEnvironment(
        host: const {'ANTHROPIC_API_KEY': _key},
        hostIsWindows: true,
      );

      expect(env['ANTHROPIC_API_KEY'], _key);
    });

    test('strips any spelling on Windows, where names are case-blind', () {
      final env = ptyChildEnvironment(
        host: const {'anthropic_api_key': _key},
        removed: _stripped,
        hostIsWindows: true,
      );

      expect(env, isEmpty);
    });

    test('strips only the exact name on POSIX, where they are two variables', () {
      final env = ptyChildEnvironment(
        host: const {'anthropic_api_key': _key, 'ANTHROPIC_API_KEY': _key},
        removed: _stripped,
        hostIsWindows: false,
      );

      expect(env.keys, ['anthropic_api_key']);
    });

    test('a Karmashala setting wins over the removal', () {
      final env = ptyChildEnvironment(
        host: const {'ANTHROPIC_API_KEY': _key},
        extra: const {'ANTHROPIC_API_KEY': 'the-one-settings-shows'},
        removed: _stripped,
        hostIsWindows: true,
      );

      expect(
        env['ANTHROPIC_API_KEY'],
        'the-one-settings-shows',
        reason: 'Settings must never describe a child that got something else',
      );
    });
  });

  group('and nothing prints it', () {
    test('a launch names its variables by count, never by value', () {
      final launch = agentPtyLaunchFor(
        _claudePane(),
        context: const LaunchContext.windowsNative(),
        environment: const {'TOKEN': _key},
      );

      expect(launch.toString(), isNot(contains(_key)));
      expect(launch.toString(), isNot(contains('TOKEN')));
      expect(launch.toString(), contains('1 removed'));
    });
  });
}
