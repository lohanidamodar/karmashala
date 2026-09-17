import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_devices/pane.dart';

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
      responder: (request) => const CommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      ),
    );
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        adbServiceProvider.overrideWithValue(
          AdbService(runner: runner, sdk: _sdk),
        ),
        deviceClockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Column(
              children: [
                Expanded(child: SizedBox.shrink()),
                DeviceLogcatSection(device: _device),
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
        tail.tail(minLevel: LogLevel.warning).map((e) => e.message),
        ['E'],
      );
      // And raising it back loses nothing: the lines were never discarded.
      expect(tail.tail(minLevel: LogLevel.verbose), hasLength(3));
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
    expect(
      startedArgv(),
      ['-s', _serial, 'shell', 'logcat', '-v', 'threadtime'],
    );
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
    expect(action('Clear what is on screen', AppIcons.broom), findsOneWidget);
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
    expect(find.textContaining('1 kept'), findsOneWidget);
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

    await tester.enterText(find.byType(TextField), 'com.example.app');
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
    await tester.enterText(find.byType(TextField), 'com.example.absent');
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
