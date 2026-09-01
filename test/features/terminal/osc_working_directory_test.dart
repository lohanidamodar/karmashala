import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/osc_router.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/domain/working_directory_osc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_instance.dart';

/// OSC 7 — the shell telling the pane which directory it is in *now*.
///
/// A pane used to record only the directory it was *launched* in, and that
/// stale value was read by relative-path link resolution, the tab label, the
/// workspace record a pane is restored from and the MCP terminal tools. These
/// pin the reading of the sequence, the ownership of xterm's single OSC slot,
/// and the cost of a `cd`.
void main() {
  group('reading OSC 7', () {
    // The payload xterm hands us: `OSC 7 ; <uri>` arrives as ('7', [uri]).
    String? read(String payload, {String? hostname}) =>
        workingDirectoryFromOsc('7', [payload], hostname: hostname);

    test('a POSIX path with the host that emitted it', () {
      expect(read('file://buildbox/home/me/src', hostname: 'buildbox'),
          '/home/me/src');
    });

    test('an empty host is always this machine', () {
      // What a shell emits when it will not name itself; there is no other
      // machine an empty authority could mean.
      expect(read('file:///home/me/src'), '/home/me/src');
      expect(read('file:///home/me/src', hostname: 'buildbox'), '/home/me/src');
    });

    test('localhost is this machine too', () {
      expect(read('file://localhost/home/me', hostname: 'buildbox'), '/home/me');
    });

    test('a Windows path loses the slash before the drive letter', () {
      // `file:///C:/src/app` — the leading slash is real URI syntax, not part
      // of the path.
      expect(read('file:///C:/src/app'), r'C:\src\app');
      expect(read('file://buildbox/C:/src/app', hostname: 'buildbox'),
          r'C:\src\app');
    });

    test('percent-encoded spaces are decoded', () {
      expect(read('file:///C:/src/my%20app'), r'C:\src\my app');
      expect(read('file:///home/me/my%20src'), '/home/me/my src');
    });

    test('the host is matched case-insensitively', () {
      expect(read('file://BuildBox/home/me', hostname: 'buildbox'), '/home/me');
    });

    test('a trailing slash is trimmed, but a root survives', () {
      expect(read('file:///home/me/'), '/home/me');
      expect(read('file:///'), '/');
      // `Uri` normalises an authority-only file URI to the root of it, so a
      // payload naming no path at all is the same directory as the two above.
      expect(read('file://localhost', hostname: 'localhost'), '/');
    });

    test('a payload split on its own semicolon is put back together', () {
      // xterm splits an OSC on ';', and a directory may legitimately contain
      // one — so the arguments are rejoined rather than the first one taken.
      expect(
        workingDirectoryFromOsc('7', ['file:///home/me/a', 'b']),
        '/home/me/a;b',
      );
    });

    group('answers nothing rather than guessing when', () {
      test('it is not an OSC 7', () {
        expect(workingDirectoryFromOsc('133', ['A']), isNull);
        expect(workingDirectoryFromOsc('0', ['file:///home/me']), isNull);
      });

      test('the payload is empty', () {
        expect(workingDirectoryFromOsc('7', const []), isNull);
        expect(read(''), isNull);
      });

      test('the scheme is not file:', () {
        expect(read('http://localhost/home/me'), isNull);
        expect(read('/home/me'), isNull, reason: 'no scheme at all');
      });

      test('the host is another machine', () {
        expect(read('file://otherbox/home/me', hostname: 'buildbox'), isNull);
        // Nothing here knows this machine's name, so no host can be trusted.
        expect(read('file://otherbox/home/me'), isNull);
      });

      test('the URI will not parse', () {
        expect(read('file://[not-a-host/home/me'), isNull);
        expect(read('file:///home/%zz'), isNull, reason: 'bad % escape');
      });
    });
  });

  group('the OSC router', () {
    test('one dispatch reaches every listener', () {
      final router = OscRouter();
      final first = <String>[];
      final second = <String>[];
      router
        ..add((code, args) => first.add('$code:${args.join(",")}'))
        ..add((code, args) => second.add('$code:${args.join(",")}'));

      router.dispatch('133', ['A']);

      expect(first, ['133:A']);
      expect(second, ['133:A']);
    });

    test('a removed listener stops hearing', () {
      final router = OscRouter();
      final seen = <String>[];
      void listener(String code, List<String> args) => seen.add(code);
      router
        ..add(listener)
        ..dispatch('7', ['file:///a'])
        ..remove(listener)
        ..dispatch('7', ['file:///b']);

      expect(seen, ['7']);
    });

    test('a listener that removes itself mid-dispatch skips nobody', () {
      final router = OscRouter();
      final seen = <String>[];
      late void Function(String, List<String>) first;
      first = (code, args) {
        seen.add('first');
        router.remove(first);
      };
      router
        ..add(first)
        ..add((code, args) => seen.add('second'))
        ..dispatch('7', ['file:///a']);

      expect(seen, ['first', 'second']);
    });
  });

  group('a pane learns where it is', () {
    test('with integration on, both listeners get the stream', () {
      final pane = FakeTerminalInstance(
        id: 'p1',
        title: 'PowerShell',
        profileId: 'powershell',
        workingDirectory: r'C:\ws',
        shellIntegration: true,
      );
      addTearDown(pane.dispose);

      pane.terminal.write('\x1b]7;file:///C:/ws/lib\x07\x1b]133;A\x07');

      expect(pane.workingDirectory, r'C:\ws\lib',
          reason: 'the directory tracker saw OSC 7');
      expect(pane.commandBlocks!.tracker.pending, isNotNull,
          reason: 'the recorder saw OSC 133 through the same slot');
    });

    test('with integration off, OSC 7 still works', () {
      // A recorder only exists when shell integration is on; the directory has
      // to follow a `cd` either way, because plenty of shells emit OSC 7 on
      // their own.
      final pane = FakeTerminalInstance(
        id: 'p1',
        title: 'Ubuntu',
        profileId: 'wsl:Ubuntu',
        workingDirectory: '/home/me',
      );
      addTearDown(pane.dispose);
      expect(pane.commandBlocks, isNull);

      pane.terminal.write('\x1b]7;file:///home/me/src\x07');

      expect(pane.workingDirectory, '/home/me/src');
    });

    test('the launch directory is the answer until a shell says otherwise', () {
      final pane = FakeTerminalInstance(
        id: 'p1',
        title: 'PowerShell',
        profileId: 'powershell',
        workingDirectory: r'C:\ws',
      );
      addTearDown(pane.dispose);

      // Not an OSC 7 we can read: the pane keeps what it launched with rather
      // than forgetting where it is.
      pane.terminal.write('\x1b]7;file://otherbox/home/me\x07');

      expect(pane.workingDirectory, r'C:\ws');
    });

    test('the same directory twice notifies once', () {
      final pane = FakeTerminalInstance(
        id: 'p1',
        title: 'PowerShell',
        profileId: 'powershell',
        workingDirectory: r'C:\ws',
      );
      addTearDown(pane.dispose);
      var notifications = 0;
      pane.directory.addListener(() => notifications++);

      pane.terminal
        ..write('\x1b]7;file:///C:/ws/lib\x07')
        ..write('\x1b]7;file:///C:/ws/lib\x07')
        ..write('\x1b]7;file:///C:/ws/lib\x07');

      expect(notifications, 1,
          reason: 'a shell that re-emits OSC 7 on every prompt redraw must not '
              'republish the workspace per prompt');
    });
  });

  group('through the controller', () {
    late TerminalSessionsController controller;
    late ProviderContainer container;

    setUp(() {
      container = fakeTerminalContainer();
      controller = container.read(terminalSessionsControllerProvider.notifier);
    });
    tearDown(() => container.dispose());

    TerminalSessionsState get$() =>
        container.read(terminalSessionsControllerProvider);

    String onlyPaneOf(String tabId) =>
        get$().tabs.firstWhere((t) => t.id == tabId).layout.panes.single;

    FakeTerminalInstance paneOf(String tabId) =>
        controller.instanceFor(onlyPaneOf(tabId))! as FakeTerminalInstance;

    test('the tab label follows a cd', () {
      final tab = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws\karmashala',
      );
      expect(controller.titleForTab(tab), 'ws/karmashala');

      paneOf(tab).terminal.write('\x1b]7;file:///C:/ws/karmashala/lib\x07');

      expect(controller.titleForTab(tab), 'karmashala/lib');
    });

    test('a cd republishes, so the tab strip actually rebuilds', () {
      final tab = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
      );
      final before = get$();

      paneOf(tab).terminal.write('\x1b]7;file:///C:/ws/lib\x07');

      expect(get$(), isNot(before));
      expect(get$().directoryOf(onlyPaneOf(tab)), r'C:\ws\lib');
    });

    test('a cd tells the topology nothing, and that pane once', () {
      final tab = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
      );
      final pane = onlyPaneOf(tab);
      var topologyRebuilds = 0;
      var directoryRebuilds = 0;
      final onTopology = container.listen(
        terminalSessionsControllerProvider.select((s) => s.tabs),
        (_, _) => topologyRebuilds++,
      );
      final onDirectory = container.listen(
        terminalSessionsControllerProvider.select((s) => s.directoryOf(pane)),
        (_, _) => directoryRebuilds++,
      );
      addTearDown(onTopology.close);
      addTearDown(onDirectory.close);

      paneOf(tab).terminal
        ..write('\x1b]7;file:///C:/ws/lib\x07')
        ..write('\x1b]7;file:///C:/ws/lib\x07');

      expect(topologyRebuilds, 0);
      expect(directoryRebuilds, 1, reason: 'one republish per cd, and no more');
    });

    test('a closed pane can no longer republish', () {
      final tab = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
      );
      final pane = paneOf(tab);
      controller.closeTab(tab);

      // Would throw on a disposed notifier if the listener were still attached.
      expect(() => pane.terminal.write('\x1b]7;file:///C:/ws/lib\x07'),
          returnsNormally);
    });

    test('the stored record is where the pane ended up, not where it began', () {
      // A restored pane reopens in the directory the user left it in: the
      // launch directory is an artefact of how the pane was opened, and the
      // scrollback it comes back holding is the *observed* directory's. It
      // starts nothing — the directory only decides where a shell would spawn
      // if the user presses Start.
      final tab = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
      );
      paneOf(tab).terminal.write('\x1b]7;file:///C:/ws/lib\x07');

      expect(controller.instanceFor(onlyPaneOf(tab))!.workingDirectory,
          r'C:\ws\lib');
    });
  });

}
