import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/src/sessions/title_sync.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

import 'sync_fixture.dart';

/// The title sync at the server (slice 2b; moved from the app's
/// `SessionTitleSyncService`): an agent's own name for a conversation — a
/// `/rename` typed into `agy`, Claude Code's summary, a Codex thread name —
/// reaches the row on it while nobody has typed one, and every client is
/// told the row.
void main() {
  late SyncFixture world;

  setUp(() => world = SyncFixture());
  tearDown(() => world.close());

  Session row({
    String title = 'New session',
    String? externalId = 'c1',
    SessionStatus status = SessionStatus.running,
    bool titleByUser = false,
  }) => sessionRow(
    installation: 'a3',
    title: title,
    externalId: externalId,
    status: status,
    titleByUser: titleByUser,
  );

  TitleSync sync({bool Function(Session row)? isRunning}) =>
      TitleSync(rows: world.rows, isRunning: isRunning ?? (_) => false);

  group('a name the person typed into the CLI reaches every client', () {
    test('the reported case: /rename in agy, "New session" on the row', () {
      world.insert(row());
      final subject = sync();

      expect(subject.wantsStoreSweep, isTrue);
      expect(
        subject.sync([
          storeSession('c1', cli: AgentIds.antigravity, title: 'test me now'),
        ]),
        1,
      );
      expect(world.row('s1')!.title, 'test me now');
      expect(world.row('s1')!.titleByUser, isFalse);
      // Told as the row, which is what the conversation index feeds on.
      expect(world.toldRows, ['s1']);
    });

    test('it is not an Antigravity rule — Claude Code syncs the same way', () {
      world.insert(row());
      expect(sync().sync([storeSession('c1', title: 'Fix the crash')]), 1);
      expect(world.row('s1')!.title, 'Fix the crash');
    });

    test('the agent name adoption writes is a placeholder too', () {
      world.insert(row(title: 'Antigravity'));
      expect(sync().sync([storeSession('c1', title: 'test me now')]), 1);
      expect(world.row('s1')!.title, 'test me now');
    });

    test('so is a row with no title at all', () {
      world.insert(row(title: ''));
      expect(sync().sync([storeSession('c1', title: 'test me now')]), 1);
      expect(world.row('s1')!.title, 'test me now');
    });
  });

  group('what it refuses to overwrite', () {
    test('a title a person typed — and it costs nothing', () {
      world.insert(row(title: 'Ledger rewrite', titleByUser: true));
      final subject = sync();

      expect(subject.wantsStoreSweep, isFalse);
      expect(subject.sync([storeSession('c1', title: 'test me now')]), 0);
      expect(world.row('s1')!.title, 'Ledger rewrite');
    });

    test('a person\'s title survives a Codex rename', () {
      world.insert(row(title: 'Old app title', titleByUser: true));
      sync().sync([
        storeSession('c1', cli: AgentIds.codex, title: 'Renamed in Codex'),
      ]);
      expect(world.row('s1')!.title, 'Old app title');
      expect(world.row('s1')!.titleByUser, isTrue);
    });

    test('a preview, which is a summary and not a name', () {
      world.insert(row());
      expect(sync().sync([storeSession('c1', preview: 'wHAT ?')]), 0);
      expect(world.row('s1')!.title, 'New session');
      expect(world.told, isEmpty);
    });

    test('a row whose conversation the stores do not hold', () {
      world.insert(row());
      expect(sync().sync([storeSession('somebody-else', title: 'x')]), 0);
      expect(world.row('s1')!.title, 'New session');
    });

    test('a row with no conversation id, which nothing can be matched to', () {
      world.insert(row(externalId: null));
      final subject = sync();
      expect(subject.wantsStoreSweep, isFalse);
      expect(subject.sync([storeSession('c1', title: 'test me now')]), 0);
    });

    test('an archived row', () {
      world.insert(row());
      world.sessions.markArchived('s1', launchedAt);
      final subject = sync();
      expect(subject.wantsStoreSweep, isFalse);
      expect(subject.sync([storeSession('c1', title: 'test me now')]), 0);
    });
  });

  group('after the first sync', () {
    test('a second CLI rename still lands while the session runs', () {
      world.insert(row());
      final subject = sync();
      expect(subject.sync([storeSession('c1', title: 'test me now')]), 1);
      expect(subject.sync([storeSession('c1', title: 'final answer')]), 1);
      expect(world.row('s1')!.title, 'final answer');
    });

    test('the same name again writes nothing', () {
      world.insert(row());
      final subject = sync();
      subject.sync([storeSession('c1', title: 'test me now')]);
      expect(subject.sync([storeSession('c1', title: 'test me now')]), 0);
      expect(world.toldRows, ['s1']);
    });

    test('but a person\'s rename settles the row for good', () {
      world.insert(row());
      final subject = sync();
      subject.sync([storeSession('c1', title: 'test me now')]);
      world.sessions.updateTitle('s1', 'Ledger rewrite', byUser: true);

      expect(subject.wantsStoreSweep, isFalse);
      expect(subject.sync([storeSession('c1', title: 'final answer')]), 0);
      expect(world.row('s1')!.title, 'Ledger rewrite');
    });

    test('and a session that has stopped is no longer watched', () {
      world.insert(row());
      final subject = sync();
      subject.sync([storeSession('c1', title: 'test me now')]);
      world.sessions.updateStatus('s1', SessionStatus.completed);

      expect(subject.wantsStoreSweep, isFalse);
      expect(subject.sync([storeSession('c1', title: 'final answer')]), 0);
      expect(world.row('s1')!.title, 'test me now');
    });
  });

  group('a restart forgets nothing: whose title it is is on the row', () {
    test('a second /rename on a new server run still lands', () {
      world.insert(row(title: 'chitragupta'));
      final subject = sync();
      expect(subject.wantsStoreSweep, isTrue);
      expect(subject.sync([storeSession('c1', title: 'karmashala')]), 1);
      expect(world.row('s1')!.title, 'karmashala');
    });

    test('a stopped session is left alone, restart or not', () {
      world.insert(row(title: 'chitragupta', status: SessionStatus.completed));
      final subject = sync();
      expect(subject.wantsStoreSweep, isFalse);
      expect(subject.sync([storeSession('c1', title: 'karmashala')]), 0);
    });
  });

  group('running is what runs it, not only what the row says', () {
    test('a settled row whose agent runs again is followed', () {
      world.insert(
        row(title: 'karmashala revisits', status: SessionStatus.completed),
      );
      final renamed = sync(
        isRunning: (row) => row.id == 's1',
      ).sync([storeSession('c1', title: 'karmashala enhanced')]);

      expect(renamed, 1);
      expect(world.row('s1')!.title, 'karmashala enhanced');
    });

    test('with nothing running it, a settled CLI name stays settled', () {
      world.insert(
        row(title: 'karmashala revisits', status: SessionStatus.completed),
      );
      expect(
        sync().sync([storeSession('c1', title: 'karmashala enhanced')]),
        0,
      );
    });
  });
}
