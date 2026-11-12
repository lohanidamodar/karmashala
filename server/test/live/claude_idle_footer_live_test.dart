@Tags(['live'])
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_host/src/domain/host_session.dart';
import 'package:karmashala_host/src/pty/conpty.dart';
import 'package:karmashala_host/src/pty/pty.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Whether the installed Claude Code's empty composer reads idle off the
/// host's own screen, in every mode shift+tab cycles through. No prompt is
/// sent. With `KARMASHALA_CAPTURE_DIR` set, each mode's rows are written there
/// for a fixture. Skips without `claude`.
void main() {
  final home = Platform.environment['USERPROFILE'] ?? '';
  final claude = File(p.join(home, '.local', 'bin', 'claude.exe'));
  final agent = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;

  test(
    'the idle composer reads idle in every mode shift+tab cycles through',
    () async {
      final work = Directory.systemTemp.createTempSync('ks-idle-live');
      addTearDown(() => _deleteLater(work));
      final request = PtySpawnRequest(
        argv: [claude.path],
        workingDirectory: work.path,
        // This test may itself run under Claude Code.
        removedEnvironment: {
          for (final name in Platform.environment.keys)
            if (name.startsWith('CLAUDE')) name,
        },
        columns: 120,
        rows: 30,
      );
      final session = HostSession(
        id: 'idle-live',
        request: request,
        pty: ConPtyLauncher().start(request),
        startedAt: DateTime.now(),
      );
      addTearDown(() => session.terminate());

      String screen() => session.tailText(30).join('\n');
      void press(String keys) =>
          session.typeAsHost(Uint8List.fromList(utf8.encode(keys)));
      Future<String> settled() async {
        var last = screen();
        var since = DateTime.now();
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().difference(since) < const Duration(seconds: 2) &&
            DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final now = screen();
          if (now != last) {
            last = now;
            since = DateTime.now();
          }
        }
        return last;
      }

      // A new folder asks first, and its default is "No, exit".
      final start = DateTime.now().add(const Duration(seconds: 30));
      while (!screen().contains('❯') && DateTime.now().isBefore(start)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if ((await settled()).contains('Yes, I trust this folder')) {
        press('\x1b[B');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        press('\r');
      }

      final capture = Platform.environment['KARMASHALA_CAPTURE_DIR'];
      final modes = <String>[];
      final unread = <String>[];
      for (var mode = 0; mode < 6; mode++) {
        await settled();
        final rows = session.tailText(agent.grid.scanLines);
        final footer = rows.lastWhere((r) => r.trim().isNotEmpty);
        // The mode's label, the footer up to its first hint.
        final label = footer.trim().split(RegExp(r' \(| · ')).first;
        if (modes.contains(label)) break;
        modes.add(label);
        // A keeper of its own, which reports a screen that changed nothing.
        final report = (HostedStatusKeeper(
          agents: AgentRegistry.builtIn,
        )..track('row', agentId: agent.id)).screen('row', rows)?.report;
        // ignore: avoid_print
        print('mode $mode: ${report?.status.name} — footer "${footer.trim()}"');
        if (report?.status != AgentActivityStatus.idle) unread.add(footer);
        if (capture != null) {
          File(
            p.join(capture, 'claude-idle-mode-$mode.screen'),
          ).writeAsStringSync('${rows.join('\n')}\n');
        }
        press('\x1b[Z');
      }
      expect(modes, isNotEmpty, reason: screen());
      expect(unread, isEmpty, reason: screen());
    },
    skip: claude.existsSync() ? false : 'no claude at ${claude.path}',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _deleteLater(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Still held by the exiting agent; the OS temp sweep takes it.
  }
}
