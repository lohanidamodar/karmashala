import 'package:karmashala/src/features/devices/domain/simulator_slimming.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/permission_fixtures.dart';

void main() {
  group('simulator slimming', _simulatorSlimmingTests);

  group('shell integration setting', () {
    test('is off by default', () {
      // A shell that fails to start is much worse than a missing feature, so
      // the injection is opt-in until the user asks for it.
      expect(const Settings().shellIntegrationEnabled, isFalse);
    });

    test('survives a JSON round-trip', () {
      const s = Settings(shellIntegrationEnabled: true);
      expect(Settings.fromJson(s.toJson()).shellIntegrationEnabled, isTrue);
      expect(Settings.fromJson(s.toJson()), s);
    });

    test('an absent key reads back as off', () {
      expect(Settings.fromJson(const {}).shellIntegrationEnabled, isFalse);
    });

    test('participates in equality', () {
      expect(
        const Settings(shellIntegrationEnabled: true),
        isNot(const Settings()),
      );
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
          .setShellIntegrationEnabled(true);

      expect(
        container.read(settingsControllerProvider).shellIntegrationEnabled,
        isTrue,
      );
      expect(
        SettingsRepository(db).load().shellIntegrationEnabled,
        isTrue,
        reason: 'the change must reach the database, not just the notifier',
      );
    });
  });

  group('host-backed local panes setting', () {
    test('is off, so nothing changes until somebody asks for it', () {
      expect(const Settings().hostBackedLocalPanes, isFalse);
      expect(Settings.fromJson(const {}).hostBackedLocalPanes, isFalse);
    });

    test('survives a JSON round-trip, on as well as off', () {
      const on = Settings(hostBackedLocalPanes: true);
      expect(Settings.fromJson(on.toJson()).hostBackedLocalPanes, isTrue);
      expect(Settings.fromJson(on.toJson()), on);
    });

    test('participates in equality', () {
      expect(const Settings(hostBackedLocalPanes: true), isNot(const Settings()));
      expect(
        const Settings(hostBackedLocalPanes: true).hashCode,
        isNot(const Settings().hashCode),
      );
    });

    test('the controller persists it', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      container.read(settingsControllerProvider.notifier).setHostBackedLocalPanes(true);

      expect(container.read(settingsControllerProvider).hostBackedLocalPanes, isTrue);
      expect(
        SettingsRepository(db).load().hostBackedLocalPanes,
        isTrue,
        reason: 'the change must reach the database, not just the notifier',
      );
    });
  });

  group('resume-running-panes setting', () {
    test('is on by default', () {
      // The owner asked for it: "if there were active panes on last close start
      // all those panes on active tab".
      expect(const Settings().restoreLivePanes, isTrue);
    });

    test('survives a JSON round-trip, off as well as on', () {
      const off = Settings(restoreLivePanes: false);
      expect(Settings.fromJson(off.toJson()).restoreLivePanes, isFalse);
      expect(Settings.fromJson(off.toJson()), off);
      expect(Settings.fromJson(const Settings().toJson()), const Settings());
    });

    test('an absent key reads back as on, not as the missing value', () {
      // Every settings file written before this key existed, which is all of
      // them: the upgrade has to arrive with the feature switched on.
      expect(Settings.fromJson(const {}).restoreLivePanes, isTrue);
    });

    test('participates in equality', () {
      expect(const Settings(restoreLivePanes: false), isNot(const Settings()));
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
          .setRestoreLivePanes(false);

      expect(
        container.read(settingsControllerProvider).restoreLivePanes,
        isFalse,
      );
      expect(
        SettingsRepository(db).load().restoreLivePanes,
        isFalse,
        reason: 'the change must reach the database, not just the notifier',
      );
    });
  });

  group('terminal theme setting', () {
    test('defaults to none, meaning the built-in theme', () {
      expect(const Settings().terminalThemeSource, isNull);
    });

    test('survives a JSON round-trip', () {
      const s = Settings(terminalThemeSource: r'warp:C:\themes\nord.yaml');
      final restored = Settings.fromJson(s.toJson());
      expect(restored.terminalThemeSource, r'warp:C:\themes\nord.yaml');
      expect(restored, s);
    });

    test('the controller persists it, and can clear it again', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.setTerminalThemeSource(r'ghostty:C:\themes\Nord');
      expect(
        SettingsRepository(db).load().terminalThemeSource,
        r'ghostty:C:\themes\Nord',
      );

      // Clearing must actually clear — a plain `?? this.x` copyWith cannot
      // express "set this back to null".
      controller.setTerminalThemeSource(null);
      expect(SettingsRepository(db).load().terminalThemeSource, isNull);
    });
  });

  group('Settings model', () {
    test('defaults to no stored permission and no default agent', () {
      const s = Settings();
      expect(s.defaultAgent, isNull);
      // There is no shared mode left to preset, and presetting one agent's
      // word here would be a guess about every other agent. Null means
      // "nobody chose", and the agent's own declared default applies.
      expect(
        s.permissionsFor(AgentIds.claudeCode).newSessions,
        isNull,
        reason: 'a fresh install imposes no mode of its own',
      );
      expect(
        s.permissionsFor(AgentIds.claudeCode).existingSessions,
        isNull,
        reason: 'a fresh install imposes no mode of its own',
      );
    });

    test('JSON round-trip preserves default agent and permissions', () {
      final s = const Settings(defaultAgent: AgentIds.codex).withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(
          newSessions: claudeAcceptEditsStored,
          existingSessions: claudeBypassStored,
        ),
      );
      final restored = Settings.fromJson(s.toJson());
      expect(restored.defaultAgent, AgentIds.codex);
      expect(
        restored.permissionsFor(AgentIds.claudeCode).newSessions,
        claudeAcceptEditsStored,
      );
      expect(
        restored.permissionsFor(AgentIds.claudeCode).existingSessions,
        claudeBypassStored,
      );
      expect(restored, s);
    });

    test('permissions for an agent with no AgentKind survive a round-trip', () {
      final s = const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(newSessions: bypassStored),
      );
      final restored = Settings.fromJson(s.toJson());
      expect(restored.permissionsFor('roverCli').newSessions, bypassStored);
      expect(
        restored.permissionsFor('roverCli').existingSessions,
        isNull,
        reason: 'the half that was never set stays unset',
      );
    });

    test('an agent id with no AgentKind can be the default agent', () {
      const s = Settings(defaultAgent: 'roverCli');
      expect(Settings.fromJson(s.toJson()).defaultAgent, 'roverCli');
    });

    test('bypass is the only dangerous rung', () {
      expect(PermissionRisk.readOnly.isDangerous, isFalse);
      expect(PermissionRisk.ask.isDangerous, isFalse);
      expect(PermissionRisk.acceptEdits.isDangerous, isFalse);
      expect(PermissionRisk.autoRun.isDangerous, isFalse);
      expect(PermissionRisk.bypass.isDangerous, isTrue);
    });
  });

  group('ui text scale', () {
    test('defaults to 100%', () {
      expect(const Settings().uiTextScale, 1.0);
    });

    test('survives a JSON round-trip', () {
      const s = Settings(uiTextScale: 1.25);
      expect(Settings.fromJson(s.toJson()).uiTextScale, 1.25);
      expect(Settings.fromJson(s.toJson()), s);
    });

    test('an absurd stored value is clamped on read', () {
      // A hand-edited 0.1 would make the whole UI unusable — including the
      // settings screen it could be fixed from.
      expect(
        Settings.fromJson(const {'uiTextScale': 0.1}).uiTextScale,
        Settings.minUiTextScale,
      );
      expect(
        Settings.fromJson(const {'uiTextScale': 9.0}).uiTextScale,
        Settings.maxUiTextScale,
      );
    });

    test('the controller persists it, clamped to the supported range', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.setUiTextScale(1.25);
      expect(SettingsRepository(db).load().uiTextScale, 1.25);

      controller.setUiTextScale(5.0);
      expect(
        container.read(settingsControllerProvider).uiTextScale,
        Settings.maxUiTextScale,
      );
    });
  });

  group('terminal font size', () {
    test('the default is exactly the pre-setting hardcoded 13', () {
      // The terminal perf/pixel goldens are painted at 13; a changed default
      // would silently repaint every golden.
      expect(Settings.defaultTerminalFontSize, 13.0);
      expect(const Settings().terminalFontSize, 13.0);
    });

    test('an absent key reads back as the default', () {
      expect(Settings.fromJson(const {}).terminalFontSize, 13.0);
    });

    test('survives a JSON round-trip', () {
      const s = Settings(terminalFontSize: 16.0);
      expect(Settings.fromJson(s.toJson()).terminalFontSize, 16.0);
      expect(Settings.fromJson(s.toJson()), s);
    });

    test('adjust, reset and clamping all persist through the controller', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.adjustTerminalFontSize(1);
      expect(SettingsRepository(db).load().terminalFontSize, 14.0);

      controller.adjustTerminalFontSize(-2);
      expect(SettingsRepository(db).load().terminalFontSize, 12.0);

      controller.resetTerminalFontSize();
      expect(
        SettingsRepository(db).load().terminalFontSize,
        Settings.defaultTerminalFontSize,
      );

      controller.setTerminalFontSize(100);
      expect(
        container.read(settingsControllerProvider).terminalFontSize,
        Settings.maxTerminalFontSize,
      );
      controller.setTerminalFontSize(1);
      expect(
        container.read(settingsControllerProvider).terminalFontSize,
        Settings.minTerminalFontSize,
      );
    });
  });

  group('SettingsRepository', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    test('load returns defaults when nothing is stored', () {
      expect(SettingsRepository(db).load(), const Settings());
    });

    test('save then load round-trips', () {
      final repo = SettingsRepository(db);
      repo.save(const Settings(defaultAgent: AgentIds.antigravity));
      expect(repo.load().defaultAgent, AgentIds.antigravity);
    });
  });

  group('SettingsController', () {
    late AppDatabase db;
    late ProviderContainer container;
    setUp(() {
      db = AppDatabase.memory();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });
    tearDown(() {
      container.dispose();
      db.close();
    });

    test('setting the default agent persists', () {
      container
          .read(settingsControllerProvider.notifier)
          .setDefaultAgent(AgentIds.codex);
      expect(
        container.read(settingsControllerProvider).defaultAgent,
        AgentIds.codex,
      );
      // A fresh repository sees the persisted value.
      expect(SettingsRepository(db).load().defaultAgent, AgentIds.codex);
    });

    test('setting a permission persists per agent and session kind', () {
      container.read(settingsControllerProvider.notifier)
        ..setNewSessionPermission(AgentIds.claudeCode, claudeBypassStored)
        ..setExistingSessionPermission(
          AgentIds.claudeCode,
          claudeAcceptEditsStored,
        );

      final loaded = SettingsRepository(db).load();
      expect(
        loaded.permissionsFor(AgentIds.claudeCode).newSessions,
        claudeBypassStored,
      );
      expect(
        loaded.permissionsFor(AgentIds.claudeCode).existingSessions,
        claudeAcceptEditsStored,
      );
    });
  });
}

