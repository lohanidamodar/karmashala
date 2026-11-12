@Tags(['live'])
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/domain/uuid.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Whether a ~4 KB multi-line message typed by the production typist
/// (`SessionToolSet.typistOver`) reaches the installed Claude Code as one
/// message — counted as `type: user` records in its transcript. The first runs
/// type as soon as the composer is drawn, while start-up may still be busy,
/// with the opening's lead-in; the rest wait for a still screen. Each run is
/// one tiny turn. Skips without `claude`.
void main() {
  final home = Platform.environment['USERPROFILE'] ?? '';
  final claude = File(p.join(home, '.local', 'bin', 'claude.exe'));
  final agent = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final runs = int.tryParse(
    Platform.environment['KARMASHALA_TYPIST_RUNS'] ?? '',
  );

  for (var run = 0; run < (runs ?? 5); run++) {
    final early = run < 3;
    test(
      'run $run: a 4 KB message typed ${early ? 'at start-up' : 'once settled'} '
      'arrives as one message',
      () async {
        final work = Directory.systemTemp.createTempSync('ks-typist-live');
        addTearDown(() => _deleteLater(work));
        final t0 = DateTime.now().toUtc();
        final database = AppDatabase.memory()
          ..execute('PRAGMA foreign_keys = OFF;')
          ..execute(
            'INSERT INTO agent_installations (id, agent_kind, environment_id, '
            'executable_path, created_at, executable_by_user) '
            'VALUES (?, ?, ?, ?, ?, ?);',
            ['a1', agent.id, 'local', claude.path, '$t0', 1],
          );
        SessionDao(database).insert(
          Session(
            id: 's1',
            repositoryId: 'r1',
            agentInstallationId: 'a1',
            title: 'typist',
            useWorktree: false,
            status: SessionStatus.running,
            createdAt: t0,
          ),
        );
        final registry = SessionRegistry(launcher: ConPtyLauncher());
        final status = DaemonAgentStatus(
          registry: registry,
          database: database,
          publish: (_, _) {},
        )..start();
        final prompts = DaemonPromptAnswers(status: status, database: database);
        final typist = SessionToolSet.typistOver(prompts);

        final conversation = newUuid();
        final session = registry.open(
          'karmashala_s1',
          PtySpawnRequest(
            argv: [claude.path, '--session-id', conversation],
            workingDirectory: work.path,
            // This test may itself run under Claude Code.
            removedEnvironment: {
              for (final name in Platform.environment.keys)
                if (name.startsWith('CLAUDE')) name,
            },
            columns: 120,
            rows: 30,
          ),
        );
        addTearDown(() async {
          await session.terminate();
          await status.close();
          await registry.shutdown();
          database.close();
        });

        String screen() => session.tailText(30).join('\n');
        void press(String keys) => session.typeAsHost(utf8.encode(keys));
        Future<bool> until(bool Function(String) test, Duration d) async {
          final end = DateTime.now().add(d);
          while (!test(screen())) {
            if (DateTime.now().isAfter(end)) return false;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return true;
        }

        // A new folder asks first, and its default is "No, exit".
        bool trust(String s) => s.contains('Yes, I trust this folder');
        bool composer(String s) =>
            s.contains('for shortcuts') || s.contains('shift+tab to cycle');
        await until(
          (s) => trust(s) || composer(s),
          const Duration(seconds: 30),
        );
        // Keys pressed the moment it is drawn can be lost, so each is read back.
        for (var tries = 0; tries < 10 && trust(screen()); tries++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          press(screen().contains('❯ Yes, I trust') ? '\r' : '\x1b[B');
        }
        expect(
          await until(
            (s) => !trust(s) && composer(s),
            const Duration(seconds: 30),
          ),
          isTrue,
          reason: screen(),
        );
        if (!early) await Future<void>.delayed(const Duration(seconds: 5));

        final nonce = newUuid();
        final lines = [
          'Reply with the single word OK.',
          for (var i = 0; i < 70; i++)
            'Filler line $i: nothing here needs doing, it only pads the text.',
          'The last line carries the marker $nonce.',
        ];
        final message = lines.join('\n');
        Object outcome;
        try {
          outcome = await typist.deliver(
            's1',
            message,
            leadIn: early ? agent.terminal.typedOpeningLeadIn : null,
          );
        } on Object catch (error) {
          outcome = error;
        }

        final transcript = File(
          p.join(
            home,
            '.claude',
            'projects',
            work.path.replaceAll(RegExp('[^A-Za-z0-9]'), '-'),
            '$conversation.jsonl',
          ),
        );
        addTearDown(() => _deleteLater(transcript.parent));
        List<String> users() => [
          if (transcript.existsSync())
            for (final line in transcript.readAsLinesSync()) ?_userText(line),
        ];
        bool answered() =>
            transcript.existsSync() &&
            transcript.readAsStringSync().contains('"type":"assistant"');
        final end = DateTime.now().add(const Duration(seconds: 60));
        while (!answered() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        // A split's tail would follow as its own message.
        await Future<void>.delayed(const Duration(seconds: 4));
        final recorded = users();
        // ignore: avoid_print
        print(
          'run $run (${early ? 'start-up' : 'settled'}): delivery $outcome; '
          '${message.length} chars typed; ${recorded.length} user message(s) '
          '${[for (final r in recorded) r.length]} chars; whole: '
          '${recorded.length == 1 && recorded.single.contains(nonce) && recorded.single.contains('single word OK')}',
        );
        printOnFailure(screen());
        expect(recorded, hasLength(1), reason: '$recorded');
        expect(recorded.single, contains('single word OK'));
        expect(recorded.single, contains('Filler line 69'));
        expect(recorded.single, contains(nonce));
      },
      skip: claude.existsSync() ? false : 'no claude at ${claude.path}',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

/// The words of a transcript line that is a message the user typed: not a
/// tool result, not the CLI's own meta rows.
String? _userText(String line) {
  try {
    final row = jsonDecode(line) as Map<String, Object?>;
    if (row['type'] != 'user' || row['isMeta'] == true) return null;
    final content = (row['message'] as Map?)?['content'];
    if (content is String) return content;
    if (content is! List) return null;
    if (content.any((c) => c is Map && c['type'] == 'tool_result')) return null;
    return [
      for (final c in content)
        if (c is Map && c['type'] == 'text') c['text'],
    ].join('\n');
  } on FormatException {
    return null;
  }
}

void _deleteLater(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Still held by the exiting agent; the OS temp sweep takes it.
  }
}
