import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_mcp_entry_service.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/agent_mcp_entry_section.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

class _StubReport extends AgentMcpEntryReportController {
  _StubReport(this._report);

  final AgentMcpEntryReport _report;

  @override
  AgentMcpEntryReport build() => _report;
}

class _RecordingService implements AgentMcpEntryService {
  final calls = <String>[];

  @override
  Future<AgentMcpEntryReport> removeAll() async {
    calls.add('remove');
    return AgentMcpEntryReport.unswept;
  }

  @override
  Future<AgentMcpEntryReport> restore() async {
    calls.add('restore');
    return AgentMcpEntryReport.unswept;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Settings → Agents and accounts: the agy entry, where it is, and the one
/// control — Remove it, or Add it back once removed.
void main() {
  final report = AgentMcpEntryReport([
    const AgentMcpEntry(
      agentId: 'antigravity',
      environmentId: 'wsl:Ubuntu',
      state: KarmashalaMcpEntryState.current,
      path:
          r'\\wsl.localhost\Ubuntu\home\someone\.gemini\config\mcp_config.json',
    ),
    const AgentMcpEntry(
      agentId: 'antigravity',
      environmentId: 'windows',
      state: KarmashalaMcpEntryState.foreign,
      path: '/home/someone/.gemini/config/mcp_config.json',
    ),
  ], checkedAt: testTime);

  Future<(ProviderContainer, _RecordingService)> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows
      ..upsert(posixEnv())
      ..upsert(wslEnv());
    final service = _RecordingService();
    final container = ProviderContainer(
      overrides: [
        await db.server.override(),
        agentMcpEntryReportProvider.overrideWith(() => _StubReport(report)),
        agentMcpEntryServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: AgentMcpEntrySection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, service);
  }

  testWidgets('names each file and offers Remove', (tester) async {
    final (container, service) = await pump(tester);

    expect(
      find.textContaining('Present for Antigravity in WSL · Ubuntu'),
      findsOneWidget,
    );
    expect(
      find.textContaining(r'.gemini\config\mcp_config.json'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Your own "karmashala" entry, left alone'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('mcp-entry-remove')));
    await tester.pump();
    expect(service.calls, ['remove']);

    container
        .read(settingsControllerProvider.notifier)
        .setAgentMcpEntries(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-entry-remove')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mcp-entry-restore')));
    await tester.pump();
    expect(service.calls, ['remove', 'restore']);
  });

  testWidgets('at 360 px and text scale 1.6 it fits', (tester) async {
    await pump(tester, size: const Size(360, 740), textScale: 1.6);

    expect(tester.takeException(), isNull);
    final button = tester.getRect(
      find.byKey(const ValueKey('mcp-entry-remove')),
    );
    expect(button.right, lessThanOrEqualTo(360));
  });
}
