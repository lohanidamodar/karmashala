import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/notes_settings_section.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/stored_preferences.dart';
import 'package:karmashala_notes/store.dart';

void main() {
  group('the setting', () {
    test('ships on — a feature nobody can find is not a feature', () {
      expect(const Settings().notesEnabled, isTrue);
    });

    test('survives a JSON round-trip and takes part in equality', () {
      const off = Settings(notesEnabled: false);
      expect(Settings.fromJson(off.toJson()).notesEnabled, isFalse);
      expect(Settings.fromJson(off.toJson()), off);
      expect(off, isNot(const Settings()));
    });

    test('a settings file written before Notes existed reads as on', () {
      expect(Settings.fromJson(const {}).notesEnabled, isTrue);
    });

    test('the controller persists it', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      container
          .read(settingsControllerProvider.notifier)
          .setNotesEnabled(false);

      expect(container.read(notesEnabledProvider), isFalse);
      expect(
        SettingsRepository(StoredPreferences(db)).load().notesEnabled,
        isFalse,
      );
    });
  });

  group('the off switch', () {
    test('takes the Notes surface off the rail and out of every menu', () {
      // One list feeds the rail, the View menu and quick open, so the surface
      // cannot be hidden in one place and reachable in another.
      expect(
        SidePanelSurface.offered(debugMode: true, notesEnabled: true),
        contains(SidePanelSurface.notes),
      );
      expect(
        SidePanelSurface.offered(debugMode: true, notesEnabled: false),
        isNot(contains(SidePanelSurface.notes)),
      );
      // And it takes nothing else with it.
      expect(
        SidePanelSurface.offered(debugMode: true, notesEnabled: false),
        contains(SidePanelSurface.logs),
      );
    });

    test('closes the surface if it is open, rather than leaving a body', () {
      expect(
        SidePanelSurface.notes.isOffered(debugMode: true, notesEnabled: false),
        isFalse,
      );
      expect(
        SidePanelSurface.changes.isOffered(
          debugMode: false,
          notesEnabled: false,
        ),
        isTrue,
      );
    });

    test('hides the feature and keeps the notes', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      container
          .read(notesProvider.notifier)
          .capture(body: 'an idea worth keeping');

      container
          .read(settingsControllerProvider.notifier)
          .setNotesEnabled(false);

      // Hidden everywhere it was offered…
      expect(container.read(notesEnabledProvider), isFalse);
      expect(
        SidePanelSurface.offered(
          debugMode: false,
          notesEnabled: container.read(notesEnabledProvider),
        ),
        isNot(contains(SidePanelSurface.notes)),
      );
      // …and not destroyed. Turning it back on brings the same list back.
      expect(NoteDao(container.read(databaseProvider)).list(), hasLength(1));
      container.read(settingsControllerProvider.notifier).setNotesEnabled(true);
      expect(
        container.read(notesProvider).single.body,
        'an idea worth keeping',
      );
    });
  });

  group('Settings → General → Notes', () {
    testWidgets('is reachable and drives the controller', (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: SettingsScreen(initialAnchor: SettingsAnchor.notes),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(NotesSettingsSection), findsOneWidget);
      // The page answers the question the switch raises before it is touched.
      expect(
        find.textContaining('Nothing you have saved is deleted'),
        findsOneWidget,
      );

      await tester.tap(find.text('Notes').last);
      await tester.pump();

      expect(container.read(settingsControllerProvider).notesEnabled, isFalse);
      expect(find.textContaining('You have no saved notes'), findsOneWidget);
    });

    testWidgets('the section is findable by searching for "notes"', (
      tester,
    ) async {
      expect(SettingsSectionId.general.matches('notes'), isTrue);
      expect(SettingsSectionId.general.matches('idea'), isTrue);
    });
  });
}
