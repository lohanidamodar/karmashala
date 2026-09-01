import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/data/follow_up_dao.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The whole chain, from a session row that says `failed` to a line in the one
/// list the app has for things that need the user.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late SessionDao sessions;

  ProviderContainer mount() {
    final made = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // The status pipeline is not the subject here; the row is.
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(made.dispose);
    // The status bar watches this in the app; nothing below works unless
    // something does (Riverpod 3 pauses an unwatched provider's own listens).
    made.listen(attentionInboxProvider, (_, _) {});
    return made;
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    sessions = SessionDao(db);
    sessions.insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    container = mount();
  });
  tearDown(() => db.close());

  AttentionInbox inbox() => container.read(attentionInboxProvider);

  test('a session that stopped in error reaches the inbox', () {
    final item = inbox().items.single;
    expect(item.kind, InboxItemKind.followUp);
    expect(item.label, 'Fix login');
    expect(item.session.openId, 's1');
    expect(inbox().unseen, 1);
  });

  test('it is still there after a restart', () {
    expect(inbox().items, hasLength(1));
    container = mount();
    expect(inbox().items.single.kind, InboxItemKind.followUp);
  });

  test('dismissing it resolves the record, so it does not come back', () {
    final item = inbox().items.single;
    container.read(attentionInboxProvider.notifier).dismiss(item.id);
    expect(inbox().items, isEmpty);
    expect(FollowUpDao(db).open(), isEmpty);

    // A rebuild of the whole chain — the app's next launch — must not raise it
    // again. The session row still says `failed` and always will.
    container = mount();
    expect(inbox().items, isEmpty);
  });

  test('a new ending shows up without a restart', () {
    sessions.insert(
      session(id: 's2', title: 'Ship the parser', status: SessionStatus.failed),
    );
    container.read(sessionsRevisionProvider.notifier).bump();

    expect(
      inbox().items.map((i) => i.label),
      containsAll(['Fix login', 'Ship the parser']),
    );
  });

  test('looking at the session leaves the follow-up where it is', () {
    container.read(selectedSessionIdProvider.notifier).select('s1');
    expect(inbox().items.single.kind, InboxItemKind.followUp);
    expect(inbox().items.single.seen, isTrue);
  });
}
