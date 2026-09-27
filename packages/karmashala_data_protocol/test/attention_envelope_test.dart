import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

/// Session status and attention (slice 5c) — the status list, the inbox and
/// its verbs, a client's "looking at", a delivery reading, a session's checks
/// — and the changes the server tells, through the envelope as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(
      DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
    ),
    request,
  ).value;

  final at = DateTime.utc(2026, 9, 27, 10, 30);
  const session = WatchedSession(
    key: AgentSessionKey('claudeCode', 'conv-1'),
    label: 'Fix the build',
    openId: 'row-1',
    imported: false,
    paneId: 'pane-1',
  );
  const imported = WatchedSession(
    key: AgentSessionKey('codex', 'conv-2'),
    label: 'Old history',
    openId: 'imp-2',
    imported: true,
    stateFilePath: '/home/me/.codex/sessions/conv-2.jsonl',
  );
  final item = InboxItem(
    session: session,
    kind: InboxItemKind.needsApproval,
    at: at,
    detail: 'Allow Bash(git push)?',
  );
  final followUp = InboxItem(
    id: 'followUp:7',
    session: imported,
    kind: InboxItemKind.followUp,
    at: at,
    seen: true,
  );
  final report = AgentStatusReport(
    agentId: 'claudeCode',
    sessionId: 'conv-1',
    status: AgentActivityStatus.awaitingApproval,
    source: AgentStatusSource.hook,
    observedAt: at,
    evidence: const ['Allow Bash(git push)?'],
    waiting: AgentWaitKind.approval,
  );

  final requests = <DataRequest<Object?>>[
    const StatusList(),
    const InboxList(),
    const InboxDismiss('finished:claudeCode/conv-1'),
    const InboxOpen('needsApproval:claudeCode/conv-1'),
    const InboxSeen(['row-1', 'imp-2']),
    const InboxSeen([]),
    const InboxMarkAllSeen(),
    InboxRaise(item),
    const ChecksRun('row-1'),
  ];

  test('every request round-trips with its arguments', () {
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.runtimeType, request.runtimeType);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('a delivery reading is the server\'s own now: no client sends one', () {
    final read = DataEnvelope.readRequest({
      'id': 1,
      'kind': 'inbox.deliveryRead',
      'arguments': {'sessionId': 'row-1', 'news': 'checksFailed'},
    });
    expect(read.refusal?.code, DataRefusalCode.invalid);
  });

  test('a forge reading and a usage-limit notice round-trip', () {
    final batch = DataChanges.fromJson(
      overTheWire(
        DataChanges(6, [
          const ForgeReadingChanged(
            EnvironmentPath(environmentId: 'local', path: '/src/shop'),
            PullRequestReading.none,
          ),
          UsageLimitNoticed(
            UsageLimitNotice(
              sessionId: 'row-1',
              agentName: 'Codex',
              windowLabel: '5-hour',
              outcome: UsageLimitOutcome.scheduled,
              resetsAt: at,
              resumeId: 'r1',
              resumeFireAt: at.add(const Duration(minutes: 1)),
              resumeMessage: 'continue',
            ),
          ),
        ]).toJson(),
      ),
    );
    final forge = batch.changes[0] as ForgeReadingChanged;
    expect(forge.checkout.path, '/src/shop');
    expect(forge.reading.pullRequest, isNull);
    final notice = (batch.changes[1] as UsageLimitNoticed).notice;
    expect(notice.outcome, UsageLimitOutcome.scheduled);
    expect(notice.resetsAt, at);
    expect(notice.resumeMessage, 'continue');
  });

  test('answers round-trip', () {
    final status = roundTrip(
      const StatusList(),
      StatusSnapshot(
        entries: [SessionStatusEntry(session: session, report: report)],
        coverage: const WatchCoverage(
          tracked: 1,
          hookAnswered: 1,
          probeCandidates: 0,
          probed: 0,
          neverProbed: 0,
          probeFailures: 0,
          rotationPeriod: Duration(milliseconds: 1200),
        ),
      ),
    );
    expect(status.entries.single.session, session);
    expect(status.entries.single.report.status, report.status);
    expect(status.entries.single.report.evidence, report.evidence);
    expect(status.coverage!.rotationPeriod, const Duration(milliseconds: 1200));
    expect(status.coverage!.isBehind, isFalse);

    final inbox = roundTrip(
      const InboxList(),
      AttentionSnapshot(
        inbox: AttentionInbox(items: [item, followUp]),
        waiting: const [
          SessionAttention(session: session, kind: AttentionKind.needsInput),
        ],
      ),
    );
    expect(inbox.inbox.items, [item, followUp]);
    expect(inbox.inbox.unseen, 1);
    expect(inbox.waiting.single.session, session);

    final opened = roundTrip(
      InboxOpen(item.id),
      InboxOpened(item: item, stillListed: true, windows: 0),
    );
    expect(opened.item, item);
    expect(opened.stillListed, isTrue);
    expect(opened.windows, 0);

    final checks = roundTrip(
      const ChecksRun('row-1'),
      const SessionChecksRun(
        SessionChecksOutcome.refused,
        message: 'no route to the box',
      ),
    );
    expect(checks.outcome, SessionChecksOutcome.refused);
    expect(checks.message, 'no route to the box');
  });

  test('every change round-trips', () {
    final changes = <DataChange>[
      SessionStatusChanged(
        SessionStatusEntry(session: session, report: report),
      ),
      const SessionStatusRemoved('row-1'),
      const WatchCoverageChanged(
        WatchCoverage(
          tracked: 3,
          hookAnswered: 1,
          probeCandidates: 2,
          probed: 2,
          neverProbed: 0,
          probeFailures: 1,
          rotationPeriod: null,
        ),
      ),
      InboxChanged(AttentionSnapshot(inbox: AttentionInbox(items: [item]))),
      AttentionNewsTold(
        AttentionNews(
          session: session,
          reason: NotificationReason.needsInput,
          from: AgentActivityStatus.working,
          to: AgentActivityStatus.awaitingApproval,
          source: AgentStatusSource.hook,
          waiting: AgentWaitKind.approval,
          evidence: const ['Allow Bash(git push)?'],
        ),
      ),
      const InboxOpenWanted(openId: 'imp-2', imported: true, itemId: 'x'),
    ];
    final batch = DataChanges.fromJson(
      overTheWire(DataChanges(5, changes).toJson()),
    );
    expect(batch.changes.map((c) => c.runtimeType), [
      for (final change in changes) change.runtimeType,
    ]);
    final entry = (batch.changes[0] as SessionStatusChanged).entry;
    expect(entry.openId, 'row-1');
    expect(entry.report.waiting, AgentWaitKind.approval);
    expect((batch.changes[1] as SessionStatusRemoved).openId, 'row-1');
    final coverage = (batch.changes[2] as WatchCoverageChanged).coverage;
    expect(coverage.rotationPeriod, isNull);
    expect(coverage.isBehind, isTrue);
    expect(
      (batch.changes[3] as InboxChanged).snapshot.inbox.items.single,
      item,
    );
    final news = (batch.changes[4] as AttentionNewsTold).news;
    expect(news.transition.from, AgentActivityStatus.working);
    expect(news.pending.evidence, ['Allow Bash(git push)?']);
    final wanted = batch.changes[5] as InboxOpenWanted;
    expect(wanted.openId, 'imp-2');
    expect(wanted.imported, isTrue);
    expect(wanted.itemId, 'x');
  });
}
