/// The phone's own log, and the copy that is the point of it.
///
/// The companion writes to the ring buffer and a file, but the file lives in
/// the app-support directory, which on Android nobody can reach — so a screen
/// that shows the lines and a button that puts them on the clipboard are what
/// turn "it just says connecting" into a report with evidence in it.
library;

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'companion_test_support.dart';

void main() {
  late Diagnostics previous;

  setUp(() {
    previous = Diagnostics.instance;
    // Its own instance, so a test's lines cannot leak into another's and the
    // console echo does not spray the test output.
    Diagnostics.instance = Diagnostics(echoToConsole: false);
  });

  tearDown(() => Diagnostics.instance = previous);

  void log(Level level, String channel, String message) {
    Diagnostics.instance.handle(LogRecord(level, message, channel));
  }

  testWidgets('shows the warnings and errors, not the chatter', (tester) async {
    log(Level.INFO, 'companion.lan', 'beacon heard from 192.168.1.9');
    log(Level.WARNING, 'companion.gateway', 'dial refused');
    log(Level.SEVERE, 'companion.gateway', 'relay closed the channel');

    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionLogScreen(),
    );

    // Problems only is the default: the line that explains a failure should
    // not have to be scrolled for past a hundred lines of link chatter.
    expect(find.textContaining('dial refused'), findsOneWidget);
    expect(find.textContaining('relay closed the channel'), findsOneWidget);
    expect(find.textContaining('beacon heard'), findsNothing);
  });

  testWidgets('and everything, once asked', (tester) async {
    log(Level.INFO, 'companion.lan', 'beacon heard from 192.168.1.9');
    log(Level.WARNING, 'companion.gateway', 'dial refused');

    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionLogScreen(),
    );
    await tester.tap(find.byTooltip('Show everything'));
    await tester.pump();

    expect(find.textContaining('beacon heard'), findsOneWidget);
    expect(find.textContaining('dial refused'), findsOneWidget);
  });

  testWidgets('says so rather than looking broken when there is nothing', (
    tester,
  ) async {
    log(Level.INFO, 'companion.lan', 'beacon heard from 192.168.1.9');

    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionLogScreen(),
    );

    // A clean run is the common case, and an empty screen would read as a
    // broken one — so it names the state and points at the way to see more.
    expect(find.textContaining('No warnings or errors'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Copy'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
      reason: 'nothing to copy',
    );
  });

  testWidgets('copy carries the build identity, always', (tester) async {
    log(Level.WARNING, 'companion.gateway', 'dial refused');

    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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

    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionLogScreen(),
    );
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();

    expect(copied, hasLength(1));
    // The version and OS lead, whatever the buffer holds: a pasted log that
    // cannot say which build wrote it cannot answer the first question anyone
    // asks of it, and a long session may have evicted the startup line.
    expect(copied.single, startsWith('Karmashala '));
    expect(copied.single, contains('dial refused'));
  });

  testWidgets('settings offers the way in', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionSettingsScreen(),
    );

    final view = find.widgetWithText(OutlinedButton, 'View log');
    expect(view, findsOneWidget);
    await tester.tap(view);
    await tester.pumpAndSettle();

    expect(find.byType(CompanionLogScreen), findsOneWidget);
  });

  testWidgets('reads at 200% text without clipping its own title', (
    tester,
  ) async {
    log(Level.SEVERE, 'companion.gateway', 'relay closed the socket');
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionLogScreen(),
      textScale: 2.0,
    );

    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.textContaining('relay closed the socket'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
