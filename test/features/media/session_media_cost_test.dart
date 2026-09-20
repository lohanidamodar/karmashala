import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/media/data/session_media_store.dart';

import 'session_media_fixture.dart';
import '../../support/temp_directory.dart';

/// What the media panel costs, and — the part that matters — what it does
/// **not** cost the transcript poll.
///
/// `sessionChatTranscriptProvider` re-parses the whole transcript every two
/// seconds while a session is on screen, and `cli_transcript_reader.dart`
/// deliberately drops `image` blocks for that reason: "their `data` is a base64
/// copy of the file, one real transcript carried 96 of them". Adding a media
/// panel must not undo that decision, so the first group here measures the
/// poll and the second measures the panel, which is a different code path with
/// a different budget: it runs when the user opens it, not five times a
/// second.
///
/// **Counted, not timed** — the same discipline as
/// `attention_inbox_cost_test.dart`. A stopwatch over a few milliseconds fails
/// whenever the machine is busy; bytes read, lines JSON-decoded and bytes
/// written out are the same numbers on any runner.
void main() {
  late Directory dir;
  late Directory cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('session_media_cost');
    cache = Directory('${dir.path}/cache')..createSync();
  });
  tearDown(() => removeTempDirectory(dir));

  /// A conversation of [turns] plain turns, with [images] pasted pictures of
  /// [kb] KB each folded in. The shape of the transcript the owner was looking
  /// at when they asked for this.
  List<String> conversation({
    required int turns,
    required int images,
    int kb = 512,
  }) {
    final lines = <String>[];
    for (var i = 0; i < turns; i++) {
      lines.add(
        textLine(
          at: '2026-09-01T10:00:00.000Z',
          role: i.isEven ? 'user' : 'assistant',
          text: 'turn $i — ${'the quick brown fox. ' * 20}',
        ),
      );
      if (i < images) {
        lines.add(
          pastedImageLine(
            at: '2026-09-01T10:00:00.000Z',
            data: bulkyBase64(kb),
          ),
        );
      }
    }
    return lines;
  }

  group('the two-second transcript poll', () {
    test('costs the same whether or not the session pasted images', () async {
      final without = writeTranscript(
        dir,
        'without.jsonl',
        conversation(turns: 40, images: 0),
      );
      final with_ = writeTranscript(
        dir,
        'with.jsonl',
        conversation(turns: 40, images: 8),
      );

      final plain = await readCliTranscript(without.path, AgentIds.claudeCode);
      final rich = await readCliTranscript(with_.path, AgentIds.claudeCode);

      // The retained conversation is byte-identical: eight 512 KB pictures
      // added 4 MB to the file and nothing at all to what the poll holds.
      int retained(List<TranscriptMessage> messages) =>
          messages.fold(0, (sum, m) => sum + m.text.length);

      // ignore: avoid_print
      print(
        'transcript poll · 40 turns · 0 images ${without.lengthSync() ~/ 1024} KB'
        ' file, ${retained(plain)} chars retained · 8 images'
        ' ${with_.lengthSync() ~/ 1024} KB file, ${retained(rich)} chars retained',
      );

      expect(
        rich.map((m) => m.text),
        plain.map((m) => m.text),
        reason: 'the poll must be blind to image blocks, as it was before',
      );
      expect(retained(rich), retained(plain));
      expect(
        with_.lengthSync(),
        greaterThan(without.lengthSync() * 4),
        reason: 'the pictures really are in the file being polled',
      );
    });

    test('the panel reads its own copy and never touches the poll', () async {
      // Nothing the panel writes is visible to the reader the poll uses: the
      // extracted pictures live under the app-support cache, and the transcript
      // is opened read-only.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:00:00.000Z', text: 'look'),
      ]);
      final before = await readCliTranscript(
        transcript.path,
        AgentIds.claudeCode,
      );
      final stamp = transcript.lastModifiedSync();

      await SessionMediaStore(
        cache,
      ).refresh(transcript.path, AgentIds.claudeCode);

      final after = await readCliTranscript(
        transcript.path,
        AgentIds.claudeCode,
      );
      expect(after.map((m) => m.text), before.map((m) => m.text));
      expect(
        transcript.lastModifiedSync(),
        stamp,
        reason: 'a scan must not make the poll think the file changed',
      );
    });
  });

  group('opening the panel', () {
    test('decodes each picture once, and never again', () async {
      final transcript = writeTranscript(
        dir,
        'a.jsonl',
        conversation(turns: 40, images: 8, kb: 128),
      );
      final store = SessionMediaStore(cache);

      final first = await store.refresh(transcript.path, AgentIds.claudeCode);
      var previous = first;
      final second = await store.refresh(
        transcript.path,
        AgentIds.claudeCode,
        previous: previous,
      );
      previous = second;
      // And with the manifest reloaded from disk, which is what a fresh app
      // run does.
      final reloaded = await store.load(transcript.path);
      final third = await store.refresh(
        transcript.path,
        AgentIds.claudeCode,
        previous: reloaded,
      );

      // ignore: avoid_print
      print(
        'media scan · ${transcript.lengthSync() ~/ 1024} KB transcript'
        ' · open ${first.bytesRead ~/ 1024} KB read,'
        ' ${first.linesDecoded} lines parsed,'
        ' ${first.bytesExtracted ~/ 1024} KB written'
        ' · reopen ${second.bytesRead} B read,'
        ' ${second.linesDecoded} lines parsed,'
        ' ${second.bytesExtracted} B written'
        ' · after restart ${third.bytesRead} B read,'
        ' ${third.bytesExtracted} B written',
      );

      expect(first.items, hasLength(8));
      expect(first.bytesExtracted, greaterThan(0));

      // An unchanged transcript is not read at all the second time: the
      // manifest already says how far the file was scanned.
      expect(second.bytesRead, 0);
      expect(second.linesDecoded, 0);
      expect(second.bytesExtracted, 0);
      expect(second.items.map((i) => i.id), first.items.map((i) => i.id));

      // The manifest survives the app closing, so neither does a restart.
      expect(third.bytesRead, 0);
      expect(third.bytesExtracted, 0);
      expect(third.items.map((i) => i.id), first.items.map((i) => i.id));
    });

    test('a growing session re-reads only what was appended', () async {
      final transcript = writeTranscript(
        dir,
        'a.jsonl',
        conversation(turns: 40, images: 8, kb: 128),
      );
      final store = SessionMediaStore(cache);
      final first = await store.refresh(transcript.path, AgentIds.claudeCode);
      final was = transcript.lengthSync();

      appendTranscript(transcript, [
        textLine(at: '2026-09-01T11:00:00.000Z', role: 'user', text: 'more'),
        pastedImageLine(at: '2026-09-01T11:00:01.000Z', data: bulkyBase64(128)),
      ]);
      final grew = transcript.lengthSync() - was;

      final second = await store.refresh(
        transcript.path,
        AgentIds.claudeCode,
        previous: first,
      );

      // ignore: avoid_print
      print(
        'media rescan · file grew by ${grew ~/ 1024} KB'
        ' · ${second.bytesRead ~/ 1024} KB read'
        ' · ${second.linesDecoded} lines parsed'
        ' · ${second.bytesExtracted ~/ 1024} KB written',
      );

      expect(second.items, hasLength(9), reason: 'the new picture is listed');
      expect(
        second.bytesRead,
        grew,
        reason: 'the pass starts where the last one stopped',
      );
      expect(
        second.bytesRead,
        lessThan(first.bytesRead ~/ 4),
        reason: 'a live session must not re-read the whole file every poll',
      );
      // One new picture, one new decode — the four already on disk are not
      // touched.
      expect(second.bytesExtracted, lessThan(first.bytesExtracted ~/ 3));
    });

    test('lines that cannot hold a picture are never JSON-decoded', () async {
      // The saving that keeps a first open cheap on a long conversation: a
      // plain turn mentions neither an image block nor an image extension, so
      // there is nothing in it for the panel and parsing it is pure cost.
      final transcript = writeTranscript(
        dir,
        'a.jsonl',
        conversation(turns: 200, images: 3, kb: 64),
      );

      final scan = await SessionMediaStore(
        cache,
      ).refresh(transcript.path, AgentIds.claudeCode);

      // ignore: avoid_print
      print(
        'media scan · 203 lines · ${scan.linesDecoded} parsed'
        ' · ${scan.items.length} items',
      );
      expect(scan.items, hasLength(3));
      expect(
        scan.linesDecoded,
        lessThanOrEqualTo(6),
        reason: 'only the lines that could hold a picture are parsed',
      );
    });

    test('one enormous block cannot be decoded into memory', () async {
      // The bound that matters for a freeze is peak memory, and it is set
      // before anything is decoded: the byte size is arithmetic on the base64
      // length.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:00:00.000Z', data: bulkyBase64(600)),
      ]);

      final scan = await SessionMediaStore(
        cache,
        maxItemBytes: 64 * 1024,
      ).refresh(transcript.path, AgentIds.claudeCode);

      expect(scan.bytesExtracted, 0);
      expect(scan.items.single.problem, contains('too large'));
    });
  });
}
