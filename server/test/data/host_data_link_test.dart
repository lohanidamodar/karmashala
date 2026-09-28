import 'dart:async';
import 'dart:io';

import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/data/data_streams.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The data API over the host protocol on a real unix socket: two clients,
/// one writing, one told.
void main() {
  late Directory dir;
  late AppDatabase db;
  late HostServer server;
  late UnixSocketHostListener listener;
  late StreamSubscription<HostConnection> serving;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('kdl');
    db = AppDatabase.memory();
    server = HostServer(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      ptyLibrary: 'libc',
    )..data = DataService(db);
    listener = await UnixSocketHostListener.bind('${dir.path}/h.sock');
    serving = server.listen(listener);
  });

  tearDown(() async {
    await serving.cancel();
    await listener.close();
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('a write answers its writer and reaches a subscribed client', () async {
    final writer = (await HostDataLink.connect(listener.path))!;
    final reader = (await HostDataLink.connect(listener.path))!;
    await reader.send(const DataSubscribe());
    final told = reader.changes.first;

    final added = await writer.send(const TodoAdd(id: 't', body: ' milk '));
    expect(added.value.body, 'milk');

    final batch = await told.timeout(const Duration(seconds: 5));
    expect(batch.revision, added.revision);
    expect((batch.changes.single as TodoChanged).todo, added.value);
    expect((await reader.send(const TodosList())).value, [added.value]);

    await writer.close();
    await reader.close();
  });

  test('a refusal arrives typed, with the reason', () async {
    final link = (await HostDataLink.connect(listener.path))!;
    await expectLater(
      link.send(const NoteDelete('ghost')),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.notFound)
            .having((r) => r.message, 'message', contains('ghost')),
      ),
    );
    await link.close();
  });

  test('a host with no store refuses as unavailable', () async {
    server.data = null;
    final link = (await HostDataLink.connect(listener.path))!;
    await expectLater(
      link.send(const PreferencesGet()),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.unavailable,
        ),
      ),
    );
    await link.close();
  });

  test(
    'nothing listening is null; a closed link refuses as unavailable',
    () async {
      expect(await HostDataLink.connect('${dir.path}/none.sock'), isNull);
      final link = (await HostDataLink.connect(listener.path))!;
      await link.close();
      await expectLater(
        link.send(const TodosList()),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.unavailable,
          ),
        ),
      );
    },
  );

  test('a conversation search round-trips; a catch-up is answered when done, '
      'by its id, with requests sent after it in flight', () async {
    final service = server.data!;
    service.conversations.dao.replaceTurns(
      sessionId: 'c1',
      cli: 'claudeCode',
      filePath: '/nowhere/c1.jsonl',
      turns: const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'the rate limiter'),
      ],
      indexedAt: DateTime.utc(2026, 9, 27),
    );
    const at = '2026-09-27T00:00:00.000Z';
    for (final sql in [
      'INSERT INTO execution_environments (id, kind, name, created_at) '
          "VALUES ('e', 'localPosix', 'Here', '$at');",
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
          "created_at) VALUES ('p', 'P', 'e', '/p', '$at');",
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
          "created_at) VALUES ('r', 'p', 'r', 'e', '/p', '$at');",
      'INSERT INTO imported_sessions (id, repository_id, source, external_id, '
          'environment_id, preview, file_path, store_home, is_subagent, '
          "created_at) VALUES ('i1', 'r', 'claudeCode', 'c1', 'e', 'hi', "
          "'/nowhere/c1.jsonl', '/h', 0, '$at');",
    ]) {
      db.execute(sql);
    }
    final link = (await HostDataLink.connect(listener.path))!;
    final catchUp = link.send(const ConversationsCatchUp());
    final page = await link.send(const ConversationsSearch('rate limiter'));
    expect(page.value.hits.single.sessionId, 'c1');
    expect(page.value.hits.single.excerpt, contains('rate limiter'));
    // Nothing started reading transcripts here: nothing changed.
    expect((await catchUp.timeout(const Duration(seconds: 5))).value, 0);
    final status = await link.send(const ConversationsStatus());
    expect(status.value.turns, 1);
    await link.close();
  });

  group('a live stream (slice 3d)', () {
    late StreamController<Object?> live;
    var cancelled = false;

    setUp(() {
      live = StreamController<Object?>.broadcast(
        onCancel: () => cancelled = true,
      );
      cancelled = false;
      server.data!.streamSources['test.lines'] = _Source(
        backlog: const ['one', 'two'],
        live: live.stream,
      );
    });

    test('the backlog comes first, then what arrives, and a cancel closes '
        'it at the server', () async {
      final link = (await HostDataLink.connect(listener.path))!;
      final items = <Object?>[];
      final got = Completer<void>();
      final subscription = link.openStream('test.lines', 'app').listen((b) {
        items.addAll(b.items);
        if (items.length == 3 && !got.isCompleted) got.complete();
      });
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return !live.hasListener;
      }).timeout(const Duration(seconds: 5));
      live.add('three');
      await got.future.timeout(const Duration(seconds: 5));
      expect(items, ['one', 'two', 'three']);

      await subscription.cancel();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return !cancelled;
      }).timeout(const Duration(seconds: 5));
      await link.close();
    });

    test('a key the source does not hold ends at once, in words', () async {
      final link = (await HostDataLink.connect(listener.path))!;
      final batches = await link
          .openStream('test.lines', 'missing')
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(batches.single.ended, contains('no app missing'));
      final unknown = await link
          .openStream('no.such', 'x')
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(unknown.single.ended, contains('no.such'));
      await link.close();
    });

    test('the link going away ends every stream it had open', () async {
      final link = (await HostDataLink.connect(listener.path))!;
      final done = link.openStream('test.lines', 'app').toList();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return !live.hasListener;
      }).timeout(const Duration(seconds: 5));
      await link.close();
      final batches = await done.timeout(const Duration(seconds: 5));
      expect(batches.last.ended, isNotNull);
    });
  });

  test('the frames keep their numbers', () {
    expect(MessageType.dataRequest.code, 0x32);
    expect(MessageType.dataAnswer.code, 0x33);
    expect(MessageType.dataChanges.code, 0x34);
    expect(MessageType.dataStreamOpen.code, 0x3b);
    expect(MessageType.dataStreamItems.code, 0x3c);
    expect(MessageType.dataStreamClose.code, 0x3d);
    expect(kProtocolVersion, 31);
  });
}

class _Source implements DataStreamSource {
  _Source({required this.backlog, required this.live});

  final List<Object?> backlog;
  final Stream<Object?> live;

  @override
  DataStreamFeed open(String key) {
    if (key != 'app') throw DataRefused.notFound('no app $key');
    return DataStreamFeed(backlog, live);
  }
}
