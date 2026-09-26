import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// The app's copy of the sessions domain (slice 1c): primed with the rest,
/// a write in the copy at once and at the server after, and every row the
/// server writes itself — a status the daemon recorded, another client's
/// rename — told as the narrowest `SessionChange`.
void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
  });

  Future<ProviderContainer> containerOf() async {
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    return container;
  }

  test('the copy is primed, and answers in the table\'s order', () async {
    server.sessionRows.insert(session(id: 'b'));
    server.sessionRows.insert(
      session(
        id: 'a',
      ).copyWith(createdAt: testTime.add(const Duration(seconds: 1))),
    );
    final sessions = await sessionsOf(server);
    expect(sessions.isPrimed, isTrue);
    expect([for (final s in sessions.getAll()) s.id], ['b', 'a']);
    expect(sessions.linksFor('b').single.isPrimary, isTrue);
  });

  test(
    'a write is in the copy at once and at the server once settled',
    () async {
      server.sessionRows.insert(session());
      final sessions = await sessionsOf(server);
      sessions.updateTitle('s1', 'Renamed', byUser: true);
      expect(sessions.getById('s1')!.title, 'Renamed');
      await sessions.settled();
      expect(server.sessionRows.getById('s1')!.titleByUser, isTrue);
      expect(server.requests, contains('sessions.edit'));
    },
  );

  test('a row the server writes itself wakes only what it moved', () async {
    server.sessionRows.insert(session());
    final container = await containerOf();
    container.read(sessionsDataProvider);
    final before = container.read(sessionSignalsProvider);

    server.sessionRows.updateStatus('s1', SessionStatus.running);
    final after = container.read(sessionSignalsProvider);
    expect(after.forSession('s1'), before.forSession('s1') + 1);
    expect(
      after.forKinds({SessionChangeKind.status}),
      before.forKinds({SessionChangeKind.status}) + 1,
    );
    expect(
      after.forKinds({SessionChangeKind.title}),
      before.forKinds({SessionChangeKind.title}),
    );
    expect(
      container.read(sessionsDataProvider).getById('s1')!.status,
      SessionStatus.running,
    );

    server.sessionRows.insert(session(id: 's2'));
    expect(
      container.read(sessionSignalsProvider).forKinds({
        SessionChangeKind.membership,
      }),
      after.forKinds({SessionChangeKind.membership}) + 1,
    );
  });

  test(
    'imported history hides what a row records, as the server does',
    () async {
      server.importedRows.insertIfAbsent(
        ImportedSession(
          id: 'i1',
          repositoryId: 'r1',
          cli: 'claude-code',
          externalId: 'conv',
          environmentId: 'windows',
          filePath: 'f',
          storeHome: 'h',
          isSubagent: false,
          preview: '',
          createdAt: testTime,
        ),
      );
      final container = await containerOf();
      final imported = container.read(importedSessionsProvider);
      expect(imported.getAll().single.id, 'i1');

      server.sessionRows.insert(session().copyWith(externalSessionId: 'conv'));
      expect(imported.getAll(), isEmpty);
      expect(imported.getById('i1'), isNotNull, reason: 'hidden, not deleted');
      expect(imported.supersedingSessionId('conv'), 's1');
    },
  );

  test('a refused write is read again whole', () async {
    server.sessionRows.insert(session());
    final container = await containerOf();
    final sessions = container.read(sessionsDataProvider);
    await expectLater(
      sessions.edit('s1', SessionPatch.rename('  ')),
      throwsA(anything),
    );
    await container.read(dataClientProvider).settled();
    await pumpEventQueue();
    expect(sessions.getById('s1')!.title, 'Work');
  });
}
