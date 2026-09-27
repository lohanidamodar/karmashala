import 'dart:async';
import 'dart:io';

import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

import 'support/fake_browser_process.dart';

/// A [DevToolsHttpEndpoint] whose probe answers are scripted. The last state
/// repeats once the script runs out, so a start-up sequence is one short list.
class ScriptedEndpoint extends DevToolsHttpEndpoint {
  ScriptedEndpoint(this.states, {required super.port});

  final List<DevToolsEndpointState> states;
  int probes = 0;
  bool wasClosed = false;

  @override
  Future<DevToolsEndpointState> probe() async {
    final state = states[probes.clamp(0, states.length - 1)];
    probes++;
    return state;
  }

  @override
  void close() => wasClosed = true;
}

Matcher failsWith(BrowserFailure failure) => throwsA(
  isA<BrowserException>().having((e) => e.failure, 'failure', failure),
);

void main() {
  late FakeProcessStarter starter;

  setUp(() => starter = FakeProcessStarter());

  BrowserLauncher buildLauncher(
    ScriptedEndpoint endpoint, {
    String? executable = r'C:\chrome.exe',
  }) => BrowserLauncher(
    startProcess: starter.call,
    locateExecutable: () => executable,
    endpointFactory: (_) => endpoint,
    createUserDataDir: () async => r'C:\Temp\karmashala-cdp-profile-test',
    pollInterval: const Duration(milliseconds: 5),
  );

  group('attach', () {
    test('attaches when a browser is already listening', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.available,
      ], port: 9222);
      final result = await buildLauncher(endpoint).connect();
      expect(result.mode, BrowserConnectionMode.attached);
      expect(result.process, isNull);
      expect(starter.starts, isEmpty);
    });

    test(
      'attaching never launches a browser, even when one is installed',
      () async {
        final endpoint = ScriptedEndpoint([
          DevToolsEndpointState.available,
        ], port: 9222);
        await buildLauncher(endpoint).connect();
        expect(starter.starts, isEmpty);
      },
    );

    test('describes itself as attached', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.available,
      ], port: 9222);
      final result = await buildLauncher(endpoint).connect(port: 9222);
      expect(result.description, contains('Attached'));
      expect(result.description, contains('9222'));
    });
  });

  group('refusing to guess', () {
    test(
      'an unrelated server on the port is reported, not launched over',
      () async {
        final endpoint = ScriptedEndpoint([
          DevToolsEndpointState.occupiedByOther,
        ], port: 9222);
        await expectLater(
          buildLauncher(endpoint).connect(port: 9222),
          failsWith(BrowserFailure.portInUse),
        );
        expect(starter.starts, isEmpty);
        expect(endpoint.wasClosed, isTrue);
      },
    );

    test(
      'nothing listening and no permission to spawn reports notRunning',
      () async {
        final endpoint = ScriptedEndpoint([
          DevToolsEndpointState.notListening,
        ], port: 9222);
        await expectLater(
          buildLauncher(endpoint).connect(spawnIfNeeded: false),
          failsWith(BrowserFailure.notRunning),
        );
        expect(starter.starts, isEmpty);
      },
    );

    test('no browser installed reports chromeNotFound', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
      ], port: 9222);
      await expectLater(
        buildLauncher(endpoint, executable: null).connect(),
        failsWith(BrowserFailure.chromeNotFound),
      );
    });
  });

  group('spawn', () {
    test('launches with the debugging port and a throwaway profile', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.available,
      ], port: 9333);
      final result = await buildLauncher(endpoint).connect(port: 9333);

      expect(result.mode, BrowserConnectionMode.spawned);
      expect(result.executable, r'C:\chrome.exe');
      expect(result.userDataDir, r'C:\Temp\karmashala-cdp-profile-test');
      expect(result.process, isNotNull);

      final request = starter.starts.single;
      expect(request.executable, r'C:\chrome.exe');
      expect(request.arguments, contains('--remote-debugging-port=9333'));
      expect(
        request.arguments,
        contains(r'--user-data-dir=C:\Temp\karmashala-cdp-profile-test'),
      );
    });

    test('the initial url is passed to the new browser', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.available,
      ], port: 9333);
      await buildLauncher(endpoint).connect(initialUrl: 'https://example.com');
      expect(starter.starts.single.arguments.last, 'https://example.com');
    });

    test('a headless launcher spawns without a window', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.available,
      ], port: 9333);
      await BrowserLauncher(
        startProcess: starter.call,
        locateExecutable: () => '/usr/bin/chromium',
        endpointFactory: (_) => endpoint,
        createUserDataDir: () async => '/tmp/profile',
        pollInterval: const Duration(milliseconds: 5),
        headless: true,
      ).connect();
      expect(starter.starts.single.arguments, contains('--headless=new'));
    });

    test('polls until the port opens rather than assuming it did', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.available,
      ], port: 9333);
      final result = await buildLauncher(endpoint).connect();
      expect(result.mode, BrowserConnectionMode.spawned);
      expect(endpoint.probes, 4);
    });

    test('a browser that exits immediately reports startupFailed with its '
        'own diagnostics', () async {
      final handle = FakeBrowserProcess();
      starter.processFactory = (_) => handle;
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
      ], port: 9333);
      scheduleMicrotask(() {
        handle.emitStderr(
          'Failed to create a ProcessSingleton for your '
          'profile directory.',
        );
        handle.complete(21);
      });
      await expectLater(
        buildLauncher(endpoint).connect(),
        throwsA(
          isA<BrowserException>()
              .having((e) => e.failure, 'failure', BrowserFailure.startupFailed)
              .having((e) => e.message, 'message', contains('code 21'))
              .having(
                (e) => e.message,
                'message',
                contains('ProcessSingleton'),
              ),
        ),
      );
    });

    test(
      'a browser that never opens the port times out as startupFailed',
      () async {
        final endpoint = ScriptedEndpoint([
          DevToolsEndpointState.notListening,
        ], port: 9333);
        await expectLater(
          buildLauncher(
            endpoint,
          ).connect(startupTimeout: const Duration(milliseconds: 40)),
          failsWith(BrowserFailure.startupFailed),
        );
      },
    );

    test('a browser that never opens the port is killed and its profile '
        'removed', () async {
      final profile = Directory.systemTemp.createTempSync('cdp-profile-');
      final handle = FakeBrowserProcess();
      starter.processFactory = (_) => handle;
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
      ], port: 9333);
      final launcher = BrowserLauncher(
        startProcess: starter.call,
        locateExecutable: () => r'C:\chrome.exe',
        endpointFactory: (_) => endpoint,
        createUserDataDir: () async => profile.path,
        pollInterval: const Duration(milliseconds: 5),
      );

      await expectLater(
        launcher.connect(startupTimeout: const Duration(milliseconds: 40)),
        failsWith(BrowserFailure.startupFailed),
      );

      // Without this, every failed start left a Chrome running on a profile
      // nobody would ever open again.
      expect(handle.killed, isTrue);
      expect(profile.existsSync(), isFalse);
      expect(endpoint.wasClosed, isTrue);
    });

    test(
      'a browser that exits at once still has its profile removed',
      () async {
        final profile = Directory.systemTemp.createTempSync('cdp-profile-');
        final handle = FakeBrowserProcess();
        starter.processFactory = (_) => handle;
        final endpoint = ScriptedEndpoint([
          DevToolsEndpointState.notListening,
        ], port: 9333);
        scheduleMicrotask(() => handle.complete(21));
        final launcher = BrowserLauncher(
          startProcess: starter.call,
          locateExecutable: () => r'C:\chrome.exe',
          endpointFactory: (_) => endpoint,
          createUserDataDir: () async => profile.path,
          pollInterval: const Duration(milliseconds: 5),
        );

        await expectLater(
          launcher.connect(),
          failsWith(BrowserFailure.startupFailed),
        );
        expect(profile.existsSync(), isFalse);
      },
    );

    test('shutDown kills a spawned browser and removes its profile', () async {
      final profile = Directory.systemTemp.createTempSync('cdp-profile-');
      final handle = FakeBrowserProcess();
      starter.processFactory = (_) => handle;
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.available,
      ], port: 9333);
      final launcher = BrowserLauncher(
        startProcess: starter.call,
        locateExecutable: () => r'C:\chrome.exe',
        endpointFactory: (_) => endpoint,
        createUserDataDir: () async => profile.path,
        pollInterval: const Duration(milliseconds: 5),
      );
      final spawned = await launcher.connect();
      expect(profile.existsSync(), isTrue);

      await spawned.shutDown();

      expect(handle.killed, isTrue);
      expect(profile.existsSync(), isFalse);
    });

    test('shutDown leaves an attached browser alone', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.available,
      ], port: 9222);
      final attached = await buildLauncher(endpoint).connect();
      await expectLater(attached.shutDown(), completes);
      expect(starter.starts, isEmpty);
    });

    test('a browser that cannot be started at all is reported', () async {
      starter.throwError = BrowserProcessException(
        'The system cannot find the file',
      );
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
      ], port: 9333);
      await expectLater(
        buildLauncher(endpoint).connect(),
        throwsA(
          isA<BrowserException>()
              .having((e) => e.failure, 'failure', BrowserFailure.startupFailed)
              .having(
                (e) => e.message,
                'message',
                contains('cannot find the file'),
              ),
        ),
      );
    });

    test('describes itself as launched', () async {
      final endpoint = ScriptedEndpoint([
        DevToolsEndpointState.notListening,
        DevToolsEndpointState.available,
      ], port: 9333);
      final result = await buildLauncher(endpoint).connect(port: 9333);
      expect(result.description, contains('Launched'));
      expect(result.description, contains('isolated profile'));
    });
  });

  test('the default port is Chrome\'s own', () {
    expect(BrowserLauncher.defaultPort, 9222);
  });
}
