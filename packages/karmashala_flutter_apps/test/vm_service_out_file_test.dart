import 'package:test/test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

void main() {
  group('vmServiceOutFileFor', () {
    test('Windows watches its own directory', () {
      expect(
        vmServiceOutFileFor(
          kind: EnvironmentKind.windowsNative,
          directory: r'C:\Users\me\AppData\Roaming\karmashala\vmservice',
          name: 'demo-1.uri',
        ),
        r'C:\Users\me\AppData\Roaming\karmashala\vmservice\demo-1.uri',
      );
    });

    test('a trailing separator does not become a double one', () {
      expect(
        vmServiceOutFileFor(
          kind: EnvironmentKind.windowsNative,
          directory: r'C:\vmservice\',
          name: 'a.uri',
        ),
        r'C:\vmservice\a.uri',
      );
      expect(
        vmServiceOutFileFor(
          kind: EnvironmentKind.localPosix,
          directory: '/home/me/.local/share/karmashala/vmservice/',
          name: 'a.uri',
        ),
        '/home/me/.local/share/karmashala/vmservice/a.uri',
      );
    });

    test(
      'WSL writes through the drive mount, so the Windows watcher fires',
      () {
        expect(
          vmServiceOutFileFor(
            kind: EnvironmentKind.wsl,
            directory: r'C:\Users\me\AppData\Roaming\karmashala\vmservice',
            name: 'demo-1.uri',
          ),
          '/mnt/c/Users/me/AppData/Roaming/karmashala/vmservice/demo-1.uri',
        );
      },
    );

    test('a WSL run whose host directory is not on a drive gets no file', () {
      expect(
        vmServiceOutFileFor(
          kind: EnvironmentKind.wsl,
          directory: r'\\server\share\vmservice',
          name: 'demo-1.uri',
        ),
        isNull,
      );
    });

    test('SSH gets none: another disk, and an address we could not dial', () {
      expect(
        vmServiceOutFileFor(
          kind: EnvironmentKind.ssh,
          directory: r'C:\vmservice',
          name: 'demo-1.uri',
        ),
        isNull,
      );
    });
  });

  group('hostSpellingOfOutFile', () {
    test('a mount path comes back as the Windows path it really is', () {
      expect(
        hostSpellingOfOutFile('/mnt/c/Users/me/vmservice/demo-1.uri'),
        r'C:\Users\me\vmservice\demo-1.uri',
      );
    });

    test('a path already on this host is left alone', () {
      expect(
        hostSpellingOfOutFile(r'C:\Users\me\vmservice\demo-1.uri'),
        r'C:\Users\me\vmservice\demo-1.uri',
      );
      expect(hostSpellingOfOutFile('/home/me/x.uri'), '/home/me/x.uri');
    });
  });

  group('vmServiceOutFileName', () {
    test('the project name survives and the awkward characters do not', () {
      expect(vmServiceOutFileName('my_app', 'id-0'), 'my_app-id-0.uri');
      expect(vmServiceOutFileName('my app/v2', 'id-1'), 'my-app-v2-id-1.uri');
    });

    test('two runs of one project are two files', () {
      expect(
        vmServiceOutFileName('demo', 'id-0'),
        isNot(vmServiceOutFileName('demo', 'id-1')),
      );
    });
  });
}
