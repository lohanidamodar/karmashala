import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';

import 'fake_host_access.dart';

/// OSC 133 shell integration in a pane on the server's terminal: the server
/// decides whether its launch carries the bootstrap (slice 5a — only a
/// Windows server injects one) and says so in `terminals.open`'s answer; the
/// pane records blocks off the markers — plus what only a server session has,
/// a reattach whose replay was produced while no pane watched it.
///
/// The fake machine feeds the bytes a PowerShell with the bootstrap would
/// write; what a real one writes through the host was measured on Windows
/// 10.0.26200 (2026-09-22) and is in `server/test/pty/conpty_live_test`.
Future<void> settle() async {
  // PtyOutputCoalescer's 16 ms watchdog, with no frame pump in a plain test.
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

const _a = '\x1b]133;A\x07';
const _b = '\x1b]133;B\x07';
const _c = '\x1b]133;C\x07';
String _d(int code) => '\x1b]133;D;$code\x07';
const _prompt = '${_a}PS C:\\work> $_b';

void main() {
  // The replay's end mark can land behind a queued chunk, which schedules a
  // frame; a plain test has no binding to ask for one.
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A pane whose `terminals.open` answers [shellIntegration] — what a
  /// Windows server says for a PowerShell launched with the setting on — and
  /// never for an agent, which runs no shell.
  HostTerminalInstance paneOn(
    PaneAccess access, {
    bool shellIntegration = true,
    AgentPaneLaunch? agentLaunch,
  }) {
    final sessionId = agentLaunch == null
        ? 'karmashala_local_p1'
        : 'karmashala_${agentLaunch.sessionId}';
    final pane = HostTerminalInstance(
      id: 'p1',
      title: 'Windows PowerShell',
      profileId: 'powershell',
      access: access,
      sessionId: sessionId,
      workingDirectory: r'C:\work',
      agentLaunch: agentLaunch,
      opener: (columns, rows) async {
        final adopted = access.liveSessions.contains(sessionId);
        access.liveSessions.add(sessionId);
        return (
          sessionId: sessionId,
          adopted: adopted,
          shellIntegration: shellIntegration && agentLaunch == null,
        );
      },
    );
    pane.terminal.resize(120, 40);
    addTearDown(pane.dispose);
    return pane;
  }

  /// A pane reattaching to a running session whose ring holds [replay].
  Future<(HostTerminalInstance, ScriptedHostChannel)> reattached(
    String replay, {
    String liveInSameChunk = '',
  }) async {
    final access = PaneAccess(readyDeployment())
      ..liveSessions.add('karmashala_local_p1')
      ..resumedTotalBytes = replay.length;
    final pane = paneOn(access);
    await settle();
    final channel = access.channels.single;
    expect(channel.all<AttachMessage>(), hasLength(1));
    channel.pushOutput(0, replay + liveInSameChunk);
    await settle();
    return (pane, channel);
  }

  /// `terminal_run`'s own sequence: watch, type, and wait on the markers.
  Future<CommandRunOutcome> run(
    HostTerminalInstance pane,
    ScriptedHostChannel channel,
    int offset,
    String output,
  ) async {
    final watch = CommandRunWatch.begin(pane);
    expect(watch, isNotNull, reason: 'the pane has a recorder');
    pane.terminal.textInput('build\r');
    channel.pushOutput(offset, output);
    return watch!.awaitFinish(const Duration(seconds: 5));
  }

  test(
    'a host pane launched with integration records blocks and exit codes',
    () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      final channel = access.channels.single;

      expect(channel.all<OpenMessage>(), isEmpty, reason: "the server's job");
      expect(pane.commandBlocks, isNotNull);

      channel.pushOutput(0, _prompt);
      await settle();
      final outcome = await run(
        pane,
        channel,
        _prompt.length,
        '${_c}compiled 12 files\r\n${_d(3)}$_prompt',
      );

      expect(outcome.finished, isTrue);
      expect(outcome.exitCode, 3);
      expect(outcome.output.lines, contains('compiled 12 files'));
      expect(outcome.duration, isNotNull);
      expect(pane.commandBlocks!.tracker.blocks.single.exitCode, 3);
    },
  );

  test('with no bootstrap in the launch, the pane has no recorder', () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(access, shellIntegration: false);
    await settle();
    expect(pane.commandBlocks, isNull);
  });

  test('an agent pane is never integrated', () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(
      access,
      agentLaunch: const AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        sessionId: 'sess-1',
      ),
    );
    await settle();
    expect(pane.commandBlocks, isNull);
  });

  group('reattaching to a running session', () {
    test('a replay that starts mid-command yields an unknown-start block, and '
        'the next command is watched correctly', () async {
      const replay = 'linking the last 40 of 300 objects\r\n';
      // The end of that command, the next prompt, in the same frame as the
      // tail of the replay — the split has to happen inside one chunk.
      final (pane, channel) = await reattached(
        replay,
        liveInSameChunk: '${_d(2)}$_prompt',
      );
      final tracker = pane.commandBlocks!.tracker;

      final old = tracker.blocks.single;
      expect(old.resumed, isTrue);
      expect(
        old.exitCode,
        2,
        reason: 'the D arrived live, so its code is real',
      );
      expect(old.startedAt, isNull, reason: 'its start was never seen');
      expect(old.duration, isNull);

      final outcome = await run(
        pane,
        channel,
        replay.length + '${_d(2)}$_prompt'.length,
        '${_c}ok\r\n${_d(0)}$_prompt',
      );
      expect(outcome.finished, isTrue);
      expect(outcome.exitCode, 0);
      expect(outcome.output.lines, ['ok']);
      expect(tracker.blocks, hasLength(2));
    });

    test('a command still running when the pane came back is not mistaken for '
        'the one typed next', () async {
      const replay = '${_prompt}npm test$_c running 400 tests\r\n';
      final (pane, channel) = await reattached(replay);
      final tracker = pane.commandBlocks!.tracker;
      expect(tracker.pending?.resumed, isTrue);
      expect(tracker.pending?.hasStarted, isTrue);

      // Its end (exit 1) arrives after the watch began; ours ends with 0.
      final outcome = await run(
        pane,
        channel,
        replay.length,
        '1 failed\r\n${_d(1)}$_prompt${_c}ok\r\n${_d(0)}$_prompt',
      );
      expect(outcome.exitCode, 0);
      expect(outcome.output.lines, ['ok']);
      expect(tracker.blocks.map((b) => b.exitCode), [1, 0]);
      expect(tracker.blocks.first.resumed, isTrue);
    });

    test(
      'finished commands in the replay make no blocks, and nothing is doubled',
      () async {
        final replay =
            '${_prompt}dir$_c a.txt\r\n${_d(0)}'
            '${_prompt}type b$_c no such file\r\n${_d(1)}'
            '$_prompt';
        final (pane, channel) = await reattached(replay);
        final tracker = pane.commandBlocks!.tracker;

        expect(
          tracker.blocks,
          isEmpty,
          reason: 'their times would be the reattach, not when they ran',
        );
        expect(screenOf(pane), contains('no such file'));
        final waiting = tracker.pending!;
        expect(waiting.resumed, isFalse, reason: 'a prompt, not a command');
        expect(waiting.promptAt, isNull);

        final outcome = await run(
          pane,
          channel,
          replay.length,
          '${_c}built\r\n${_d(0)}$_prompt',
        );
        expect(outcome.exitCode, 0);
        expect(outcome.duration, isNotNull);
        expect(tracker.blocks.single.exitCode, 0);
        expect(tracker.blocks.single.resumed, isFalse);
      },
    );

    test(
      'a session that has printed nothing still resumes live tracking',
      () async {
        final (pane, channel) = await reattached('');
        final tracker = pane.commandBlocks!.tracker;
        expect(pane.commandBlocks!.isReplaying, isFalse);

        channel.pushOutput(0, _prompt);
        await settle();
        expect(tracker.pending, isNotNull);
        final outcome = await run(
          pane,
          channel,
          _prompt.length,
          '${_c}x\r\n${_d(4)}$_prompt',
        );
        expect(outcome.exitCode, 4);
      },
    );
  });
}

String screenOf(HostTerminalInstance pane) =>
    terminalTailLines(pane.terminal, lines: 200).join('\n');
