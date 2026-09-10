// What a restart is allowed to leave behind. Each restart deploys a jar, opens
// a forward, starts a server and holds two sockets, none of which clean
// themselves up: killing the host-side `adb shell` does not kill the
// `app_process` it started, and four live servers on one device were found.
@Tags(['cost'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/device_stream.dart';

import './fake_scrcpy_device.dart';

const _serial = 'F6IZLV6LMFT4U4ZT';

void main() {
  group('rapid repeated restarts', () {
    test('leave no server, forward, jar or socket behind', () async {
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final runner = device.runner();
      final service = fakeStreamService(runner);

      const restarts = 5;
      final urls = <Uri>[];
      for (var i = 0; i < restarts; i++) {
        final session = await service.start(_serial);
        urls.add(session.url);
        await session.stop();
      }

      // The device's own account of what is still running.
      expect(
        device.runningScids,
        isEmpty,
        reason: 'a killed adb shell does not kill the app_process it started',
      );
      expect(device.pushedJars, isEmpty, reason: '700 KB per restart adds up');

      final arguments = runner.requests.map((r) => r.arguments).toList();
      int count(bool Function(List<String>) match) =>
          arguments.where(match).length;
      expect(count((a) => a.contains('tcp:0')), restarts);
      expect(
        count((a) => a.contains('--remove')),
        restarts,
        reason: 'one forward opened, one forward removed',
      );
      expect(count((a) => a.contains('pkill')), restarts);
      expect(
        runner.startRequests.length,
        restarts,
        reason: 'one server per session, and no retry needed',
      );
      expect(
        device.handles.every((handle) => handle.killed),
        isTrue,
        reason: 'every host-side adb shell was killed',
      );

      // Two sockets per session — video and control — waited for, not assumed:
      // both counts are fed by the far end's own `onDone`, after the FIN has
      // crossed a real loopback socket.
      await device.untilSocketsClosed(restarts * 2);
      expect(device.socketsAccepted, restarts * 2);
      expect(device.socketsClosedByHost, restarts * 2);

      // Sound to ask by port: `stop()` awaits `HttpServer.close(force: true)`
      // before it returns. Measured under a full concurrent run: of 200
      // loopback ephemeral ports bound and closed, zero were answered by
      // anybody on the next connect.
      for (final url in urls) {
        await expectLater(
          Socket.connect(url.host, url.port),
          throwsA(isA<SocketException>()),
          reason: 'the media server for $url is still listening',
        );
      }
    });

    test('the count waits on the socket\'s own done, not on a moment',
        () async {
      // The seam the assertion above leans on: nothing can satisfy the wait
      // except the closes themselves.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(device.runner()).start(_serial);

      var settled = false;
      unawaited(device.untilSocketsClosed(2).then((_) => settled = true));
      await device.untilSocketsAccepted(2);
      expect(
        settled,
        isFalse,
        reason: 'both sockets are open; nothing has been closed yet',
      );

      await session.stop();
      await device.untilSocketsClosed(2);
      expect(device.socketsClosedByHost, 2);
    });

    test('a second stop is not a second teardown', () async {
      // The pane's dispose cannot await a stop, so stopping twice must not kill
      // a session that is no longer this one's.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final runner = device.runner();
      final session = await fakeStreamService(runner).start(_serial);

      await session.stop();
      final afterFirst = runner.requests.length;
      await session.stop();
      expect(runner.requests.length, afterFirst);
    });

    test('a start clears what an earlier run left running', () async {
      // Reaping on the way *in* is the only cleanup that always gets to run:
      // closing the app leaves whatever a teardown had not finished.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final orphan = scrcpyJarPathFor('deadbeef');
      final runner = device.runner(
        processList:
            ' 11026 sh -c CLASSPATH=$orphan app_process / '
            'com.genymobile.scrcpy.Server 4.1 scid=deadbeef\n',
      );
      final session = await fakeStreamService(runner).start(_serial);
      addTearDown(session.stop);

      expect(
        runner.requests.map((r) => r.arguments),
        contains(containsAllInOrder(['shell', 'kill', '-9', '11026'])),
      );
    });
  });
}
