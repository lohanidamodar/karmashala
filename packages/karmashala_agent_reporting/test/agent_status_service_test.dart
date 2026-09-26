import 'dart:io';

import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'support/fakes.dart';
import 'support/temp_directory.dart';

void main() {
  final now = DateTime.utc(2026, 8, 29, 12);

  late Directory tmp;
  late AgentHookReports reports;
  late AgentStatusService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_svc_');
    reports = AgentHookReports();
    service = AgentStatusService(
      registry: AgentRegistry.builtIn,
      hookReports: reports,
      clock: FixedClock(now),
    );
  });
  tearDown(() => removeTempDirectory(tmp));

  /// A Claude transcript whose last record says the agent finished its turn.
  String idleTranscript() {
    final file = File(p.join(tmp.path, 'a.jsonl'))..createSync();
    file.writeAsStringSync('{"type":"assistant","message":{"content":"x"}}\n');
    return file.path;
  }

  void recordHook(AgentActivityStatus status, {required DateTime at}) {
    reports.record(
      AgentStatusReport(
        agentId: 'claudeCode',
        sessionId: 's1',
        status: status,
        source: AgentStatusSource.hook,
        observedAt: at,
      ),
    );
  }

  test('an unknown agent is unknown, sourced from nothing', () async {
    final report = await service.statusFor(
      const AgentStatusQuery(agentId: 'nobody', sessionId: 's1'),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(report.source, AgentStatusSource.none);
    expect(report.agentId, 'nobody');
    expect(report.sessionId, 's1');
  });

  test('a fresh hook report beats a contradicting state file', () async {
    recordHook(
      AgentActivityStatus.awaitingApproval,
      at: now.subtract(const Duration(seconds: 30)),
    );

    final report = await service.statusFor(
      AgentStatusQuery(
        agentId: 'claudeCode',
        sessionId: 's1',
        stateFilePath: idleTranscript(),
      ),
    );

    expect(report.status, AgentActivityStatus.awaitingApproval);
    expect(report.source, AgentStatusSource.hook);
  });

  test('a stale hook report is ignored and the state file decides', () async {
    recordHook(
      AgentActivityStatus.awaitingApproval,
      at: now.subtract(const Duration(hours: 2)),
    );

    final report = await service.statusFor(
      AgentStatusQuery(
        agentId: 'claudeCode',
        sessionId: 's1',
        stateFilePath: idleTranscript(),
      ),
    );

    expect(report.status, AgentActivityStatus.idle);
    expect(report.source, AgentStatusSource.stateFile);
  });

  test('the state-file report carries the queried session id', () async {
    final report = await service.statusFor(
      AgentStatusQuery(
        agentId: 'claudeCode',
        sessionId: 's1',
        stateFilePath: idleTranscript(),
      ),
    );

    expect(report.sessionId, 's1');
  });

  test('no hook and no state file is unknown', () async {
    final report = await service.statusFor(
      const AgentStatusQuery(agentId: 'claudeCode', sessionId: 's1'),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(report.source, AgentStatusSource.none);
  });

  test('a missing state file is unknown, not an error', () async {
    final report = await service.statusFor(
      AgentStatusQuery(
        agentId: 'claudeCode',
        sessionId: 's1',
        stateFilePath: p.join(tmp.path, 'gone.jsonl'),
      ),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(report.source, AgentStatusSource.none);
  });

  test('a grid-scraping agent is unknown until that source exists', () async {
    const cursor = AgentDescriptor(
      id: 'cursorAgent',
      displayName: 'Cursor Agent',
      binaries: AgentBinaries(windows: ['cursor'], posix: ['cursor']),
      statusStrategy: AgentStatusStrategy.terminalGrid,
    );
    final gridService = AgentStatusService(
      registry: const AgentRegistry([DataOnlyAgentAdapter(cursor)]),
      hookReports: reports,
      clock: FixedClock(now),
    );

    final report = await gridService.statusFor(
      AgentStatusQuery(
        agentId: 'cursorAgent',
        sessionId: 's1',
        stateFilePath: idleTranscript(),
      ),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(report.source, AgentStatusSource.none);
  });

  group('a menu drawn after the turn ended', () {
    // Claude Code 2.1.283 draws its startup offers under the idle footer after
    // a turn, with no hook of its own; the turn's `Stop` is then older than
    // the menu on screen.
    const menuScreen = [
      '  \u23f5\u23f5 auto mode on (shift+tab to cycle) \u00b7 \u2190 for agents',
      '',
      ' Teach auto mode about your environment?',
      '',
      ' \u276f 1. Yes',
      '   2. Not now',
      "   3. Don't show again",
      '',
      ' Enter to confirm \u00b7 Esc to cancel',
    ];

    test('outranks a fresh idle hook', () async {
      recordHook(
        AgentActivityStatus.idle,
        at: now.subtract(const Duration(seconds: 5)),
      );
      final report = await service.statusFor(
        const AgentStatusQuery(
          agentId: 'claudeCode',
          sessionId: 's1',
          terminalTailLines: menuScreen,
        ),
      );
      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.waiting, AgentWaitKind.approval);
      expect(report.source, AgentStatusSource.terminalGrid);
    });

    test('does not outrank a fresh hook that the turn is running', () async {
      recordHook(
        AgentActivityStatus.working,
        at: now.subtract(const Duration(seconds: 5)),
      );
      final report = await service.statusFor(
        const AgentStatusQuery(
          agentId: 'claudeCode',
          sessionId: 's1',
          terminalTailLines: menuScreen,
        ),
      );
      expect(report.status, AgentActivityStatus.working);
      expect(report.source, AgentStatusSource.hook);
    });
  });
}
