/// One bound, one function, three paths.
///
/// The failure this pins is silent by construction: a phone that reopens a
/// session is handed the *stored* row and the *rehydrated* one, and if either
/// keeps more text than the live stream had carried, the same turn reads
/// differently depending on which door it arrived through. So the claim tested
/// here is not "each path bounds something" — it is that all three bound at the
/// same number, through the same function.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_transcript_reader.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala/src/features/sessions/domain/tool_activity.dart';

import '../../support/temp_directory.dart';

void main() {
  group('boundedText', () {
    test('leaves anything under the bound exactly as it was', () {
      const text = 'a tool that printed one line';
      final (bounded, truncated) = boundedText(text);
      expect(identical(bounded, text), isTrue, reason: 'no copy is made');
      expect(truncated, isFalse);
    });

    test('counts BYTES, not code units', () {
      // Four bytes of UTF-8 per character, so 40 characters is 160 bytes and
      // over a 100-byte budget that a `length` check would have passed.
      final text = '\u{1F600}' * 40;
      expect(text.length, 80, reason: 'UTF-16 code units, two per emoji');
      final (bounded, truncated) = boundedText(text, maxBytes: 100);
      expect(truncated, isTrue);
      expect(utf8.encode(bounded).length, lessThanOrEqualTo(100));
    });

    test('never cuts a code point in half', () {
      // The cut lands mid-emoji at every one of these budgets; each answer must
      // still be a string that survives a round trip through UTF-8.
      for (var budget = 1; budget <= 24; budget++) {
        final (bounded, _) = boundedText('\u{1F600}' * 8, maxBytes: budget);
        expect(
          utf8.decode(utf8.encode(bounded)),
          bounded,
          reason: 'budget $budget produced an unencodable string',
        );
        expect(utf8.encode(bounded).length, lessThanOrEqualTo(budget));
      }
    });

    test('the bound is 64 KiB', () {
      expect(kMaxTranscriptTextBytes, 64 * 1024);
    });
  });

  group('the same function on all three paths', () {
    // 64 KiB plus a tail nobody may keep.
    final oversized = 'x' * (kMaxTranscriptTextBytes + 5000);

    test('provider-history rehydration cuts at the shared bound', () {
      final (bounded, truncated) = boundedToolOutput(oversized);
      expect(truncated, isTrue);
      expect(utf8.encode(bounded).length, kMaxTranscriptTextBytes);
      // The tool-output policy is a *name* for the shared bound now, not a
      // second number: the two answers must be byte-identical.
      expect(bounded, boundedText(oversized).$1);
    });

    test('a rehydrated turn is bounded, not only its tool result', () async {
      // The row the phone actually receives is the turn text — tool rows are
      // dropped on the way to the wire — so bounding only the result left the
      // one payload that crosses unbounded.
      final dir = Directory.systemTemp.createTempSync('bounded_text_test');
      addTearDown(() => removeTempDirectory(dir));
      final file = File('${dir.path}/claude.jsonl')
        ..writeAsStringSync(
          jsonEncode({
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': oversized},
              ],
            },
          }),
        );

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(messages, hasLength(1));
      expect(utf8.encode(messages.single.text).length, kMaxTranscriptTextBytes);
    });

    test('the live path bounds a row the database already held', () async {
      // The wire's bound is its own, not one it inherits: a row written before
      // the stored-row cut existed still reaches the phone through here.
      final page = collapseTaskNotifications([
        RemoteTranscriptMessage(role: 'agent', text: oversized),
      ]);
      expect(utf8.encode(page.single.text).length, kMaxTranscriptTextBytes);
      expect(page.single.role, 'agent');
    });

    test('a bounded head is a prefix of what was cut', () {
      // Not an elision, not a summary: the head, so the two paths can be
      // compared byte for byte rather than by eye.
      final (bounded, _) = boundedText(oversized);
      expect(oversized.startsWith(bounded), isTrue);
    });
  });
}
