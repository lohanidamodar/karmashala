import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/util/bounded_lines.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// **One record cannot cost the reader the whole machine.**
///
/// `LineSplitter` streams the file but materialises each record whole, and
/// `jsonDecode` has no streaming form — so peak memory was set by the largest
/// record, not by the file. Measured 2026-09-20 with
/// `packages/agent_cli/tool/giant_line.dart`: a 256 MiB record cost 2,451 ms
/// and 1,269 MiB of RSS, and the chat view pays it again every two seconds.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcript_bound'));
  tearDown(() => removeTempDirectory(dir));

  String turn(String text) =>
      '{"type":"user","message":{"role":"user","content":"$text"}}';

  File write(String name, List<String> lines) =>
      File('${dir.path}/$name')..writeAsStringSync(lines.join('\n'));

  test(
    'an oversized record is refused, and the turns around it survive',
    () async {
      final file = write('claude.jsonl', [
        turn('before'),
        turn('x' * (kMaxTranscriptLineBytes + 1024)),
        turn('after'),
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(
        messages.map((m) => m.text),
        ['before', 'after'],
        reason:
            'the record past the bound is dropped rather than built; the '
            'file keeps parsing around it',
      );
    },
  );

  test(
    'a record just under the bound is still read, and still text-bounded',
    () async {
      // Comfortably under the record bound, comfortably over the 64 KiB every
      // message's *text* is cut to — the two bounds are different things and
      // both have to hold.
      final file = write('claude.jsonl', [
        turn('y' * (1024 * 1024)),
        turn('after'),
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(messages, hasLength(2));
      expect(messages.first.text, hasLength(64 * 1024));
      expect(messages.last.text, 'after');
    },
  );

  test(
    'a file that is nothing but one oversized record reads as empty',
    () async {
      final file = write('claude.jsonl', [
        turn('x' * (kMaxTranscriptLineBytes + 1024)),
      ]);

      expect(await readCliTranscript(file.path, AgentIds.claudeCode), isEmpty);
    },
  );
}
