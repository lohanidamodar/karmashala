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
      expect(apps.single.uri.toString(), 'ws://127.0.0.1:54385/Rzp5Wq0-P2o=/ws');
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
    test('is under LOCALAPPDATA on Windows — measured on this machine', () {
      expect(
        dtdPidFileDirectory(
          const <String, String>{r'LOCALAPPDATA': r'C:\Users\dlohani\AppData\Local'},
          isWindows: true,
        ),
        r'C:\Users\dlohani\AppData\Local\Dart\dtd',
      );
    });

    test('DART_DATA_HOME wins wherever it is set', () {
      expect(
        dtdPidFileDirectory(
          const <String, String>{'DART_DATA_HOME': '/elsewhere/dart'},
          isWindows: false,
        ),
        '/elsewhere/dart/dtd',
      );
    });

    test('is null when the environment says nothing, never a guessed path', () {
      expect(
        dtdPidFileDirectory(const <String, String>{}, isWindows: true),
        isNull,
      );
      expect(
        dtdPidFileDirectory(const <String, String>{}, isWindows: false),
        isNull,
      );
    });
  });
}
