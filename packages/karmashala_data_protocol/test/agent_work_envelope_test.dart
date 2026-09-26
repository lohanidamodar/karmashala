import 'dart:convert';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The work the server does for its agents (slice 2a): usage, the signed-in
/// account, detection and the CLI import, through the envelope as JSON text.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 8);
  final installation = AgentInstallation(
    id: 'a1',
    agentId: 'codex',
    executable: const EnvironmentPath(environmentId: 'windows', path: 'c.exe'),
    version: '1.2',
    versionReadAt: t0,
    createdAt: t0,
  );
  final usage = AgentUsage(
    fetchedAt: t0,
    email: 'me@x.com',
    windows: [
      UsageWindow(
        label: '5-hour',
        percent: 41.5,
        resetsAt: t0.add(const Duration(hours: 2)),
        span: const Duration(hours: 5),
      ),
      const UsageWindow(label: 'weekly'),
    ],
  );
  final state = AccountUsageState(
    accountKey: 'codex@windows',
    agentId: 'codex',
    environmentId: 'windows',
    usage: usage,
    failure: UsageFailure(
      message: 'Rate limited.',
      kind: UsageFailureKind.rateLimited,
      until: t0.add(const Duration(minutes: 2)),
    ),
    nextAt: t0.add(const Duration(minutes: 3)),
  );
  final session = DetectedSession(
    cli: 'claude',
    sessionId: 's1',
    cwd: const EnvironmentPath(environmentId: 'windows', path: '/src/app'),
    filePath: '/h/.claude/projects/x/s1.jsonl',
    storeHome: '/h/.claude',
    title: 'Fix it',
    preview: 'fix the bug',
    modifiedAt: t0,
  );
  final project = DetectedProject(
    canonicalKey: 'windows:/src/app',
    displayPath: '/src/app',
    sessions: [session],
    subagentSessions: const [],
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
      DataEnvelope.readAnswer(
        overTheWire(
          DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
        ),
        request,
      );

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const UsageCurrent(),
      const UsageRefresh(),
      const UsageRefresh(accountKey: 'codex@windows'),
      const AccountsCurrent('a1'),
      const AccountsCapture('a1'),
      const AccountsSwitch(installationId: 'a1', accountId: 'c1'),
      const AgentsDetect(),
      const AgentsDetect(environmentId: 'wsl:Ubuntu'),
      const AgentsRepair(full: true),
      const AgentsRefreshVersions(),
      const AgentsDiscoverUnprobed(),
      const ImportsScan(),
      ImportsAdd([project]),
      const ImportsForRepositories(['r1', 'r2']),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(read.request, isA<AgentWorkRequest<Object?>>());
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
  });

  test('usage states carry the reading, the failure and the schedule', () {
    final back = roundTrip(const UsageCurrent(), [state]).value.single;
    expect(back.accountKey, 'codex@windows');
    expect(back.usage!.email, 'me@x.com');
    expect(back.usage!.windows.first.percent, 41.5);
    expect(back.usage!.windows.first.span, const Duration(hours: 5));
    expect(back.usage!.windows.last.percent, isNull);
    expect(back.failure!.kind, UsageFailureKind.rateLimited);
    expect(back.failure!.toException(t0).retryIn, const Duration(minutes: 2));
    expect(back.nextAt, t0.add(const Duration(minutes: 3)));
    expect(back.sameAs(state), isTrue);

    final change =
        DataChanges.fromJson(
              overTheWire(DataChanges(3, [UsageStateChanged(state)]).toJson()),
            ).changes.single
            as UsageStateChanged;
    expect(change.state.sameAs(state), isTrue);

    final agents = roundTrip(
      const AgentsList(),
      AgentsSnapshot(usage: [state]),
    ).value;
    expect(agents.usage.single.sameAs(state), isTrue);
  });

  test('a sign-in carries identity and expiry, never a token', () {
    final anthropic = roundTrip(
      const AccountsCurrent('a1'),
      AnthropicSignIn(
        ClaudeAuthSnapshot(
          environmentId: 'windows',
          email: 'me@x.com',
          organizationUuid: 'org',
          subscriptionType: 'max',
          accessTokenExpiresAt: t0,
        ),
        usableLogin: true,
      ),
    ).value;
    expect(anthropic, isA<AnthropicSignIn>());
    anthropic as AnthropicSignIn;
    expect(anthropic.snapshot.email, 'me@x.com');
    expect(anthropic.snapshot.accessTokenExpiresAt, t0);
    expect(anthropic.usableLogin, isTrue);

    final openAi = roundTrip(
      const AccountsCurrent('a1'),
      const OpenAiSignIn(
        CodexAuthSnapshot(environmentId: 'windows', accountId: 'acct'),
      ),
    ).value;
    expect((openAi as OpenAiSignIn).snapshot.isSignedIn, isTrue);
    expect(
      roundTrip(const AccountsCurrent('a1'), const NoSignIn()).value,
      isA<NoSignIn>(),
    );
    expect(roundTrip(const AccountsCapture('a1'), 'c9').value, 'c9');
  });

  test('detection reports read back whole', () {
    final report = AgentDiscoveryReport([
      EnvironmentScanReport(
        environmentId: 'windows',
        environmentName: 'This PC',
        reachable: true,
        found: [installation],
        missing: const ['Antigravity'],
        added: [installation],
        updated: const [
          AgentVersionChange(displayName: 'Codex', from: '1.1', to: '1.2'),
        ],
        movedPaths: const [
          AgentPathChange(displayName: 'Codex', from: 'a', to: 'b'),
        ],
      ),
      const EnvironmentScanReport.unreachable(
        environmentId: 'ssh:h1',
        environmentName: 'box',
        error: 'host key refused',
      ),
    ]);
    final back = roundTrip(const AgentsDetect(), report).value;
    expect(back.summary, report.summary);
    expect(back.installations, [installation]);
    expect(back.unreachable.single.error, 'host key refused');

    final repair = AgentPathRepairReport(
      checkedAt: t0,
      broken: [
        AgentPathReading(
          installation: installation,
          displayName: 'Codex',
          reading: const ExecutableReading(
            path: 'c.exe',
            reachability: ExecutableReachability.missing,
          ),
        ),
      ],
      unresolved: [
        AgentPathReading(
          installation: installation,
          displayName: 'Codex',
          reading: const ExecutableReading(
            path: 'c.exe',
            reachability: ExecutableReachability.missing,
          ),
        ),
      ],
      scan: report,
    );
    final repaired = roundTrip(const AgentsRepair(), repair).value;
    expect(repaired.summary, repair.summary);
    expect(repaired.scan!.summary, report.summary);
    expect(
      roundTrip(
        const AgentsRepair(),
        const AgentPathRepairReport.unchecked(),
      ).value.hasChecked,
      isFalse,
    );
    expect(
      '${roundTrip(const AgentsRefreshVersions(), const [AgentVersionChange(displayName: 'Codex', from: null, to: '2')]).value.single}',
      'Codex ? → 2',
    );
    expect(roundTrip(const AgentsDiscoverUnprobed(), [installation]).value, [
      installation,
    ]);
  });

  test('the import scan and its summary read back', () {
    final back = roundTrip(const ImportsScan(), [project]).value.single;
    expect(back.canonicalKey, project.canonicalKey);
    expect(back.sessions.single, session);
    expect(back.sessions.single.title, 'Fix it');
    expect(back.sessions.single.modifiedAt, t0);
    final summary = roundTrip(
      ImportsAdd([project]),
      const ImportSummary(projects: 1, repositories: 1, sessions: 2),
    ).value;
    expect(summary.sessions, 2);
    expect((summary + summary).projects, 2);
  });
}
