import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_self_update_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_launch_arguments.dart';

import '../../support/permission_fixtures.dart';

/// The switch that stops a Karmashala-launched agent updating itself, as it
/// reaches the command line and the descriptor. The provider that resolves the
/// per-platform default is covered by `settings_self_update_test.dart`.
void main() {
  const registry = AgentRegistry.builtIn;
  final codexDefault = PermissionSelection.parse(codexDefaultStored)!;
  final claudeAsk = PermissionSelection.parse(claudeAskStored)!;

  group('the descriptors declare their self-update controls', () {
    test('Codex disables the startup check with a global -c override', () {
      final u = registry.byId(AgentIds.codex)!.launch.selfUpdate;
      expect(u.canSuppress, isTrue);
      expect(u.disableArguments, ['-c', 'check_for_update_on_startup=false']);
      expect(u.disableEnvironment, isEmpty);
      expect(u.updateCommand, ['codex', 'update']);
      expect(u.evidence, contains('check_for_update_on_startup'));
    });

    test('Claude Code disables it with an environment variable', () {
      final u = registry.byId(AgentIds.claudeCode)!.launch.selfUpdate;
      expect(u.canSuppress, isTrue);
      expect(u.disableArguments, isEmpty);
      expect(u.disableEnvironment, {'DISABLE_AUTOUPDATER': '1'});
      expect(u.updateCommand, ['claude', 'update']);
      expect(u.evidence.toLowerCase(), contains('disable_autoupdater'));
    });
  });

  group('agentPaneArguments and suppressSelfUpdate', () {
    test('Codex gets the -c override, left of any resume subcommand', () {
      final args = agentPaneArguments(
        registry.byId(AgentIds.codex),
        codexDefault,
        resumeSessionId: 'thread-1',
        suppressSelfUpdate: true,
      );
      // The global override precedes `resume`.
      final cIndex = args.indexOf('check_for_update_on_startup=false');
      final resumeIndex = args.indexOf('resume');
      expect(cIndex, greaterThan(0));
      expect(args[cIndex - 1], '-c');
      if (resumeIndex >= 0) expect(cIndex, lessThan(resumeIndex));
    });

    test('off, nothing about updates is on the Codex command line', () {
      final args = agentPaneArguments(
        registry.byId(AgentIds.codex),
        codexDefault,
        suppressSelfUpdate: false,
      );
      expect(args, isNot(contains('check_for_update_on_startup=false')));
    });

    test('Claude carries no update argument either way — it is env', () {
      final on = agentPaneArguments(
        registry.byId(AgentIds.claudeCode),
        claudeAsk,
        suppressSelfUpdate: true,
      );
      expect(on.join(' ').toLowerCase(), isNot(contains('autoupdater')));
      expect(on.join(' '), isNot(contains('check_for_update')));
    });
  });

  group('the app-server is always launched without the update check', () {
    test('the global override leads the arguments', () {
      expect(codexAppServerArguments.take(3), [
        '-c',
        'check_for_update_on_startup=false',
        'app-server',
      ]);
    });
  });

  group('the unset default is per platform', () {
    test('off on Windows, on elsewhere', () {
      // Where the harm was measured. macOS and Linux see a self-update as
      // unremarkable, so nothing is taken away there by default.
      expect(defaultLetAgentsUpdateThemselves(isWindows: true), isFalse);
      expect(defaultLetAgentsUpdateThemselves(isWindows: false), isTrue);
    });
  });
}
