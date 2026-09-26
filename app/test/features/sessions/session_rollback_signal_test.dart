import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// **The server's word over this app's own write is published** (slice 1c).
///
/// A write lands in the app's copy at once and its writer announces it. When
/// the server answers otherwise — a status for a session it runs is its own
/// to record, so it ignores the app's — the copy rolls back, and that roll
/// back is a change like any other: the narrowest [SessionChange], or every
/// watcher keeps showing the value the server refused.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;
  late SessionsData sessions;

  setUp(() async {
    server = FakeDataServer();
    server.sessionRows.insert(session(status: SessionStatus.running));
    container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    sessions = container.read(sessionsDataProvider);
  });

  SessionSignals signals() => container.read(sessionSignalsProvider);

  test('a status the server records itself rolls back, and says so', () async {
    server.runsSessions.add('s1');
    final before = signals();

    sessions.updateStatus('s1', SessionStatus.cancelled);
    expect(
      sessions.getById('s1')!.status,
      SessionStatus.cancelled,
      reason: 'the copy takes the write the moment it is asked',
    );
    await sessions.settled();

    expect(sessions.getById('s1')!.status, SessionStatus.running);
    final after = signals();
    expect(after.revision, before.revision + 1);
    expect(after.forKinds({SessionChangeKind.status}), 1);
    expect(after.forSession('s1'), before.forSession('s1') + 1);
  });

  test('only what the server overrode is published: the rest of the edit '
      'was the writer\'s to announce', () async {
    server.runsSessions.add('s1');
    final before = signals();

    await sessions.edit(
      's1',
      SessionPatch.status(
        SessionStatus.failed,
      ).and(SessionPatch.view(SessionView.chat)),
    );

    final row = sessions.getById('s1')!;
    expect(row.status, SessionStatus.running);
    expect(row.view, SessionView.chat);
    final after = signals();
    expect(after.revision, before.revision + 1);
    expect(after.byKind.keys, [SessionChangeKind.status]);
  });

  test('a write the server takes as asked publishes nothing more', () async {
    final before = signals();

    sessions.updateStatus('s1', SessionStatus.completed);
    await sessions.settled();

    expect(sessions.getById('s1')!.status, SessionStatus.completed);
    expect(signals().revision, before.revision);
  });
}
