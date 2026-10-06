import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/explorer/application/explorer_agent_filter.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// Archived sessions leave the lists unless "Show archived" is on, archiving
/// is one request for a whole selection, and sending to an archived session
/// brings it back first.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  Session row(
    String id, {
    SessionStatus status = SessionStatus.completed,
    DateTime? archivedAt,
    String? parent,
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work $id',
    useWorktree: false,
    status: status,
    createdAt: testTime,
    archivedAt: archivedAt,
    parentSessionId: parent,
  );

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows
      ..insert(row('done'))
      ..insert(row('hidden', archivedAt: testTime))
      ..insert(row('busy', status: SessionStatus.running));
    container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    await pumpEventQueue();
  });

  List<String> listed() => [
    for (final entry in container.read(workspaceSessionsProvider)) entry.id,
  ];

  test('the Sessions list hides archived sessions until the switch is on, and '
      'counts them', () async {
    final sub = container.listen(workspaceSessionsProvider, (_, _) {});
    addTearDown(sub.close);
    expect(listed(), unorderedEquals(['done', 'busy']));
    expect(container.read(archivedSessionCountProvider), 1);

    container.read(sessionListPrefsProvider.notifier).setShowArchived(true);
    expect(listed(), unorderedEquals(['done', 'hidden', 'busy']));
  });

  test('the project tree hides them too', () {
    final visible = container.read(visibleProjectSessionsProvider('p1'));
    expect(visible.sessions.native.map((s) => s.id), isNot(contains('hidden')));
    expect(visible.archived, 1);

    container.read(sessionListPrefsProvider.notifier).setShowArchived(true);
    expect(
      container
          .read(visibleProjectSessionsProvider('p1'))
          .sessions
          .native
          .map((s) => s.id),
      contains('hidden'),
    );
  });

  test('archiving a selection is one request; a live one is named', () async {
    server.requests.clear();
    final result = await container
        .read(sessionActionsProvider)
        .archiveSessions(['done', 'busy']);

    expect(server.requests.where((k) => k == SessionsArchive.name), hasLength(1));
    expect(result.changed, ['done']);
    expect(result.live.single.id, 'busy');
    expect(
      container.read(sessionsDataProvider).getById('done')!.isArchived,
      isTrue,
    );
    expect(container.read(sessionsDataProvider).getById('done')!.worktree, isNull);
  });

  test('unarchiving restores it', () async {
    await container.read(sessionActionsProvider).unarchiveSessions(['hidden']);
    expect(
      container.read(sessionsDataProvider).getById('hidden')!.isArchived,
      isFalse,
    );
  });

  test('sending to an archived session unarchives it first', () async {
    server.requests.clear();
    try {
      await container
          .read(sessionActionsProvider)
          .continueSession('hidden', 'carry on');
    } on Object {
      // The resume itself has no agent to start here; the unarchive is
      // what this asks about.
    }
    expect(server.requests.where((k) => k == SessionsUnarchive.name), hasLength(1));
    expect(
      container.read(sessionsDataProvider).getById('hidden')!.isArchived,
      isFalse,
    );
    // The writer announced it: the lists show it again.
    expect(
      container.read(sessionsRevisionProvider),
      isNot(0),
    );
  });

  test('opening an archived session shows it and resumes nothing', () async {
    server.requests.clear();
    final result = await container
        .read(explorerActionsProvider)
        .openNative('hidden');

    expect(result.outcome, ExplorerOutcome.selected);
    expect(result.message, contains('archived'));
    expect(container.read(selectedSessionIdProvider), 'hidden');
    expect(
      container.read(sessionsDataProvider).getById('hidden')!.isArchived,
      isTrue,
    );
    expect(server.requests.where((k) => k == SessionsUnarchive.name), isEmpty);
  });
}
