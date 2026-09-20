import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/apps.dart';

/// **The desktop's own list, read rather than guessed.**
///
/// Measured on the owner's Windows machine 2026-09-14: 180 applications in
/// 1.3s, and three of the five editors installed — Antigravity, T3 Code,
/// Visual Studio — put nothing on `PATH` at all. A curated catalogue of editor
/// names could not have offered any of them.
void main() {
  group('the Start Menu pass', () {
    test('reads a name and its target off each line', () {
      final apps = windowsApplicationsIn(
        'Antigravity\tC:\\Users\\me\\AppData\\Local\\Programs\\antigravity\\Antigravity.exe\n'
        'Firefox\tC:\\Program Files\\Mozilla Firefox\\firefox.exe\n',
      );

      expect(apps.map((a) => a.name), ['Antigravity', 'Firefox']);
      expect(apps.first.launchPath, endsWith(r'\Antigravity.exe'));
      expect(apps.first.source, 'Start Menu');
    });

    test('one program listed by both menus is one application', () {
      // The per-machine and per-user Start Menus both carry anything installed
      // for everyone; VS Code really does appear twice on this machine.
      final apps = windowsApplicationsIn(
        'Visual Studio Code\tC:\\Programs\\Microsoft VS Code\\Code.exe\n'
        'Visual Studio Code\tc:\\programs\\microsoft vs code\\code.exe\n',
      );

      expect(apps, hasLength(1));
    });

    test('sorts by name, not by the order the menu was walked', () {
      final apps = windowsApplicationsIn(
        'Zed\tC:\\a\\zed.exe\nAudacity\tC:\\b\\audacity.exe\n',
      );

      expect(apps.map((a) => a.name), ['Audacity', 'Zed']);
    });

    test('a line with no target is not an application', () {
      expect(windowsApplicationsIn('Broken\t\n\n  \n'), isEmpty);
    });
  });

  group('a .desktop entry', () {
    InstalledApplication? entry(String contents) =>
        desktopEntryIn(contents, source: '/usr/share/applications');

    test('is its Name and the program its Exec names', () {
      final app = entry('''
[Desktop Entry]
Type=Application
Name=Visual Studio Code
Exec=/usr/share/code/code --unity-launch %F
Icon=code
''');

      expect(app!.name, 'Visual Studio Code');
      expect(app.launchPath, '/usr/share/code/code');
      expect(app.arguments, ['--unity-launch']);
    });

    test('a hidden entry is not offered', () {
      expect(
        entry(
          '[Desktop Entry]\nType=Application\nName=A\nExec=a\nNoDisplay=true\n',
        ),
        isNull,
      );
      expect(
        entry(
          '[Desktop Entry]\nType=Application\nName=A\nExec=a\nHidden=true\n',
        ),
        isNull,
      );
    });

    test('a link or a directory entry is not an application', () {
      expect(
        entry('[Desktop Entry]\nType=Link\nName=A\nURL=http://x\n'),
        isNull,
      );
    });

    test('only the Desktop Entry group is read', () {
      // An action group carries its own Name and Exec; taking those would
      // offer "New Window" as though it were a separate application.
      final app = entry('''
[Desktop Entry]
Type=Application
Name=Firefox
Exec=/usr/bin/firefox %u

[Desktop Action new-window]
Name=New Window
Exec=/usr/bin/firefox --new-window
''');

      expect(app!.name, 'Firefox');
      expect(app.arguments, isEmpty);
    });

    test('a localised name does not overwrite the plain one', () {
      final app = entry(
        '[Desktop Entry]\nType=Application\nName=Files\nName[de]=Dateien\n'
        'Exec=nautilus\n',
      );

      expect(app!.name, 'Files');
    });
  });

  group('splitDesktopExec', () {
    test('drops the field codes the desktop would have substituted', () {
      // Passed through, `%F` becomes a file the editor tries to open.
      expect(splitDesktopExec('/usr/bin/code %F'), ['/usr/bin/code']);
      expect(splitDesktopExec('app %f %u %i %c %k'), ['app']);
    });

    test('keeps an escaped percent', () {
      expect(splitDesktopExec('app 100%%'), ['app', '100%']);
    });

    test('keeps a quoted path whole', () {
      expect(splitDesktopExec('"/opt/My App/bin/run" --flag %U'), [
        '/opt/My App/bin/run',
        '--flag',
      ]);
    });

    test('an empty line is no program', () {
      expect(splitDesktopExec('   '), isEmpty);
      expect(splitDesktopExec('%F'), isEmpty);
    });
  });

  group('the picker', () {
    final apps = [
      const InstalledApplication(
        name: 'Antigravity',
        launchPath: r'C:\Programs\antigravity\Antigravity.exe',
        source: 'Start Menu',
      ),
      const InstalledApplication(
        name: 'Firefox',
        launchPath: r'C:\Program Files\Mozilla Firefox\firefox.exe',
        source: 'Start Menu',
      ),
    ];

    test('matches on the name and on the path', () {
      expect(matchingApplications(apps, 'grav').single.name, 'Antigravity');
      expect(matchingApplications(apps, 'mozilla').single.name, 'Firefox');
    });

    test('an empty query is the whole list', () {
      expect(matchingApplications(apps, '   '), hasLength(2));
    });

    test('names a path nobody recorded a label for', () {
      expect(applicationNameFor(r'C:\Programs\t3code\T3 Code.exe'), 'T3 Code');
      expect(applicationNameFor('/Applications/Zed.app'), 'Zed');
    });

    test('a macOS bundle is told from a program', () {
      // It is a directory: `open -a` launches it and `Process.start` cannot.
      expect(isMacApplicationBundle('/Applications/Zed.app'), isTrue);
      expect(isMacApplicationBundle(r'C:\Programs\Code.exe'), isFalse);
    });
  });
}
