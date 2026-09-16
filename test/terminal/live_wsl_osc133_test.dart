@Tags(['live-wsl'])
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/terminal_tools.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../features/terminal/fake_instance.dart';

/// **Does a WSL pane report its own command boundaries?**
///
/// Nothing above the PTY can tell. The markers are emitted by a shell inside
/// the distribution, from an rc file this app wrote there a moment earlier,
/// through `cmd.exe` and `wsl.exe` and a ConPTY — and every one of those relays
/// is a place a sequence could be split, expanded or eaten. Only the far end of
/// a real chain answers it.
///
/// Loop 32 wrote the bash rc file, ran it against real bash, and then **parked
/// it** for three reasons. The first was that it could not be verified end to
/// end: through a *pipe* the marker order came out wrong (a spurious `D;0`, a
/// doubled `C`), which was probably the non-tty relay rather than the script —
/// but "probably" is not verified, and telling the two apart needs a real
/// ConPTY. This file is that ConPTY. The second was the delivery: `bash
/// --rcfile` pointed at a file it cannot read starts a shell with *no user
/// configuration at all*, so a probe had to confirm both the login shell and
/// the file. [wslIntegrationBootstrap] answers both from inside the
/// distribution instead. The third was that the only distro here defaults to
/// zsh, so bash would have been inert — which is why zsh is covered too, and
/// why bash is driven with its one input forced.
///
/// **Measured 2026-09-09 on Windows 10.0.26200 against `archlinux`** — bash
/// 5.3.15, zsh 5.9.2, starship — the results are in each test's own comment.
///
/// Nothing here polls: a marker arrives on the PTY's own callback and completes
/// a future. The timeouts are failure guards, not a cadence.
///
/// Skips itself where there is no WSL or no `flutter_pty.dll` to spawn a real
/// ConPTY with — the same shape as `live_wsl_pane_test.dart`.
void main() {
  // A real pane ingests through `PtyOutputCoalescer`, which asks
  // `SchedulerBinding` for a post-frame callback. No frames are pumped in a
  // plain `test()`, so it is the coalescer's own watchdog that drains the
  // stream — but the binding still has to exist for it to get that far.
  TestWidgetsFlutterBinding.ensureInitialized();

  final probe = _probe();
  if (probe != null) {
    test('live WSL OSC 133 test is skipped', () {}, skip: probe);
    return;
  }
  final distro = _defaultDistro()!;
  final profile = TerminalProfile(
    id: TerminalProfile.wslId(distro),
    label: '$distro (WSL)',
    shell: TerminalShell.wsl,
    wslDistribution: distro,
  );

  for (final shell in const ['bash', 'zsh']) {
    test('$shell in a WSL pane reports every command boundary', () async {
      final path = _pathIn(distro, shell);
      if (path == null) {
        markTestSkipped('no $shell in $distro');
        return;
      }
      final pane = await _Pane.open(
        _forcedShellLaunch(distro, path),
        'osc133-$shell',
      );
      addTearDown(pane.close);

      // Measured 2026-09-09: 0, 1 and 7 for both shells, and the command text
      // recovered from `B` in every block.
      final zero = await pane.run('true');
      final one = await pane.run('false');
      final seven = await pane.run("sh -c 'exit 7'");

      expect([zero.exitCode, one.exitCode, seven.exitCode], [0, 1, 7]);
      for (final block in [zero, one, seven]) {
        expect(
          block.hasStarted,
          isTrue,
          reason: 'C never arrived, so the block would have been discarded',
        );
        expect(block.inputRef, isNotNull, reason: 'B never arrived');
        expect(block.duration, isNotNull);
      }
      expect(zero.command, contains('true'));
      expect(seven.command, contains('exit 7'));

      // Whole, not merely present: a sequence the parser could not reassemble
      // would have landed in the buffer as text instead of becoming a marker.
      expect(pane.screen, isNot(contains('133;')));
      expect(pane.screen, isNot(contains('\u001b')));
    }, timeout: const Timeout(Duration(seconds: 120)));
  }

  test('an empty Enter is not a command', () async {
    final path = _pathIn(distro, 'bash');
    if (path == null) {
      markTestSkipped('no bash in $distro');
      return;
    }
    final pane = await _Pane.open(
      _forcedShellLaunch(distro, path),
      'osc133-empty',
    );
    addTearDown(pane.close);

    // `PS0` expands in a subshell and cannot flag "a command is running", so an
    // empty line emits `A … D` with no `C`. Measured: the tracker drops it, and
    // the next real command is still the one that completes.
    pane.type('');
    final real = await pane.run('true');
    expect(real.exitCode, 0);
    expect(pane.completed, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('terminal_run gets a real exit code out of a WSL pane', () async {
    final db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), const SystemClock());
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          database: db,
          shellIntegration: true,
          // The production factory, so the pane is built by the same code the
          // app runs — including `ptyLaunchFor`'s integrated WSL branch.
          instanceFactory: createPtyTerminalInstance,
        ),
      ],
    );
    addTearDown(db.close);
    addTearDown(container.dispose);

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tabId = controller.openTab(profile, workingDirectory: '/tmp');
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id == tabId)
        .focusedPaneId;
    addTearDown(() => controller.closeTab(tabId, detach: false));

    final instance = controller.instanceFor(paneId)!;
    expect(
      instance.commandBlocks,
      isNotNull,
      reason: 'the pane must carry a recorder, or terminal_run cannot wait',
    );
    await _firstPrompt(instance);

    final tools = TerminalControlTools(container);
    Future<Map<String, Object?>> run(String command) async =>
        (await tools.call('terminal_run', <String, dynamic>{
              'paneId': paneId,
              'command': command,
              'timeoutSeconds': 45,
            }))!
            as Map<String, Object?>;

    // Measured 2026-09-09 against the owner's `archlinux`, whose login shell is
    // zsh: `finished` true, the real code, and the command's own output.
    final ok = await run('echo karmashala-ok');
    expect(ok['finished'], isTrue);
    expect(ok['exitCode'], 0);
    expect(ok['exitCodeKnown'], isTrue);
    expect(ok['output'], contains('karmashala-ok'));
    expect(ok['durationMs'], isNotNull);
    expect(ok['note'], contains('Finished with exit code 0'));

    final failed = await run("sh -c 'exit 5'");
    expect(failed['finished'], isTrue);
    expect(failed['exitCode'], 5);
    expect(failed['exitCodeKnown'], isTrue);
  }, timeout: const Timeout(Duration(seconds: 180)));
}

