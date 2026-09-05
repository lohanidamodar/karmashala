// Samples a running Karmashala's VM service: frames, heap, isolate work.
//
// The Dart MCP server is the usual way in; this exists for when it will not
// connect. Run it with the WINDOWS dart, because the VM service binds Windows
// loopback and WSL cannot reach it:
//
//   dart.exe tool/vm_probe.dart <ws-uri> <seconds>
//
// The URI is the `ws://…/ws` one `flutter run` prints. `Flutter.Frame` events
// are what DevTools' frame chart reads: `elapsed` is the whole frame, `build`
// the UI thread, `raster` the GPU one. A frame over ~16 ms dropped below 60fps.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

late WebSocket _ws;
int _id = 0;
final Map<int, Completer<Map<String, dynamic>>> _pending = {};
final List<Map<String, dynamic>> frames = [];

Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
  final id = ++_id;
  final c = Completer<Map<String, dynamic>>();
  _pending[id] = c;
  _ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params ?? {}}));
  return c.future.timeout(const Duration(seconds: 30), onTimeout: () => {'error': 'timeout'});
}

String ms(num micros) => (micros / 1000).toStringAsFixed(1);

void main(List<String> args) async {
  final uri = args[0];
  final seconds = args.length > 1 ? int.parse(args[1]) : 20;
  _ws = await WebSocket.connect(uri);
  _ws.listen((raw) {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = m['id'];
    if (id is int && _pending.containsKey(id)) {
      _pending.remove(id)!.complete(m);
      return;
    }
    final p = m['params'];
    if (p is Map && p['event'] is Map) {
      final ev = p['event'] as Map;
      if (ev['extensionKind'] == 'Flutter.Frame') {
        final d = ev['extensionData'];
        // Flutter replays its buffered frames to every new subscriber, so the
        // first burst is history — including startup — not what is happening
        // now. Stamp arrival and drop anything that landed before `_live`.
        if (d is Map) {
          frames.add({...Map<String, dynamic>.from(d), '_at': DateTime.now()});
        }
      }
    }
  });

  final vm = (await call('getVM'))['result'] as Map<String, dynamic>;
  final isolates = (vm['isolates'] as List).cast<Map<String, dynamic>>();
  stdout.writeln('isolates: ${isolates.map((i) => i['name']).join(', ')}');
  final main = isolates.firstWhere(
    (i) => (i['name'] as String).contains('main'),
    orElse: () => isolates.first,
  );

  for (final s in ['Extension', 'GC']) {
    final r = await call('streamListen', {'streamId': s});
    if (r['error'] != null) stdout.writeln('  streamListen $s: ${r['error']}');
  }
  final flags = await call('setVMTimelineFlags', {
    'recordedStreams': ['Dart', 'Embedder', 'GC', 'API'],
  });
  if (flags['error'] != null) stdout.writeln('  setVMTimelineFlags: ${flags['error']}');
  await call('clearVMTimeline');
  final t0 = (await call('getVMTimelineMicros'))['result']?['timestamp'] as int? ?? 0;

  // Let the replay burst land, then mark the live boundary.
  await Future<void>.delayed(const Duration(seconds: 2));
  final live = DateTime.now();
  stdout.writeln('>>> CAPTURING $seconds s — drive the app now <<<');
  await Future<void>.delayed(Duration(seconds: seconds));

  // Frames first: this is the question "does the UI stutter" actually asks.
  final replayed = frames.where((f) => (f['_at'] as DateTime).isBefore(live)).length;
  frames.removeWhere((f) => (f['_at'] as DateTime).isBefore(live));
  stdout.writeln('\n=== frames: ${frames.length} live ($replayed replayed history, dropped) ===');
  if (frames.isNotEmpty) {
    final elapsed = frames.map((f) => (f['elapsed'] as num?) ?? 0).toList();
    final janky = <Map<String, dynamic>>[];
    for (final f in frames) {
      if (((f['elapsed'] as num?) ?? 0) > 16000) janky.add(f);
    }
    elapsed.sort();
    stdout.writeln('  median ${ms(elapsed[elapsed.length ~/ 2])} ms   '
        'p90 ${ms(elapsed[(elapsed.length * 0.9).floor()])} ms   '
        'worst ${ms(elapsed.last)} ms');
    stdout.writeln('  over 16 ms: ${janky.length} of ${frames.length}');
    janky.sort((a, b) => ((b['elapsed'] as num?) ?? 0).compareTo((a['elapsed'] as num?) ?? 0));
    stdout.writeln('  worst 12 (elapsed / build = UI thread / raster = GPU):');
    for (final f in janky.take(12)) {
      stdout.writeln('    ${ms((f['elapsed'] as num?) ?? 0).padLeft(8)} ms  '
          'build ${ms((f['build'] as num?) ?? 0).padLeft(7)}  '
          'raster ${ms((f['raster'] as num?) ?? 0).padLeft(7)}');
    }
  }

  final t1 = (await call('getVMTimelineMicros'))['result']?['timestamp'] as int? ?? 0;
  final tl = (await call('getVMTimeline', {
    'timeOriginMicros': t0,
    'timeExtentMicros': t1 - t0,
  }))['result'] as Map<String, dynamic>?;
  final events = ((tl?['traceEvents'] as List?) ?? []).cast<Map<String, dynamic>>();

  // 'X' events carry `dur`; 'B'/'E' pairs do not, and most of Flutter's are
  // pairs. Match them per thread with a stack, or the costly work is invisible.
  final durs = <MapEntry<String, num>>[];
  final stacks = <String, List<Map<String, dynamic>>>{};
  for (final e in events) {
    final tid = '${e['tid']}';
    final ph = e['ph'];
    if (ph == 'X' && e['dur'] is num) {
      durs.add(MapEntry('${e['name']}', e['dur'] as num));
    } else if (ph == 'B') {
      (stacks[tid] ??= []).add(e);
    } else if (ph == 'E') {
      final st = stacks[tid];
      if (st != null && st.isNotEmpty) {
        final b = st.removeLast();
        final ts = e['ts'], bts = b['ts'];
        if (ts is num && bts is num) durs.add(MapEntry('${b['name']}', ts - bts));
      }
    }
  }
  durs.sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('\n=== timeline: ${events.length} events, 12 longest (ms) ===');
  for (final e in durs.take(12)) {
    stdout.writeln('  ${ms(e.value).padLeft(8)}  ${e.key}');
  }

  // A thread blocked in a native call logs nothing, so the only trace it leaves
  // is a gap. The event that opened the gap is what went in and did not return.
  final perThread = <String, List<Map<String, dynamic>>>{};
  for (final e in events) {
    if (e['ts'] is num) (perThread['${e['tid']}'] ??= []).add(e);
  }
  stdout.writeln('\n=== largest stalls, and the event that opened each ===');
  final gaps = <List<Object>>[];
  for (final entry in perThread.entries) {
    final list = entry.value..sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));
    for (var i = 1; i < list.length; i++) {
      final g = (list[i]['ts'] as num) - (list[i - 1]['ts'] as num);
      if (g > 20000) gaps.add([g, entry.key, '${list[i - 1]['name']}', '${list[i]['name']}']);
    }
  }
  gaps.sort((a, b) => (b[0] as num).compareTo(a[0] as num));
  stdout.writeln('  stalls over 20 ms: ${gaps.length}');
  for (final g in gaps.take(15)) {
    stdout.writeln('  ${ms(g[0] as num).padLeft(8)} ms  tid ${g[1]}  '
        'after "${g[2]}"  ->  "${g[3]}"');
  }

  final mem = (await call('getMemoryUsage', {'isolateId': main['id']}))['result'];
  if (mem is Map) {
    stdout.writeln('\nheap ${(mem['heapUsage'] / 1048576).toStringAsFixed(1)} MB '
        'of ${(mem['heapCapacity'] / 1048576).toStringAsFixed(1)} MB');
  }
  await _ws.close();
  exit(0);
}
