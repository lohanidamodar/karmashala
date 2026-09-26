import 'dart:io';

import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/core/paths/server_data_directory.dart';
import 'package:karmashala/src/features/remote/application/remote_access_settings.dart';
import 'package:karmashala_host/server_config.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';

void main() {
  group('remote access is the server config, not the app settings', () {
    test('a fresh server serves no phones, with no relay override', () {
      // A listener nobody asked for is the one default this feature must
      // never ship with.
      final fresh = RemoteAccessSettings.fromConfig(ServerConfig.empty);
      expect(fresh.enabled, isFalse);
      expect(fresh.relay, isNull);
      expect(fresh.relayEnabled, isTrue);
      expect(RemoteAccessSettings.unknown.enabled, isFalse);
      expect(RemoteAccessSettings.unknown.loaded, isFalse);
    });

    test(
      'the retired keys in the app settings are neither read nor written',
      () {
        final restored = Settings.fromJson(const {
          'remoteAccessEnabled': true,
          'remoteRelayUrl': 'wss://relay.example.com',
        });
        expect(restored, const Settings());
        expect(restored.toJson(), isNot(contains('remoteAccessEnabled')));
        expect(restored.toJson(), isNot(contains('remoteRelayUrl')));
      },
    );

    test('what server.config.get says, every field decided', () {
      final read = RemoteAccessSettings.fromSettings({
        'companion': {
          'enabled': true,
          'relay': 'wss://relay.example.com',
          'relayEnabled': false,
          'extraRelays': ['ws://box.example.com:8787/k/token'],
          'notes': false,
        },
      });
      expect(read.enabled, isTrue);
      expect(read.relay, Uri.parse('wss://relay.example.com'));
      expect(read.relayEnabled, isFalse);
      expect(read.extraRelays, [
        Uri.parse('ws://box.example.com:8787/k/token'),
      ]);
      expect(read.notes, isFalse);
      expect(read.loaded, isTrue);
    });

    test('where no server runs, the file itself is read and written — '
        'owner-only, patched, the rest kept', () async {
      final dir = Directory.systemTemp.createTempSync('server-config-file-');
      addTearDown(() => dir.deleteSync(recursive: true));
      await const ServerConfig(name: 'desk', mcpPort: 47901).write(dir.path);
      final source = FileServerConfigSource(() async => dir);

      expect((await source.read()).enabled, isFalse);
      final written = await source.write({
        'companion': {'enabled': true, 'bind': '0.0.0.0'},
      });
      expect(written.enabled, isTrue);

      final file = await ServerConfig.read(dir.path);
      expect(file.companionEnabled, isTrue);
      expect(file.bind, '0.0.0.0');
      expect(file.name, 'desk');
      expect(file.mcpPort, 47901);
      if (!Platform.isWindows) {
        final mode = File(
          p.join(dir.path, kServerConfigFileName),
        ).statSync().mode;
        expect(mode & 0x1ff, 0x180);
      }
      await expectLater(
        source.write({
          'companion': {'bind': 'everywhere'},
        }),
        throwsA(isA<ServerConfigError>()),
      );
    });
  });

  group('the server data folder the app opens', () {
    test('is ~/.karmashala, created owner-only', () async {
      final home = Directory.systemTemp.createTempSync('server-data-home-');
      addTearDown(() => home.deleteSync(recursive: true));
      final dir = await resolveServerDataDirectory(
        probe: ProbeMode.off,
        environment: {'HOME': home.path, 'USERPROFILE': home.path},
      );
      expect(dir.path, p.join(home.path, '.karmashala'));
      expect(dir.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(dir.statSync().mode & 0x1ff, 0x1c0);
      }
    });

    test('a probe keeps its own folder, and never the real one', () async {
      final home = Directory.systemTemp.createTempSync('server-data-probe-');
      addTearDown(() => home.deleteSync(recursive: true));
      final env = {'HOME': home.path, 'USERPROFILE': home.path};
      final own = p.join(home.path, 'probe');
      expect(
        (await resolveServerDataDirectory(
          probe: ProbeMode(enabled: true, dataDirectory: own),
          environment: env,
        )).path,
        own,
      );
      await expectLater(
        resolveServerDataDirectory(
          probe: ProbeMode(
            enabled: true,
            dataDirectory: p.join(home.path, '.karmashala'),
          ),
          environment: env,
        ),
        throwsA(isA<ProbeDataDirectoryError>()),
      );
      await expectLater(
        resolveServerDataDirectory(probe: ProbeMode.on, environment: env),
        throwsA(isA<ProbeDataDirectoryError>()),
      );
    });

    test('is refused under flutter test with no folder of its own', () async {
      await expectLater(serverDataDirectory(), throwsStateError);
    });
  });

  group('the local relay port, still the app\'s', () {
    test('the local relay defaults to the standard port', () {
      expect(const Settings().localRelayPort, 8787);
    });

    test('the port survives a JSON round-trip', () {
      const s = Settings(localRelayPort: 9001);
      final restored = Settings.fromJson(s.toJson());
      expect(restored.localRelayPort, 9001);
      expect(restored, s);
    });

    test('a junk port reads back as the default', () {
      final restored = Settings.fromJson(const {
        'localRelayPort': 'yes please',
      });
      expect(restored.localRelayPort, 8787);
    });

    test('the retired relay mode is neither read nor written', () {
      // Carried into remote.relay_prefs.v1 by the store's v50 upgrade.
      final restored = Settings.fromJson(const {'remoteRelayMode': 'local'});
      expect(restored, const Settings());
      expect(const Settings().toJson(), isNot(contains('remoteRelayMode')));
    });

    test('the port participates in equality', () {
      expect(const Settings(localRelayPort: 9001), isNot(const Settings()));
    });

    test('the controller persists the port', () async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.setLocalRelayPort(9001);

      await pumpEventQueue();
      final stored = SettingsRepository(server.store).load();
      expect(stored.localRelayPort, 9001);
    });
  });
}
