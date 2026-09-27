import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_sdk_readings.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';

/// **A Flutter SDK a person names for one environment.** The path is kept in
/// `Settings` (here); the server reads it on every `flutter.sdk` and measures
/// it on its own machine (slice 3d, `server/test/flutter/`), so this app
/// only asks and forgets a reading taken against an older answer.
final DateTime _now = DateTime.utc(2026, 9, 9, 12);

final _windows = ExecutionEnvironment(
  id: 'env',
  kind: EnvironmentKind.windowsNative,
  name: 'Windows',
  createdAt: _now,
);

void main() {
  group('Settings holds the answer, keyed by environment', () {
    test('it round-trips through the stored JSON', () {
      final set = const Settings().withFlutterSdkPath(
        'wsl:Ubuntu',
        '/home/me/flutter/bin/flutter',
      );
      expect(
        set.flutterSdkPathFor('wsl:Ubuntu'),
        '/home/me/flutter/bin/flutter',
      );
      final back = Settings.fromJson(set.toJson());
      expect(
        back.flutterSdkPathFor('wsl:Ubuntu'),
        '/home/me/flutter/bin/flutter',
      );
      expect(back, set);
    });

    test('one environment says nothing about another', () {
      // §17: a Windows SDK is exactly the wrong answer inside a distribution.
      final set = const Settings().withFlutterSdkPath(
        'windows',
        r'C:\src\flutter\bin\flutter.bat',
      );
      expect(set.flutterSdkPathFor('wsl:Ubuntu'), isNull);
    });

    test('blank takes the answer back, and PATH answers again', () {
      final set = const Settings().withFlutterSdkPath('env', '/opt/flutter');
      expect(
        set.withFlutterSdkPath('env', '  ').flutterSdkPathFor('env'),
        isNull,
      );
      expect(
        set.withFlutterSdkPath('env', null).flutterSdkPathFor('env'),
        isNull,
      );
      // Removed, not stored as an empty string.
      expect(
        set
            .withFlutterSdkPath('env', '')
            .toJson()
            .containsKey('flutterSdkPaths'),
        isFalse,
      );
    });

    test('a stray space is not part of a path', () {
      expect(
        const Settings()
            .withFlutterSdkPath('env', '  /opt/flutter/bin/flutter  ')
            .flutterSdkPathFor('env'),
        '/opt/flutter/bin/flutter',
      );
    });

    test('an unreadable entry is skipped rather than becoming a bad path', () {
      final back = Settings.fromJson(const {
        'flutterSdkPaths': {'env': 7, 'other': '', 'good': '/opt/flutter'},
      });
      expect(back.flutterSdkPathFor('env'), isNull);
      expect(back.flutterSdkPathFor('other'), isNull);
      expect(back.flutterSdkPathFor('good'), '/opt/flutter');
    });
  });

  group('the reading is the server\'s', () {
    late FakeDataServer server;
    late ProviderContainer container;

    setUp(() async {
      server = FakeDataServer();
      container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
    });

    test('asks flutter.sdk, and forces only when told to', () async {
      final readings = container.read(flutterSdkReadingsProvider.notifier);
      final reading = await readings.readFor(_windows);
      await readings.readFor(_windows, force: true);

      expect(reading.executable, 'flutter');
      expect(readings.cached('env'), isNotNull);
      final asked = server.runs.asked.whereType<FlutterSdk>().toList();
      expect(asked.map((r) => r.environmentId), ['env', 'env']);
      expect(asked.map((r) => r.force), [false, true]);
    });

    test('a changed hand-set path drops the reading taken before it', () async {
      final readings = container.read(flutterSdkReadingsProvider.notifier);
      await readings.readFor(_windows);
      expect(readings.cached('env'), isNotNull);

      container
          .read(settingsControllerProvider.notifier)
          .setFlutterSdkPath('env', r'D:\sdk\flutter\bin\flutter.bat');
      container.read(flutterSdkReadingsProvider);
      expect(readings.cached('env'), isNull);
    });

    test('a refusal is the server\'s, in its words', () async {
      server.runs.onFlutter = (_) => throw const DataRefused(
        DataRefusalCode.failed,
        'Nothing named flutter.bat is on this environment\'s PATH.',
      );
      await expectLater(
        container.read(flutterSdkReadingsProvider.notifier).readFor(_windows),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('PATH'),
          ),
        ),
      );
    });
  });
}
