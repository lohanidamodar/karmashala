import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/media/data/session_media_store.dart';
import 'package:karmashala/src/features/media/domain/session_image_reference.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';

import 'session_media_fixture.dart';
import '../../support/temp_directory.dart';

/// What `[Image #6]` in a terminal pane actually names.
///
/// The owner's request: *"image link inside terminal still not wired, i should
/// be able to ctrl click on the image `[Image #6]` and preview the image in
/// dialog"*.
///
/// The thing that had to be established before any of it could be built is in
/// the second group below. The CLI numbers pastes with a counter of its own and
/// the media scanner numbers *everything it finds*, so the two do **not** agree
/// — proved here on the shapes read out of the owner's real transcripts. What
/// does agree is the CLI's own `imagePasteIds`, which is recorded in the
/// transcript beside the picture it belongs to. That is the key this uses.
void main() {
  group('finding the reference in a line of terminal output', () {
    test('a printed reference is found, with its number and its span', () {
      const line = 'ok [Image #6] saved';

      final found = imageReferencesIn(line).single;

      expect(found.pasteId, 6);
      expect(line.substring(found.start, found.end), '[Image #6]');
      expect(found.label, '[Image #6]');
    });

    test('several on one line are all found, in reading order', () {
      final found = imageReferencesIn('[Image #1] [Image #2] check these');

      expect(found.map((r) => r.pasteId), [1, 2]);
    });

    test('the reference under a character is the one that covers it', () {
      const line = 'ok [Image #6] saved';

      expect(imageReferenceAt(line, 3)?.pasteId, 6, reason: 'the `[`');
      expect(imageReferenceAt(line, 12)?.pasteId, 6, reason: 'the `]`');
      expect(imageReferenceAt(line, 2), isNull, reason: 'the space before');
      expect(imageReferenceAt(line, 13), isNull, reason: 'the space after');
    });

    test('prose that merely mentions an image is not a reference', () {
      // A wrong match opens the wrong picture, which is worse than not
      // offering the link at all — the same rule the path scan follows.
      for (final line in const [
        'Image #6 without brackets',
        '[image #6] lower case is not what the CLI writes',
        '[Image #] no number',
        '[Images #6] a different word',
      ]) {
        expect(imageReferencesIn(line), isEmpty, reason: line);
      }
    });

    test('an audio reference is left alone', () {
      // Claude Code prints `[Audio #N]` in the same shape — its bundle carries
      // the parser `Image #\d+|Audio #\d+`. Karmashala has no sound in the
      // media store and no player, so a link there could only ever refuse.
      expect(imageReferencesIn('[Audio #3] listen to this'), isEmpty);
    });
  });

  group("the number the CLI prints is the transcript's own paste id", () {
    late Directory dir;
    late SessionMediaStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('session_image_ref');
      store = SessionMediaStore(Directory('${dir.path}/cache')..createSync());
    });
    tearDown(() => removeTempDirectory(dir));

    Future<List<SessionMediaItem>> scan(File transcript) async =>
        (await store.refresh(
          transcript.path,
          AgentIds.claudeCode,
        )).items;

    test('a paste carries the id the CLI printed, not its position', () async {
      // The proof that position is the wrong key. This transcript has two
      // pictures the agent read before the paste, so the paste is the *third*
      // thing the scanner finds and is numbered `[Image #1]` on screen.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': '/mnt/c/work/a.png'},
        ),
        toolUseLine(
          at: '2026-09-01T10:00:01.000Z',
          id: 't2',
          name: 'Read',
          input: {'file_path': '/mnt/c/work/b.png'},
        ),
        pastedImageLine(
          at: '2026-09-01T10:00:02.000Z',
          text: '[Image #1] look at this',
          pasteIds: [1],
        ),
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(3));
      expect(items.last.origin, SessionMediaOrigin.pasted);
      expect(items.last.sequence, 2, reason: 'third thing found');
      expect(items.last.pasteId, 1, reason: 'but the CLI called it #1');
    });

    test('a queued paste carries the id from the attachment', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        queuedPasteLine(
          at: '2026-09-01T10:00:00.000Z',
          text: '[Image #6] add this though',
          pasteIds: [6],
        ),
      ]);

      final items = await scan(transcript);

      expect(items.single.pasteId, 6);
    });

    test('two pastes in one turn take their ids in order', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        multiPastedImageLine(
          at: '2026-09-01T10:00:00.000Z',
          text: '[Image #1] [Image #2] check these images',
          pasteIds: [1, 2],
        ),
      ]);

      final items = await scan(transcript);

      expect(items.map((item) => item.pasteId), [1, 2]);
    });

    test('a picture the CLI never numbered has no id at all', () async {
      // `Read` results and tool screenshots are never `[Image #N]` on screen,
      // and neither is a paste from a CLI build that does not record the field.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': '/mnt/c/work/a.png'},
        ),
        pastedImageLine(at: '2026-09-01T10:00:01.000Z', text: 'no ids here'),
      ]);

      final items = await scan(transcript);

      expect(items.map((item) => item.pasteId), [null, null]);
    });

    test('ids that do not answer the pictures one for one are refused', () async {
      // Guessing a pairing is how the wrong picture gets opened. If the record
      // does not line up, nothing is keyed.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        multiPastedImageLine(
          at: '2026-09-01T10:00:00.000Z',
          text: '[Image #4] and one more',
          pasteIds: [4],
        ),
      ]);

      final items = await scan(transcript);

      expect(items.map((item) => item.pasteId), [null, null]);
    });

    test('the id survives a reload from the manifest', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(
          at: '2026-09-01T10:00:00.000Z',
          text: '[Image #3] here',
          pasteIds: [3],
        ),
      ]);
      await scan(transcript);

      // A second store, so the answer can only have come off the manifest.
      final reopened = SessionMediaStore(
        Directory('${dir.path}/cache'),
      );
      final again = await reopened.refresh(
        transcript.path,
        AgentIds.claudeCode,
      );

      expect(again.items.single.pasteId, 3);
    });
  });
}
