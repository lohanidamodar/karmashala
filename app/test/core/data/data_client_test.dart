import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/app_preferences.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/todos/data/todos_repository.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fake_data_server.dart';

/// The client of the server's data, against the fake server: priming,
/// revisions, refusals, and a server that is not there or goes away.
void main() {
  late FakeDataServer server;

  setUp(() => server = FakeDataServer(projects: {}));

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  test('connecting primes every copy before it answers', () async {
    server.preferences['settings.v1'] = '{}';
    server.todos['t'] = Todo(
      id: 't',
      body: 'one',
      position: 0,
      createdAt: DateTime.utc(2026),
    );
    final client = await server.connect();

    expect(client.connection.state, DataLinkState.connected);
    expect(client.todos.isPrimed, isTrue);
    expect(client.todos['t']!.body, 'one');
    expect(AppPreferences(client).read('settings.v1'), '{}');
  });

  test('no server at launch: unavailable and nothing known, then primed '
      'once it comes up', () async {
    server.stop();
    final client = await DataClient.connect(
      server.dial,
      unavailableReason: 'failed: no binary',
    );
    addTearDown(client.close);
    expect(client.connection.state, DataLinkState.unavailable);
    expect(client.connection.reason, 'failed: no binary');
    expect(client.preferences.isPrimed, isFalse);
    expect(AppPreferences(client).read('anything'), isNull);

    server
      ..preferences['k'] = 'v'
      ..start();
    await until(() => client.connection.state == DataLinkState.connected);
    expect(AppPreferences(client).read('k'), 'v');
  });

  test('a client with no server to reach refuses writes at once', () async {
    final client = DataClient.unavailable('no server here');
    addTearDown(client.close);
    await expectLater(
      AppPreferences(client).writeStored('k', 'v'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          contains('no server here'),
        ),
      ),
    );
    expect(AppPreferences(client).read('k'), isNull);
  });

  test('a late answer never overwrites a newer change', () async {
    final client = await server.connect();
    client.preferences.applyAt('k', 'new', 5);
    client.preferences.applyAt('k', 'old', 4);
    expect(client.preferences['k'], 'new');
    client.preferences.applyAt('k', null, 6);
    client.preferences.applyAt('k', 'resurrected', 5);
    expect(client.preferences['k'], isNull);
  });

  test('a refused write is undone by reading the domain again', () async {
    final client = await server.connect();
    final todos = TodosRepository(client);
    final draft = Todo(
      id: 't',
      body: 'x',
      projectId: 'no-such-project',
      position: 0,
      createdAt: DateTime.utc(2026),
    );
    final write = todos.add(draft);
    expect(todos.list(), [draft], reason: 'the copy has it at once');
    await expectLater(
      write,
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
    await pumpEventQueue();
    expect(todos.list(), isEmpty);
  });

  group('an open question, across a lost link', () {
    SessionStatusEntry entry(AgentActivityStatus status, AgentWaitKind wait) =>
        SessionStatusEntry(
          session: const WatchedSession(
            key: AgentSessionKey('claudeCode', 'conv-1'),
            label: 'Webhooks',
            openId: 'row-1',
            imported: false,
          ),
          report: AgentStatusReport(
            agentId: 'claudeCode',
            sessionId: 'conv-1',
            status: status,
            source: AgentStatusSource.hook,
            observedAt: DateTime.utc(2026, 10, 6),
            waiting: wait,
          ),
        );

    final asking = entry(
      AgentActivityStatus.awaitingApproval,
      AgentWaitKind.question,
    );

    // The phone kept the last word it heard while it could hear nothing: a
    // question answered on the desktop meanwhile held its composer and card.
    test('is not held while the link is down', () async {
      final client = await server.connect();
      final told = <AttentionChange>[];
      client.attentionChanges.listen(told.add);
      server.writeAsAnotherClient([SessionStatusChanged(asking)]);
      expect(client.sessionStatuses['row-1']!.report.hasOpenQuestion, isTrue);

      server.stop();
      await pumpEventQueue();
      expect(client.connection.state, DataLinkState.connecting);
      expect(
        client.sessionStatuses['row-1']?.report.hasOpenQuestion ?? false,
        isFalse,
      );
      expect(told.whereType<SessionStatusRemoved>().single.openId, 'row-1');
    });

    test(
      'a status that asks nothing is kept until the server says again',
      () async {
        final client = await server.connect();
        server.writeAsAnotherClient([
          SessionStatusChanged(
            entry(AgentActivityStatus.working, AgentWaitKind.unrecorded),
          ),
        ]);
        server.stop();
        await pumpEventQueue();
        expect(
          client.sessionStatuses['row-1']!.report.status,
          AgentActivityStatus.working,
        );
      },
    );
  });

  test('another client\'s write arrives as a change', () async {
    final client = await server.connect();
    server.writeAsAnotherClient([const PreferenceChanged('theme', 'dark')]);
    expect(AppPreferences(client).read('theme'), 'dark');
  });

  test('writes wait for a server that went away, go before the snapshot, '
      'and the copy is read again', () async {
    final client = await server.connect();
    final prefs = AppPreferences(client);

    server.stop();
    await pumpEventQueue();
    expect(client.connection.state, DataLinkState.connecting);

    final waiting = prefs.writeStored('a', '1');
    // Another client wrote while this one was away.
    server.preferences['b'] = '2';
    server.requests.clear();
    server.start();

    await waiting.timeout(const Duration(seconds: 5));
    await until(() => client.connection.state == DataLinkState.connected);
    expect(
      server.requests.indexOf('preferences.set'),
      lessThan(server.requests.indexOf('preferences.get')),
      reason: 'the waiting write goes before the snapshot that includes it',
    );
    expect(prefs.read('a'), '1');
    expect(prefs.read('b'), '2');
  });

  test('a write held past the wait is refused, saying why', () async {
    final client = await server.connect(
      wait: const Duration(milliseconds: 100),
    );
    server.stop();
    await pumpEventQueue();
    await expectLater(
      AppPreferences(client).writeStored('a', '1'),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.unavailable)
            .having((r) => r.message, 'message', contains('not running')),
      ),
    );
    expect(server.preferences, isNot(contains('a')));
  });

  test('Retry dials at once rather than at the next backoff step', () async {
    server.stop();
    final client = await DataClient.connect(server.dial);
    addTearDown(client.close);
    expect(client.connection.state, DataLinkState.unavailable);
    server.start();
    client.retry();
    await pumpEventQueue();
    expect(
      client.connection.state,
      DataLinkState.connected,
      reason: 'the first backoff step is 250 ms; this did not wait for it',
    );
  });

  test('closing waits for a write still in flight', () async {
    final client = await server.connect();
    server.hold = Completer<void>();
    final write = AppPreferences(client).writeStored('quit', 'yes');
    final closing = client.close();
    await pumpEventQueue();
    server.hold!.complete();
    await closing;
    await expectLater(write, completes, reason: 'answered, not cut off');
    expect(server.preferences['quit'], 'yes');
  });
}
