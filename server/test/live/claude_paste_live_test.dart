@Tags(['live'])
@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/src/domain/uuid.dart';
import 'package:karmashala_host/src/pty/conpty.dart';
import 'package:karmashala_host/src/pty/pty.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Whether a multi-line opening message typed into the installed Claude Code
/// reaches the model whole, though its composer shows `[Pasted text #N]`.
/// The typed handoff route is built on the answer. Skips without `claude`.
void main() {
  final home = Platform.environment['USERPROFILE'] ?? '';
  final claude = File(p.join(home, '.local', 'bin', 'claude.exe'));

  for (final bracketed in [true, false]) {
    test(
      'a multi-line message typed ${bracketed ? 'as a bracketed paste' : 'raw'} '
      'reaches Claude Code whole',
      () async {
        final work = Directory.systemTemp.createTempSync('ks-paste-live');
        addTearDown(() => _deleteLater(work));
        final sessionId = newUuid();
        final pty = ConPtyLauncher().start(
          PtySpawnRequest(
            argv: [claude.path, '--session-id', sessionId],
            workingDirectory: work.path,
            // This test may itself run under Claude Code, whose markers would
            // turn the child's transcript off.
            removedEnvironment: {
              for (final name in Platform.environment.keys)
                if (name.startsWith('CLAUDE')) name,
            },
            columns: 120,
            rows: 40,
          ),
        );
        final screen = StringBuffer();
        final log = StringBuffer();
        final sub = pty.output.listen((bytes) {
          final text = utf8.decode(bytes, allowMalformed: true);
          screen.write(text);
          log.write(text);
        });
        addTearDown(() async {
          pty.kill();
          await sub.cancel();
          await pty.close();
        });

        Future<bool> until(bool Function(String s) test, Duration d) async {
          final end = DateTime.now().add(d);
          while (!test(screen.toString())) {
            if (DateTime.now().isAfter(end)) return false;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          return true;
        }

        void type(String text) =>
            pty.write(Uint8List.fromList(utf8.encode(text)));

        bool composer(String s) =>
            s.contains('shift+tab') || s.contains('shortcuts');
        await until(
          (s) => s.contains('to confirm') || composer(s),
          const Duration(seconds: 20),
        );
        // A new folder asks first, and its default is "No, exit".
        if (screen.toString().contains('trust')) {
          type('\x1b[B');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          type('\r');
          screen.clear();
        }
        expect(
          await until(composer, const Duration(seconds: 30)),
          isTrue,
          reason: screen.toString(),
        );
        await Future<void>.delayed(const Duration(seconds: 2));

        final nonce = newUuid();
        final lines = [
          'Reply with only the word ok.',
          'This is line two of a long opening message, "quoted" and %VAR%.',
          for (var i = 0; i < 30; i++) 'Filler line $i of the opening message.',
          'The last line carries the marker $nonce.',
        ];
        final message = lines.join('\n');
        type(bracketed ? '\x1b[200~$message\x1b[201~' : message);
        await Future<void>.delayed(const Duration(seconds: 2));
        final shown = screen.toString();
        type('\r');

        final transcript = File(
          p.join(
            home,
            '.claude',
            'projects',
            work.path.replaceAll(RegExp('[^A-Za-z0-9]'), '-'),
            '$sessionId.jsonl',
          ),
        );
        addTearDown(() => _deleteLater(transcript.parent));
        printOnFailure(log.toString());
        String firstUser() {
          if (!transcript.existsSync()) return '';
          for (final line in transcript.readAsLinesSync()) {
            try {
              final row = jsonDecode(line) as Map<String, Object?>;
              if (row['type'] != 'user') continue;
              final content = (row['message'] as Map?)?['content'];
              return content is String ? content : jsonEncode(content);
            } on FormatException {
              continue;
            }
          }
          return '';
        }

        final end = DateTime.now().add(const Duration(seconds: 30));
        while (firstUser().isEmpty && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final recorded = firstUser();
        // ignore: avoid_print
        print(
          'composer showed a paste placeholder: '
          '${shown.contains('Pasted text')}; recorded '
          '${recorded.length} chars; whole: ${recorded.contains(nonce)}',
        );
        expect(recorded, contains(nonce), reason: recorded);
        expect(recorded, contains('line two'), reason: recorded);
        expect(recorded, contains('Filler line 29'), reason: recorded);
      },
      skip: claude.existsSync() ? false : 'no claude at ${claude.path}',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

void _deleteLater(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Still held by the exiting agent; the OS temp sweep takes it.
  }
}
