import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala/src/features/sessions/application/sub_session_fold.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fixtures.dart';

/// A parent's sub-sessions fold under it: counted, always folded by default,
/// and the person's choice kept per device.
void main() {
  Session row(String id, SessionStatus status) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: id,
    useWorktree: false,
    status: status,
    createdAt: testTime,
  );

  bool live(Session s) => s.status.claimsLive;

  test('counts every sub-session and the running ones, in words', () {
    final fold = SubSessionFold.of(row('p', SessionStatus.running), [
      for (var i = 0; i < 10; i++) row('done$i', SessionStatus.completed),
      row('a', SessionStatus.running),
      row('b', SessionStatus.idle),
    ], isLive: live);
    expect(fold.count, 12);
    expect(fold.running, 2);
    expect(fold.label, '12 sub-sessions · 2 running');
    expect(
      SubSessionFold.of(row('p', SessionStatus.completed), [
        row('c', SessionStatus.completed),
      ], isLive: live).label,
      '1 sub-session',
    );
  });

  test('always folded by default, whoever is still running', () {
    SubSessionFold fold(SessionStatus parent, List<SessionStatus> children) =>
        SubSessionFold.of(row('p', parent), [
          for (final (i, s) in children.indexed) row('c$i', s),
        ], isLive: live);

    for (final (parent, children) in [
      (SessionStatus.completed, [SessionStatus.running]),
      (SessionStatus.running, [SessionStatus.completed]),
      (SessionStatus.running, [SessionStatus.completed, SessionStatus.running]),
    ]) {
      final f = fold(parent, children);
      expect(f.foldedIn(const SessionListPrefs()), isTrue, reason: '$parent');
    }
  });

  test('the person\'s choice wins over the default', () {
    final fold = SubSessionFold.of(row('p', SessionStatus.completed), [
      row('c', SessionStatus.completed),
    ], isLive: live);
    expect(fold.foldedIn(const SessionListPrefs()), isTrue);
    expect(fold.foldedIn(const SessionListPrefs(folds: {'p': false})), isFalse);
  });

  test('the fold choices survive the device file round trip', () {
    final kept = SessionListPrefs.fromJson(
      const SessionListPrefs(
        showArchived: true,
        folds: {'p': false, 'q': true},
      ).toJson(),
    );
    expect(kept.showArchived, isTrue);
    expect(kept.folds, {'p': false, 'q': true});
  });
}
