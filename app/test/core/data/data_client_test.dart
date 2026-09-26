import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/app_preferences.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/in_process_data_endpoint.dart';
import 'package:karmashala/src/features/todos/data/todos_repository.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_store/database.dart';

/// A server link a test can hold answers on, drop, and bring back: the
/// server's own service behind it, asynchronous like a socket.
class _Link implements DataEndpoint {
  _Link(DataService service) : _inner = InProcessDataEndpoint.over(service);

  final InProcessDataEndpoint _inner;
  final _done = Completer<void>();
  Completer<void>? hold;
  final sent = <String>[];

  @override
  Stream<DataChanges> get changes => _inner.changes;

  @override
  Future<void> get done => _done.future;

  @override
  Future<DataReply<R>> send<R>(DataRequest<R> request) async {
    if (_done.isCompleted) {
      throw const DataRefused.unavailable('link down');
    }
    sent.add(request.kind);
    final reply = _inner.sendNow(request);
    await hold?.future;
    if (_done.isCompleted) throw const DataRefused.unavailable('link down');
    return reply;
  }

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    drop();
    await _inner.close();
  }
}

void main() {
  late AppDatabase db;
  late DataService service;

  setUp(() {
    db = AppDatabase.memory();
    service = DataService(db);
  });
  tearDown(() => db.close());

  test('connecting primes every copy before it answers', () async {
    db.writeMetadata('settings.v1', '{}');
    final seeded = service.open((_) {});
    seeded.handle(const TodoAdd(id: 't', body: 'one'));
    final client = await DataClient.connect(() async => _Link(service));
    addTearDown(client.close);

    expect(client.connection.state, DataLinkState.connected);
    expect(client.todos.isPrimed, isTrue);
    expect(client.todos['t']!.body, 'one');
    expect(AppPreferences(client).read('settings.v1'), '{}');
  });

  test('no server on the first dial is a refusal the caller sees', () async {
    await expectLater(
      DataClient.connect(() async => null),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.unavailable,
        ),
      ),
    );
  });

  test('a late answer never overwrites a newer change', () {
    final client = DataClient.inProcess(db);
    addTearDown(client.close);
    client.ensurePrimed(DataDomain.preferences);
    client.preferences.applyAt('k', 'new', 5);
    client.preferences.applyAt('k', 'old', 4);
    expect(client.preferences['k'], 'new');
    client.preferences.applyAt('k', null, 6);
    client.preferences.applyAt('k', 'resurrected', 5);
    expect(client.preferences['k'], isNull);
  });

  test('a refused write is undone by reading the domain again', () async {
    final client = DataClient.inProcess(db);
    addTearDown(client.close);
    final todos = TodosRepository(client);
    final draft = Todo(
      id: 't',
      body: 'x',
      projectId: 'no-such-project',
      position: 0,
      createdAt: DateTime.utc(2026),
    );
    await expectLater(
      todos.add(draft),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
    expect(todos.list(), isEmpty);
  });

  test(
    'writes wait for a server that went away, then the copy is re-read',
    () async {
      final links = <_Link>[];
      final client = await DataClient.connect(() async {
        final link = _Link(service);
        links.add(link);
        return link;
      });
      addTearDown(client.close);
      final prefs = AppPreferences(client);

      links.single.drop();
      await pumpEventQueue();
      expect(client.connection.state, DataLinkState.reconnecting);

      final waiting = prefs.writeStored('a', '1');
      // Another client writes while this one is away.
      service.open((_) {}).handle(const PreferenceSet('b', '2'));

      await waiting.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(client.connection.state, DataLinkState.connected);
      expect(links, hasLength(2));
      expect(
        links.last.sent.indexOf('preferences.set'),
        lessThan(links.last.sent.lastIndexOf('preferences.get')),
        reason: 'the waiting write goes before the snapshot that includes it',
      );
      expect(prefs.read('a'), '1');
      expect(prefs.read('b'), '2');
    },
  );

  test('closing waits for a write still in flight', () async {
    final link = _Link(service);
    final client = await DataClient.connect(() async => link);
    link.hold = Completer<void>();
    final write = AppPreferences(client).writeStored('quit', 'yes');
    final closing = client.close();
    await pumpEventQueue();
    link.hold!.complete();
    await closing;
    await expectLater(write, completes, reason: 'answered, not cut off');
    expect(db.readMetadata('quit'), 'yes');
  });
}
