import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_device_pane/ports.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/widgets.dart';
import 'package:karmashala_device_pane/pane.dart';

import 'support/fake_command_runner.dart';
import 'support/fakes.dart';

const _serial = 'emulator-5554';

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
  emulator: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\emulator\emulator.exe',
  ),
);

const _device = AndroidDevice(
  serial: _serial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'Pixel',
);

/// One `logcat -v threadtime` line, in the shape the parser expects.
String _line(String level, String tag, String message) =>
    '09-08 10:15:33.123  1234  5678 $level $tag: $message';

/// **A device's log, beside its picture.**
///
/// The finding this closes: `device_logcat` could read a device's log and a
/// person could not — on the one surface in the app where somebody is watching
/// an app run and wants to know why it just did that.
///
/// Nothing here touches a device. `AdbService` is real and its `CommandRunner`
/// is a fake, which is how every other adb test in this suite works.
void main() {
  late FakeCommandRunner runner;
  late FakeProcessHandle logcat;

  setUp(() {
    logcat = FakeProcessHandle();
    runner = FakeCommandRunner(
      processFactory: (_) => logcat,
      responder: (request) =>
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    ProviderContainer? container,
    AndroidDevice device = _device,
    Size size = const Size(900, 700),
    double logHeight = DeviceLogcatSection.defaultLogHeight,
  }) async {
    if (container == null) {
      container = ProviderContainer(
        overrides: [
          adbServiceProvider.overrideWithValue(
            AdbService(runner: runner, sdk: _sdk),
          ),
          deviceClockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox.shrink()),
                DeviceLogcatSection(device: device, logHeight: logHeight),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder strip() => find.textContaining('Logcat — Pixel');

  /// The argv adb was started with, or null when nothing was started.
  List<String>? startedArgv() =>
      runner.startRequests.isEmpty ? null : runner.startRequests.last.arguments;

  group('the tail is bounded, and says what it dropped', () {
    test('keeps the newest lines and counts the rest', () {
      final tail = LogcatTail(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        tail.add(
          LogcatEntry(
            timestamp: '09-08 10:15:33.123',
            pid: 1,
            tid: 1,
            level: LogLevel.info,
            tag: 'T',
            message: 'line $i',
          ),
        );
      }
      expect(tail.length, 3);
      expect(tail.entries.first.message, 'line 3');
      expect(tail.entries.last.message, 'line 5');
      // Counted, not estimated: this number is what the status line prints,
      // and a tail that quietly forgot would look like one that never saw.
      expect(tail.dropped, 2);
    });

    test('the level filter is applied to what is kept, not at adb', () {
      final tail = LogcatTail(capacity: 10);
      for (final level in [LogLevel.debug, LogLevel.error, LogLevel.info]) {
        tail.add(
          LogcatEntry(
            timestamp: '09-08 10:15:33.123',
            pid: 1,
            tid: 1,
            level: level,
            tag: 'T',
            message: level.code,
          ),
        );
      }
      expect(
        filterLogcat(
          tail.entries,
          const LogcatQuery(levels: {LogLevel.warning, LogLevel.error}),
        ).lines.map((l) => l.entry.message),
        ['E'],
      );
      // And widening it again loses nothing: the lines were never discarded.
      expect(
        filterLogcat(tail.entries, const LogcatQuery()).lines,
        hasLength(3),
      );
    });
  });

  testWidgets('a closed strip streams nothing', (tester) async {
    final container = await pump(tester);

    expect(strip(), findsOneWidget);
    expect(startedArgv(), isNull);
    expect(container.exists(deviceLogcatSessionProvider(_serial)), isFalse);
  });

  testWidgets('opening it attaches logcat over the same adb service', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();

    // `logcat` without `-d`: the tool takes a snapshot because a call has to
    // answer and stop; a person wants the next line.
    expect(startedArgv(), [
      '-s',
      _serial,
      'shell',
      'logcat',
      '-v',
      'threadtime',
    ]);
  });

  testWidgets('streaming shows pause, and paused shows play — nothing else', (
    tester,
  ) async {
    // Play and stop in circles were Launch and Force-stop an app a few rows
    // up; trash was "delete a file" in the files dialog.
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();

    Finder action(String tooltip, IconData glyph) => find.descendant(
      of: find.byTooltip(tooltip),
      matching: find.byIcon(glyph),
    );
    expect(action('Pause logcat', AppIcons.pause), findsOneWidget);
    expect(
      action('Clear the view (the device keeps its log)', AppIcons.broom),
      findsOneWidget,
    );
    expect(find.byIcon(AppIcons.stopCircle), findsNothing);

    await tester.tap(find.byTooltip('Pause logcat'));
    await tester.pumpAndSettle();
    expect(logcat.killed, isTrue);
    expect(action('Resume logcat', AppIcons.play), findsOneWidget);
    expect(find.byTooltip('Pause logcat'), findsNothing);
  });

  testWidgets('lines arrive and are drawn in the device\'s own words', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();

    logcat.emitStdout(_line('I', 'MyTag', 'hello from the app'));
    logcat.emitStdout('--------- beginning of main');
    await tester.pump(DeviceLogcatSession.flushWindow);
    await tester.pumpAndSettle();

    expect(find.textContaining('hello from the app'), findsOneWidget);
    // A separator banner is not a log line; the snapshot reader drops it too.
    expect(find.textContaining('beginning of main'), findsNothing);
  });

  testWidgets('errors are drawn in failure and warnings in attention, in the '
      'mono family', (tester) async {
    // The Flutter console draws an error in `failure`; the same error on the
    // device's own log was amber, and a bare 'monospace' family fell back to
    // whatever the engine picked instead of Consolas or Monaco.
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();

    // Two at a time: the open log is short, and older lines scroll away.
    Future<void> say(List<String> levels) async {
      for (final level in levels) {
        logcat.emitStdout(_line(level, 'MyTag', 'said at $level'));
      }
      await tester.pump(DeviceLogcatSession.flushWindow);
      await tester.pumpAndSettle();
    }

    final context = tester.element(find.byType(DeviceLogcatSection));
    final semantic = SemanticColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    await say(['E', 'W']);
    expect(_styleOf(tester, 'said at E').color, semantic.failure);
    expect(_styleOf(tester, 'said at W').color, semantic.attention);
    await say(['F', 'I']);
    expect(_styleOf(tester, 'said at F').color, semantic.failure);
    expect(_styleOf(tester, 'said at I').color, scheme.onSurface);
    final style = _styleOf(tester, 'said at I');
    expect(style.fontFamily, kMonoFamily);
    expect(style.fontFamilyFallback, kMonoFallback);
  });

  testWidgets('the status line carries the age of the reading, never a zero', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(strip());
    await tester.pumpAndSettle();
    // Attached, but nothing has been logged: "no line yet" rather than an age
    // that would read as a line having just arrived.
    expect(find.textContaining('Attached just now'), findsOneWidget);
    expect(find.textContaining('no line yet'), findsOneWidget);

    logcat.emitStdout(_line('W', 'MyTag', 'careful'));
    await tester.pump(DeviceLogcatSession.flushWindow);
    await tester.pumpAndSettle();
    expect(find.textContaining('last line just now'), findsOneWidget);
    expect(find.textContaining('1 line'), findsOneWidget);
  });

  testWidgets('a package filter pins logcat to that package\'s pids', (
    tester,
  ) async {
    runner.responder = (request) => request.arguments.contains('pidof')
        ? const CommandResult(exitCode: 0, stdout: '4866\n', stderr: '')
        : const CommandResult(exitCode: 0, stdout: '', stderr: '');
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(DeviceLogcatToolbar.packageKey),
      'com.example.app',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(startedArgv(), contains('--pid'));
    expect(startedArgv(), contains('4866'));
    expect(find.textContaining('only com.example.app'), findsOneWidget);
  });

  testWidgets('a package that is not running says so, and starts nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();
    final before = runner.startRequests.length;

    // pidof answers nothing, which is the default responder.
    await tester.enterText(
      find.byKey(DeviceLogcatToolbar.packageKey),
      'com.example.absent',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('is not running'), findsOneWidget);
    // `logcat --pid` with no pids would stream the whole device, which is the
    // opposite of what was asked for.
    expect(runner.startRequests.length, before);
  });

  testWidgets('closing it kills the process it started', (tester) async {
    final container = await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();
    expect(logcat.killed, isFalse);

    await tester.tap(strip());
    await tester.pumpAndSettle();

    // `autoDispose` is the whole bound: no widget watching means no session,
    // and no session means no `logcat` talking to a view nobody has open.
    expect(container.exists(deviceLogcatSessionProvider(_serial)), isFalse);
    expect(logcat.killed, isTrue);
  });

  testWidgets('the device pane mounts it under the picture', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceCommandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
          androidSdkProvider.overrideWith((ref) async => _sdk),
          devicesProvider.overrideWith((ref) async => const [_device]),
          avdsProvider.overrideWith((ref) async => const []),
          deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
          androidEmulatorArgumentsProvider.overrideWithValue(const []),
          androidSlimmingServiceProvider.overrideWithValue(null),
          slimmingOnStartProvider.overrideWithValue(false),
          slimmingKeptCategoriesProvider.overrideWithValue(const {}),
          hostCanRunSimulatorsProvider.overrideWithValue(false),
          iosSimulatorsProvider.overrideWith((ref) async => const []),
          simulatorBackendProvider.overrideWithValue(null),
          deviceClockProvider.overrideWithValue(FixedClock(testTime)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: DevicePane()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(strip(), findsOneWidget);
    // Still nothing running: the strip is one row until somebody opens it.
    expect(startedArgv(), isNull);
  });

  testWidgets('nothing polls: a quiet device costs no further adb calls', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(strip());
    await tester.pumpAndSettle();
    final settled = runner.startRequests.length + runner.requests.length;

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(
      runner.startRequests.length + runner.requests.length,
      settled,
      reason: 'the stream produces lines; nothing asks for them',
    );
  });

  group('search and filters, as in the Flutter console', () {
    /// Opens the strip on whichever device is pumped.
    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.textContaining('Logcat — '));
      await tester.pumpAndSettle();
    }

    Future<void> say(WidgetTester tester, List<String> lines) async {
      for (final line in lines) {
        logcat.emitStdout(_line('I', 'T', line));
      }
      await tester.pump(DeviceLogcatSession.flushWindow);
      await tester.pumpAndSettle();
    }

    Future<void> sayAt(
      WidgetTester tester,
      List<(String, String, String)> lines,
    ) async {
      for (final (level, tag, message) in lines) {
        logcat.emitStdout(_line(level, tag, message));
      }
      await tester.pump(DeviceLogcatSession.flushWindow);
      await tester.pumpAndSettle();
    }

    Finder field() => find.descendant(
      of: find.byKey(DeviceLogcatToolbar.searchKey),
      matching: find.byType(TextField),
    );

    Future<void> search(WidgetTester tester, String text) async {
      await tester.enterText(field(), text);
      await tester.pumpAndSettle();
    }

    testWidgets('typing highlights and counts; only-matching hides the rest', (
      tester,
    ) async {
      await pump(tester, logHeight: 400);
      await open(tester);
      await say(tester, ['alpha boom', 'beta', 'gamma BOOM']);

      await search(tester, 'boom');
      expect(find.text('2 matches'), findsOneWidget);
      // Highlighting never hides.
      expect(find.text('T: beta'), findsOneWidget);
      expect(
        _styleOf(tester, 'boom').backgroundColor,
        StateLayers.selected(Theme.of(tester.element(field())).colorScheme),
      );

      await tester.tap(find.byTooltip('Show only matching lines'));
      await tester.pumpAndSettle();
      expect(find.text('T: beta'), findsNothing);
      expect(find.text('T: alpha boom'), findsOneWidget);
      expect(find.textContaining('2 of 3 lines'), findsOneWidget);

      await tester.tap(find.byTooltip('Match case'));
      await tester.pumpAndSettle();
      expect(find.text('1 match'), findsOneWidget);
      expect(find.text('T: gamma BOOM'), findsNothing);
    });

    testWidgets('an invalid regex says so inline and hides nothing', (
      tester,
    ) async {
      await pump(tester, logHeight: 400);
      await open(tester);
      await say(tester, ['one', 'two']);
      await tester.tap(find.byTooltip('Use regular expression'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show only matching lines'));
      await search(tester, '(unclosed');
      expect(tester.takeException(), isNull);
      expect(find.text('Invalid pattern'), findsOneWidget);
      expect(find.text('T: one'), findsOneWidget);
      expect(find.text('T: two'), findsOneWidget);
    });

    testWidgets('level chips count and filter, multi-select, and the tag menu '
        'narrows — none of it restarts adb', (tester) async {
      await pump(tester, logHeight: 400);
      await open(tester);
      await sayAt(tester, [
        ('D', 'net', 'net up'),
        ('D', 'db', 'db ready'),
        ('I', 'App', 'hello'),
        ('W', 'Choreographer', 'skipped frames'),
        ('E', 'AndroidRuntime', 'boom'),
      ]);
      final started = runner.startRequests.length;

      expect(find.text('V 0'), findsOneWidget);
      expect(find.text('D 2'), findsOneWidget);
      expect(find.text('I 1'), findsOneWidget);
      expect(find.text('W 1'), findsOneWidget);
      expect(find.text('E 1'), findsOneWidget);
      expect(find.text('F 0'), findsOneWidget);

      await tester.tap(find.text('E 1'));
      await tester.pumpAndSettle();
      expect(find.text('AndroidRuntime: boom'), findsOneWidget);
      expect(find.text('App: hello'), findsNothing);

      // Multi-select: add Debug, then narrow to one tag.
      await tester.tap(find.text('D 2'));
      await tester.pumpAndSettle();
      expect(find.text('net: net up'), findsOneWidget);
      await tester.tap(find.text('All tags'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('net 1').last);
      await tester.pumpAndSettle();
      expect(find.text('net: net up'), findsOneWidget);
      expect(find.text('db: db ready'), findsNothing);
      expect(find.text('AndroidRuntime: boom'), findsNothing);
      // Counts are taken before the filters: a chip says what it would add.
      expect(find.text('I 1'), findsOneWidget);

      expect(runner.startRequests.length, started);
    });

    testWidgets('Enter and Shift+Enter step through matches, scrolling to and '
        'highlighting the current one', (tester) async {
      await pump(tester, logHeight: 500);
      await open(tester);
      await say(tester, [
        for (var i = 0; i < 200; i++) i % 50 == 0 ? 'needle $i' : 'hay $i',
      ]);
      await search(tester, 'needle');
      expect(find.text('4 matches'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('4 of 4'), findsOneWidget);

      // Wraps from the newest to the oldest, far above the fold.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('1 of 4'), findsOneWidget);
      _expectCurrentVisible(tester, 'T: needle 0');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('4 of 4'), findsOneWidget);
      _expectCurrentVisible(tester, 'T: needle 150');

      await tester.tap(find.byTooltip('Previous match (Shift+Enter)'));
      await tester.pumpAndSettle();
      expect(find.text('3 of 4'), findsOneWidget);
      _expectCurrentVisible(tester, 'T: needle 100');
    });

    testWidgets('Ctrl+F focuses the search from inside the log; Esc clears, '
        'then leaves', (tester) async {
      await pump(tester, logHeight: 400);
      await open(tester);
      await say(tester, ['first line', 'second line']);

      await tester.tap(find.text('T: second line'));
      await tester.pumpAndSettle();
      final focus = tester.widget<TextField>(field()).focusNode!;
      expect(focus.hasFocus, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);

      await tester.enterText(field(), 'first');
      await tester.pumpAndSettle();
      expect(find.text('1 match'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
      expect(find.text('1 match'), findsNothing);
      expect(focus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('follows the newest line until scrolled up, then offers a '
        'jump', (tester) async {
      await pump(tester, logHeight: 500);
      await open(tester);
      await say(tester, [for (var i = 0; i < 120; i++) 'line $i']);
      await say(tester, ['line 120']);
      expect(find.text('T: line 120'), findsOneWidget);
      expect(find.textContaining('Jump to latest'), findsNothing);

      await tester.drag(find.text('T: line 115'), const Offset(0, 300));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('T: line 105'));

      await say(tester, ['line 121', 'line 122']);
      // Not moved by what arrived, and not showing it.
      expect(tester.getTopLeft(find.text('T: line 105')), before);
      expect(find.text('T: line 122'), findsNothing);
      expect(find.text('Jump to latest (2 new)'), findsOneWidget);

      await tester.tap(find.text('Jump to latest (2 new)'));
      await tester.pumpAndSettle();
      expect(find.text('T: line 122'), findsOneWidget);
      await say(tester, ['line 123']);
      expect(find.text('T: line 123'), findsOneWidget);
      expect(find.textContaining('Jump to latest'), findsNothing);
    });

    testWidgets('the query and filters are kept per device, across closing the '
        'strip and switching devices', (tester) async {
      // A fresh process per start: each device, and each reopening, spawns
      // its own `logcat`.
      final spawned = <FakeProcessHandle>[];
      runner.processFactory = (_) {
        final handle = FakeProcessHandle();
        spawned.add(handle);
        return handle;
      };
      const other = AndroidDevice(
        serial: 'emulator-5556',
        environmentId: 'windows',
        state: DeviceConnectionState.device,
        model: 'Tablet',
      );
      final container = await pump(tester, logHeight: 400);
      await open(tester);
      await search(tester, 'keep');
      await tester.tap(find.text('E 0'));
      await tester.pumpAndSettle();

      // Closed and reopened: a new session, the same view.
      await tester.tap(strip());
      await tester.pumpAndSettle();
      expect(container.exists(deviceLogcatSessionProvider(_serial)), isFalse);
      await open(tester);
      expect(tester.widget<TextField>(field()).controller!.text, 'keep');
      FilterChip chip(String label) => tester.widget<FilterChip>(
        find.ancestor(of: find.text(label), matching: find.byType(FilterChip)),
      );
      expect(chip('E 0').selected, isTrue);

      // Another device starts clean.
      await pump(tester, container: container, device: other, logHeight: 400);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
      expect(chip('E 0').selected, isFalse);
      await search(tester, 'tablet only');

      // And the first comes back as it was left.
      await pump(tester, container: container, logHeight: 400);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field()).controller!.text, 'keep');
      expect(chip('E 0').selected, isTrue);
      expect(
        container.read(deviceLogcatViewProvider(other.serial)).query.text,
        'tablet only',
      );
    });

    testWidgets('a new line does not rebuild the toolbar', (tester) async {
      await pump(tester, logHeight: 400);
      await open(tester);
      await say(tester, ['first']);
      final builds = DeviceLogcatToolbar.debugBuilds;
      await say(tester, ['second', 'third']);
      expect(find.text('T: third'), findsOneWidget);
      expect(find.text('I 3'), findsOneWidget);
      expect(DeviceLogcatToolbar.debugBuilds, builds);
    });

    testWidgets('clearing empties the view, not the tail or the device', (
      tester,
    ) async {
      final container = await pump(tester, logHeight: 400);
      await open(tester);
      await say(tester, ['old news']);
      final ran = runner.requests.length + runner.startRequests.length;

      await tester.tap(
        find.byTooltip('Clear the view (the device keeps its log)'),
      );
      await tester.pumpAndSettle();
      expect(find.text('T: old news'), findsNothing);
      expect(find.text('Cleared. New lines will appear here.'), findsOneWidget);
      // The tail still holds it, and nothing was asked of adb (no logcat -c).
      expect(container.read(deviceLogcatSessionProvider(_serial)).kept, 1);
      expect(runner.requests.length + runner.startRequests.length, ran);

      await say(tester, ['fresh']);
      expect(find.text('T: fresh'), findsOneWidget);
      expect(find.text('T: old news'), findsNothing);
    });

    testWidgets('copy takes the lines shown, in the device\'s own format', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester, logHeight: 400);
      await open(tester);
      await sayAt(tester, [
        ('I', 'App', 'keep me'),
        ('D', 'App', 'not me'),
        ('I', 'App', 'keep me too'),
      ]);
      await search(tester, 'keep');
      await tester.tap(find.byTooltip('Show only matching lines'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Copy the lines shown'));
      await tester.pumpAndSettle();
      expect(
        copied,
        '09-08 10:15:33.123 1234 5678 I App: keep me\n'
        '09-08 10:15:33.123 1234 5678 I App: keep me too',
      );
      expect(find.text('Copied 2 lines.'), findsOneWidget);
    });

    testWidgets('a narrow panel folds chips and toggles into one menu', (
      tester,
    ) async {
      await pump(tester, size: const Size(240, 700), logHeight: 400);
      await open(tester);
      await sayAt(tester, [('I', 'App', 'fine'), ('E', 'App', 'bad')]);
      expect(find.byType(FilterChip), findsNothing);

      await tester.tap(find.byTooltip('Filters and search options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('E Error 1'));
      await tester.pumpAndSettle();
      expect(find.text('App: fine'), findsNothing);
      expect(find.text('App: bad'), findsOneWidget);

      await search(tester, 'bad');
      // The count moves to the status row.
      expect(find.text('1 match'), findsOneWidget);
    });

    testWidgets('the filtered view is capped for rendering, and says so', (
      tester,
    ) async {
      await pump(tester, logHeight: 400);
      await open(tester);
      await say(tester, [for (var i = 0; i < 520; i++) 'row $i']);
      expect(
        find.textContaining('showing newest 400 of 520 lines'),
        findsOneWidget,
      );
    });
  });
}

/// The current match is on screen and drawn on the current-match fill.
void _expectCurrentVisible(WidgetTester tester, String text) {
  final line = find.text(text);
  expect(line, findsOneWidget, reason: '$text should be built');
  final list = tester.getRect(find.byType(ListView));
  final rect = tester.getRect(line);
  expect(
    list.contains(rect.center),
    isTrue,
    reason: '$text at $rect should be inside $list',
  );
  final scheme = Theme.of(tester.element(line)).colorScheme;
  final selectable = tester.widget<SelectableText>(
    find.ancestor(of: line, matching: find.byType(SelectableText)),
  );
  final spans = <InlineSpan>[];
  selectable.textSpan!.visitChildren((span) {
    spans.add(span);
    return true;
  });
  expect(
    spans.any(
      (span) =>
          span.style?.backgroundColor == StateLayers.textSelection(scheme),
    ),
    isTrue,
  );
}

/// The style [text] is drawn in: the span holding it, merged over every span
/// above it, so a colour set on the line and a fill set on a match both count.
TextStyle _styleOf(WidgetTester tester, String text) {
  final selectable = tester
      .widgetList<SelectableText>(find.byType(SelectableText))
      .firstWhere(
        (widget) => (widget.textSpan?.toPlainText() ?? widget.data ?? '')
            .contains(text),
      );
  TextStyle? found;
  void visit(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is TextSpan) {
      if (found == null && (span.text ?? '').contains(text)) found = style;
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }
  }

  final root = selectable.textSpan ?? TextSpan(text: selectable.data);
  visit(root, selectable.style ?? const TextStyle());
  return found!;
}
