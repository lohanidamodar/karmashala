import 'dart:async';

import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/browser/data/browser_launcher.dart';
import 'package:karmashala/src/features/browser/data/devtools_http_endpoint.dart';
import 'package:karmashala/src/features/browser/domain/browser_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

/// A [DevToolsHttpEndpoint] whose probe answers are scripted.
///
/// The last state is repeated once the script runs out, so "not listening,
/// then listening after the browser starts" is one short list.
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
  late FakeCommandRunner runner;

  setUp(() => runner = FakeCommandRunner());

  BrowserLauncher buildLauncher(
    ScriptedEndpoint endpoint, {
    String? executable = r'C:\chrome.exe',
  }) => BrowserLauncher(
    runner: runner,
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
      expect(runner.startRequests, isEmpty);
    });

    test(
      'attaching never launches a browser, even when one is installed',
      () async {
        final endpoint = ScriptedEndpoint([
          DevToolsEndpointState.available,
        ], port: 9222);
        await buildLauncher(endpoint).connect();
        expect(runner.startRequests, isEmpty);
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
        expect(runner.startRequests, isEmpty);
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
        expect(runner.startRequests, isEmpty);
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

      final request = runner.startRequests.single;
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
      expect(runner.startRequests.single.arguments.last, 'https://example.com');
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
      final handle = FakeProcessHandle();
      runner.processFactory = (_) => handle;
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

    test('a browser that cannot be started at all is reported', () async {
      runner.throwError = CommandException('The system cannot find the file');
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
