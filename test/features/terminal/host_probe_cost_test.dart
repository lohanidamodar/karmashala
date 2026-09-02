import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/editor/application/code_editor_providers.dart';
import 'package:karmashala/src/features/editor/data/code_editor_service.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';

import '../../support/fake_command_runner.dart';

/// What **finding the host's terminals and editors costs on Windows**, counted
/// rather than timed, in the shape `ingest_throughput_cost_test.dart` and
/// `quiet_soak_cost_test.dart` established.
///
/// "Stop assuming the host is Windows" turned two compile-time constants — the
/// external-terminal catalogue and the `where.exe` PATH probe — into runtime
/// branches, and both sit on a path that spawns host processes. That is the
/// shape a refactor like it usually pays for: a fact that used to be free
/// becomes a process spawn, and a process spawn on the primary target is real
/// main-isolate time. Nothing counted it, so this does.
///
/// The units:
///
/// * **host process spawns** — `CommandRunner.run` calls. Each one is a real
///   `where.exe` on Windows, tens of milliseconds of process creation.
/// * **filesystem stats** — the `Directory(path).existsSync()` the refactor
///   added to `available()` for macOS app bundles, which must not run here.
/// * **reads** — how many times the provider graph was asked, so the count can
///   be shown to be per *session* rather than per read.
void main() {
  /// Enough reads that a per-read cost could not hide inside a per-session one.
  const reads = 25;

  group('detecting external terminals on a Windows host', () {
    test('costs one PATH probe per candidate, once for the session', () async {
      final runner = FakeCommandRunner();
      final container = ProviderContainer(
        overrides: [
          hostCommandRunnerProvider.overrideWithValue(runner),
          systemTerminalServiceProvider.overrideWithValue(
            SystemTerminalService(runner, windows: true, macOs: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      for (var i = 0; i < reads; i++) {
        await container.read(availableSystemTerminalsProvider.future);
      }

      final candidates = SystemTerminalService.candidatesFor(
        windows: true,
        macOs: false,
      );
      // ignore: avoid_print
      print(
        'HOST-PROBE terminals host=windows reads=$reads '
        'candidates=${candidates.length} spawns=${runner.requests.length} '
        'starts=${runner.startRequests.length}',
      );

      expect(
        runner.requests.length,
        candidates.length,
        reason: 'one probe per candidate — and $reads reads, not $reads times '
            'that: the provider is not auto-dispose, so the catalogue is '
            'settled once per session',
      );
      expect(
        runner.requests.map((r) => r.executable).toSet(),
        {'where.exe'},
        reason: 'the Windows probe is unchanged by the refactor',
      );
      expect(runner.startRequests, isEmpty, reason: 'detection launches nothing');
    });

    test('is the same five candidates it was, and stats no bundle', () {
      // The macOS additions are additions *to the macOS branch*. Windows keeps
      // exactly the catalogue that shipped before, and `appBundlePaths` — the
      // one new per-candidate filesystem stat inside `available()` — is empty
      // on every one of them, so the loop makes no syscall here at all.
      final windows = SystemTerminalService.candidatesFor(
        windows: true,
        macOs: false,
      );

      expect(windows.map((t) => t.executable), [
        'wt.exe',
        'wezterm.exe',
        'alacritty.exe',
        'powershell.exe',
        'cmd.exe',
      ]);
      expect(
        windows.expand((t) => t.appBundlePaths),
        isEmpty,
        reason: 'a Windows probe costs zero filesystem stats',
      );
    });

    test('a Mac answers Terminal.app from disk rather than PATH', () {
      // The reason the stat exists: neither Terminal.app nor iTerm puts
      // anything on PATH, so probing for them there spawns a process that can
      // only ever fail. A stat replaces that spawn — it does not add to it.
      final macOs = SystemTerminalService.candidatesFor(
        windows: false,
        macOs: true,
      );
      final bundled = macOs.where((t) => t.appBundlePaths.isNotEmpty);

      expect(bundled.map((t) => t.label), ['Terminal', 'iTerm']);
    });
  });

  group('detecting code editors on a Windows host', () {
    test('costs one PATH probe per candidate, once for the session', () async {
      final runner = FakeCommandRunner();
      final container = ProviderContainer(
        overrides: [
          hostCommandRunnerProvider.overrideWithValue(runner),
          codeEditorServiceProvider.overrideWithValue(
            CodeEditorService(runner, windows: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      for (var i = 0; i < reads; i++) {
        await container.read(availableCodeEditorsProvider.future);
      }

      // ignore: avoid_print
      print(
        'HOST-PROBE editors host=windows reads=$reads '
        'spawns=${runner.requests.length} '
        'starts=${runner.startRequests.length}',
      );

      expect(
        runner.requests.length,
        2,
        reason: 'VS Code and Zed, once — not once per read',
      );
      expect(runner.requests.map((r) => r.executable).toSet(), {'where.exe'});
      expect(runner.startRequests, isEmpty);
    });
  });
}
