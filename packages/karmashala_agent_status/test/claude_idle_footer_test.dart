import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:test/test.dart';

/// Claude Code 2.1.316's empty composer in each mode shift+tab cycles through,
/// captured by `server/test/live/claude_idle_footer_live_test.dart` (banner
/// rows dropped). Its default mode reads `⏸ manual mode on`, with no cycle key.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;

  for (final mode in ['auto', 'manual', 'accept-edits', 'plan']) {
    test('the idle composer in $mode mode reads idle', () {
      final rows = File(
        'test/fixtures/claude-code-idle-$mode-2.1.316.screen',
      ).readAsLinesSync();
      final keeper = HostedStatusKeeper(agents: AgentRegistry.builtIn)
        ..track('row-1', agentId: claude.id);
      final report = keeper.screen('row-1', rows)!.report;
      expect(report.status, AgentActivityStatus.idle);
      expect(report.waiting, AgentWaitKind.input);
      expect(report.source, AgentStatusSource.terminalGrid);
    });
  }
}
