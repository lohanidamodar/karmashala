import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/notification_request.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';

const _coalescer = NotificationCoalescer();

PendingNotification _event(
  String id,
  NotificationReason reason, {
  String? label,
  bool imported = true,
  List<String> evidence = const [],
  AgentWaitKind waiting = AgentWaitKind.unrecorded,
}) => PendingNotification(
  session: WatchedSession(
    key: AgentSessionKey('claudeCode', id),
    label: label ?? 'Session $id',
    openId: 'row-$id',
    imported: imported,
  ),
  reason: reason,
  evidence: evidence,
  waiting: waiting,
);

void main() {
  test('nothing to say produces no notification', () {
    expect(_coalescer.summarize(const []), isNull);
  });

  test('one event names the session and carries where to open it', () {
    final request = _coalescer.summarize([
      _event(
        'a',
        NotificationReason.needsInput,
        label: 'Fix login',
        waiting: AgentWaitKind.approval,
      ),
    ])!;

    expect(request.title, 'Agent needs your approval');
    expect(request.body, 'Fix login');
    final payload = NotificationPayload.decode(request.payload)!;
    expect(payload.openId, 'row-a');
    expect(payload.imported, isTrue);
  });

  test('one event says what the agent asked for, when it said', () {
    // "Agent needs your approval" over a session name tells a user to go and
    // look; it does not tell them what they are about to authorise.
    final request = _coalescer.summarize([
      _event(
        'a',
        NotificationReason.needsInput,
        label: 'Fix login',
        evidence: const ['Claude needs your permission to use Bash'],
      ),
    ])!;

    expect(
      request.body,
      'Fix login \u2014 Claude needs your permission to use Bash',
    );
  });

  test('an idle nudge does not claim there is something to approve', () {
    // Claude Code's `Notification` fires for a permission prompt *and* for its
    // 60-second idle nudge. Both are honestly `awaitingApproval` — the user is
    // held up either way — so only the wait kind separates them. Saying
    // "needs your approval" for the nudge sent the owner looking for a button
    // that was never drawn.
    final nudge = _coalescer.summarize([
      _event(
        'a',
        NotificationReason.needsInput,
        label: 'Fix login',
        waiting: AgentWaitKind.input,
        evidence: const ['Claude is waiting for your input'],
      ),
    ])!;
    expect(nudge.title, 'Agent is waiting for you');

    final approval = _coalescer.summarize([
      _event(
        'b',
        NotificationReason.needsInput,
        label: 'Fix login',
        waiting: AgentWaitKind.approval,
        evidence: const ['Claude needs your permission to use Bash'],
      ),
    ])!;
    expect(approval.title, 'Agent needs your approval');
  });

  test('a wait kind nobody recorded takes the weaker sentence', () {
    // A surface that cannot tell must not be the one to claim a decision is
    // waiting.
    final request = _coalescer.summarize([
      _event('a', NotificationReason.needsInput, label: 'Fix login'),
    ])!;
    expect(request.title, 'Agent is waiting for you');
  });

  test('a quoted screen keeps its own order and is never picked apart', () {
    final request = _coalescer.summarize([
      _event(
        'a',
        NotificationReason.needsInput,
        label: 'Fix login',
        evidence: const ['  Run this command?  ', '', 'rm -rf build/'],
      ),
    ])!;

    expect(request.body, 'Fix login \u2014 Run this command? \u00b7 rm -rf build/');
  });

  test('a long quote is clipped at the end, not the middle', () {
    final request = _coalescer.summarize([
      _event(
        'a',
        NotificationReason.needsInput,
        label: 'S',
        evidence: [List.filled(80, 'ab').join()],
      ),
    ])!;

    expect(request.body, startsWith('S \u2014 abab'));
    expect(request.body, endsWith('\u2026'));
    expect(request.body.length, lessThan(140));
  });

  test('no evidence leaves the body exactly as it was', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished, label: 'Fix login'),
    ])!;

    expect(request.body, 'Fix login');
  });

  test('three agents finishing at once are one notification', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished, label: 'One'),
      _event('b', NotificationReason.finished, label: 'Two'),
      _event('c', NotificationReason.finished, label: 'Three'),
    ])!;

    expect(request.title, '3 agents finished');
    expect(request.body, 'One · Two · Three');
  });

  test('several sessions all waiting say so', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.needsInput, label: 'One'),
      _event('b', NotificationReason.failed, label: 'Two'),
    ])!;

    expect(request.title, '2 sessions need you');
  });

  test('a mixed burst does not claim they all need you', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished),
      _event('b', NotificationReason.needsInput),
    ])!;

    expect(request.title, '2 agent updates');
  });

  test('a long list names a few and counts the rest', () {
    final request = _coalescer.summarize([
      for (final id in ['a', 'b', 'c', 'd', 'e'])
        _event(id, NotificationReason.finished, label: id.toUpperCase()),
    ])!;

    expect(request.title, '5 agents finished');
    expect(request.body, 'A · B · C · +2 more');
  });

  test('a summary does not guess which session to open', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished),
      _event('b', NotificationReason.finished),
    ])!;

    expect(request.payload, isNull);
  });

  test(
    'one session moving twice is one line, described by its latest state',
    () {
      final request = _coalescer.summarize([
        _event('a', NotificationReason.finished, label: 'Only'),
        _event(
          'a',
          NotificationReason.needsInput,
          label: 'Only',
          waiting: AgentWaitKind.approval,
        ),
      ])!;

      expect(request.title, 'Agent needs your approval');
      expect(request.body, 'Only');
    },
  );

  group('payload encoding', () {
    test('round-trips both session kinds', () {
      for (final imported in [true, false]) {
        final encoded = NotificationPayload(
          openId: 'abc:def',
          imported: imported,
        ).encode();
        final decoded = NotificationPayload.decode(encoded)!;
        expect(decoded.openId, 'abc:def');
        expect(decoded.imported, imported);
      }
    });

    test('rejects anything it did not write', () {
      for (final raw in [null, '', 'abc', 'other:abc', ':abc', 'native:']) {
        expect(NotificationPayload.decode(raw), isNull, reason: 'raw=$raw');
      }
    });
  });
}
