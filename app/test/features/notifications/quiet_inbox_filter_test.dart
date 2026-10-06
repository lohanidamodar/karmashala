import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

InboxItem _item(String label, InboxItemKind kind, int minutesAgo) => InboxItem(
  session: WatchedSession(
    key: AgentSessionKey('claudeCode', 'cli-$label'),
    label: label,
    openId: 'open-$label',
    imported: false,
  ),
  kind: kind,
  at: testTime.subtract(Duration(minutes: minutesAgo)),
);

void main() {
  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    Future<ProviderContainer> pumpInbox(
      WidgetTester tester,
      NotifyLevel level,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = FakeDataServer()
        ..environmentRows.upsert(windowsEnv())
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(notificationSettingsControllerProvider.notifier)
          .setLevel(level);
      server.attention.setInbox(
        AttentionInbox(
          items: [
            _item('Broke the build', InboxItemKind.failed, 1),
            _item('Wrote the docs', InboxItemKind.finished, 5),
            _item('Green PR', InboxItemKind.readyToMerge, 9),
          ],
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: size.width,
                child: const AttentionInboxView(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('$name: Only when needed keeps quiet items out of the list '
        'until Show quiet', (tester) async {
      final container = await pumpInbox(tester, NotifyLevel.whenNeeded);

      expect(find.textContaining('Broke the build'), findsOneWidget);
      expect(find.textContaining('Wrote the docs'), findsNothing);
      expect(find.textContaining('Green PR'), findsNothing);
      expect(find.text('2 quiet · Show'), findsOneWidget);

      await tester.tap(find.text('2 quiet · Show'));
      await tester.pumpAndSettle();

      expect(container.read(inboxShowQuietProvider), isTrue);
      expect(find.text('QUIET'), findsOneWidget);
      expect(find.textContaining('Wrote the docs'), findsOneWidget);
      expect(find.textContaining('Green PR'), findsOneWidget);
      // Below what needs you, not mixed into it.
      expect(
        tester.getTopLeft(find.textContaining('Wrote the docs')).dy,
        greaterThan(
          tester.getTopLeft(find.textContaining('Broke the build')).dy,
        ),
      );
      // Newest first, as everywhere in the inbox.
      expect(
        tester.getTopLeft(find.textContaining('Green PR')).dy,
        greaterThan(
          tester.getTopLeft(find.textContaining('Wrote the docs')).dy,
        ),
      );

      await tester.tap(find.text('Hide quiet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Wrote the docs'), findsNothing);
    });

    testWidgets('$name: Everything lists every item as before', (tester) async {
      await pumpInbox(tester, NotifyLevel.everything);

      expect(find.textContaining('Broke the build'), findsOneWidget);
      expect(find.textContaining('Wrote the docs'), findsOneWidget);
      expect(find.textContaining('Green PR'), findsOneWidget);
      expect(find.textContaining('quiet'), findsNothing);
    });

    testWidgets('$name: with only quiet items, the empty list offers them', (
      tester,
    ) async {
      final container = await pumpInbox(tester, NotifyLevel.whenNeeded);
      container
          .read(attentionInboxProvider.notifier)
          .dismiss(_item('Broke the build', InboxItemKind.failed, 1).id);
      await tester.pumpAndSettle();

      expect(find.text('Nothing needs you.'), findsOneWidget);
      expect(find.text('2 quiet · Show'), findsOneWidget);
    });
  }
}