/// The production bootstrap with its one input — the login shell — forced.
///
/// A distribution has exactly one login shell, and this machine's is zsh, so
/// the bash half could otherwise never be driven here. Everything else is the
/// launch the app builds: [wrapForPty]'s
/// `cmd.exe /c wsl.exe -d … --cd … -- eval $(…|base64 -d)`, carrying the same
/// script.
PtyLaunch _forcedShellLaunch(String distro, String shellPath) => wrapForPty(
  ShellCommand(
    executable: '/bin/sh',
    arguments: [
      '-c',
      'SHELL=$shellPath\nexport SHELL\n${wslIntegrationBootstrap()}',
    ],
    workingDirectory: '/tmp',
  ),
  LaunchContext.wsl(distro),
);

/// One throwaway pane, built the way production builds one, with the recorder
/// armed.
class _Pane {
  _Pane(this.instance);

  static Future<_Pane> open(PtyLaunch launch, String id) async {
    final instance = PtyTerminalInstance(
      id: id,
      title: id,
      profileId: id,
      launch: launch,
      shellIntegration: true,
    );
    final pane = _Pane(instance);
    instance.commandBlocks!.tracker.addCompletionListener(pane._onCompleted);
    await _firstPrompt(instance);
    return pane;
  }

  final PtyTerminalInstance instance;
  final List<CommandBlock> completed = [];
  Completer<CommandBlock>? _waiting;

  /// The pane as a person would see it, which is where a marker that failed to
  /// parse would have ended up.
  String get screen => terminalTailLines(instance.terminal, lines: 200).join('\n');

  void type(String command) => instance.terminal
    ..textInput(command)
    ..textInput('\r');

  /// Types [command] and waits for **its** `D`. Event-driven: the tracker
  /// completes this from inside the marker's own callback.
  Future<CommandBlock> run(String command) {
    final waiter = _waiting = Completer<CommandBlock>();
    type(command);
    return waiter.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail(
        'no OSC 133 D for `$command`. Screen:\n$screen',
      ),
    );
  }

  void _onCompleted(CommandBlock block) {
    completed.add(block);
    final waiter = _waiting;
    if (waiter != null && !waiter.isCompleted) {
      _waiting = null;
      waiter.complete(block);
    }
  }

  /// Awaits the reap rather than only asking for it: a live test must leave
  /// nothing running inside the distribution.
  Future<void> close() async {
    instance.dispose();
    await instance.reaped;
  }
}

/// Completes on the pane's first `OSC 133 ; A`, which is the shell saying it is
/// ready to be typed into.
///
/// Asks the recorder first, in case one already arrived, then wraps the pane's
/// own OSC handler rather than replacing it — the pane owns xterm's single slot
/// for its whole life, and the recorder is behind it.
Future<void> _firstPrompt(TerminalInstance instance) {
  final recorder = instance.commandBlocks!;
  if (recorder.tracker.latest != null) return Future<void>.value();
  final ready = Completer<void>();
  final terminal = instance.terminal;
  final inner = terminal.onPrivateOSC;
  terminal.onPrivateOSC = (code, args) {
    inner?.call(code, args);
    if (code == '133' && args.isNotEmpty && args.first == 'A') {
      if (!ready.isCompleted) ready.complete();
    }
  };
  return ready.future.timeout(
    const Duration(seconds: 60),
    onTimeout: () => fail('the pane never emitted a prompt-start marker'),
  );
}

/// The absolute path of [shell] inside [distro], or null when it is not there.
String? _pathIn(String distro, String shell) {
  final result = Process.runSync('wsl.exe', [
    '-d',
    distro,
    '--exec',
    '/bin/sh',
    '-c',
    'command -v $shell',
  ], stdoutEncoding: systemEncoding);
  final path = '${result.stdout}'.trim();
  return result.exitCode == 0 && path.startsWith('/') ? path : null;
}

/// The distribution `wsl.exe` opens by default, or null when there is none.
String? _defaultDistro() {
  try {
    final result = Process.runSync('wsl.exe', [
      '-e',
      'sh',
      '-c',
      r'printf %s "$WSL_DISTRO_NAME"',
    ]);
    final name = '${result.stdout}'.trim();
    return name.isEmpty ? null : name;
  } on ProcessException {
    return null;
  }
}

/// Why this suite cannot run here, or null when it can.
String? _probe() {
  if (!Platform.isWindows) return 'A WSL pane is a Windows ConPTY.';
  if (_defaultDistro() == null) return 'No WSL distribution answered.';
  for (final path in [
    r'build\windows\x64\runner\Debug\flutter_pty.dll',
    r'build\windows\x64\runner\Release\flutter_pty.dll',
    r'C:\Program Files\Karmashala\flutter_pty.dll',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      DynamicLibrary.open(file.absolute.path);
      return null;
    } on ArgumentError {
      continue;
    }
  }
  return 'No flutter_pty.dll to spawn a ConPTY with; build the app first.';
}
