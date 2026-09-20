import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_devices/widgets.dart';

/// The manners every device control shares, on either platform.
///
/// They lived in the simulator pane alone, so the Android row — which had only
/// key presses, none of which can fail visibly — grew none of them. The moment
/// Android gained a screenshot and a deep link, a failure there would have been
/// swallowed and a double press would have run two processes at once.
Future<void> _pump(WidgetTester tester, List<DeviceControl> controls) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DeviceControlBar(controls: controls)),
      ),
    );

void main() {
  testWidgets('says out loud when a control fails', (tester) async {
    await _pump(tester, [
      DeviceControl(
        name: 'Screenshot',
        tooltip: 'Save a screenshot to the Desktop',
        icon: AppIcons.image,
        onPressed: () async => throw StateError('device went away'),
        buttonKey: const Key('shot'),
      ),
    ]);

    await tester.tap(find.byKey(const Key('shot')));
    await tester.pumpAndSettle();

    // Named, because a caught-and-dropped failure is indistinguishable from
    // the device ignoring the tap.
    expect(find.textContaining('Screenshot failed:'), findsOneWidget);
    expect(find.textContaining('device went away'), findsOneWidget);
  });

  testWidgets('refuses a second press while the first is still running', (
    tester,
  ) async {
    final gate = Completer<void>();
    var runs = 0;
    await _pump(tester, [
      DeviceControl(
        name: 'Appearance',
        tooltip: 'Switch to dark appearance',
        icon: AppIcons.circleHalf,
        onPressed: () async {
          runs++;
          await gate.future;
        },
        buttonKey: const Key('appearance'),
      ),
    ]);

    await tester.tap(find.byKey(const Key('appearance')));
    await tester.pump();
    // Each of these spawns a process on the device; two of them racing is how
    // an appearance toggle ends up back where it started.
    await tester.tap(find.byKey(const Key('appearance')), warnIfMissed: false);
    await tester.pump();

    expect(runs, 1);
    gate.complete();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('appearance')));
    await tester.pump();
    expect(runs, 2, reason: 'the gate lifts once the first one is done');
  });

  testWidgets('a control with nothing behind it is disabled, not hidden', (
    tester,
  ) async {
    // A row that loses buttons when the device goes reads as a fault in the
    // app; an inert one with a tooltip says what is missing.
    await _pump(tester, const [
      DeviceControl(
        name: 'Home',
        tooltip: 'Start the live view to use the device controls',
        icon: AppIcons.circle,
        onPressed: null,
        buttonKey: Key('home'),
      ),
    ]);

    expect(find.byKey(const Key('home')), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('home'))).onPressed,
      isNull,
    );
  });

  testWidgets('a toggle shows on as the selected state layer', (tester) async {
    Future<void> pump({required bool on}) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DeviceControlBar(
            controls: [
              DeviceControl(
                name: 'Appearance',
                tooltip: 'Switch appearance',
                icon: AppIcons.moon,
                selected: on,
                onPressed: () async {},
                buttonKey: const Key('toggle'),
              ),
              DeviceControl(
                name: 'Screenshot',
                tooltip: 'Save a screenshot',
                icon: AppIcons.camera,
                onPressed: () async {},
                buttonKey: const Key('plain'),
              ),
            ],
          ),
        ),
      ),
    );
    Color? fill(String key) {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Material),
            )
            .first,
      );
      return material.color;
    }

    await pump(on: true);
    final scheme = Theme.of(
      tester.element(find.byKey(const Key('toggle'))),
    ).colorScheme;
    expect(fill('toggle'), StateLayers.selected(scheme));
    expect(
      tester.widget<IconButton>(find.byKey(const Key('plain'))).isSelected,
      isNull,
      reason: 'a plain action is not a toggle',
    );

    await pump(on: false);
    expect(fill('toggle'), isNot(StateLayers.selected(scheme)));
    // The glyph does not change with the state; the layer says it.
    expect(
      find.descendant(
        of: find.byKey(const Key('toggle')),
        matching: find.byIcon(AppIcons.moon),
      ),
      findsOneWidget,
    );
  });

  group('desktopScreenshotPath', () {
    // The home is named rather than read. Reading it made this suite agree
    // with whichever shell started it: Git Bash hands the Dart process
    // `HOME=C:\Users\<user>`, whose drive letter is a colon and failed the
    // colon check, while PowerShell sets no `HOME` at all and the test used
    // to return early and assert nothing. Neither of those is a verdict on
    // the code under test.
    const home = {'HOME': '/Users/someone'};

    test('puts both platforms on the Desktop under the same name', () {
      // The Simulator's own Cmd+S writes there, and it is the one place a
      // person will look. Drifting into two folders is the failure this shared
      // helper exists to prevent.
      final ios = desktopScreenshotPath('Simulator', environment: home)!;
      final android = desktopScreenshotPath('Android', environment: home)!;

      expect(ios, contains('/Desktop/Simulator Screen Shot '));
      expect(android, contains('/Desktop/Android Screen Shot '));
      expect(ios, endsWith('.png'));
      expect(
        ios,
        isNot(contains(':')),
        reason: 'a colon in a filename is a path separator to the Finder',
      );
    });

    test('a host with no home directory is given no path at all', () {
      // The branch the early return used to hide: the callers check for null
      // and say so, rather than writing to a path built from the word "null".
      expect(desktopScreenshotPath('Simulator', environment: const {}), isNull);
    });
  });
}
