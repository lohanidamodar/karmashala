import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/loopback_media_server.dart';

/// The door the video player opens, on its own so a second live-view backend
/// can use it without going through scrcpy.
void main() {
  Future<HttpClientResponse> get(Uri url) async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    return (await client.getUrl(url)).close();
  }

  test('serves what the producer emits, in order', () async {
    final server = await LoopbackMediaServer.serve(
      openStream: () => Stream.fromIterable([
        utf8.encode('one'),
        utf8.encode('two'),
        utf8.encode('three'),
      ]),
    );
    addTearDown(server.close);

    final body = await (await get(server.url)).transform(utf8.decoder).join();

    expect(body, 'onetwothree');
  });

  test('binds loopback on an ephemeral port', () async {
    final server = await LoopbackMediaServer.serve(
      openStream: () => const Stream<List<int>>.empty(),
    );
    addTearDown(server.close);

    // What this serves is the user's screen. Anywhere but loopback would put
    // that on the network.
    expect(server.url.host, '127.0.0.1');
    expect(server.url.port, greaterThan(0));
    expect(server.url.path, '/live.ts');
  });

  test('declares MPEG-TS by default, and honours an override', () async {
    final ts = await LoopbackMediaServer.serve(
      openStream: () => const Stream<List<int>>.empty(),
    );
    addTearDown(ts.close);
    expect(
      (await get(ts.url)).headers.contentType.toString(),
      startsWith('video/mp2t'),
    );

    final mp4 = await LoopbackMediaServer.serve(
      openStream: () => const Stream<List<int>>.empty(),
      contentType: ContentType('video', 'mp4'),
      path: 'live.mp4',
    );
    addTearDown(mp4.close);
    expect(
      (await get(mp4.url)).headers.contentType.toString(),
      startsWith('video/mp4'),
    );
    expect(mp4.url.path, '/live.mp4');
  });

  test('opens a fresh producer per viewer', () async {
    // Per-viewer state is why this is a factory and not a stream: a muxer's
    // continuity counters and timestamp base belong to one output stream.
    var opened = 0;
    final server = await LoopbackMediaServer.serve(
      openStream: () {
        opened++;
        return Stream.fromIterable([utf8.encode('viewer $opened')]);
      },
    );
    addTearDown(server.close);

    final first = await (await get(server.url)).transform(utf8.decoder).join();
    final second = await (await get(server.url)).transform(utf8.decoder).join();

    expect(opened, 2);
    expect(first, 'viewer 1');
    expect(second, 'viewer 2');
  });

  test('closing the server ends the viewer\'s producer', () async {
    // The server cannot notice a viewer that vanished — measured on macOS,
    // writes to a destroyed peer keep reporting success — so this is the seam
    // that actually ends a stream.
    var cancelled = false;
    final controller = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    addTearDown(controller.close);

    final server = await LoopbackMediaServer.serve(
      openStream: () => controller.stream,
    );

    final socket = await Socket.connect(server.url.host, server.url.port);
    socket.write('GET ${server.url.path} HTTP/1.1\r\n');
    socket.write('Host: ${server.url.host}\r\n\r\n');
    await socket.flush();
    socket.listen((_) {}, onError: (Object _) {});
    controller.add(utf8.encode('frame'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cancelled, isFalse, reason: 'still watching');

    await server.close();
    socket.destroy();

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(cancelled, isTrue);
  });

  test('reports each chunk that reached the socket', () async {
    var written = 0;
    final server = await LoopbackMediaServer.serve(
      openStream: () => Stream.fromIterable([
        utf8.encode('a'),
        utf8.encode('b'),
      ]),
      onChunkWritten: () => written++,
    );
    addTearDown(server.close);

    await (await get(server.url)).drain<void>();

    expect(written, 2);
  });
}
