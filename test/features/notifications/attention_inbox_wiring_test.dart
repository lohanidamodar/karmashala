import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/notifications/application/attention_inbox.dart';
import 'package:chitragupta/src/features/notifications/application/notification_providers.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
import 'package:chitragupta/src/features/notifications/domain/inbox_item.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_policy.dart';
import 'package:chitragupta/src/features/notifications/domain/session_attention.dart';
import 'package:chitragupta/src/features/notifications/domain/watched_session.dart';
import 'package:chitragupta/src/features/projects/application/projects_controller.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The inbox wired to the app: what marks an item seen, and the single count
/// the status bar, the rail and the tray all read.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  const key = AgentSessionKey('claudeCode', 'cli-1');
  const watched = WatchedSession(
    key: key,
    label: 'Fix login',
    openId: 's1',
    imported: false,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1'));
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  AttentionInboxController controller() =>
      container.read(attentionInboxProvider.notifier);

  // Not `const`: a const set literal may not hold a type that overrides `==`,
  // and `AgentSessionKey` does.
  void finished() => controller().apply(
    InboxUpdate(
      watched: {key},
      news: [(session: watched, reason: NotificationReason.finished)],
    ),
  );

  void waiting() => controller().apply(
    InboxUpdate(
      watched: {key},
      waiting: [
        SessionAttention(session: watched, kind: AttentionKind.needsInput),
      ],
    ),
  );

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

  test('opening an item walks to its project and repository', () {
    finished();
    final item = container.read(attentionInboxProvider).items.single;

    controller().open(item);

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
