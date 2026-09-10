import 'dart:io';

import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Manual diagnostic — NOT part of `flutter test`'s default run, and not a
/// test. It lived in `integration_test/` until Loop 63; being there overstated
/// what is actually covered.
///
/// Run it explicitly, on a Windows desktop device, with WSL plus a logged-in
/// `codex` and/or `claude` inside the distro:
///
///   flutter test -d windows tool/verification/resume_conflict_probe.dart
///
/// EXPERIMENT: does resuming a conversation that another process is already
/// holding work, and how does each agent refuse?
///
/// **It answers that question by printing, not by asserting.** The codex case
/// asserts only that pane A produced a rollout file — nothing about the second
/// resume, which is the behaviour the name promises. The claude case asserts
/// nothing at all. Both lean on fixed 15–35 second sleeps, on installed CLIs
/// and live accounts, and on whatever mutable session state the host already
/// has. Read the `TRACE`/`SCREEN` dumps; do not read a pass as evidence.
///
/// See `tool/verification/README.md` for what a real regression test of this
/// behaviour would need.
/// Codex's own selections, in its own vocabulary — the probe drives Codex and
/// nothing else, so there is no shared mode left to name here.
const _codexReadOnly = PermissionSelection({
  'sandbox': 'read-only',
  'approval': 'on-request',
});
const _codexWorkspace = PermissionSelection({
  'sandbox': 'workspace-write',
  'approval': 'on-request',
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('cg_resume_'));
  tearDown(() {
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  });

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

  bool inWsl(String distro, String exe) {
    try {
      return Process.runSync('wsl.exe', [
            '-d',
            distro,
            '--',
            'bash',
            '-lc',
            'command -v $exe',
          ]).exitCode ==
          0;
    } catch (_) {
      return false;
    }
  }

  TerminalInstance start(AgentPaneLaunch launch, String label) {
    final instance = createPtyTerminalInstance(
      id: label,
      profile: TerminalProfile.powerShell,
      workingDirectory: launch.workingDirectory,
      agentLaunch: launch,
    );
    instance.terminal.resize(120, 30);
    // ignore: avoid_print
    print(
      'TRACE launch $label: ${launch.executable} ${launch.arguments} '
      'wsl=${launch.wslDistribution} cwd=${launch.workingDirectory}',
    );
    return instance;
  }

  Future<void> watch(
    TerminalInstance instance,
    String agentId,
    String label, {
    required bool Function(List<AgentActivityStatus> seen) done,
    void Function()? onApproval,
    Duration within = const Duration(minutes: 3),
  }) async {
    final descriptor = AgentRegistry.builtIn.byId(agentId)!;
    const source = TerminalGridStatusSource();
    final seen = <AgentActivityStatus>[];
    final started = DateTime.now();
    var answered = false;
    while (DateTime.now().difference(started) < within) {
      final report = source.read(
        descriptor,
        terminalTailLines(instance.terminal, lines: descriptor.grid.scanLines),
        DateTime.now(),
        sessionId: 'probe',
      );
      final status = report?.status ?? AgentActivityStatus.unknown;
      if (seen.isEmpty || seen.last != status) {
        seen.add(status);
        // ignore: avoid_print
        print(
          'TRACE $label '
          '+${DateTime.now().difference(started).inMilliseconds}ms '
          '${status.name}',
        );
      }
      if (status == AgentActivityStatus.awaitingApproval &&
          onApproval != null &&
          !answered) {
        answered = true;
        onApproval();
      }
      if (done(seen)) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print('TRACE $label gave up: $seen');
  }

  void dump(TerminalInstance instance, String label) {
    // ignore: avoid_print
    print('=== SCREEN $label ===');
    for (final line in terminalTailLines(instance.terminal, lines: 30)) {
      // ignore: avoid_print
      print('| $line');
    }
    // ignore: avoid_print
    print('=== END $label (liveness=${instance.liveness.value.name}) ===');
  }

  testWidgets(
    'EXPERIMENT codex WSL: second resume of a held thread',
    (_) async {
      final distro = firstWslDistro()!;
      Set<String> rollouts() {
        final out = Process.runSync('wsl.exe', [
          '-d',
          distro,
          '--',
          'bash',
          '-lc',
          r'find ~/.codex/sessions -name "rollout-*.jsonl" 2>/dev/null',
        ]).stdout.toString();
        return out
            .split(RegExp(r'[\r\n]+'))
            .where((l) => l.trim().isNotEmpty)
            .toSet();
      }

      final before = rollouts();

      final a = start(
        AgentPaneLaunch(
          agentId: AgentIds.codex,
          executable: 'codex',
          arguments: agentPaneArguments(
            AgentRegistry.builtIn.byId(AgentIds.codex),
            _codexReadOnly,
            prompt: 'Reply with exactly the word PONG and nothing else.',
          ),
          workingDirectory: '/tmp',
          wslDistribution: distro,
          sessionId: 'sess-a',
        ),
        'codex-A',
      );
      addTearDown(a.dispose);
      await watch(
        a,
        AgentIds.codex,
        'codex-A',
        onApproval: () => a.terminal.textInput('\r'),
        done: (seen) => seen.contains(AgentActivityStatus.working),
        within: const Duration(minutes: 2),
      );
      await Future<void>.delayed(const Duration(seconds: 15));
      dump(a, 'codex-A');

      final added = rollouts().difference(before);
      // ignore: avoid_print
      print('TRACE new rollouts: $added');
      expect(added, isNotEmpty, reason: 'no rollout appeared for pane A');
      final id = RegExp(
        r'rollout-[\dT:-]+-([0-9a-f-]{36})\.jsonl',
      ).firstMatch(added.first.split('/').last)!.group(1)!;
      // ignore: avoid_print
      print('TRACE thread id: $id');

      final b = start(
        AgentPaneLaunch(
          agentId: AgentIds.codex,
          executable: 'codex',
          arguments: agentPaneArguments(
            AgentRegistry.builtIn.byId(AgentIds.codex),
            _codexReadOnly,
            resumeSessionId: id,
          ),
          workingDirectory: '/tmp',
          wslDistribution: distro,
          sessionId: 'sess-b',
        ),
        'codex-B',
      );
      addTearDown(b.dispose);
      // Codex 0.145 opens on an "Update available" chooser; skip it so the
      // resume itself is what we observe.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final screen = terminalTailLines(b.terminal, lines: 30).join('\n');
        if (screen.contains('Update available')) {
          b.terminal.textInput('2');
          await Future<void>.delayed(const Duration(milliseconds: 300));
          b.terminal.textInput('\r');
          break;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 30));
      dump(b, 'codex-B');
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: firstWslDistro() == null || !inWsl(firstWslDistro()!, 'codex'),
  );

  testWidgets(
    'EXPERIMENT claude: second resume of a live session',
    (_) async {
      final distro = firstWslDistro()!;
      const id = 'b1f5c2a4-3d61-4e28-9a70-5c8e1d2f7a93';
      final a = start(
        AgentPaneLaunch(
          agentId: AgentIds.claudeCode,
          executable: 'claude',
          arguments: agentPaneArguments(
            AgentRegistry.builtIn.byId(AgentIds.claudeCode),
            _codexWorkspace,
            sessionId: id,
            prompt: 'Reply with exactly the word PONG and nothing else.',
          ),
          workingDirectory: '/tmp',
          wslDistribution: distro,
          sessionId: 'sess-a',
        ),
        'claude-A',
      );
      addTearDown(a.dispose);
      await watch(
        a,
        AgentIds.claudeCode,
        'claude-A',
        onApproval: () {
          a.terminal.textInput('[B');
          a.terminal.textInput('\r');
        },
        done: (seen) =>
            seen.contains(AgentActivityStatus.working) &&
            seen.last == AgentActivityStatus.idle,
      );
      dump(a, 'claude-A');

      final b = start(
        AgentPaneLaunch(
          agentId: AgentIds.claudeCode,
          executable: 'claude',
          arguments: agentPaneArguments(
            AgentRegistry.builtIn.byId(AgentIds.claudeCode),
            _codexWorkspace,
            resumeSessionId: id,
          ),
          workingDirectory: '/tmp',
          wslDistribution: distro,
          sessionId: 'sess-b',
        ),
        'claude-B',
      );
      addTearDown(b.dispose);
      await Future<void>.delayed(const Duration(seconds: 35));
      dump(b, 'claude-B');
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: firstWslDistro() == null || !inWsl(firstWslDistro()!, 'claude'),
  );
}
