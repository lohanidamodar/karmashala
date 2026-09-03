import 'dart:io';

import 'package:karmashala/src/features/agents/data/terminal_grid_status_source.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Drives **real agent CLIs in real ConPTYs** through the app's own launch path.
///
/// `GenericAgentAdapter` shipped in Loop 30 having never met a real CLI, and the
/// grid status source is a claim about text an agent draws on a screen. Both are
/// the kind of thing a unit suite agrees with and reality does not, so this
/// starts the actual binaries and reads the actual buffer.
///
/// Skipped automatically when the agent is not installed, so the suite stays
/// green on a machine without it — a skipped test says so, which is the point.
/// The selections these tests launch under, in each CLI's own words.
///
/// Codex's two axes together are what the old shared `ask` and `acceptEdits`
/// both meant for it; Claude's `manual` is its prompting mode.
const _codexWorkspaceWrite = PermissionSelection({
  'sandbox': 'workspace-write',
  'approval': 'on-request',
});
const _claudeManual = PermissionSelection({'mode': 'manual'});
const _claudeAcceptEdits = PermissionSelection({'mode': 'acceptEdits'});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('cg_agent_'));
  tearDown(() {
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Whether [executable] resolves on the Windows host.
  bool onHostPath(String executable) {
    try {
      return Process.runSync('where.exe', [executable]).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Whether [executable] resolves inside WSL distribution [distro].
  bool inWsl(String distro, String executable) {
    try {
      return Process.runSync('wsl.exe', [
            '-d',
            distro,
            '--',
            'bash',
            '-lc',
            'command -v $executable',
          ]).exitCode ==
          0;
    } catch (_) {
      return false;
    }
  }

  String? firstWslDistro() {
    try {
      final out = Process.runSync('wsl.exe', [
        '-l',
        '-q',
      ], stdoutEncoding: null).stdout;
      final text = String.fromCharCodes(
        (out as List<int>).where((b) => b != 0),
      );
      for (final line in text.split(RegExp(r'[\r\n]+'))) {
        if (line.trim().isNotEmpty) return line.trim();
      }
    } catch (_) {}
    return null;
  }

  /// Polls [instance]'s screen and records every status change until [done]
  /// accepts the trace, answering an approval modal once if [onApproval] is
  /// given.
  ///
  /// The trace, not a single reading, is what the assertions look at: "it is
  /// idle" is true of an agent that has not started yet and of one that has
  /// finished, and only the order between them says which.
  Future<List<AgentActivityStatus>> watchTrace(
    TerminalInstance instance,
    String agentId, {
    required bool Function(List<AgentActivityStatus> seen) done,
    void Function()? onApproval,
    Duration within = const Duration(minutes: 3),
  }) async {
    final descriptor = AgentRegistry.builtIn.byId(agentId)!;
    const source = TerminalGridStatusSource();
    final seen = <AgentActivityStatus>[];
    final started = DateTime.now();
    final deadline = started.add(within);
    var answered = false;

    while (DateTime.now().isBefore(deadline)) {
      final report = source.read(
        descriptor,
        terminalTailLines(instance.terminal, lines: descriptor.grid.scanLines),
        DateTime.now(),
        sessionId: 'probe',
      );
      final status = report?.status ?? AgentActivityStatus.unknown;
      if (seen.isEmpty || seen.last != status) {
        seen.add(status);
        final at = DateTime.now().difference(started).inMilliseconds;
        // Printed so the loop report can quote real transitions with real
        // timings rather than assert that some happened.
        // ignore: avoid_print
        print(
          'TRACE $agentId +${at}ms ${status.name}'
          '${report?.detail == null ? '' : ' <- "${report!.detail}"'}',
        );
      }
      if (status == AgentActivityStatus.awaitingApproval &&
          onApproval != null &&
          !answered) {
        answered = true;
        onApproval();
      }
      if (done(seen)) return seen;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print('TRACE $agentId gave up after ${within.inSeconds}s: $seen');
    return seen;
  }

  /// True once the agent has been observed working and has settled back to idle
  /// — a finished turn, which no single reading can express.
  bool workedThenIdled(List<AgentActivityStatus> seen) =>
      seen.contains(AgentActivityStatus.working) &&
      seen.last == AgentActivityStatus.idle;

  /// The whole of the app's launch path for one agent, minus the database.
  ///
  /// The terminal is resized because a full-screen TUI draws for the size it is
  /// told about, and nothing here lays out a widget to tell it. Without this the
  /// pane renders blank and every assertion below fails for a reason that has
  /// nothing to do with the agent.
  TerminalInstance start(AgentPaneLaunch launch) {
    final instance = createPtyTerminalInstance(
      id: 'pane',
      profile: TerminalProfile.powerShell,
      workingDirectory: launch.workingDirectory,
      agentLaunch: launch,
    );
    instance.terminal.resize(120, 30);
    // ignore: avoid_print
    print(
      'TRACE launch ${launch.agentId}: ${launch.executable} '
      '${launch.arguments} wsl=${launch.wslDistribution} '
      'cwd=${launch.workingDirectory}',
    );
    return instance;
  }

  /// Answers a modal the way a user would, through the same path
  /// `SessionLauncher.sendTo` writes on.
  void answer(TerminalInstance instance, String keys) =>
      instance.terminal.textInput(keys);

  group('an approval answered the way the transcript control answers it', () {
    testWidgets(
      'the prompt is quoted from the screen and its declared key clears it',
      (_) async {
        final descriptor = AgentRegistry.builtIn.byId(AgentIds.codex)!;
        // The mode the user picked reaches the process. Writing-in-the-workspace
        // is the mapping a real codex rejected until this loop, so launching
        // under it is itself the regression test: a bad flag never reaches a
        // trust modal, it exits.
        final arguments = agentPaneArguments(
          descriptor,
          _codexWorkspaceWrite,
          prompt: 'Reply with exactly the word PONG and nothing else.',
        );
        expect(
          arguments,
          containsAllInOrder([
            '--sandbox',
            'workspace-write',
            '--ask-for-approval',
            'on-request',
          ]),
        );

        final instance = start(
          AgentPaneLaunch(
            agentId: AgentIds.codex,
            executable: 'codex.exe',
            arguments: arguments,
            workingDirectory: work.path,
            sessionId: 'sess-codex-approval',
          ),
        );
        addTearDown(instance.dispose);

        // Poll the way the app does, and keep the report — not just its status
        // — so the evidence the card would render can be asserted on.
        const source = TerminalGridStatusSource();
        AgentStatusReport? pending;
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (DateTime.now().isBefore(deadline)) {
          final report = source.read(
            descriptor,
            terminalTailLines(
              instance.terminal,
              lines: descriptor.grid.scanLines,
            ),
            DateTime.now(),
            sessionId: 'probe',
          );
          if (report?.status == AgentActivityStatus.awaitingApproval) {
            pending = report;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        final screen = terminalTailLines(
          instance.terminal,
          lines: 24,
        ).join('\n');
        expect(
          pending,
          isNotNull,
          reason: 'codex never blocked on its trust modal. Screen:\n$screen',
        );

        // The card would render exactly this. It must be the agent's own words
        // and not the matcher that fired.
        // ignore: avoid_print
        print('TRACE evidence:\n${pending!.evidence.join("\n")}');
        expect(pending.evidence, isNotEmpty);
        expect(pending.detail, 'Press enter to continue');
        expect(
          pending.evidence.join('\n'),
          contains('Press enter to continue'),
          reason: 'the quoted rows must include the prompt itself',
        );
        expect(
          pending.evidence.any((l) => l.trim().isEmpty),
          isFalse,
          reason: 'blank rows are dropped',
        );

        // Answer with the key the *descriptor declares*, which is the value the
        // transcript card passes to `answerPrompt` — not a literal typed here.
        final approve = descriptor.approval.approve!;
        expect(approve.keys, '\r');
        expect(descriptor.approval.deny, isNull);
        answer(instance, approve.keys);

        final after = await watchTrace(
          instance,
          AgentIds.codex,
          done: (seen) => seen.contains(AgentActivityStatus.working),
          within: const Duration(minutes: 2),
        );
        expect(
          after,
          contains(AgentActivityStatus.working),
          reason:
              'the declared key did not clear the modal. Screen:\n'
              '${terminalTailLines(instance.terminal, lines: 24).join("\n")}',
        );
      },
      timeout: const Timeout(Duration(minutes: 8)),
      skip: !onHostPath('codex.exe'),
    );
  });

  group('Codex, natively on Windows', () {
    testWidgets(
      'runs in a PTY, and its status is read off its own screen',
      (_) async {
        final launch = AgentPaneLaunch(
          agentId: AgentIds.codex,
          executable: 'codex.exe',
          arguments: agentPaneArguments(
            AgentRegistry.builtIn.byId(AgentIds.codex),
            _codexWorkspaceWrite,
            prompt: 'Reply with exactly the word PONG and nothing else.',
          ),
          workingDirectory: work.path,
          sessionId: 'sess-codex',
        );
        final instance = start(launch);
        addTearDown(instance.dispose);

        expect(instance.liveness.value, PaneLiveness.live);
        expect(instance.agentLaunch, isNotNull);

        // A brand-new directory, so Codex opens on its trust modal — the state
        // only this source can see. A transcript cannot express "a dialog is
        // waiting for you", which is why Loop 28 had to call it hook-only.
        // Answering it also proves keystrokes reach the agent through the pane.
        final seen = await watchTrace(
          instance,
          AgentIds.codex,
          onApproval: () => answer(instance, '\r'),
          done: (seen) => seen.contains(AgentActivityStatus.working),
          within: const Duration(minutes: 2),
        );
        final screen = terminalTailLines(
          instance.terminal,
          lines: 20,
        ).join('\n');
        expect(
          seen,
          contains(AgentActivityStatus.awaitingApproval),
          reason: 'never blocked on the trust modal. Screen:\n$screen',
        );
        expect(
          seen,
          contains(AgentActivityStatus.working),
          reason: 'never started working. Screen:\n$screen',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
      skip: !onHostPath('codex.exe'),
    );
  });

  group('the safe mode reaches a real interactive agent', () {
    testWidgets(
      'Claude Code starts under the flag `ask` now passes',
      (_) async {
        final distro = firstWslDistro()!;
        final descriptor = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
        final arguments = agentPaneArguments(
          descriptor,
          _claudeManual,
          prompt: 'Reply with exactly the word PONG and nothing else.',
        );
        // `ask` used to add nothing here, which silently left a Pro/Max/Team
        // session in `auto`. It names the prompting mode now, and this proves
        // the *interactive* CLI accepts it — `--permission-mode manual -p ...`
        // only proves print mode does, and flags have differed between the two.
        expect(arguments, containsAllInOrder(['--permission-mode', 'manual']));

        final instance = start(
          AgentPaneLaunch(
            agentId: AgentIds.claudeCode,
            executable: 'claude',
            arguments: arguments,
            workingDirectory: '/tmp',
            wslDistribution: distro,
            sessionId: 'sess-claude-ask',
          ),
        );
        addTearDown(instance.dispose);

        final seen = await watchTrace(
          instance,
          AgentIds.claudeCode,
          done: workedThenIdled,
          within: const Duration(minutes: 3),
        );
        // A rejected flag never draws a TUI at all, so reaching any of Claude's
        // own footers is the assertion that matters.
        expect(
          seen.where((s) => s != AgentActivityStatus.unknown),
          isNotEmpty,
          reason:
              'claude never drew its own UI, which is what a rejected flag '
              'looks like. Screen:\n'
              '${terminalTailLines(instance.terminal, lines: 24).join("\n")}',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
      skip:
          firstWslDistro() == null || !inWsl(firstWslDistro() ?? '', 'claude'),
    );
  });

  group('Claude Code, through WSL', () {
    testWidgets(
      'runs in a PTY and its status goes working then idle',
      (_) async {
        final distro = firstWslDistro()!;
        final launch = AgentPaneLaunch(
          agentId: AgentIds.claudeCode,
          executable: 'claude',
          arguments: agentPaneArguments(
            AgentRegistry.builtIn.byId(AgentIds.claudeCode),
            _claudeAcceptEdits,
            prompt: 'Reply with exactly the word PONG and nothing else.',
          ),
          // A Linux-side path: the launch is wrapped in `wsl.exe --cd`, and the
          // host process is deliberately given no working directory it could
          // not resolve.
          workingDirectory: '/tmp',
          wslDistribution: distro,
          sessionId: 'sess-claude',
        );
        final instance = start(launch);
        addTearDown(instance.dispose);

        expect(instance.liveness.value, PaneLiveness.live);

        // Claude's workspace-trust modal defaults to "No, exit", so the answer
        // is Down then Enter. It does not appear for a directory already
        // trusted, which is why the trace, not a fixed sequence, is asserted.
        final seen = await watchTrace(
          instance,
          AgentIds.claudeCode,
          onApproval: () {
            answer(instance, '\u001b[B');
            answer(instance, '\r');
          },
          // The agent's own answer has to be on screen too, so this cannot
          // pass on a startup spinner that happened to look like a turn.
          done: (seen) =>
              workedThenIdled(seen) &&
              terminalTailLines(
                instance.terminal,
                lines: 30,
              ).join('\n').contains('PONG'),
        );
        final screen = terminalTailLines(
          instance.terminal,
          lines: 20,
        ).join('\n');

        expect(
          seen,
          contains(AgentActivityStatus.working),
          reason: 'never saw working. Screen:\n$screen',
        );
        expect(
          seen.last,
          AgentActivityStatus.idle,
          reason: 'never settled to idle. Screen:\n$screen',
        );
        expect(
          screen,
          contains('PONG'),
          reason: "the agent's own output should be in the pane",
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: firstWslDistro() == null || !inWsl(firstWslDistro()!, 'claude'),
    );
  });
}
