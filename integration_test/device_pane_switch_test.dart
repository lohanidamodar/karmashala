// Loop 40 — drives the **real** device pane against **real** devices.
//
// Loops 27, 27a, 34 and 36 all recorded the same gap: everything below the
// widget layer was verified on hardware, but the pane itself "was not driven by
// hand". These three bugs live in the pane, so that gap is exactly where they
// hid. This test closes it: no provider overrides, no fakes — the shipped
// `DevicePane`, the shipped providers, real adb, real scrcpy, real media_kit.
//
// Run it with a phone and one emulator attached:
//
//   flutter test integration_test/device_pane_switch_test.dart -d windows
//
// It is deliberately not part of `flutter test`: it needs hardware, an
// interactive Windows desktop, and it shuts the emulator down at the end.

import 'dart:io';

import 'package:chitragupta/src/features/devices/application/device_providers.dart';
import 'package:chitragupta/src/features/devices/domain/android_device.dart';
import 'package:chitragupta/src/features/devices/presentation/device_pane.dart';
import 'package:chitragupta/src/features/devices/presentation/device_stream_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const _adb =
    r'C:\Users\dlohani\AppData\Local\Android\Sdk\platform-tools\adb.exe';

/// Everything this run observed, written where it can be read afterwards: the
/// test binding does not forward the app's stdout to the reporter.
final File _evidence = File(
  '${Directory.systemTemp.path}${Platform.pathSeparator}loop40_evidence.log',
);

void _note(String line) {
  _evidence.writeAsStringSync('$line\n', mode: FileMode.append);
  debugPrint(line);
}

Future<String> _run(List<String> args) async {
  final result = await Process.run(_adb, args);
  return '${result.stdout}${result.stderr}';
}

/// Serials adb currently reports as ready.
Future<List<String>> _readySerials() async {
  final out = await _run(['devices']);
  return [
    for (final line in out.split('\n').skip(1))
      if (line.trim().endsWith('\tdevice')) line.split('\t').first.trim(),
  ];
}

/// `adb forward --list` lines belonging to one serial. A live scrcpy session
/// owns exactly one; this is how "the stream really moved" is proved rather
/// than assumed from what the UI says about itself.
Future<List<String>> _scrcpyForwards(String serial) async {
  final out = await _run(['forward', '--list']);
  return [
    for (final line in out.split('\n'))
      if (line.contains('scrcpy_') && line.trim().startsWith(serial))
        line.trim(),
  ];
}

/// The command line of every running `emulator.exe`, so "-no-window really was
/// passed" is read off the OS rather than trusted.
Future<String> _emulatorCommandLines() async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-Command',
    "Get-CimInstance Win32_Process -Filter \"Name like 'emulator%'\" "
        '| Select-Object -ExpandProperty CommandLine',
  ]);
  return '${result.stdout}';
}

/// Clears scrcpy tunnels left behind by an earlier run.
///
/// The app reaps orphans for the serial it is *starting*, so a tunnel left on
/// the other device survives into the next run — and this test reads those
/// tunnels as evidence of where the stream is. Without this the second run of
/// the day measures the first run's litter.
Future<void> _reapForwards() async {
  final out = await _run(['forward', '--list']);
  for (final line in out.split('\n')) {
    if (!line.contains('scrcpy_')) continue;
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    await _run(['-s', parts[0], 'forward', '--remove', parts[1]]);
    _note('[loop40] reaped stale tunnel: ${line.trim()}');
  }
}

Future<({int width, int height})> _screenSize(String serial) async {
  final out = await _run(['-s', serial, 'shell', 'wm', 'size']);
  final match = RegExp(r'Physical size:\s*(\d+)x(\d+)').firstMatch(out)!;
  return (
    width: int.parse(match.group(1)!),
    height: int.parse(match.group(2)!),
  );
}

/// The visible labels on a device's current screen, via `uiautomator`.
Future<Set<String>> _screenLabels(String serial) async {
  const path = '/data/local/tmp/loop40_dump.xml';
  await _run(['-s', serial, 'shell', 'uiautomator', 'dump', path]);
  final xml = await _run(['-s', serial, 'shell', 'cat', path]);
  return {
    for (final match in RegExp(r'text="([^"]+)"').allMatches(xml))
      match.group(1)!,
  };
}

