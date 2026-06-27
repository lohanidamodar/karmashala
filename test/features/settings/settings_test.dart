import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/agents/domain/agent_kind.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/data/settings_repository.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Settings model', () {
    test('defaults to ask permissions and no default agent', () {
      const s = Settings();
      expect(s.defaultAgent, isNull);
      expect(
        s.permissionsFor(AgentKind.claudeCode).newSessions,
        PermissionMode.ask,
      );
      expect(
        s.permissionsFor(AgentKind.claudeCode).existingSessions,
        PermissionMode.ask,
      );
    });

    test('JSON round-trip preserves default agent and permissions', () {
      final s = const Settings(defaultAgent: AgentKind.codex).withPermissions(
        AgentKind.claudeCode,
        const AgentPermissions(
          newSessions: PermissionMode.acceptEdits,
          existingSessions: PermissionMode.bypass,
        ),
      );
      final restored = Settings.fromJson(s.toJson());
      expect(restored.defaultAgent, AgentKind.codex);
      expect(
        restored.permissionsFor(AgentKind.claudeCode).newSessions,
        PermissionMode.acceptEdits,
      );
      expect(
        restored.permissionsFor(AgentKind.claudeCode).existingSessions,
        PermissionMode.bypass,
      );
      expect(restored, s);
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
      repo.save(const Settings(defaultAgent: AgentKind.antigravity));
      expect(repo.load().defaultAgent, AgentKind.antigravity);
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
          .setDefaultAgent(AgentKind.codex);
      expect(
        container.read(settingsControllerProvider).defaultAgent,
        AgentKind.codex,
      );
      // A fresh repository sees the persisted value.
      expect(SettingsRepository(db).load().defaultAgent, AgentKind.codex);
    });

    test('setting a permission persists per agent and session kind', () {
      container.read(settingsControllerProvider.notifier)
        ..setNewSessionPermission(AgentKind.claudeCode, PermissionMode.bypass)
        ..setExistingSessionPermission(
          AgentKind.claudeCode,
          PermissionMode.acceptEdits,
        );

      final loaded = SettingsRepository(db).load();
      expect(
        loaded.permissionsFor(AgentKind.claudeCode).newSessions,
        PermissionMode.bypass,
      );
      expect(
        loaded.permissionsFor(AgentKind.claudeCode).existingSessions,
        PermissionMode.acceptEdits,
      );
    });
  });
}
