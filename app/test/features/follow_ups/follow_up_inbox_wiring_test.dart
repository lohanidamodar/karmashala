import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// The whole chain, from a session row that says `failed` to a line in the one
/// list the app has for things that need the user.
void main() {
  late Override data;
  late ProviderContainer container;
  late FakeDataServer server;
  late FakeSessionRows sessions;

  /// The follow-ups the app raised or resolved, answered by the server.
  Future<void> settle() async {
    await container.read(sessionsDataProvider).settled();
    await Future<void>.delayed(Duration.zero);
  }

  ProviderContainer mount() {
    final made = ProviderContainer(
      overrides: [
        data,
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

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    data = await server.override();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    sessions = server.sessionRows;
    sessions.insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    container = mount();
    await settle();
  });

  AttentionInbox inbox() => container.read(attentionInboxProvider);

  test('a session that stopped in error reaches the inbox', () {
    final item = inbox().items.single;
    expect(item.kind, InboxItemKind.followUp);
    expect(item.label, 'Fix login');
    expect(item.session.openId, 's1');
    expect(inbox().unseen, 1);
  });

  test('it is still there after a restart', () async {
    expect(inbox().items, hasLength(1));
    container = mount();
    await settle();
    expect(inbox().items.single.kind, InboxItemKind.followUp);
  });

  test('dismissing it resolves the record, so it does not come back', () async {
    final item = inbox().items.single;
    container.read(attentionInboxProvider.notifier).dismiss(item.id);
    expect(inbox().items, isEmpty);
    await settle();
    expect(server.followUpRows.open(), isEmpty);

    // A rebuild of the whole chain — the app's next launch — must not raise it
    // again. The session row still says `failed` and always will.
    container = mount();
    await settle();
    expect(inbox().items, isEmpty);
  });

  test('a new ending shows up without a restart', () async {
    // Another client's row, reaching this app as the server's change.
    sessions.insert(
      session(id: 's2', title: 'Ship the parser', status: SessionStatus.failed),
    );
    inbox();
    await settle();

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