/// Top-level Settings rows on the device's current screen, in reading order,
/// with each row's centre in device pixels.
///
/// The node's own centre is used rather than its clickable ancestor's — inside
/// a list the nearest clickable ancestor is often the list itself, whose centre
/// is a completely different row (Loop 34).
Future<List<({String label, int x, int y})>> _settingsRows(
  String serial,
  ({int width, int height}) screen,
) async {
  const path = '/data/local/tmp/loop40_dump.xml';
  await _run(['-s', serial, 'shell', 'uiautomator', 'dump', path]);
  final xml = await _run(['-s', serial, 'shell', 'cat', path]);
  final rows = <({String label, int x, int y})>[];
  for (final node in RegExp(r'<node[^>]*>').allMatches(xml)) {
    final raw = node.group(0)!;
    final label = RegExp(r'text="([^"]*)"').firstMatch(raw)?.group(1) ?? '';
    if (label.trim().isEmpty) continue;
    final bounds = RegExp(
      r'bounds="\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]"',
    ).firstMatch(raw);
    if (bounds == null) continue;
    final l = int.parse(bounds.group(1)!);
    final t = int.parse(bounds.group(2)!);
    final r = int.parse(bounds.group(3)!);
    final b = int.parse(bounds.group(4)!);
    final x = (l + r) ~/ 2;
    final y = (t + b) ~/ 2;
    // Off-screen rows keep their bounds when scrolled away; tapping their
    // centre would hit whatever is really there.
    if (x < 0 || y < 0 || x >= screen.width || y >= screen.height) continue;
    // Skip the status bar and the search field at the top of Settings.
    if (y < screen.height * 0.18) continue;
    if (r - l < 40 || b - t < 40) continue;
    rows.add((label: label, x: x, y: y));
  }
  return rows;
}

/// Pumps real frames for [duration]. `pumpAndSettle` cannot be used anywhere
/// near this pane: a live video and a progress indicator never settle.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Pumps until [ready] holds, or fails after [timeout].
Future<void> _pumpUntil(
  WidgetTester tester,
  String what,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  fail('Timed out waiting for: $what');
}

/// The rectangle the video fills, once there is one.
///
/// Not simply `getRect`: when the watchdog fires, the pane replaces the picture
/// with a spinner while it reconnects, and a measurement taken then throws.
Future<Rect> _pictureRect(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    'the picture to be on screen',
    () => find.byType(AspectRatio).evaluate().isNotEmpty,
  );
  return tester.getRect(find.byType(AspectRatio).first);
}

