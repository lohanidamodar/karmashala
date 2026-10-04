import 'dart:io';

import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// What a send has to say (an image left a path) is told to the server
/// around the runtime whoever sent it: a queued message and a resume's first
/// turn have no sender waiting on a reply.
void main() {
  late AppDatabase database;
  late Directory temp;
  late _NoticeHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_send_notices');
    host = _NoticeHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  test('a send that left an image a path tells the host, once', () async {
    final shot = File(p.join(temp.path, 'shot.png'))..writeAsBytesSync([1]);
    final process = FakeAcpProcess(FakeAcpAgent(turns: const [FakeTurn([])]));
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    final said = await runtime.send('Look\n\nAttached image(s):\n${shot.path}');
    await runtime.awaitTurn();

    expect(host.notices, [('s1', said)]);
    expect(said, contains('does not take images'));
    await runtime.stop();
  });

  test('a send with nothing to say tells nothing', () async {
    final process = FakeAcpProcess(FakeAcpAgent(turns: const [FakeTurn([])]));
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('hello');
    await runtime.awaitTurn();
    expect(host.notices, isEmpty);
    await runtime.stop();
  });
}

class _NoticeHost extends RecordingHost {
  final notices = <(String, String?)>[];

  @override
  void notice(String sessionId, String message) =>
      notices.add((sessionId, message));
}
