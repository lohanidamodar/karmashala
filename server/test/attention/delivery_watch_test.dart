import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_host/src/attention/delivery_watch.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Every live session's delivery, read by the server (slice 5c): the app's
/// two-minute pull-request poll, moved — so a PR going red is noticed, told
/// to every window and answered to a phone, with every app closed.
void main() {
  final now = DateTime.utc(2026, 9, 27, 12);
  late AppDatabase db;
  late List<GitWorkRequest<Object?>> asked;
  late List<DataChange> told;
  late List<(String, NotificationReason?)> news;
  late PullRequestReading forge;
  late DeliveryWatch watch;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'shop', 'local', '/src/shop', ?);",
      [now.toIso8601String()],
    );
    asked = [];
    told = [];
    news = [];
    forge = PullRequestReading(
      pullRequest: const PullRequestSnapshot(
        number: 7,
        state: PullRequestState.open,
        checks: ChecksSummary(passed: 3, failed: 1),
      ),
    );
    watch = DeliveryWatch(
      database: db,
      git: (request) async {
        asked.add(request);
        return switch (request) {
          GitDelivery() => const SessionDelivery(
            branch: 'fix-cart',
            hasRemote: true,
          ),
          GitHubPullRequest() => forge,
          _ => throw StateError('not asked here'),
        };
      },
      tell: told.addAll,
      news: (id, reason) => news.add((id, reason)),
      clock: () => now,
    );
  });

  tearDown(() {
    watch.stop();
    db.close();
  });

  void row(
    String id, {
    SessionStatus status = SessionStatus.running,
    bool archived = false,
    DateTime? createdAt,
  }) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Session $id',
      useWorktree: false,
      status: status,
      createdAt: createdAt ?? now,
      archivedAt: archived ? now : null,
    ),
  );

  test('a sweep reads each watched checkout once, local then forge, and '
      'judges every session there', () async {
    row('s1');
    row('s2');
    await watch.sweep();

    expect(
      asked.whereType<GitDelivery>(),
      hasLength(1),
      reason: 'one checkout',
    );
    final pr = asked.whereType<GitHubPullRequest>().single;
    expect(pr.branch, 'fix-cart');
    expect(news, [
      ('s1', NotificationReason.checksFailed),
      ('s2', NotificationReason.checksFailed),
    ]);
    expect(watch.stageOf('s1'), isNotNull);
    expect(watch.deliveryOf('s1')!.pullRequest!.number, 7);
  });

  test('a changed forge reading is told to every window, an unchanged one '
      'is not', () async {
    row('s1');
    await watch.sweep();
    await watch.sweep();
    final readings = told.whereType<ForgeReadingChanged>().toList();
    expect(readings, hasLength(1));
    expect(
      readings.single.checkout,
      const EnvironmentPath(environmentId: 'local', path: '/src/shop'),
    );
    expect(watch.greeting(), hasLength(1));

    forge = PullRequestReading.none;
    await watch.sweep();
    expect(told.whereType<ForgeReadingChanged>(), hasLength(2));
  });

  test('archived rows and old ended rows are not read', () async {
    row('gone', archived: true);
    row(
      'old',
      status: SessionStatus.completed,
      createdAt: now.subtract(const Duration(days: 30)),
    );
    await watch.sweep();
    expect(asked, isEmpty);
  });

  test('a branch with no remote asks the forge nothing', () async {
    row('s1');
    final local = DeliveryWatch(
      database: db,
      git: (request) async {
        asked.add(request);
        return const SessionDelivery(branch: 'wip', hasRemote: false);
      },
      tell: told.addAll,
      news: (id, reason) => news.add((id, reason)),
      clock: () => now,
    );
    await local.sweep();
    expect(asked.whereType<GitHubPullRequest>(), isEmpty);
    expect(news.single.$2, isNull);
  });

  test(
    'a turn ending in a checkout reads it again, at most once per floor',
    () async {
      row('s1');
      await watch.sweep();
      asked.clear();
      const touched = CheckoutTouched(
        environmentId: 'local',
        path: '/src/shop',
        cause: CheckoutTouchCause.turnEnded,
      );
      watch.changed(const [touched]);
      await Future<void>.delayed(Duration.zero);
      expect(asked, isEmpty, reason: 'read moments ago: inside the floor');
    },
  );

  test('a checkout git cannot read is skipped, not fatal', () async {
    row('s1');
    final broken = DeliveryWatch(
      database: db,
      git: (_) async => throw const DataRefused.unavailable('no route'),
      tell: told.addAll,
      news: (id, reason) => news.add((id, reason)),
      clock: () => now,
    );
    await broken.sweep();
    expect(news, isEmpty);
    expect(broken.stageOf('s1'), isNull, reason: 'could not tell');
  });
}