Finder _bannerTextContaining(String needle) => find.descendant(
  of: find.byType(TransportBanner),
  matching: find.textContaining(needle),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late String phone;
  late String emulator;

  setUpAll(() async {
    final ready = await _readySerials();
    phone = ready.firstWhere(
      (s) => !s.startsWith('emulator-'),
      orElse: () => fail('No physical device attached. Found: $ready'),
    );
    emulator = ready.firstWhere(
      (s) => s.startsWith('emulator-'),
      orElse: () => fail('No emulator running. Found: $ready'),
    );
    _note('[loop40] phone=$phone emulator=$emulator');
    await _reapForwards();
  });

  tearDown(_reapForwards);

  /// The shipped pane, with **no** overrides at all.
  Future<void> pumpPane(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: DevicePane())),
      ),
    );
    await _pumpUntil(
      tester,
      'the device list to load',
      () => find.byType(DropdownButton<String>).evaluate().isNotEmpty,
    );
    // Discovery, `adb devices -l` and `emulator -list-avds` all have to land.
    await _pumpFor(tester, const Duration(seconds: 3));
  }

  Future<void> selectFromDropdown(WidgetTester tester, String serial) async {
    await tester.tap(find.byType(DropdownButton<String>));
    await _pumpFor(tester, const Duration(milliseconds: 600));
    await tester.tap(find.textContaining(serial).last);
    await _pumpFor(tester, const Duration(milliseconds: 600));
  }

  testWidgets('the live view follows the device picker, on real hardware', (
    tester,
  ) async {
    await pumpPane(tester);

    // ---- start on the phone, from its own row in the list -------------------
    await tester.tap(find.byKey(Key('preview-$phone')));
    await _pumpUntil(
      tester,
      'the live view to start on $phone',
      () => _bannerTextContaining(phone).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _pumpFor(tester, const Duration(seconds: 3));

    final phoneForwards = await _scrcpyForwards(phone);
    _note('[loop40] streaming $phone, forwards=$phoneForwards');
    expect(phoneForwards, isNotEmpty, reason: 'no scrcpy tunnel to the phone');
    expect(await _scrcpyForwards(emulator), isEmpty);

    // ---- switch to the emulator --------------------------------------------
    // This is the bug: the picker moved, the picture did not.
    await selectFromDropdown(tester, emulator);
    await _pumpUntil(
      tester,
      'the live view to move to $emulator',
      () => _bannerTextContaining(emulator).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _pumpFor(tester, const Duration(seconds: 4));

    // What the UI says…
    expect(_bannerTextContaining(emulator), findsOneWidget);
    expect(_bannerTextContaining(phone), findsNothing);
    // …and what is actually on the wire. The phone's tunnel is gone and the
    // emulator has one of its own: the picture really is a different device.
    final afterPhone = await _scrcpyForwards(phone);
    final afterEmulator = await _scrcpyForwards(emulator);
    _note('[loop40] after switch: phone=$afterPhone emulator=$afterEmulator');
    expect(afterPhone, isEmpty, reason: 'the phone stream was left running');
    expect(afterEmulator, isNotEmpty);

    // ---- a tap lands on the device now being shown --------------------------
    // The two screens are very different sizes, so a tap mapped through the
    // wrong one cannot land where it should by accident.
    final phoneScreen = await _screenSize(phone);
    final emulatorScreen = await _screenSize(emulator);
    _note(
      '[loop40] screens: phone=${phoneScreen.width}x${phoneScreen.height} '
      'emulator=${emulatorScreen.width}x${emulatorScreen.height}',
    );
    expect(emulatorScreen, isNot(phoneScreen));

    await _run([
      '-s',
      emulator,
      'shell',
      'am',
      'start',
      '-a',
      'android.settings.SETTINGS',
    ]);
    await _pumpFor(tester, const Duration(seconds: 5));

    // The picture is the AspectRatio box the video fills, so widget->device is
    // a pure scale (Loop 27's reason for the AspectRatio in the first place).
    final picture = await _pictureRect(tester);

    // Targets are read off the device rather than hardcoded: two Android builds
    // do not put the same words in the same place. A Settings row is used
    // because AOSP titles the page it opens with the row's own label, so
    // "the tap landed on the row I aimed at" is checkable, not just
    // "something happened".
    final candidates = await _settingsRows(emulator, emulatorScreen);
    _note('[loop40] tap candidates: $candidates');
    expect(candidates, isNotEmpty, reason: 'no Settings row found to tap');

    String? opened;
    Set<String> before = const {};
    Set<String> after = const {};
    for (final candidate in candidates.take(3)) {
      before = await _screenLabels(emulator);
      final fx = candidate.x / emulatorScreen.width;
      final fy = candidate.y / emulatorScreen.height;
      final tapAt = Offset(
        picture.left + fx * picture.width,
        picture.top + fy * picture.height,
      );
      _note(
        '[loop40] tapping "${candidate.label}" at device '
        '(${candidate.x},${candidate.y}) = fraction '
        '(${fx.toStringAsFixed(3)},${fy.toStringAsFixed(3)}) '
        '-> widget $tapAt inside picture $picture',
      );
      await tester.tapAt(tapAt);
      await _pumpFor(tester, const Duration(seconds: 4));
      after = await _screenLabels(emulator);
      if (after.difference(before).isEmpty &&
          before.difference(after).isEmpty) {
        _note('[loop40] "${candidate.label}" did not change the screen');
        continue;
      }
      opened = candidate.label;
      _note('[loop40] screen changed; now shows: ${after.take(14).toList()}');
      // Landing on the *wrong* row also changes the screen, so this is the
      // assertion that matters: the page that opened is the one aimed at.
      expect(
        after,
        contains(candidate.label),
        reason:
            'the tap changed the screen but opened the wrong thing — '
            'aimed at "${candidate.label}", got ${after.take(14).toList()}',
      );
      expect(
        before.difference(after).length,
        greaterThanOrEqualTo(3),
        reason: 'the Settings list did not go away; did the tap land on a row?',
      );
      break;
    }
    expect(
      opened,
      isNotNull,
      reason: 'no tap in the live view reached $emulator at all',
    );

    // ---- stop, and leave nothing behind -------------------------------------
    await tester.tap(find.text('Stop'));
    await _pumpFor(tester, const Duration(seconds: 3));
    expect(await _scrcpyForwards(phone), isEmpty);
    expect(await _scrcpyForwards(emulator), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('screen sizes come from the device named, on real hardware', (
    tester,
  ) async {
    // Bug 3's core: ask for a device by serial and get *that* device's screen.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(androidSdkProvider.future);
    final devices = await container.read(devicesProvider.future);
    expect(
      devices.map((AndroidDevice d) => d.serial),
      containsAll([phone, emulator]),
    );

    final fromApp = {
      phone: await container.read(deviceScreenSizeProvider(phone).future),
      emulator: await container.read(deviceScreenSizeProvider(emulator).future),
    };
    final fromAdb = {
      phone: await _screenSize(phone),
      emulator: await _screenSize(emulator),
    };
    _note('[loop40] app=$fromApp adb=$fromAdb');

    expect(fromApp[phone]!.width, fromAdb[phone]!.width);
    expect(fromApp[phone]!.height, fromAdb[phone]!.height);
    expect(fromApp[emulator]!.width, fromAdb[emulator]!.width);
    expect(fromApp[emulator]!.height, fromAdb[emulator]!.height);
    expect(fromApp[phone], isNot(fromApp[emulator]));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a running emulator is stopped from the list, live view never '
      'started', (tester) async {
    // The owner's report, end to end: see it running, stop it, without going
    // anywhere near the live view.
    await pumpPane(tester);
    expect(
      find.text('Live view'),
      findsOneWidget,
      reason: 'the live view must be off for this to prove anything',
    );

    final row = find.byKey(Key('stop-emulator-$emulator'));
    expect(row, findsOneWidget, reason: 'no stop control for $emulator');

    await tester.tap(row);
    await _pumpFor(tester, const Duration(seconds: 1));
    expect(find.textContaining('is lost'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop emulator'));
    await _pumpFor(tester, const Duration(seconds: 20));

    final left = await _readySerials();
    _note('[loop40] devices after the stop: $left');
    expect(left, isNot(contains(emulator)));
    expect(left, contains(phone), reason: 'the phone must be untouched');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('an AVD boots headless and the live preview is the only view', (
    tester,
  ) async {
    // The owner's request: no emulator window, watched here instead — the
    // Android Studio embedded-emulator experience. The open question was
    // whether scrcpy can capture a `-no-window` emulator at all; it captures
    // the device's display through `app_process` on the device, not the host
    // window, so it should. Verified rather than assumed.
    await pumpPane(tester);

    const avd = 'loop40_probe';
    final start = find.byKey(const Key('start-avd-$avd'));
    expect(start, findsOneWidget, reason: '$avd should be listed and stopped');
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('headless-emulator-toggle')),
    );
    expect(toggle.value, isTrue, reason: 'headless is meant to be the default');

    await tester.tap(start);
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(
      find.text('starting…'),
      findsOneWidget,
      reason: 'headless there is nothing else to show for the click',
    );

    // Boot, then the live view, in one flow.
    await _pumpUntil(
      tester,
      'the headless emulator to boot and its live view to open',
      () => find.byType(TransportBanner).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 5),
    );
    await _pumpFor(tester, const Duration(seconds: 8));

    final serials = await _readySerials();
    final booted = serials.firstWhere((s) => s.startsWith('emulator-'));
    _note('[loop40] booted headless: $booted');

    final commandLines = await _emulatorCommandLines();
    _note('[loop40] emulator command line: ${commandLines.trim()}');
    expect(
      commandLines,
      contains('-no-window'),
      reason: 'the emulator was started with a window after all',
    );

    // The preview is genuinely rendering it: the watchdog reports "stalled"
    // when bytes stop decoding, and it has not.
    expect(_bannerTextContaining(booted), findsOneWidget);
    expect(
      find.byType(StreamStalledOverlay),
      findsNothing,
      reason: 'scrcpy could not capture a headless emulator',
    );

    // …and gestures reach it, which is the other half of "the only view".
    final screen = await _screenSize(booted);
    await _run([
      '-s',
      booted,
      'shell',
      'am',
      'start',
      '-a',
      'android.settings.SETTINGS',
    ]);
    await _pumpFor(tester, const Duration(seconds: 5));
    final picture = await _pictureRect(tester);
    final rows = await _settingsRows(booted, screen);
    _note('[loop40] headless tap candidates: $rows');
    expect(rows, isNotEmpty);

    var opened = false;
    for (final row in rows.take(3)) {
      final before = await _screenLabels(booted);
      final tapAt = Offset(
        picture.left + (row.x / screen.width) * picture.width,
        picture.top + (row.y / screen.height) * picture.height,
      );
      _note('[loop40] headless tap "${row.label}" at $tapAt');
      await tester.tapAt(tapAt);
      await _pumpFor(tester, const Duration(seconds: 4));
      final after = await _screenLabels(booted);
      if (after.difference(before).isEmpty &&
          before.difference(after).isEmpty) {
        continue;
      }
      _note('[loop40] headless screen changed: ${after.take(12).toList()}');
      expect(after, contains(row.label));
      opened = true;
      break;
    }
    expect(opened, isTrue, reason: 'no gesture reached the headless emulator');

    await tester.tap(find.text('Stop'));
    await _pumpFor(tester, const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('the emulator capture profile still fits headless', (
    tester,
  ) async {
    // Loop 27a pinned emulators to 640@20 because the software encoder
    // sustains ~13 fps and asking for more queues frames *inside the device*,
    // where they never come back. Headless changes the host's workload, so the
    // question is whether that still holds. Measured, not assumed.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(androidSdkProvider.future);
    final service = container.read(deviceStreamServiceProvider)!;
    final serial = (await _readySerials()).firstWhere(
      (s) => s.startsWith('emulator-'),
    );

    Future<void> scroll() async {
      // A static screen encodes almost nothing; the profile only matters under
      // load, so the device is kept busy for the whole measurement.
      for (var i = 0; i < 12; i++) {
        await _run([
          '-s',
          serial,
          'shell',
          'input',
          'swipe',
          '360',
          '1200',
          '360',
          '300',
          '300',
        ]);
      }
    }

    Future<String> measure(int maxSize, int maxFps) async {
      final session = await service.start(
        serial,
        maxSize: maxSize,
        maxFps: maxFps,
      );
      final samples = <({int frames, int lagUs})>[];
      final busy = scroll();
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final mark = session.mark;
        if (mark.frames == 0) continue;
        samples.add((frames: mark.frames, lagUs: mark.arrivalUs - mark.ptsUs));
      }
      await busy;
      final frames = samples.isEmpty ? 0 : samples.last.frames;
      await session.stop();
      if (samples.isEmpty) return '$maxSize@$maxFps: no frames at all';
      // Self-anchored: the smallest observed capture-to-arrival difference is
      // the clock offset plus the true floor, so the *growth* above it is the
      // queue. A saturated encoder makes this climb across the run.
      final floor = samples.map((s) => s.lagUs).reduce((a, b) => a < b ? a : b);
      final queued = samples.map((s) => s.lagUs - floor).toList()..sort();
      final p50 = queued[queued.length ~/ 2] / 1000;
      final p90 = queued[(queued.length * 9) ~/ 10] / 1000;
      final worst = queued.last / 1000;
      final fps = frames / 20;
      return '$maxSize@$maxFps: ${fps.toStringAsFixed(1)} fps sustained, '
          'queue p50=${p50.toStringAsFixed(0)}ms '
          'p90=${p90.toStringAsFixed(0)}ms max=${worst.toStringAsFixed(0)}ms';
    }

    final shipped = await measure(640, 20);
    _note('[loop40] headless capture, shipped profile — $shipped');
    final greedy = await measure(1024, 60);
    _note('[loop40] headless capture, 1024@60 for comparison — $greedy');

    expect(shipped, contains('fps sustained'));
    expect(greedy, contains('fps sustained'));
    await _reapForwards();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
