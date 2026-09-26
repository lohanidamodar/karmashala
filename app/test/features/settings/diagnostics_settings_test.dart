import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/logging/diagnostics_bootstrap.dart';
import 'package:karmashala/src/core/logging/diagnostics_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/diagnostics_settings.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/presentation/diagnostics_page.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  tearDown(() => Logger.root.level = Level.INFO);

  group('diagnostics settings', () {
    test('ship the way the design asked: file on, buffer bounded', () {
      const settings = Settings();
      expect(settings.logToFile, isTrue);
      expect(settings.logVerbosity, LogVerbosity.normal);
      expect(settings.logBufferSize, kDefaultLogBufferCapacity);
      // Debug mode follows the build: on while developing, off in release.
      expect(settings.debugMode, kDefaultDebugMode);
    });

    test('survive a JSON round-trip', () {
      const settings = Settings(
        debugMode: true,
        logVerbosity: LogVerbosity.verbose,
        logToFile: false,
        logBufferSize: 20000,
      );
      final back = Settings.fromJson(settings.toJson());
      expect(back.debugMode, isTrue);
      expect(back.logVerbosity, LogVerbosity.verbose);
      expect(back.logToFile, isFalse);
      expect(back.logBufferSize, 20000);
      expect(back, settings);
    });

    test('participate in equality', () {
      expect(const Settings(logToFile: false), isNot(const Settings()));
      expect(
        const Settings(logVerbosity: LogVerbosity.warnings),
        isNot(const Settings()),
      );
    });

    test('a hand-edited buffer size is clamped rather than allocated', () {
      expect(
        Settings.fromJson(const {'logBufferSize': 5000000}).logBufferSize,
        kMaxLogBufferCapacity,
      );
      expect(
        Settings.fromJson(const {'logBufferSize': 1}).logBufferSize,
        kMinLogBufferCapacity,
      );
    });

    test('the controller persists debug mode and applies it', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final diagnostics = Diagnostics(echoToConsole: false);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          diagnosticsProvider.overrideWithValue(diagnostics),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.setDebugMode(true);

      expect(container.read(settingsControllerProvider).debugMode, isTrue);
      expect(
        SettingsRepository(db).load().debugMode,
        isTrue,
        reason: 'the change must reach the database, not just the notifier',
      );
      // The point of the toggle: `AppLogger.debug` is `Logger.fine`, which INFO
      // filters out before any sink sees it.
      expect(Logger.root.level, Level.ALL);

      controller.setDebugMode(false);
      expect(Logger.root.level, Level.INFO);
    });

    test('the controller resizes the live buffer', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final diagnostics = Diagnostics(echoToConsole: false);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          diagnosticsProvider.overrideWithValue(diagnostics),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(settingsControllerProvider.notifier)
          .setLogBufferSize(1000);

      expect(diagnostics.buffer.capacity, 1000);
      expect(SettingsRepository(db).load().logBufferSize, 1000);
    });

    test('applying settings never opens a file when the file is off', () {
      final diagnostics = Diagnostics(echoToConsole: false);
      applyDiagnosticsSettings(
        diagnostics,
        debugMode: false,
        fileLevel: Level.INFO,
        logToFile: false,
        bufferSize: kDefaultLogBufferCapacity,
      );
      expect(diagnostics.file, isNull);
      expect(Logger.root.level, Level.INFO);
    });
  });

  group('Settings → Diagnostics', () {
    testWidgets('is reachable and drives the controller', (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final diagnostics = Diagnostics(echoToConsole: false);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          diagnosticsProvider.overrideWithValue(diagnostics),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: SettingsScreen(initialSection: SettingsSectionId.diagnostics),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(DebugModeSection), findsOneWidget);
      final before = container.read(settingsControllerProvider).debugMode;
      await tester.tap(find.text('Debug mode'));
      await tester.pump();

      expect(container.read(settingsControllerProvider).debugMode, !before);
    });

    testWidgets('the section is findable by searching for "logs"', (
      tester,
    ) async {
      expect(SettingsSectionId.diagnostics.matches('logs'), isTrue);
      expect(SettingsSectionId.diagnostics.matches('debug'), isTrue);
    });
  });
}
