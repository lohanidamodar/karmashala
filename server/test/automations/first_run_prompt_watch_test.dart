import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/first_run_prompt_watch.dart';
import 'package:test/test.dart';

/// The watch on an unattended launch, at the folder-trust menus Codex 0.160
/// and Antigravity draw (real captures). It only reads: an automation's run
/// is stopped with the reason, and any other session — one an agent or a
/// person started — is left waiting for the person, never typed into nor
/// killed.
void main() {
  late FakePtyLauncher launcher;
  late SessionRegistry registry;

  setUp(() {
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
  });

  tearDown(() async {
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
  });

  List<int> fixture(String name) => utf8.encode(
    File('../app/test/features/agents/fixtures/$name.raw').readAsStringSync(),
  );

  for (final (agentId, name, fixtureName) in [
    (AgentIds.codex, 'Codex CLI', 'codex-trust-prompt-0.160'),
    (AgentIds.antigravity, 'Antigravity', 'antigravity-trust-prompt'),
  ]) {
    test('$name at folder trust: an automation is stopped with the reason, '
        'any other session waits for the person', () async {
      final automationRuns = {'auto'};
      final blocked = <String, String>{};
      final watch = FirstRunPromptWatch(
        registry: registry,
        interval: const Duration(milliseconds: 5),
        // The daemon's rule: only a session an automation run owns is acted
        // on; false keeps the others as they are.
        onBlocked: (sessionId, reason) {
          blocked[sessionId] = reason;
          return automationRuns.contains(sessionId);
        },
      );
      addTearDown(watch.close);

      for (final id in ['auto', 'agent-started']) {
        registry.open(
          'karmashala_$id',
          const PtySpawnRequest(argv: ['agent'], columns: 120, rows: 30),
        );
        launcher.handles.last.emit(fixture(fixtureName));
        watch.follow(sessionId: id, agentId: agentId, directory: '/src/r1');
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        blocked['auto'],
        startsWith(
          '$name is asking whether to trust /src/r1, and nobody is there to '
          'answer.',
        ),
      );
      expect(watch.watching, ['agent-started']);
      for (final handle in launcher.handles) {
        expect(handle.writes, isEmpty);
        expect(handle.signals, isEmpty);
      }
      expect(
        registry.find('karmashala_agent-started')!.lifecycle.hasEnded,
        isFalse,
      );
    });
  }
}
