import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/data/settings_repository.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  group('Settings model', () {
    test('defaults to ask permissions and no default agent', () {
      const s = Settings();
      expect(s.defaultAgent, isNull);
      expect(
        s.permissionsFor(AgentIds.claudeCode).newSessions,
        PermissionMode.ask,
      );
      expect(
        s.permissionsFor(AgentIds.claudeCode).existingSessions,
        PermissionMode.ask,
      );
    });

    test('JSON round-trip preserves default agent and permissions', () {
      final s = const Settings(defaultAgent: AgentIds.codex).withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(
          newSessions: PermissionMode.acceptEdits,
          existingSessions: PermissionMode.bypass,
        ),
      );
      final restored = Settings.fromJson(s.toJson());
      expect(restored.defaultAgent, AgentIds.codex);
      expect(
        restored.permissionsFor(AgentIds.claudeCode).newSessions,
        PermissionMode.acceptEdits,
      );
      expect(
        restored.permissionsFor(AgentIds.claudeCode).existingSessions,
        PermissionMode.bypass,
      );
      expect(restored, s);
    });

    test('permissions for an agent with no AgentKind survive a round-trip', () {
      final s = const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(newSessions: PermissionMode.bypass),
      );
      final restored = Settings.fromJson(s.toJson());
      expect(
        restored.permissionsFor('roverCli').newSessions,
        PermissionMode.bypass,
      );
      expect(
        restored.permissionsFor('roverCli').existingSessions,
        PermissionMode.ask,
      );
    });

    test('an agent id with no AgentKind can be the default agent', () {
      const s = Settings(defaultAgent: 'roverCli');
      expect(Settings.fromJson(s.toJson()).defaultAgent, 'roverCli');
    });

    test('bypass is the only dangerous mode', () {
      expect(PermissionMode.ask.isDangerous, isFalse);
      expect(PermissionMode.acceptEdits.isDangerous, isFalse);
      expect(PermissionMode.bypass.isDangerous, isTrue);
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
        ..setNewSessionPermission(AgentIds.claudeCode, PermissionMode.bypass)
        ..setExistingSessionPermission(
          AgentIds.claudeCode,
          PermissionMode.acceptEdits,
        );

      final loaded = SettingsRepository(db).load();
      expect(
        loaded.permissionsFor(AgentIds.claudeCode).newSessions,
        PermissionMode.bypass,
      );
      expect(
        loaded.permissionsFor(AgentIds.claudeCode).existingSessions,
        PermissionMode.acceptEdits,
      );
    });
  });
}
