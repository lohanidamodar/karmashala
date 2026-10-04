import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart' show SessionInfoUpdate;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_titles.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../sessions/sync_fixture.dart';
import 'acp_fixture.dart';

/// `session_info_update`: the session's title follows the agent's, unless a
/// person typed one (the row's `title_by_user` wins), and every client is told
/// the row.
void main() {
  group('the runtime', () {
    late AppDatabase database;
    late Directory temp;
    late _TitlesHost host;

    setUp(() {
      database = AppDatabase.memory();
      database.execute('PRAGMA foreign_keys = OFF;');
      temp = Directory.systemTemp.createTempSync('acp_titles_test');
      host = _TitlesHost();
    });

    tearDown(() {
      database.close();
      temp.deleteSync(recursive: true);
    });

    test('hands on each title the agent gives, and nothing without one', () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: [
            const FakeTurn([
              FakeStep.update(SessionInfoUpdate(title: 'Fix the login bug')),
              FakeStep.update(SessionInfoUpdate(updatedAt: '2026-10-04T00:00Z')),
              FakeStep.update(SessionInfoUpdate(title: '  ')),
              FakeStep.message('On it.'),
            ]),
          ],
        ),
      );
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
      );
      await runtime.start();
      await runtime.send('fix it');
      await runtime.awaitTurn();
      await pump();
      expect(host.titles, [('s1', 'Fix the login bug')]);
      await runtime.stop();
    });

    test('a title told while the session loads is kept too', () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          loadReplay: const [SessionInfoUpdate(title: 'Earlier work')],
        ),
      );
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
        resumeSessionId: 'earlier',
      );
      await runtime.start();
      await pump();
      expect(host.titles, [('s1', 'Earlier work')]);
      await runtime.stop();
    });
  });

  group('the row', () {
    late SyncFixture world;
    late AcpTitles titles;

    setUp(() {
      world = SyncFixture();
      titles = AcpTitles(world.rows);
    });
    tearDown(() => world.close());

    test("follows the agent's title, and every client is told", () {
      world.insert(sessionRow());
      expect(titles.follow('s1', 'Fix the login bug'), isTrue);
      expect(world.row('s1')!.title, 'Fix the login bug');
      expect(world.row('s1')!.titleByUser, isFalse);
      expect(world.toldRows, ['s1']);

      // A later title replaces an agent's earlier one.
      expect(titles.follow('s1', 'Fix login and logout'), isTrue);
      expect(world.row('s1')!.title, 'Fix login and logout');
    });

    test('a title a person typed wins', () {
      world.insert(sessionRow(title: 'My name for it', titleByUser: true));
      expect(titles.follow('s1', 'Fix the login bug'), isFalse);
      expect(world.row('s1')!.title, 'My name for it');
      expect(world.toldRows, isEmpty);
    });

    test('the same title, a blank one, or no row writes nothing', () {
      world.insert(sessionRow(title: 'Same'));
      expect(titles.follow('s1', 'Same'), isFalse);
      expect(titles.follow('s1', '   '), isFalse);
      expect(titles.follow('nobody', 'A title'), isFalse);
      expect(world.toldRows, isEmpty);
    });
  });
}

class _TitlesHost extends RecordingHost {
  final titles = <(String, String)>[];

  @override
  void titleChanged(String sessionId, String title) =>
      titles.add((sessionId, title));
}
