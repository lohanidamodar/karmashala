import 'package:karmashala_devices/devices.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/permission_fixtures.dart';
import '../../support/fake_data_server.dart';

/// The settings as the fake server holds them, once the writes in flight
/// have landed.
Future<Settings> _stored(FakeDataServer server) async {
  await pumpEventQueue();
  return SettingsRepository(server.store).load();
}

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

    test('the controller persists it', () async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);

      container
          .read(settingsControllerProvider.notifier)
          .setShellIntegrationEnabled(true);

      expect(
        container.read(settingsControllerProvider).shellIntegrationEnabled,
        isTrue,
      );
      expect(
        (await _stored(server)).shellIntegrationEnabled,
        isTrue,
        reason: 'the change must reach the database, not just the notifier',
      );
    });
  });

  group('let-agents-update-themselves setting', () {
    test('is unset by default, so the platform decides', () {
      // Tri-state: null means "nobody has said", resolved by platform where it
      // is read (agentsMayUpdateThemselvesProvider) — off on Windows, on else.
      expect(const Settings().letAgentsUpdateThemselves, isNull);
      expect(Settings.fromJson(const {}).letAgentsUpdateThemselves, isNull);
    });

    test('survives a JSON round-trip, both concrete values', () {
      const on = Settings(letAgentsUpdateThemselves: true);
      const off = Settings(letAgentsUpdateThemselves: false);
      expect(Settings.fromJson(on.toJson()).letAgentsUpdateThemselves, isTrue);
      expect(
        Settings.fromJson(off.toJson()).letAgentsUpdateThemselves,
        isFalse,
      );
      expect(Settings.fromJson(on.toJson()), on);
      expect(Settings.fromJson(off.toJson()), off);
    });

    test('participates in equality', () {
      expect(
        const Settings(letAgentsUpdateThemselves: false),
        isNot(const Settings()),
      );
      expect(
        const Settings(letAgentsUpdateThemselves: true),
        isNot(const Settings(letAgentsUpdateThemselves: false)),
      );
    });

    test('the controller persists a concrete choice', () async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);

      container
          .read(settingsControllerProvider.notifier)
          .setLetAgentsUpdateThemselves(false);

      expect(
        container.read(settingsControllerProvider).letAgentsUpdateThemselves,
        isFalse,
      );
      expect(
        (await _stored(server)).letAgentsUpdateThemselves,
        isFalse,
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

    test('the controller persists it', () async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);

      container
          .read(settingsControllerProvider.notifier)
          .setRestoreLivePanes(false);

      expect(
        container.read(settingsControllerProvider).restoreLivePanes,
        isFalse,
      );
      expect(
        (await _stored(server)).restoreLivePanes,
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

    test('the controller persists it, and can clear it again', () async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.setTerminalThemeSource(r'ghostty:C:\themes\Nord');
      expect(
        (await _stored(server)).terminalThemeSource,
        r'ghostty:C:\themes\Nord',
      );

      // Clearing must actually clear — a plain `?? this.x` copyWith cannot
      // express "set this back to null".
      controller.setTerminalThemeSource(null);
      expect((await _stored(server)).terminalThemeSource, isNull);
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

    test('permissions for a data-only agent survive a round-trip', () {
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

    test('a data-only agent id can be the default agent', () {
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

    test(
      'the controller persists it, clamped to the supported range',
      () async {
        final server = FakeDataServer();
        final container = ProviderContainer(
          overrides: [await server.override()],
        );
        addTearDown(container.dispose);
        final controller = container.read(settingsControllerProvider.notifier);

        controller.setUiTextScale(1.25);
        expect((await _stored(server)).uiTextScale, 1.25);

        controller.setUiTextScale(5.0);
        expect(
          container.read(settingsControllerProvider).uiTextScale,
          Settings.maxUiTextScale,
        );
      },
    );
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

    test(
      'adjust, reset and clamping all persist through the controller',
      () async {
        final server = FakeDataServer();
        final container = ProviderContainer(
          overrides: [await server.override()],
        );
        addTearDown(container.dispose);
        final controller = container.read(settingsControllerProvider.notifier);

        controller.adjustTerminalFontSize(1);
        expect((await _stored(server)).terminalFontSize, 14.0);

        controller.adjustTerminalFontSize(-2);
        expect((await _stored(server)).terminalFontSize, 12.0);

        controller.resetTerminalFontSize();
        expect(
          (await _stored(server)).terminalFontSize,
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
      },
    );
  });

  group('SettingsRepository', () {
    test('load returns defaults when nothing is stored', () {
      expect(
        SettingsRepository(FakeDataServer().store).load(),
        const Settings(),
      );
    });

    test('save then load round-trips', () {
      final repo = SettingsRepository(FakeDataServer().store);
      repo.save(const Settings(defaultAgent: AgentIds.antigravity));
      expect(repo.load().defaultAgent, AgentIds.antigravity);
    });
  });

  group('SettingsController', () {
    late FakeDataServer server;
    late ProviderContainer container;
    setUp(() async {
      server = FakeDataServer();
      container = ProviderContainer(overrides: [await server.override()]);
    });
    tearDown(() => container.dispose());

    test('setting the default agent persists', () async {
      container
          .read(settingsControllerProvider.notifier)
          .setDefaultAgent(AgentIds.codex);
      expect(
        container.read(settingsControllerProvider).defaultAgent,
        AgentIds.codex,
      );
      // A fresh repository sees the persisted value.
      expect((await _stored(server)).defaultAgent, AgentIds.codex);
    });

    test('setting a permission persists per agent and session kind', () async {
      container.read(settingsControllerProvider.notifier)
        ..setNewSessionPermission(AgentIds.claudeCode, claudeBypassStored)
        ..setExistingSessionPermission(
          AgentIds.claudeCode,
          claudeAcceptEditsStored,
        );

      final loaded = (await _stored(server));
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
      {
        for (final id in settings.simulatorSlimmingKept)
          ?SlimmingCategory.byId(id),
      },
      {SlimmingCategory.store},
    );
  });
}
