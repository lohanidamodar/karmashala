import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

void main() {
  /// Verbatim a real `…\Local\Dart\dtd\36984`, written 2026-09-09 by the DTD
  /// a plain-terminal `flutter run` started without being asked.
  const pidFile =
      '{"wsUri":"ws://127.0.0.1:54382/xkQinOxHDeY=","epoch":1788941794103,'
      '"pid":36984,"dartVersion":"3.13.2 (stable) (Tue Aug 25 01:01:12 2026 '
      '-0700) on \\"windows_x64\\"","workspaceRoot":"C:\\\\kw\\\\vmprobe"}';

  /// Verbatim that daemon's `ConnectedApp.getVmServices` reply, asked over a
  /// plain WebSocket with no secret.
  const reply =
      '{"type":"VmServicesResponse","vmServices":[{"uri":'
      '"ws://127.0.0.1:54385/Rzp5Wq0-P2o=/ws","name":"Kind: Flutter - Device: '
      'sdk gphone64 x86 64 - Package: vmprobe"}]}';

  group('a tooling daemon that wrote itself down', () {
    test('gives up its address, its pid and the project it was started in', () {
      final instance = parseDtdPidFile('36984', pidFile);

      expect(instance, isNotNull);
      expect(instance!.wsUri.toString(), 'ws://127.0.0.1:54382/xkQinOxHDeY=');
      expect(instance.pid, 36984);
      expect(instance.workspaceRoot, r'C:\kw\vmprobe');
      expect(
        instance.startedAt,
        DateTime.fromMillisecondsSinceEpoch(1788941794103, isUtc: true),
      );
    });

    test('a file that is not one is ignored rather than reported', () {
      expect(parseDtdPidFile('36984', 'not json'), isNull);
      expect(parseDtdPidFile('36984', '{"pid":1}'), isNull);
      expect(parseDtdPidFile('notapid', pidFile), isNull);
      expect(parseDtdPidFile('36984', '{"wsUri":"nonsense","pid":1}'), isNull);
    });
  });

  group('what the daemon knows about its apps', () {
    test('is a VM service address with its auth token still on it', () {
      final apps = vmServicesInDtdReply(reply);

      expect(apps, hasLength(1));
      expect(
        apps.single.uri.toString(),
        'ws://127.0.0.1:54385/Rzp5Wq0-P2o=/ws',
      );
      expect(apps.single.name, contains('Package: vmprobe'));
    });

    test('an entry that is not an address is dropped, not guessed at', () {
      final apps = vmServicesInDtdReply(
        '{"type":"VmServicesResponse","vmServices":['
        '{"uri":"not a uri"},{"name":"no uri at all"},'
        '{"uri":"ws://127.0.0.1:1/t=/ws"}]}',
      );
      expect(apps, hasLength(1));
      expect(apps.single.uri.port, 1);
    });

    test('a reply of another shape yields nothing rather than throwing', () {
      expect(vmServicesInDtdReply('{"type":"Something else"}'), isEmpty);
      expect(vmServicesInDtdReply('[]'), isEmpty);
      expect(vmServicesInDtdReply('not json'), isEmpty);
    });
  });

  group('where the daemons write themselves down', () {
    List<String> on(String os, Map<String, String> environment) =>
        dtdPidFileDirectories(environment, operatingSystem: os);

    test('is under LOCALAPPDATA on Windows — measured on this machine', () {
      expect(
        on('windows', const {
          'LOCALAPPDATA': r'C:\Users\dlohani\AppData\Local',
          'APPDATA': r'C:\Users\dlohani\AppData\Roaming',
          'HOME': r'C:\Users\dlohani',
        }),
        [r'C:\Users\dlohani\AppData\Local\Dart\dtd'],
      );
    });

    test('is under Application Support on macOS, not the XDG state home', () {
      expect(
        on('macos', const {
          'HOME': '/Users/me',
          'XDG_STATE_HOME': '/Users/me/.xdg-state',
        }),
        ['/Users/me/Library/Application Support/Dart/dtd'],
      );
    });

    test('is the XDG state home on Linux when set, with the default beside '
        'it', () {
      expect(
        on('linux', const {
          'HOME': '/home/me',
          'XDG_STATE_HOME': '/xdg/state/',
        }),
        ['/xdg/state/Dart/dtd', '/home/me/.local/state/Dart/dtd'],
      );
    });

    test('is ~/.local/state on Linux without XDG_STATE_HOME', () {
      expect(on('linux', const {'HOME': '/home/me'}), [
        '/home/me/.local/state/Dart/dtd',
      ]);
      expect(on('linux', const {'HOME': '/home/me', 'XDG_STATE_HOME': ''}), [
        '/home/me/.local/state/Dart/dtd',
      ]);
    });

    test('DART_DATA_HOME comes first but does not hide the default', () {
      expect(
        on('macos', const {'DART_DATA_HOME': '/elsewhere/dart', 'HOME': '/u'}),
        ['/elsewhere/dart/dtd', '/u/Library/Application Support/Dart/dtd'],
      );
      expect(
        on('windows', const {
          'DART_DATA_HOME': r'D:\dart',
          'LOCALAPPDATA': r'C:\L',
        }),
        [r'D:\dart\dtd', r'C:\L\Dart\dtd'],
      );
    });

    test('names each directory once', () {
      expect(
        on('linux', const {
          'HOME': '/home/me',
          'DART_DATA_HOME': '/home/me/.local/state/Dart',
        }),
        ['/home/me/.local/state/Dart/dtd'],
      );
    });

    test(
      'is empty when the environment says nothing, never a guessed path',
      () {
        expect(on('windows', const {}), isEmpty);
        expect(on('macos', const {}), isEmpty);
        expect(on('linux', const {}), isEmpty);
        expect(on('fuchsia', const {'HOME': '/h'}), isEmpty);
      },
    );
  });
}
