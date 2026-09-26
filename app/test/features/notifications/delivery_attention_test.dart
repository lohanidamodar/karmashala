import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/delivery_attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/transitions.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// Delivery news, and the inbox it lands in.
///
/// The classifier is the same object that judges agent status, on purpose: an
/// inbox that used its own rules would list things no toast ever mentioned, and
/// the two counts would drift apart within a day.
void main() {
  const policy = AgentNotificationPolicy();
  const watched = WatchedSession(
    key: AgentSessionKey('claude', 'ext-1'),
    label: 'Fix the login',
    openId: 's1',
    imported: false,
  );

  SessionDelivery withPr({
    PullRequestState state = PullRequestState.open,
    ChecksSummary checks = ChecksSummary.none,
    ReviewDecision? review,
    bool? mergeable = true,
    bool draft = false,
  }) => SessionDelivery(
    branch: 'work',
    hasRemote: true,
    pullRequest: PullRequestSnapshot(
      number: 9,
      state: state,
      url: 'https://github.com/o/r/pull/9',
      isDraft: draft,
      mergeable: mergeable,
      reviewDecision: review,
      checks: checks,
    ),
  );

  NotificationReason? newsOf(SessionDelivery? from, SessionDelivery to) =>
      policy
          .newsInDelivery(
            DeliveryTransition(session: watched, from: from, to: to),
          )
          .reason;

  group('what counts as delivery news', () {
    test('checks going red', () {
      expect(
        newsOf(withPr(), withPr(checks: const ChecksSummary(failed: 1))),
        NotificationReason.checksFailed,
      );
    });

    test('a reviewer asking for changes', () {
      expect(
        newsOf(withPr(), withPr(review: ReviewDecision.changesRequested)),
        NotificationReason.changesRequested,
      );
    });

    test('a pull request becoming mergeable', () {
      expect(
        newsOf(
          withPr(checks: const ChecksSummary(pending: 1)),
          withPr(checks: const ChecksSummary(passed: 2)),
        ),
        NotificationReason.readyToMerge,
      );
    });

    test('the same state twice is not news', () {
      final red = withPr(checks: const ChecksSummary(failed: 1));
      expect(newsOf(red, red), isNull);
    });

    test('a first reading counts as news — it may have happened while the app '
        'was closed', () {
      expect(
        newsOf(null, withPr(checks: const ChecksSummary(failed: 1))),
        NotificationReason.checksFailed,
      );
    });

    test('a session with no pull request has no delivery news', () {
      expect(newsOf(null, const SessionDelivery(dirtyFiles: 4)), isNull);
    });

    test('a merged pull request is not news — it is finished', () {
      expect(newsOf(withPr(), withPr(state: PullRequestState.merged)), isNull);
    });

    test('a draft that is otherwise green is not ready to merge', () {
      expect(
        newsOf(
          withPr(),
          withPr(draft: true, checks: const ChecksSummary(passed: 1)),
        ),
        isNull,
      );
    });

    test(
      'one item per session: a red build outranks the review it also needs',
      () {
        expect(
          newsOf(
            null,
            withPr(
              checks: const ChecksSummary(failed: 1),
              review: ReviewDecision.changesRequested,
            ),
          ),
          NotificationReason.checksFailed,
        );
      },
    );

    test('and the blocker that remains after the build goes green is news of '
        'its own', () {
      final red = withPr(
        checks: const ChecksSummary(failed: 1),
        review: ReviewDecision.changesRequested,
      );
      final green = withPr(
        checks: const ChecksSummary(passed: 1),
        review: ReviewDecision.changesRequested,
      );
      expect(newsOf(red, green), NotificationReason.changesRequested);
    });
  });

  group('the inbox it lands in', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      SessionDao(db).insert(
        Session(
          id: 's1',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Fix the login',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime,
          externalSessionId: 'ext-1',
        ),
      );
    });
    tearDown(() => db.close());

    ProviderContainer harness() {
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a failing build becomes an inbox item', () {
      final container = harness();
      container
          .read(deliveryAttentionProvider.notifier)
          .observe('s1', withPr(checks: const ChecksSummary(failed: 1)));

      final item = container.read(attentionInboxProvider).items.single;
      expect(item.kind, InboxItemKind.checksFailed);
      expect(item.label, 'Fix the login');
      expect(item.menuLabel, 'Fix the login — checks failed');
      expect(container.read(attentionInboxProvider).unseen, 1);
    });

    test('the same reading again does not file a second item', () {
      final container = harness();
      final red = withPr(checks: const ChecksSummary(failed: 1));
      final notifier = container.read(deliveryAttentionProvider.notifier)
        ..observe('s1', red)
        ..observe('s1', red);
      expect(notifier, isNotNull);
      expect(container.read(attentionInboxProvider).items, hasLength(1));
    });

    test('an item that clears is not swept away by the agent watcher', () {
      final container = harness();
      container
          .read(deliveryAttentionProvider.notifier)
          .observe('s1', withPr(checks: const ChecksSummary(failed: 1)));

      // The status poller looks at the same session and sees nothing waiting.
      // A delivery item is an *event*, so it must survive that — the poller
      // knows nothing about pull requests.
      container
          .read(attentionInboxProvider.notifier)
          .apply(
            InboxUpdate(watched: {const AgentSessionKey('claude', 'ext-1')}),
          );
      expect(container.read(attentionInboxProvider).items, hasLength(1));
    });

    test('looking at the session retires it', () {
      final container = harness();
      container
          .read(deliveryAttentionProvider.notifier)
          .observe('s1', withPr(checks: const ChecksSummary(failed: 1)));

      container
          .read(attentionInboxProvider.notifier)
          .open(container.read(attentionInboxProvider).items.single);
      expect(container.read(attentionInboxProvider).items, isEmpty);
    });

    test('a session that has gone files nothing and does not throw', () {
      final container = harness();
      container
          .read(deliveryAttentionProvider.notifier)
          .observe('gone', withPr(checks: const ChecksSummary(failed: 1)));
      expect(container.read(attentionInboxProvider).items, isEmpty);
    });
  });
}
