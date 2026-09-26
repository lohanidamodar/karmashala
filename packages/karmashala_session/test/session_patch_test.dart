import 'package:agent_cli/process.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:test/test.dart';

/// The session values on the wire (slice 1c), and what each change a client
/// may ask does to a row — the one rule the server and a client's copy both
/// apply.
void main() {
  final at = DateTime.utc(2026, 9, 26, 12);
  const dir = EnvironmentPath(environmentId: 'windows', path: r'C:\src');
  final full = Session(
    id: 's1',
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work',
    useWorktree: true,
    worktree: dir,
    workingDirectory: dir,
    status: SessionStatus.running,
    createdAt: at,
    externalSessionId: 'conv',
    parentSessionId: 'p',
    parentLink: SessionLink.handoff,
    paneId: 'pane',
    surface: SessionSurface.pane,
    view: SessionView.chat,
    permissionMode: 'plan',
    modelId: 'opus',
    archivedAt: at,
    titleByUser: true,
  );

  test('every value round-trips through JSON', () {
    expect(Session.fromJson(full.toJson()), full);
    final bare = Session(
      id: 's2',
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Bare',
      useWorktree: false,
      status: SessionStatus.created,
      createdAt: at,
    );
    expect(Session.fromJson(bare.toJson()), bare);
    final event = SessionEvent(
      id: 3,
      sessionId: 's1',
      seq: 2,
      type: 'message.user',
      payload: '{}',
      createdAt: at,
    );
    expect(SessionEvent.fromJson(event.toJson()), event);
    final decision = DecisionRecord(
      id: 1,
      sessionId: 's1',
      sequence: 1,
      kind: DecisionKind.approachRejected,
      summary: 'No',
      detail: 'because',
      origin: DecisionOrigin.decisionTool,
      recordedAt: at,
    );
    expect(DecisionRecord.fromJson(decision.toJson()), decision);
    final recap = SessionRecap(
      sessionId: 's1',
      text: 't',
      agentId: 'claude-code',
      turnCount: 4,
      writtenAt: at,
    );
    expect(SessionRecap.fromJson(recap.toJson()), recap);
    final followUp = FollowUp(
      id: 7,
      sessionId: 's1',
      reason: FollowUpReason.endedInFailure,
      ending: SessionEnding.failed,
      raisedAt: at,
      resolvedAt: at,
      resolution: FollowUpResolution.dismissed,
    );
    expect(FollowUp.fromJson(followUp.toJson()), followUp);
    const link = SessionRepositoryLink(repositoryId: 'r1', role: 'primary');
    expect(SessionRepositoryLink.fromJson(link.toJson()), link);
  });

  test('a word this build does not know reads as the store reads it', () {
    final json = full.toJson()
      ..['status'] = 'hibernating'
      ..['surface'] = 'hologram'
      ..['view'] = 'vr';
    final read = Session.fromJson(json);
    expect(read.status, SessionStatus.unknown);
    expect(read.surface, SessionSurface.external);
    expect(read.view, SessionView.terminal);
  });

  group('a patch', () {
    test('writes only the columns it names', () {
      final renamed = SessionPatch.rename('New', byUser: false).applyTo(full);
      expect(renamed.title, 'New');
      expect(renamed.titleByUser, isFalse);
      expect(renamed.copyWith(title: 'Work', titleByUser: true), full);
    });

    test('writes null where none is a value', () {
      final cleared = SessionPatch.pane(null)
          .and(SessionPatch.permissionMode(null))
          .and(SessionPatch.model(''))
          .and(SessionPatch.directory(null))
          .applyTo(full);
      expect(cleared.paneId, isNull);
      expect(cleared.permissionMode, isNull);
      expect(cleared.modelId, isNull);
      expect(cleared.workingDirectory, isNull);
      expect(cleared.worktree, dir, reason: 'the worktree is never touched');
    });

    test('names its status, and can drop it', () {
      final patch = SessionPatch.status(
        SessionStatus.failed,
      ).and(SessionPatch.view(SessionView.terminal));
      expect(patch.status, SessionStatus.failed);
      expect(patch.withoutStatus().status, isNull);
      expect(patch.withoutStatus().applyTo(full).status, SessionStatus.running);
      expect(SessionPatch.none.isEmpty, isTrue);
      expect(SessionPatch.none.applyTo(full), full);
    });

    test('travels through JSON, and one out of shape is refused', () {
      final patch = SessionPatch.archive(at)
          .and(SessionPatch.attribute('conv-2'))
          .and(SessionPatch.worktree(useWorktree: false));
      final back = SessionPatch.fromJson(patch.toJson());
      expect(back.applyTo(full), patch.applyTo(full));
      expect(() => SessionPatch.fromJson({'id': 'x'}), throwsFormatException);
      expect(() => SessionPatch.fromJson({'title': 3}), throwsFormatException);
      expect(
        () => SessionPatch.fromJson({'status': 'nonsense'}),
        throwsFormatException,
      );
    });
  });

  test('links sort the primary first', () {
    expect(
      [
        for (final l in orderedLinks(const [
          SessionRepositoryLink(repositoryId: 'a', role: 'additional'),
          SessionRepositoryLink(repositoryId: 'z', role: 'primary'),
        ]))
          l.repositoryId,
      ],
      ['z', 'a'],
    );
  });
}
