import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:test/test.dart';

/// How long a bridged call may wait for its answer: as long as the tool may
/// legitimately take, never the flat minute that cut a 240 s `subagent_run`
/// off at 60 s — while a server that hangs up is still known at once.
void main() {
  group('the answer bound', () {
    test('a tool\'s own wait, plus a margin, sets it', () {
      expect(
        localRpcAnswerTimeout('subagent_run', {'timeoutSeconds': 240}),
        const Duration(seconds: 240) + kLocalRpcAnswerMargin,
      );
      expect(
        localRpcAnswerTimeout('terminal_run', {'timeoutSeconds': 600}),
        const Duration(seconds: 600) + kLocalRpcAnswerMargin,
      );
    });

    test('a long tool asked without one waits its own default', () {
      expect(
        localRpcAnswerTimeout('subagent_run', const {}),
        const Duration(seconds: 600) + kLocalRpcAnswerMargin,
      );
      expect(
        localRpcAnswerTimeout('terminal_run', const {}),
        const Duration(seconds: 60) + kLocalRpcAnswerMargin,
      );
      expect(
        localRpcAnswerTimeout('flutter_pick_widget', const {}),
        const Duration(seconds: 120) + kLocalRpcAnswerMargin,
      );
    });

    test('a short tool keeps the minute; nothing exceeds the ceiling', () {
      expect(
        localRpcAnswerTimeout('list_sessions', const {}),
        kLocalRpcTimeout,
      );
      expect(
        localRpcAnswerTimeout('session_wait', {'timeoutSeconds': 0}),
        kLocalRpcTimeout,
      );
      expect(
        localRpcAnswerTimeout('subagent_run', {'timeoutSeconds': 99999}),
        kLocalRpcMaxAnswerTimeout,
      );
      expect(
        localRpcAnswerTimeout('subagent_run', {'timeoutSeconds': 'soon'}),
        const Duration(seconds: 600) + kLocalRpcAnswerMargin,
      );
    });
  });

  // Over a stream, not a socket: a real unix socket on Windows is what
  // bugchecked the machine (orderly_close.dart).
  group('reading the answer', () {
    test(
      'an answer later than a short bound arrives under a longer one',
      () async {
        final wire = StreamController<List<int>>();
        final answer = readLocalRpcAnswer(
          wire.stream,
          const Duration(seconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        wire.add(utf8.encode('late\n'));
        expect(await answer, 'late');
        await wire.close();
      },
    );

    test('past its bound it gives up', () async {
      final wire = StreamController<List<int>>();
      await expectLater(
        readLocalRpcAnswer(wire.stream, const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      await wire.close();
    });

    test(
      'a server that hangs up is known at once, whatever the bound',
      () async {
        final wire = StreamController<List<int>>();
        final answer = readLocalRpcAnswer(
          wire.stream,
          const Duration(hours: 1),
        );
        final clock = Stopwatch()..start();
        unawaited(wire.close());
        await expectLater(answer, throwsA(isA<StateError>()));
        expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      },
    );
  });

  group('over a real socket', () {
    test('an answer later than the call\'s old bound succeeds; a closed socket '
        'fails fast', () async {
      final directory = Directory.systemTemp.createTempSync('rpc_bound');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/rpc.sock';
      final server = await LocalRpcServer.bind(path, (line) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return 'echo:$line';
      });
      addTearDown(server.close);
      await expectLater(
        LocalRpcClient.call(
          path,
          'hi',
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        await LocalRpcClient.call(
          path,
          'hi',
          timeout: const Duration(seconds: 5),
        ),
        'echo:hi',
      );
      await server.close();
      await expectLater(
        LocalRpcClient.call(path, 'hi', timeout: const Duration(hours: 1)),
        throwsA(isA<LocalRpcUnreachable>()),
      );
    }, testOn: 'mac-os || linux');
  });
}
