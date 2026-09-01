import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/mjpeg_stream.dart';

/// A JPEG-shaped payload: the real start and end markers around [size] bytes of
/// filler. The parser must not be confused by a body that contains bytes
/// resembling a boundary or a marker.
Uint8List jpeg(int size, {int fill = 0x41}) {
  final bytes = Uint8List(size + 4)
    ..[0] = 0xFF
    ..[1] = 0xD8;
  for (var i = 2; i < size + 2; i++) {
    bytes[i] = fill;
  }
  bytes[size + 2] = 0xFF;
  bytes[size + 3] = 0xD9;
  return bytes;
}

List<int> part(Uint8List body, {bool contentLength = true}) => [
  ...'--BoundaryString\r\n'.codeUnits,
  ...'Content-type: image/jpeg\r\n'.codeUnits,
  if (contentLength) ...'Content-Length: ${body.length}\r\n'.codeUnits,
  ...'\r\n'.codeUnits,
  ...body,
  ...'\r\n'.codeUnits,
];

/// Serves [chunks] as one `multipart/x-mixed-replace` response, writing them in
/// exactly the pieces given so a test can control where the splits fall.
Future<HttpServer> serve(List<List<int>> chunks, {int status = 200}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType(
        'multipart',
        'x-mixed-replace',
        parameters: {'boundary': '--BoundaryString'},
      );
      for (final chunk in chunks) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    }
  }());
  return server;
}

void main() {
  group('MjpegStream', () {
    late HttpServer server;

    tearDown(() => server.close(force: true));

    Uri urlOf(HttpServer server) =>
        Uri.parse('http://127.0.0.1:${server.port}');

    test('yields each frame in the body', () async {
      final first = jpeg(64, fill: 0x11);
      final second = jpeg(96, fill: 0x22);
      server = await serve([part(first), part(second)]);

      final frames = await MjpegStream.connect(urlOf(server)).take(2).toList();

      expect(frames, [first, second]);
    });

    test('reassembles a frame split across chunks', () async {
      // The realistic case: a 120 KB frame never arrives in one read, and the
      // split lands wherever the network puts it — including inside the part
      // headers, which is what makes header parsing incremental.
      final frame = jpeg(4096, fill: 0x33);
      final bytes = part(frame);
      final chunks = <List<int>>[
        for (var i = 0; i < bytes.length; i += 500)
          bytes.sublist(i, i + 500 > bytes.length ? bytes.length : i + 500),
      ];
      expect(chunks.length, greaterThan(4));
      server = await serve(chunks);

      final frames = await MjpegStream.connect(urlOf(server)).take(1).toList();

      expect(frames.single, frame);
    });

    test('does not mistake image bytes for a boundary', () async {
      // Content-Length is what makes this safe: a frame whose pixels happen to
      // spell the boundary would cut short any parser that scanned for one.
      final frame = Uint8List.fromList([
        0xFF, 0xD8,
        ...'\r\n--BoundaryString\r\nContent-Length: 9\r\n\r\n'.codeUnits,
        0xFF, 0xD9,
      ]);
      server = await serve([part(frame), part(jpeg(16))]);

      final frames = await MjpegStream.connect(urlOf(server)).take(2).toList();

      expect(frames.first, frame);
    });

    test('falls back to the end marker when there is no Content-Length',
        () async {
      final frame = jpeg(64, fill: 0x44);
      server = await serve([part(frame, contentLength: false)]);

      final frames = await MjpegStream.connect(urlOf(server)).take(1).toList();

      expect(frames.single, frame);
    });

    test('reports a refusal rather than waiting for frames', () async {
      server = await serve([], status: 500);

      expect(
        MjpegStream.connect(urlOf(server)).first,
        throwsA(isA<HttpException>()),
      );
    });

    test('closes the connection when the listener goes away', () async {
      server = await serve([part(jpeg(32)), part(jpeg(32))]);
      final subscription = MjpegStream.connect(urlOf(server)).listen(null);

      // Cancelling has to tear down the HTTP client: this body never ends on
      // its own, so a leaked subscription keeps WebDriverAgent streaming
      // frames at a pane that is no longer on screen.
      await subscription.cancel();

      await expectLater(server.close(), completes);
    });
  });
}
