import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/probe_banner.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// The switch itself, and the rule that a probe never opens the real database.
void main() {
  group('reading the switch', () {
    test('KARMASHALA_PROBE=1 and its spellings turn it on', () {
      for (final value in ['1', 'true', 'TRUE', 'yes', 'on', ' 1 ']) {
        expect(
          ProbeMode.fromEnvironment({'KARMASHALA_PROBE': value}).enabled,
          isTrue,
          reason: value,
        );
      }
    });

    test('unset, empty or 0 is not a probe', () {
      for (final env in [
        <String, String>{},
        {'KARMASHALA_PROBE': ''},
        {'KARMASHALA_PROBE': '0'},
        {'KARMASHALA_PROBE': 'false'},
        // The data-folder override alone is not a probe.
        {'KARMASHALA_DATA_DIR': r'C:\x'},
      ]) {
        expect(ProbeMode.fromEnvironment(env).enabled, isFalse, reason: '$env');
      }
    });

    test('it carries the data folder it was given', () {
      final probe = ProbeMode.fromEnvironment({
        'KARMASHALA_PROBE': '1',
        'KARMASHALA_DATA_DIR': '  /tmp/probe  ',
      });
      expect(probe.dataDirectory, '/tmp/probe');
    });
  });

  group('the data folder', () {
    late Directory root;
    late Directory real;
    var defaultAsked = 0;

    setUp(() {
      root = Directory.systemTemp.createTempSync('karmashala_probe_dir_');
      real = Directory(p.join(root.path, 'real'))..createSync();
      defaultAsked = 0;
    });
    tearDown(() => removeTempDirectory(root));

    Future<Directory> platformDefault() async {
      defaultAsked++;
      return real;
    }

    test('a probe without KARMASHALA_DATA_DIR is refused', () async {
      await expectLater(
        resolveDataDirectory(
          probe: ProbeMode.on,
          platformDefault: platformDefault,
        ),
        throwsA(
          isA<ProbeDataDirectoryError>().having(
            (e) => e.message,
            'message',
            contains('KARMASHALA_DATA_DIR'),
          ),
        ),
      );
      expect(defaultAsked, 0, reason: 'the real folder is never even named');
    });

    test('a probe pointed at the real folder is refused', () async {
      for (final spelling in [
        real.path,
        '${real.path}${Platform.pathSeparator}',
        p.join(real.path, '..', 'real'),
      ]) {
        await expectLater(
          resolveDataDirectory(
            probe: ProbeMode(enabled: true, dataDirectory: spelling),
            platformDefault: platformDefault,
          ),
          throwsA(isA<ProbeDataDirectoryError>()),
          reason: spelling,
        );
      }
    });

    test('a probe with its own folder gets exactly that folder', () async {
      final own = p.join(root.path, 'probe');

      final dir = await resolveDataDirectory(
        probe: ProbeMode(enabled: true, dataDirectory: own),
        platformDefault: platformDefault,
      );

      expect(dir.path, own);
      expect(dir.existsSync(), isTrue);
      expect(sameDirectory(dir.path, real.path), isFalse);
    });

    test('an ordinary launch is unchanged', () async {
      final dir = await resolveDataDirectory(
        probe: ProbeMode.off,
        platformDefault: platformDefault,
      );
      expect(dir.path, real.path);

      final overridden = p.join(root.path, 'elsewhere');
      final moved = await resolveDataDirectory(
        probe: ProbeMode(enabled: false, dataDirectory: overridden),
        platformDefault: platformDefault,
      );
      expect(moved.path, overridden);
      expect(
        defaultAsked,
        1,
        reason: 'an override is not checked outside a probe',
      );
    });

    test('same-directory ignores case only where the file system does', () {
      expect(sameDirectory('/a/B', '/a/b', caseInsensitive: true), isTrue);
      expect(sameDirectory('/a/B', '/a/b', caseInsensitive: false), isFalse);
      expect(sameDirectory('/a/b/', '/a/b', caseInsensitive: false), isTrue);
    });
  });

  group('the banner', () {
    // Mounted the way the app mounts it: from MaterialApp.builder, above the
    // Navigator and so above the only Overlay. A banner placed as `home:`
    // would sit inside the Navigator and hide anything that needs an Overlay.
    Future<void> pump(WidgetTester tester, ProbeMode probe) =>
        tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                ProbeBanner(probe: probe, child: child!),
            home: const Text('app'),
          ),
        );

    testWidgets('hovering it does not blank the window', (tester) async {
      // A Tooltip in the banner threw "No Overlay widget found" on hover and
      // left the probe's release window white.
      await pump(
        tester,
        const ProbeMode(enabled: true, dataDirectory: r'C:\scratch\probe'),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('PROBE')));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await tester.longPress(find.text('PROBE'));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('what a probe leaves off is readable without hovering', (
      tester,
    ) async {
      await pump(
        tester,
        const ProbeMode(enabled: true, dataDirectory: r'C:\scratch\probe'),
      );

      final label = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((s) => s.properties.label ?? '')
          .firstWhere((l) => l.startsWith('Probe instance'), orElse: () => '');
      for (final effect in ProbeMode.disabledEffects) {
        expect(label, contains(effect));
      }
      expect(find.textContaining('hooks'), findsOneWidget);
    });

    testWidgets('a probe says so above the app', (tester) async {
      await pump(
        tester,
        const ProbeMode(enabled: true, dataDirectory: r'C:\scratch\probe'),
      );

      expect(find.byKey(const ValueKey('probe_banner')), findsOneWidget);
      expect(find.text('PROBE'), findsOneWidget);
      expect(find.textContaining(r'C:\scratch\probe'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('the real app shows nothing extra', (tester) async {
      await pump(tester, ProbeMode.off);

      expect(find.byKey(const ValueKey('probe_banner')), findsNothing);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('it fits a phone width without overflowing', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump(
        tester,
        ProbeMode(enabled: true, dataDirectory: 'C:\\${'long' * 40}'),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
