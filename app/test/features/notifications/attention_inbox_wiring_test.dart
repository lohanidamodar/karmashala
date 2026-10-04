import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// The inbox wired to the app: what marks an item seen, and the single count
/// the status bar, the rail and the tray all read.

/// The terminal's foreground panes, driven by hand so the listener under test
/// sees a real change rather than a fixed override. The pane is resolved to a
/// session through this window's own panes (`paneSessionsProvider`): a row's
/// `pane_id` names whichever window opened it last, so it is not believed.
class _ForegroundPanes extends Notifier<List<String>> {
  @override
  List<String> build() => const [];
  void show(List<String> paneIds) => state = paneIds;
}

final _foregroundProvider = NotifierProvider<_ForegroundPanes, List<String>>(
  _ForegroundPanes.new,
);

void main() {
  late TestMachine db;
  late ProviderContainer container;

  const key = AgentSessionKey('claudeCode', 'cli-1');
  const watched = WatchedSession(
    key: key,
    label: 'Fix login',
    openId: 's1',
    imported: false,
  );

  setUp(() async {
    db = TestMachine();
    final server = FakeDataServer().runsOn(db)
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(session(id: 's1'));
    db.server.sessionRows.updatePaneId('s1', 'pane-1');
    container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        foregroundTerminalPaneIdsProvider.overrideWith(
          (ref) => ref.watch(_foregroundProvider),
        ),
        // This window holds pane-1, launched for s1.
        paneSessionsProvider.overrideWithValue(
          PaneSessions.of(const {'pane-1': 's1'}),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  AttentionInboxController controller() =>
      container.read(attentionInboxProvider.notifier);

  // Not `const`: a const set literal may not hold a type that overrides `==`,
  // and `AgentSessionKey` does.
  void finished() =>
      FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
        InboxUpdate(
          watched: {key},
          news: [(session: watched, reason: NotificationReason.finished)],
        ),
      );

  void waiting() =>
      FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
        InboxUpdate(
          watched: {key},
          waiting: [
            SessionAttention(session: watched, kind: AttentionKind.needsInput),
          ],
        ),
      );

  test('an item carries the agent\'s own words, like the toast does', () {
    // The inbox is the panel you open *because* you missed the toast. It
    // showing less than the toast did was the wrong way round.
    FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
      InboxUpdate(
        watched: {key},
        news: [(session: watched, reason: NotificationReason.needsInput)],
        details: {key: 'Claude needs your permission to use Bash'},
      ),
    );

    expect(
      container.read(attentionInboxProvider).items.single.detail,
      'Claude needs your permission to use Bash',
    );
  });

  test('and says nothing rather than something invented', () {
    finished();
    expect(container.read(attentionInboxProvider).items.single.detail, isNull);
  });

  test('the attention count is the inbox\'s unseen count', () {
    expect(container.read(attentionCountProvider), 0);
    finished();
    expect(container.read(attentionCountProvider), 1);
    controller().markAllSeen();
    expect(container.read(attentionCountProvider), 0);
  });

  test('selecting the session while focused clears its finished turn', () {
    finished();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    expect(container.read(attentionInboxProvider).items, isEmpty);
    expect(container.read(attentionCountProvider), 0);
  });

  test('a session selected behind another window is not being looked at', () {
    container.read(windowFocusedProvider.notifier).set(false);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    finished();

    // The whole point of the inbox: a turn that finished while you were
    // elsewhere is still waiting for you when you come back.
    expect(container.read(attentionCountProvider), 1);

    container.read(windowFocusedProvider.notifier).set(true);
    expect(container.read(attentionCountProvider), 0);
  });

  test('going to the session\'s terminal tab clears its finished turn', () async {
    // The selection above is only ever set by the Explorer, quick open and the
    // inbox. Clicking a tab sets nothing, so before this the most ordinary way
    // of arriving at a session retired nothing.
    // Listened, as the tray keeps it in the app: an unlistened inbox is paused.
    container.listen(attentionInboxProvider, (_, _) {});
    finished();
    expect(container.read(attentionCountProvider), 1);

    container.read(_foregroundProvider.notifier).show(['pane-1']);
    await pumpEventQueue();

    expect(container.read(attentionInboxProvider).items, isEmpty);
    expect(container.read(attentionCountProvider), 0);
  });

  test('a tab on screen behind another window is not being looked at', () {
    container.read(windowFocusedProvider.notifier).set(false);
    container.read(_foregroundProvider.notifier).show(['pane-1']);
    finished();

    expect(container.read(attentionCountProvider), 1);
  });

  test('an approval in the tab you are looking at still stands', () {
    // Looking at an approval prompt does not answer it, so it retires on the
    // condition clearing and not on being seen.
    waiting();
    container.read(_foregroundProvider.notifier).show(['pane-1']);

    expect(container.read(attentionInboxProvider).items, hasLength(1));
  });

  test('an approval you looked at goes quiet but stays listed', () {
    waiting();
    container.read(selectedSessionIdProvider.notifier).select('s1');

    expect(container.read(attentionCountProvider), 0);
    expect(container.read(attentionInboxProvider).items, hasLength(1));
    expect(
      container.read(attentionInboxProvider).items.single.kind,
      InboxItemKind.needsApproval,
    );
  });

  test(
    'a turn that finishes on the session already on screen never queues',
    () {
      container.read(selectedSessionIdProvider.notifier).select('s1');
      finished();
      expect(container.read(attentionInboxProvider).items, isEmpty);
    },
  );

  test('opening an item walks to its project and repository, on the '
      "server's cue to every window", () async {
    finished();
    final item = container.read(attentionInboxProvider).items.single;

    controller().open(item);
    // Marked seen here at once; shown when the server says so.
    expect(container.read(attentionInboxProvider).items, isEmpty);
    await pumpEventQueue();

    expect(container.read(selectedProjectIdProvider), 'p1');
    expect(container.read(selectedRepositoryIdProvider), 'r1');
    expect(container.read(selectedSessionIdProvider), 's1');
    expect(container.read(attentionInboxProvider).items, isEmpty);
  });

  test('dismissing drops it without visiting the session', () {
    waiting();
    final item = container.read(attentionInboxProvider).items.single;
    controller().dismiss(item.id);

    expect(container.read(attentionInboxProvider).items, isEmpty);
    expect(container.read(selectedSessionIdProvider), isNull);
  });
}
