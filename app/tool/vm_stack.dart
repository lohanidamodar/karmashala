// Dumps every isolate's Dart stack from a running VM service, for the case
// where the app has stopped answering and there is nothing else to read.
//
//     dart.exe tool/vm_stack.dart <ws-uri> [out-file]
//
// The URI is the one the debug build prints on stdout as
// `The Dart VM service is listening on http://127.0.0.1:<port>/<auth>/`; the
// websocket form is that with `ws://` and a `ws` suffix. Run it with the
// WINDOWS dart: the service binds Windows loopback and WSL cannot reach it.
//
// `app_soak.ps1` runs this on a cycle whose app ignored `WM_CLOSE`, before it
// stops the process — the soak found 2 of 20 doing that with nothing in the
// log to tell them from the 18 that quit. Every call is bounded and failures
// are printed rather than thrown, because a report that says "the main isolate
// would not answer `getStack`" is itself the finding: it means the isolate is
// not merely slow but blocked, and a Dart timeout could never have fired.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _callTimeout = Duration(seconds: 10);

late WebSocket _ws;
int _id = 0;
final Map<int, Completer<Map<String, dynamic>>> _pending = {};

Future<Map<String, dynamic>> call(
  String method, [
  Map<String, dynamic>? params,
]) {
  final id = ++_id;
  final completer = Completer<Map<String, dynamic>>();
  _pending[id] = completer;
  _ws.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params ?? <String, dynamic>{},
    }),
  );
  return completer.future.timeout(
    _callTimeout,
    onTimeout: () => {
      'error': {'message': 'no answer in ${_callTimeout.inSeconds}s'},
    },
  );
}

String _frame(Map<String, dynamic> frame) {
  final function = frame['function'];
  final name = function is Map ? '${function['name']}' : '<anonymous>';
  final location = frame['location'];
  var where = '';
  if (location is Map) {
    final script = location['script'];
    if (script is Map) where = ' ${script['uri']}';
    if (location['line'] != null) where = '$where:${location['line']}';
  }
  return '  $name$where';
}

void _writeStack(StringBuffer out, String label, Object? stack) {
  if (stack is! Map || stack['frames'] == null) {
    out.writeln('$label: ${jsonEncode(stack)}');
    return;
  }
  final frames = (stack['frames'] as List).cast<Map<String, dynamic>>();
  out.writeln('$label (${frames.length} frames)');
  for (final frame in frames) {
    out.writeln(_frame(frame));
  }
  final messages = stack['messages'];
  if (messages is List && messages.isNotEmpty) {
    out.writeln('  … $label has ${messages.length} queued message(s)');
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart tool/vm_stack.dart <ws-uri> [out-file]');
    exitCode = 2;
    return;
  }
  final out = StringBuffer()
    ..writeln('vm_stack ${DateTime.now().toIso8601String()} ${args[0]}');
  _ws = await WebSocket.connect(args[0]).timeout(_callTimeout);
  _ws.listen((raw) {
    final message = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = message['id'];
    if (id is int) _pending.remove(id)?.complete(message);
  });

  final vm = await call('getVM');
  final result = vm['result'];
  if (result is! Map) {
    out.writeln('getVM failed: ${jsonEncode(vm)}');
  } else {
    final isolates = (result['isolates'] as List).cast<Map<String, dynamic>>();
    out.writeln('isolates: ${isolates.map((i) => i['name']).join(', ')}');
    for (final isolate in isolates) {
      final id = '${isolate['id']}';
      final name = '${isolate['name']}';
      final detail = await call('getIsolate', {'isolateId': id});
      final isolateResult = detail['result'];
      if (isolateResult is Map) {
        out.writeln(
          '\n$name  runnable=${isolateResult['runnable']} '
          'pauseEvent=${(isolateResult['pauseEvent'] as Map?)?['kind']}',
        );
      } else {
        out.writeln('\n$name  getIsolate: ${jsonEncode(detail)}');
      }
      final stack = await call('getStack', {'isolateId': id});
      final frames = stack['result'] ?? stack['error'];
      _writeStack(out, name, frames);
      // An isolate waiting on a future that never completes has *no* sync
      // frames — the finding is then the absence, plus whichever await chain
      // the VM still remembers. Printed only when there is one, so a healthy
      // idle isolate stays one line.
      if (frames is Map) {
        for (final kind in ['asyncCausalFrames', 'awaiterFrames']) {
          final chain = frames[kind];
          if (chain is List && chain.isNotEmpty) {
            out.writeln('$name $kind (${chain.length})');
            for (final frame in chain.cast<Map<String, dynamic>>()) {
              out.writeln(_frame(frame));
            }
          }
        }
      }
    }
  }

  await _ws.close();
  if (args.length > 1) {
    File(args[1]).writeAsStringSync(out.toString());
    stdout.writeln('wrote ${args[1]}');
  } else {
    stdout.write(out.toString());
  }
}
