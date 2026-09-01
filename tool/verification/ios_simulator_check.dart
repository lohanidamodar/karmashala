/// Drives a real iOS Simulator end to end, so the whole path can be tried by
/// hand before any of it is on screen.
///
///   dart run tool/verification/ios_simulator_check.dart [udid]
///
/// With no udid it picks the first available iPhone. It boots the simulator if
/// it has to, starts the vendored `idb_companion`, and then exercises every
/// capability in turn, printing what it saw. Nothing is left running: the
/// companion is stopped and a simulator this script booted is shut down again.
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/core/process/local_command_runner.dart';
import 'package:karmashala/src/features/devices/data/mjpeg_stream.dart';
import 'package:karmashala/src/features/devices/data/wda_backend.dart';
import 'package:karmashala/src/features/devices/data/wda_locator.dart';
import 'package:karmashala/src/features/devices/data/simctl_service.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';
import 'package:karmashala/src/features/devices/domain/simulator_backend.dart';
import 'package:karmashala/src/features/environments/domain/local_environment.dart';

const String _tick = '  ok ';
const String _cross = '  -- ';

void main(List<String> args) async {
  final env = localHostEnvironment(DateTime.now().toUtc());
  // The local runner directly, not through `CommandRunnerFactory`: the factory
  // reaches the SSH connection pool, which reaches `path_provider`, which
  // reaches `dart:ui` — and this is a plain `dart run` script with no Flutter
  // engine under it. `real_chrome_smoke.dart` does the same, for the same
  // reason.
  const runner = LocalCommandRunner();
  final simctl = SimctlService(runner: runner);

  stdout.writeln('Host: ${env.name} (${env.kind.name})');

  final wda = WdaLocator().locate();
  if (wda == null) {
    stdout.writeln('$_cross No WebDriverAgent. Run tool/vendor/fetch_wda.sh');
    exit(1);
  }
  stdout.writeln('$_tick WebDriverAgent ${wda.source.name}: ${wda.appPath}');

  final simulators = await simctl.listSimulators();
  stdout.writeln('$_tick ${simulators.length} simulators, '
      '${simulators.where((s) => s.isAvailable).length} available');

  final IosSimulator target;
  if (args.isNotEmpty) {
    target = simulators.firstWhere(
      (s) => s.udid == args.first,
      orElse: () => throw StateError('No simulator with udid ${args.first}'),
    );
  } else {
    target = simulators.firstWhere(
      (s) => s.isAvailable && s.name.contains('iPhone'),
      orElse: () => throw StateError('No available iPhone simulator'),
    );
  }
  stdout.writeln('$_tick target ${target.displayName}  ${target.udid}');

  final weBooted = target.state != SimulatorState.booted;
  if (weBooted) {
    stdout.writeln('     booting...');
    final started = DateTime.now();
    await simctl.bootAndWait(target.udid);
    stdout.writeln(
      '$_tick booted in ${DateTime.now().difference(started).inSeconds}s',
    );
  } else {
    stdout.writeln('$_tick already booted');
  }

  final backend = WdaBackend(
    runner: runner,
    simctl: simctl,
    locator: WdaLocator(),
  );

  var failures = 0;
  Future<void> step(String what, Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (error) {
      failures++;
      stdout.writeln('$_cross $what FAILED: $error');
    }
  }

  try {
    await step('attach', () async {
      final started = DateTime.now();
      await backend.attach(target.udid);
      stdout.writeln(
        '$_tick WebDriverAgent ready in '
        '${DateTime.now().difference(started).inMilliseconds}ms',
      );
    });

    await step('screen', () async {
      final screen = await backend.screen(target.udid);
      stdout.writeln('$_tick screen (points) ${screen?.points}');
    });

    await step('ui tree', () async {
      final started = DateTime.now();
      final tree = await backend.describeUi(target.udid);
      final took = DateTime.now().difference(started).inMilliseconds;
      stdout.writeln('$_tick ui tree ${tree.nodeCount} nodes in ${took}ms');
      // Only the ones with a real rectangle: WDA reports every element in the
      // tree, and the icons on other home-screen pages come back with a zero
      // frame because they genuinely are not on screen.
      final visible = tree.allNodes.where(
        (n) => n.label.isNotEmpty && !(n.bounds?.isEmpty ?? true),
      );
      stdout.writeln('       (${visible.length} with a real rectangle)');
      for (final node in visible.take(6)) {
        stdout.writeln('       ${node.className.padRight(14)} '
            '${node.label}  ${node.bounds ?? ''}');
      }
    });

    await step('tap', () async {
      final screen = await backend.screen(target.udid);
      final points = screen?.points;
      if (points == null) throw StateError('no screen size to tap within');
      // The middle of the screen: harmless on a home screen, and it proves the
      // event reached SpringBoard rather than being accepted and dropped.
      await backend.tap(target.udid, points.width ~/ 2, points.height ~/ 2);
      stdout.writeln('$_tick tap accepted');
    });

    await step('swipe', () async {
      final screen = await backend.screen(target.udid);
      final points = screen!.points;
      await backend.swipe(
        target.udid,
        fromX: points.width ~/ 2,
        fromY: (points.height * 0.7).round(),
        toX: points.width ~/ 2,
        toY: (points.height * 0.3).round(),
        duration: const Duration(milliseconds: 300),
      );
      stdout.writeln('$_tick swipe accepted');
    });

    await step('button', () async {
      await backend.pressButton(target.udid, SimulatorButton.home);
      stdout.writeln('$_tick home button accepted');
    });

    await step('type', () async {
      await backend.inputText(target.udid, 'hello 123');
      stdout.writeln('$_tick text accepted');
    });
    await step('video', () async {
      final started = DateTime.now();
      final feed = await backend.startVideo(target.udid, fps: 30);
      stdout.writeln('$_tick video url ${feed.url}');

      // Pull the stream the way the pane does, through the same parser, and
      // check that whole JPEGs come out of it.
      //
      // This used to count bytes only, and so reported a healthy stream the
      // whole time the pane was black: bytes were arriving and nothing could
      // read them. Frames are the thing that matters.
      var frames = 0;
      var bytes = 0;
      var shortest = 1 << 30;
      final malformed = <String>[];
      final done = Completer<void>();
      final subscription = MjpegStream.connect(feed.url).listen(
        (frame) {
          frames++;
          bytes += frame.length;
          if (frame.length < shortest) shortest = frame.length;
          final soi = frame.length > 1 && frame[0] == 0xFF && frame[1] == 0xD8;
          final eoi = frame.length > 1 &&
              frame[frame.length - 2] == 0xFF &&
              frame[frame.length - 1] == 0xD9;
          if (!soi || !eoi) {
            malformed.add('frame $frames: soi=$soi eoi=$eoi len=${frame.length}');
          }
          if (frames >= 30 && !done.isCompleted) done.complete();
        },
        onError: (Object error) {
          if (!done.isCompleted) done.completeError(error);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      try {
        await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
      } finally {
        await subscription.cancel();
        await feed.stop();
      }

      final seconds = DateTime.now().difference(started).inSeconds;
      stdout.writeln(
        '$_tick video: $frames frames, ${(bytes / 1024).round()} KiB in '
        '${seconds}s (~${seconds == 0 ? frames : frames ~/ seconds} fps), '
        'smallest ${shortest ~/ 1024} KiB',
      );
      if (frames == 0) {
        throw StateError('no frames came out of the stream');
      }
      if (malformed.isNotEmpty) {
        throw StateError('frames were not whole JPEGs: ${malformed.take(3)}');
      }
    });

  } finally {
    await backend.detach(target.udid);
    stdout.writeln('$_tick WebDriverAgent stopped');
    if (weBooted) {
      await simctl.shutdown(target.udid);
      stdout.writeln('$_tick simulator shut down');
    } else {
      stdout.writeln('     left booted (it already was)');
    }
  }

  stdout.writeln(
    failures == 0 ? '\nAll checks passed.' : '\n$failures check(s) failed.',
  );
  exit(failures == 0 ? 0 : 1);
}
