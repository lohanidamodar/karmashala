import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/media/data/session_media_store.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';

import 'session_media_fixture.dart';
import '../../support/temp_directory.dart';

/// What the media panel can find in a session, and what it costs to find it.
///
/// The request this answers, in the owner's words: *"where can i see this
/// image preview in the terminal? i can't see it, may be we can create a media
/// sidebar that shows all the media from current session in descending
/// order?"* — they had **pasted** a picture into the terminal, and a paste
/// carries bytes and no path, so the path-driven `TranscriptImagePreview` had
/// nothing to draw.
void main() {
  late Directory dir;
  late Directory cache;
  late SessionMediaStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('session_media');
    cache = Directory('${dir.path}/cache')..createSync();
    store = SessionMediaStore(cache);
  });
  tearDown(() => removeTempDirectory(dir));

  Future<List<SessionMediaItem>> scan(File transcript) async {
    final result = await store.refresh(transcript.path, AgentIds.claudeCode);
    return result.newestFirst;
  }

  group('what the panel can find', () {
    test('an image the agent read is listed by its file name', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': '/mnt/c/work/shot.png'},
        ),
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(1));
      expect(items.single.origin, SessionMediaOrigin.read);
      expect(items.single.path, '/mnt/c/work/shot.png');
      expect(items.single.label, 'shot.png');
      // Written in the *agent's* environment, so the panel has to translate it
      // before `dart:io` on the Windows host is asked to open it.
      expect(items.single.fromAgentEnvironment, isTrue);
      expect(items.single.toolName, 'Read');
    });

    test('a `Read` of an ordinary file is not media', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': '/mnt/c/work/main.dart'},
        ),
      ]);

      expect(await scan(transcript), isEmpty);
    });

    test('a pasted image is extracted to a file the panel can draw', () async {
      // The owner's case. No path anywhere in the record — only bytes.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:00:00.000Z', text: 'look at this'),
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(1));
      final item = items.single;
      expect(item.origin, SessionMediaOrigin.pasted);
      expect(item.label, 'Pasted image');
      expect(item.problem, isNull);
      // Extracted onto the host, so no translation is wanted.
      expect(item.fromAgentEnvironment, isFalse);
      expect(item.path, isNotNull);
      final file = File(item.path!);
      expect(file.existsSync(), isTrue, reason: 'the bytes were written out');
      expect(file.readAsBytesSync(), base64Decode(tinyPngBase64));
      expect(file.path, startsWith(cache.path));
    });

    test('a paste queued as a prompt is found too', () async {
      // The shape that matters most, and the one a `message.content` reader
      // misses entirely: eight of the nine pastes in the real
      // `sampada-trails` transcript are `type:"attachment"` lines whose blocks
      // hang off `attachment.prompt`, not off a `user` message at all.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        queuedPasteLine(
          at: '2026-09-01T10:00:00.000Z',
          text: 'the layout image proposed layut',
        ),
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(1));
      expect(items.single.origin, SessionMediaOrigin.pasted);
      expect(File(items.single.path!).existsSync(), isTrue);
    });

    test('a screenshot a tool answered with is listed as captured', () async {
      // `device_screenshot`, `browser_screenshot` and `browser_capture` all
      // answer with an MCP image block; only `device_screenshot` also leaves a
      // copy in the temp directory, so the block is the one source that covers
      // every one of them.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'mcp__karmashala__device_screenshot',
          input: {'serial': 'emulator-5554'},
        ),
        toolResultLine(
          at: '2026-09-01T10:00:01.000Z',
          id: 't1',
          imageData: tinyPngBase64,
          text: 'Screenshot of Pixel 8. Saved to /tmp/karmashala_x.png.',
        ),
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(1));
      expect(items.single.origin, SessionMediaOrigin.captured);
      expect(items.single.toolName, 'mcp__karmashala__device_screenshot');
      // Named by the tool that produced it, without the MCP prefix nobody reads.
      expect(items.single.label, 'device_screenshot');
      expect(File(items.single.path!).existsSync(), isTrue);
    });

    test('a browser capture with no on-disk copy is still listed', () async {
      // `browser_screenshot` writes nothing to disk at all — the block is all
      // there is, and it is enough.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'mcp__karmashala__browser_screenshot',
          input: {'fullPage': true},
        ),
        toolResultLine(
          at: '2026-09-01T10:00:01.000Z',
          id: 't1',
          imageData: tinyPngBase64,
          text: 'Viewport of example.com — 12 KB.',
        ),
      ]);

      final items = await scan(transcript);

      expect(items.single.origin, SessionMediaOrigin.captured);
      expect(items.single.label, 'browser_screenshot');
    });
  });

  group('Codex, best effort', () {
    // Codex wraps its rollout items in `payload` and sends a picture as an
    // `input_image` data URI. Unlike the Claude shapes above, this one has not
    // been checked against a real store — these tests pin the guess so that
    // changing the line filter cannot quietly stop it finding anything, and so
    // the shape is written down where the next person can correct it.
    test('a data-URI paste is extracted', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        jsonEncode({
          'timestamp': '2026-09-01T10:00:00.000Z',
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {
                'type': 'input_image',
                'image_url': 'data:image/png;base64,$tinyPngBase64',
              },
            ],
          },
        }),
      ]);

      final result = await store.refresh(transcript.path, AgentIds.codex);

      expect(result.items, hasLength(1));
      expect(result.items.single.origin, SessionMediaOrigin.pasted);
      expect(File(result.items.single.path!).existsSync(), isTrue);
    });

    test('a shell call that names an image file is listed by path', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        jsonEncode({
          'timestamp': '2026-09-01T10:00:00.000Z',
          'type': 'response_item',
          'payload': {
            'type': 'function_call',
            'name': 'view_image',
            'call_id': 'c1',
            'arguments': '{"path":"/home/me/shot.png"}',
          },
        }),
      ]);

      final result = await store.refresh(transcript.path, AgentIds.codex);

      expect(result.items, hasLength(1));
      expect(result.items.single.origin, SessionMediaOrigin.read);
      expect(result.items.single.path, '/home/me/shot.png');
      expect(result.items.single.fromAgentEnvironment, isTrue);
    });
  });

  group('an image the agent read is one picture, not two', () {
    // Claude Code answers `Read(shot.png)` with the file's bytes as a base64
    // `image` block, so the same picture is in the transcript twice: once as a
    // path in the call, once as ~300 KB of base64 in the result. Every one of
    // the 20 tool_result images in the real `sampada-trails` transcript is a
    // `Read` like this. Listing both would double the panel *and* write 6 MB of
    // cache for pictures that are already on disk under their own names.
    Future<List<SessionMediaItem>> readAndAnswer(String data) async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': r'C:\work\thumbs\temple.png'},
        ),
        toolResultLine(
          at: '2026-09-01T10:00:01.000Z',
          id: 't1',
          imageData: data,
        ),
      ]);
      return scan(transcript);
    }

    test('the file wins and the copy in the answer is skipped', () async {
      final items = await readAndAnswer(tinyPngBase64);

      expect(items, hasLength(1));
      expect(items.single.origin, SessionMediaOrigin.read);
      expect(items.single.path, r'C:\work\thumbs\temple.png');
      expect(items.single.fromAgentEnvironment, isTrue);
    });

    test('and nothing at all is extracted for it', () async {
      final result = await store.refresh(
        writeTranscript(dir, 'b.jsonl', [
          toolUseLine(
            at: '2026-09-01T10:00:00.000Z',
            id: 't1',
            name: 'Read',
            input: {'file_path': r'C:\work\thumbs\temple.png'},
          ),
          toolResultLine(
            at: '2026-09-01T10:00:01.000Z',
            id: 't1',
            imageData: bulkyBase64(300),
          ),
        ]).path,
        AgentIds.claudeCode,
      );

      expect(result.bytesExtracted, 0);
    });

    test('the skip survives the call and its answer being scanned apart', () async {
      // A poll can catch the file between the two lines, so the fact that the
      // call already gave us a path has to outlive the pass that saw it.
      final transcript = writeTranscript(dir, 'c.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': r'C:\work\thumbs\temple.png'},
        ),
      ]);
      final first = await store.refresh(transcript.path, AgentIds.claudeCode);
      appendTranscript(transcript, [
        toolResultLine(
          at: '2026-09-01T10:00:01.000Z',
          id: 't1',
          imageData: bulkyBase64(300),
        ),
      ]);

      final second = await store.refresh(
        transcript.path,
        AgentIds.claudeCode,
        previous: first,
      );

      expect(second.items, hasLength(1));
      expect(second.bytesExtracted, 0);
    });
  });

  group('the order the owner asked for', () {
    test('newest first', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        toolUseLine(
          at: '2026-09-01T10:00:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': '/work/first.png'},
        ),
        textLine(at: '2026-09-01T10:01:00.000Z', role: 'user', text: 'ok'),
        pastedImageLine(at: '2026-09-01T10:02:00.000Z'),
        toolUseLine(
          at: '2026-09-01T10:03:00.000Z',
          id: 't2',
          name: 'Read',
          input: {'file_path': '/work/last.png'},
        ),
      ]);

      final items = await scan(transcript);

      expect(
        items.map((item) => item.label),
        ['last.png', 'Pasted image', 'first.png'],
        reason: 'descending order, as asked',
      );
      // Descending by the order they were recorded, which is the order that
      // survives a transcript with no timestamps.
      expect(items.first.sequence, greaterThan(items.last.sequence));
    });

    test('the time each one arrived is carried through', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:02:00.000Z'),
      ]);

      final items = await scan(transcript);

      expect(items.single.at, DateTime.utc(2026, 9, 1, 10, 2));
    });
  });

  group('degrading instead of crashing', () {
    test('a transcript that is not there yields nothing', () async {
      final result = await store.refresh(
        '${dir.path}/never-written.jsonl',
        AgentIds.claudeCode,
      );
      expect(result.items, isEmpty);
    });

    test('malformed and truncated lines are skipped, not fatal', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        '{not json at all',
        '[]',
        pastedImageLine(at: '2026-09-01T10:00:00.000Z'),
        '{"type":"user","message":{"content":"a string"}}',
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(1));
      expect(items.single.origin, SessionMediaOrigin.pasted);
    });

    test('a pasted block too large to preview is listed, not decoded', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(
          at: '2026-09-01T10:00:00.000Z',
          data: bulkyBase64(64),
        ),
      ]);

      final small = SessionMediaStore(cache, maxItemBytes: 1024);
      final result = await small.refresh(transcript.path, AgentIds.claudeCode);

      expect(result.items, hasLength(1));
      expect(result.items.single.path, isNull);
      expect(result.items.single.problem, contains('too large'));
      expect(
        result.bytesExtracted,
        0,
        reason: 'the size is read off the base64 length, never by decoding',
      );
    });

    test('an image block with no usable data is listed with a reason', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        jsonEncode({
          'type': 'user',
          'timestamp': '2026-09-01T10:00:00.000Z',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                // A URL source, which Claude also accepts: nothing to write out.
                'source': {'type': 'url', 'url': 'https://example.com/a.png'},
              },
            ],
          },
        }),
      ]);

      final items = await scan(transcript);

      expect(items, hasLength(1));
      expect(items.single.path, isNull);
      expect(items.single.problem, isNotNull);
    });

    test('an agent with no readable store is refused by name', () async {
      // Antigravity's file is a SQLite database whose message columns are
      // protobuf; `readCliTranscript` refuses it for the same reason.
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:00:00.000Z'),
      ]);

      final result = await store.refresh(
        transcript.path,
        AgentIds.antigravity,
      );

      expect(result.items, isEmpty);
      expect(result.bytesRead, 0);
    });
  });

  group('what the panel holds', () {
    test('only the newest N, so a long session cannot grow forever', () async {
      final lines = [
        for (var i = 0; i < 12; i++)
          toolUseLine(
            at: '2026-09-01T10:00:00.000Z',
            id: 't$i',
            name: 'Read',
            input: {'file_path': '/work/shot-$i.png'},
          ),
      ];
      final transcript = writeTranscript(dir, 'a.jsonl', lines);

      final capped = SessionMediaStore(cache, cap: 5);
      final result = await capped.refresh(
        transcript.path,
        AgentIds.claudeCode,
      );

      expect(result.items, hasLength(5));
      expect(
        result.newestFirst.first.label,
        'shot-11.png',
        reason: 'the cap drops the oldest, never the newest',
      );
    });
  });

  group('the manifest', () {
    test('survives a round trip through disk', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:00:00.000Z'),
        toolUseLine(
          at: '2026-09-01T10:01:00.000Z',
          id: 't1',
          name: 'Read',
          input: {'file_path': '/work/shot.png'},
        ),
      ]);
      final first = await store.refresh(transcript.path, AgentIds.claudeCode);

      final reloaded = await store.load(transcript.path);

      expect(reloaded, isNotNull);
      expect(
        reloaded!.items.map((item) => item.id),
        first.items.map((item) => item.id),
      );
      expect(
        reloaded.items.map((item) => item.origin),
        first.items.map((item) => item.origin),
      );
      expect(reloaded.scannedBytes, first.scannedBytes);
    });

    test('a rewritten transcript is rescanned from the start', () async {
      final transcript = writeTranscript(dir, 'a.jsonl', [
        pastedImageLine(at: '2026-09-01T10:00:00.000Z'),
        pastedImageLine(at: '2026-09-01T10:01:00.000Z'),
      ]);
      await store.refresh(transcript.path, AgentIds.claudeCode);

      // Shorter than what was scanned: the file cannot be the same one grown.
      transcript.writeAsStringSync(
        '${textLine(at: '2026-09-01T11:00:00.000Z', role: 'user', text: 'hi')}\n',
      );
      final result = await store.refresh(transcript.path, AgentIds.claudeCode);

      expect(result.items, isEmpty);
      expect(result.scannedBytes, transcript.lengthSync());
    });
  });
}
