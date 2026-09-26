import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/remote.dart' show kHostCompanionPort;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz012345_-AB';

void main() {
  group('server.json', () {
    test('reads every field it names', () {
      final config = ServerConfig.fromJson({
        'name': 'droplet',
        'companion': {
          'enabled': true,
          'bind': '0.0.0.0',
          'port': 47900,
          'beacon': false,
          'relay': 'wss://relay.example.com',
          'relayToken': _token,
          'extraRelays': ['ws://box.example.com:8787/k/$_token'],
          'notes': false,
        },
        'mcp': {'port': 47901},
      }, source: 'server.json');
      expect(config.name, 'droplet');
      expect(config.bind, '0.0.0.0');
      expect(config.companionPort, 47900);
      expect(config.beacon, isFalse);
      expect(config.relay, Uri.parse('wss://relay.example.com'));
      expect(config.relayToken, _token);
      expect(config.extraRelays, hasLength(1));
      expect(config.notes, isFalse);
      expect(config.mcpPort, 47901);
    });

    test('round-trips through toJson', () {
      final config = ServerConfig.fromJson({
        'name': 'box',
        'companion': {'bind': '100.64.0.7', 'port': 1},
      }, source: 'server.json');
      expect(
        ServerConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())),
          source: 'again',
        ).toJson(),
        config.toJson(),
      );
    });

    for (final (why, json, says) in [
      ('an unknown key', {'nmae': 'x'}, 'unknown key "nmae"'),
      (
        'an unknown companion key',
        {
          'companion': {'prot': 1},
        },
        'companion.prot',
      ),
      (
        'a port as a string',
        {
          'companion': {'port': '47820'},
        },
        '"companion.port" must be a whole number',
      ),
      (
        'a port out of range',
        {
          'mcp': {'port': 70000},
        },
        'not between 0 and 65535',
      ),
      (
        'a bind that is not an IP',
        {
          'companion': {'bind': 'everywhere'},
        },
        'not an IP address',
      ),
      (
        'a relay that is not a relay URL',
        {
          'companion': {'relay': 'ftp://x'},
        },
        'not a relay URL',
      ),
      (
        'a short relay token',
        {
          'companion': {'relay': 'wss://r.example.com', 'relayToken': 'short'},
        },
        '32 or more',
      ),
      (
        'a token with no relay',
        {
          'companion': {'relayToken': _token},
        },
        'needs a relay',
      ),
    ]) {
      test('refuses $why, by name', () {
        expect(
          () => ServerConfig.fromJson(json, source: 'server.json'),
          throwsA(
            isA<ServerConfigError>().having(
              (e) => e.message,
              'message',
              allOf(startsWith('server.json: '), contains(says)),
            ),
          ),
        );
      });
    }

    group('on disk', () {
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('kh-config'));
      tearDown(() => dir.deleteSync(recursive: true));

      test('is empty when there is none', () async {
        expect(
          (await ServerConfig.read(dir.path)).toJson(),
          ServerConfig.empty.toJson(),
        );
      });

      test('is written owner-only and read back', () async {
        await const ServerConfig(
          name: 'box',
          relay: null,
          bind: '127.0.0.1',
        ).write(dir.path);
        final file = File(p.join(dir.path, kServerConfigFileName));
        expect(file.statSync().mode & 0x1ff, 0x180);
        expect((await ServerConfig.read(dir.path)).name, 'box');
      }, testOn: 'mac-os || linux');

      test('a file others can read is made owner-only, and said', () async {
        final file = File(p.join(dir.path, kServerConfigFileName))
          ..writeAsStringSync('{"name": "box"}');
        await Process.run('chmod', ['644', file.path]);
        final said = <String>[];
        final config = await ServerConfig.read(dir.path, log: said.add);
        expect(config.name, 'box');
        expect(file.statSync().mode & 0x1ff, 0x180);
        expect(said.single, contains('made owner-only'));
      }, testOn: 'mac-os || linux');

      test('a file that is not JSON is refused by its path', () async {
        File(
          p.join(dir.path, kServerConfigFileName),
        ).writeAsStringSync('name = box');
        await expectLater(
          ServerConfig.read(dir.path),
          throwsA(
            isA<ServerConfigError>().having(
              (e) => e.message,
              'message',
              contains('not JSON'),
            ),
          ),
        );
      });
    });
  });

  group('flags', () {
    test('read the fields they name and leave others unset', () {
      final flags = ServerConfig.fromFlags([
        '--data-dir=/tmp/x',
        '--companion-port=0',
        '--bind=0.0.0.0',
        '--relay=wss://relay.example.com',
        '--relay-token=$_token',
        '--beacon',
        '--name=box',
      ]);
      expect(flags.companionPort, 0);
      expect(flags.bind, '0.0.0.0');
      expect(flags.beacon, isTrue);
      expect(flags.name, 'box');
      expect(flags.mcpPort, isNull);
      expect(flags.notes, isNull);
    });

    test('the last of a toggle wins', () {
      expect(ServerConfig.fromFlags(['--beacon', '--no-beacon']).beacon, false);
    });

    test('refuse a port that is not a number, by flag', () {
      expect(
        () => ServerConfig.fromFlags(['--mcp-port=abc']),
        throwsA(
          isA<ServerConfigError>().having(
            (e) => e.message,
            'message',
            contains('--mcp-port=abc'),
          ),
        ),
      );
    });
  });

  group('precedence', () {
    const file = ServerConfig(
      name: 'from-file',
      bind: '0.0.0.0',
      companionPort: 47900,
      beacon: true,
      mcpPort: 47901,
    );

    test('a flag beats the file, field by field', () {
      final settings = ServerSettings.resolve(
        file: file,
        flags: const ServerConfig(companionPort: 0, name: 'from-flag'),
        hostName: 'machine',
      );
      expect(settings.companionPort, 0);
      expect(settings.name, 'from-flag');
      expect(settings.bind, '0.0.0.0', reason: 'the file, no flag');
      expect(settings.mcpPort, 47901);
      expect(settings.companion.advertise, isTrue);
    });

    test('with neither, a fresh server serves no phones, and would on '
        'loopback', () {
      final settings = ServerSettings.resolve(
        file: ServerConfig.empty,
        flags: ServerConfig.empty,
        hostName: 'machine',
      );
      expect(settings.name, 'machine');
      expect(settings.bind, '127.0.0.1');
      expect(settings.companionPort, kHostCompanionPort);
      expect(settings.mcpPort, kPreferredMcpPort);
      final companion = settings.companion;
      expect(companion.enabled, isFalse);
      expect(companion.relay, isNull);
      expect(companion.advertise, isFalse);
    });

    test('a relay switched off is kept and parked', () {
      final companion = ServerSettings.companionConfigOf(
        ServerConfig(
          companionEnabled: true,
          relay: Uri.parse('wss://relay.example.com'),
          relayEnabled: false,
        ),
      );
      expect(companion.relay, Uri.parse('wss://relay.example.com'));
      expect(companion.hostedEnabled, isFalse);
    });

    test('the relay token is spelled into the path the relay gates on', () {
      final own = ServerSettings.companionConfigOf(
        ServerConfig(
          relay: Uri.parse('wss://relay.example.com/'),
          relayToken: _token,
        ),
      );
      expect(own.relay.toString(), 'wss://relay.example.com/k/$_token');
      expect(own.hostedEnabled, isTrue);
    });
  });

  group('a patch', () {
    final file = ServerConfig(
      name: 'desk',
      companionEnabled: true,
      relay: Uri.parse('wss://relay.example.com'),
      relayToken: _token,
      mcpPort: 47901,
    );

    test('replaces what it names, clears what it nulls, keeps the rest', () {
      final next = file.patchedWith({
        'companion': {'bind': '0.0.0.0', 'relayToken': null, 'relay': null},
        'mcp': {'port': null},
      });
      expect(next.name, 'desk');
      expect(next.companionEnabled, isTrue);
      expect(next.bind, '0.0.0.0');
      expect(next.relay, isNull);
      expect(next.relayToken, isNull);
      expect(next.mcpPort, isNull);
      expect(next.toJson().containsKey('mcp'), isFalse);
    });

    test('is checked as the file is', () {
      expect(
        () => file.patchedWith({
          'companion': {'bind': 'everywhere'},
        }),
        throwsA(isA<ServerConfigError>()),
      );
      expect(
        () => file.patchedWith({'what': 1}),
        throwsA(isA<ServerConfigError>()),
      );
    });
  });

  test('the data directory is ~/.karmashala', () {
    expect(
      defaultServerDataDirectory(
        environment: {'HOME': '/home/k', 'USERPROFILE': r'C:\Users\k'},
      ),
      Platform.isWindows ? r'C:\Users\k\.karmashala' : '/home/k/.karmashala',
    );
    expect(
      () => defaultServerDataDirectory(environment: const {}),
      throwsStateError,
    );
  });
}