void _simulatorSlimmingTests() {
  test('slimming is on by default, keeping the three a Flutter app needs', () {
    const settings = Settings();

    expect(settings.simulatorSlimming, isTrue);
    expect(settings.simulatorSlimmingKept, ['store', 'photos', 'web']);
  });

  test('a settings file written before slimming existed still slims', () {
    // The default is *on*, so reading the absent key as `== true` would have
    // silently turned it off for every existing install.
    final settings = Settings.fromJson(const {'keepAwake': true});

    expect(settings.simulatorSlimming, isTrue);
    expect(settings.simulatorSlimmingKept, kDefaultSlimmingKept);
  });

  test('keeping nothing survives a round trip', () {
    // Distinct from "absent": an empty list is a choice, and falling back to
    // the default here would re-spare three categories the user switched off.
    const settings = Settings(simulatorSlimmingKept: []);

    final restored = Settings.fromJson(settings.toJson());

    expect(restored.simulatorSlimmingKept, isEmpty);
  });

  test('a category that no longer exists is dropped, not fatal', () {
    final settings = Settings.fromJson(const {
      'simulatorSlimmingKept': ['store', 'a-category-from-the-future'],
    });

    expect(settings.simulatorSlimmingKept, hasLength(2));
    expect(
      {for (final id in settings.simulatorSlimmingKept) ?SlimmingCategory.byId(id)},
      {SlimmingCategory.store},
    );
  });
}
