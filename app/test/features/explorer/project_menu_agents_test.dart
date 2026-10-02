import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala_ui/menus.dart';

import '../../support/fixtures.dart';

/// The project menu's "New session with …" entries: one per agent installed
/// here, only when there is a choice, and never for an installation whose
/// agent the registry no longer knows — a removed ACP agent's leftover row
/// would otherwise show as its raw id.
void main() {
  final claude = agentInstallation(id: 'a', agentId: AgentIds.claudeCode);
  final codex = agentInstallation(
    id: 'b',
    agentId: AgentIds.codex,
    path: r'C:\codex.exe',
  );
  final ghost = agentInstallation(
    id: 'ghost',
    agentId: 'acp:gone',
    path: r'C:\gone.exe',
  );

  List<String> valuesOf(List<PopupMenuEntry<String>> items) => [
    for (final item in items) (item as DesktopMenuItem<String>).value!,
  ];

  test('skips an installation of an agent the registry does not know', () {
    final items = newSessionWithItems([
      claude,
      codex,
      ghost,
    ], AgentRegistry.builtIn);
    expect(valuesOf(items), ['new-with:a', 'new-with:b']);
    for (final item in items) {
      expect((item as DesktopMenuItem<String>).label, isNot(contains('acp:')));
    }
  });

  test('a forgotten agent beside one known is no choice', () {
    expect(
      newSessionWithItems([claude, ghost], AgentRegistry.builtIn),
      isEmpty,
    );
  });
}
