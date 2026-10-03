import 'dart:async';
import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:test/test.dart';

/// The far end of a peer, driven by hand: raw lines in, decoded JSON out.
/// What the peer writes is queued, so a message sent before anyone asked for
/// it is still there when they do.
class RawSide {
  RawSide() {
    peer = AcpPeer(_toPeer.stream, _fromPeer.sink);
    _fromPeer.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_raw.push);
  }

  final _toPeer = StreamController<List<int>>();
  final _fromPeer = StreamController<List<int>>();
  final _raw = _Queue<String>();
  late final AcpPeer peer;

  /// The next line the peer wrote, without its newline.
  Future<String> nextRaw() => _raw.next();

  Future<Map<String, Object?>> next() async =>
      jsonDecode(await nextRaw()) as Map<String, Object?>;

  void sendLine(String line) => _toPeer.add(utf8.encode('$line\n'));

  void send(Map<String, Object?> message) => sendLine(jsonEncode(message));

  Future<void> endInput() => _toPeer.close();
}

class _Queue<T> {
  final _items = <T>[];
  final _waiters = <Completer<T>>[];

  void push(T item) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(item);
    } else {
      _items.add(item);
    }
  }

  Future<T> next() {
    if (_items.isNotEmpty) return Future.value(_items.removeAt(0));
    final waiter = Completer<T>();
    _waiters.add(waiter);
    return waiter.future;
  }
}

void main() {
  group('AcpPeer', () {
    test('a call is one line with jsonrpc, a fresh id and params, and the '
        'answer with that id completes it', () async {
      final side = RawSide();
      final seen = side.next();
      final result = side.peer.call('initialize', {'protocolVersion': 1});
      final request = await seen;
      expect(request, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': 1},
      });
      side.send({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'ok': true},
      });
      expect(await result, {'ok': true});
      await side.peer.close();
    });

    test(
      'answers are routed by id, in whatever order they come back',
      () async {
        final side = RawSide();
        final first = side.peer.call('a', null);
        final second = side.peer.call('b', null);
        await Future.wait([side.next(), side.next()]);
        side.send({'jsonrpc': '2.0', 'id': 2, 'result': 'B'});
        side.send({'jsonrpc': '2.0', 'id': 1, 'result': 'A'});
        expect(await first, 'A');
        expect(await second, 'B');
        await side.peer.close();
      },
    );

    test('an error answer throws AcpRpcError with its code and data', () async {
      final side = RawSide();
      final call = side.peer.call('session/new', {});
      await side.next();
      side.send({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'code': -32000, 'message': 'login first', 'data': 'x'},
      });
      await expectLater(
        call,
        throwsA(
          isA<AcpAuthenticationRequired>()
              .having((e) => e.code, 'code', -32000)
              .having((e) => e.message, 'message', 'login first')
              .having((e) => e.data, 'data', 'x'),
        ),
      );
      await side.peer.close();
    });

    test('a notification has no id; a string with a newline still goes out '
        'as one line', () async {
      final side = RawSide();
      final line = side.nextRaw();
      side.peer.notify('session/cancel', {'note': 'two\nlines'});
      final raw = await line;
      // One line: had the newline gone out raw, this line would be half a
      // message and not decode.
      expect(raw.contains('\n'), isFalse);
      expect(jsonDecode(raw), {
        'jsonrpc': '2.0',
        'method': 'session/cancel',
        'params': {'note': 'two\nlines'},
      });
      await side.peer.close();
    });

    test('a request from the far side arriving while our call is pending is '
        'surfaced, answered, and our call still completes', () async {
      final side = RawSide();
      final incoming = side.peer.requests.first;
      final ours = side.peer.call('session/prompt', {'sessionId': 's'});
      await side.next();
      side.send({
        'jsonrpc': '2.0',
        'id': 'agent-7',
        'method': 'fs/read_text_file',
        'params': {'path': 'a.txt'},
      });
      final request = await incoming;
      expect(request.method, 'fs/read_text_file');
      expect(request.paramsMap['path'], 'a.txt');
      final reply = side.next();
      request.respond({'content': 'hello'});
      expect(await reply, {
        'jsonrpc': '2.0',
        'id': 'agent-7',
        'result': {'content': 'hello'},
      });
      side.send({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'stopReason': 'end_turn'},
      });
      expect(await ours, {'stopReason': 'end_turn'});
      await side.peer.close();
    });

    test(
      'fail answers with an error object; a second answer is dropped',
      () async {
        final side = RawSide();
        final incoming = side.peer.requests.first;
        side.send({'jsonrpc': '2.0', 'id': 3, 'method': 'terminal/create'});
        final request = await incoming;
        final reply = side.next();
        request.fail(-32601, 'Method not found');
        request.respond({'late': true});
        expect(await reply, {
          'jsonrpc': '2.0',
          'id': 3,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
        await side.peer.close();
      },
    );

    test(
      r'$/cancel_request fails the pending incoming request with -32800 '
      'and marks it cancelled; the handler\'s later answer is dropped',
      () async {
        final side = RawSide();
        final incoming = side.peer.requests.first;
        side.send({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'session/request_permission',
          'params': {},
        });
        final request = await incoming;
        final reply = side.next();
        side.send({
          'jsonrpc': '2.0',
          'method': r'$/cancel_request',
          'params': {'requestId': 9},
        });
        expect(await reply, {
          'jsonrpc': '2.0',
          'id': 9,
          'error': {'code': -32800, 'message': 'Request cancelled'},
        });
        await request.cancelled;
        expect(request.isCancelled, isTrue);
        expect(request.isAnswered, isTrue);
        final after = side.next().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => {},
        );
        request.respond({'outcome': 'late'});
        expect(await after, isEmpty);
        await side.peer.close();
      },
    );

    test('blank lines are skipped; non-JSON and non-object lines are reported '
        'on malformed, and the peer keeps working', () async {
      final side = RawSide();
      final malformed = side.peer.malformed.take(3).toList();
      side.sendLine('');
      side.sendLine('   ');
      side.sendLine('npm WARN something');
      side.sendLine('[1, 2]');
      side.sendLine('{"jsonrpc":"2.0","id":42,"result":1}');
      final reported = await malformed;
      expect(reported[0].line, 'npm WARN something');
      expect(reported[0].reason, startsWith('not JSON'));
      expect(reported[1].reason, 'not a JSON object');
      expect(reported[2].reason, contains('unknown id 42'));
      final call = side.peer.call('ping', null);
      await side.next();
      side.send({'jsonrpc': '2.0', 'id': 1, 'result': 'pong'});
      expect(await call, 'pong');
      await side.peer.close();
    });

    test('when the input ends, pending calls fail with AcpPeerClosed, done '
        'completes, and later calls refuse', () async {
      final side = RawSide();
      final call = side.peer.call('session/prompt', {});
      await side.next();
      await side.endInput();
      await expectLater(
        call,
        throwsA(
          isA<AcpPeerClosed>().having(
            (e) => e.method,
            'method',
            'session/prompt',
          ),
        ),
      );
      await side.peer.done;
      expect(side.peer.isClosed, isTrue);
      await expectLater(
        side.peer.call('x', null),
        throwsA(isA<AcpPeerClosed>()),
      );
    });
  });
}
