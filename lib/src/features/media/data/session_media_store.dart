import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../agents/domain/agent_ids.dart';
import '../../sessions/domain/tool_activity.dart';
import '../domain/session_media_item.dart';

/// Finds every picture a session has and puts the ones that exist only as bytes
/// somewhere the panel can draw them.
///
/// ## Why this is not the transcript reader
///
/// `cli_transcript_reader.dart` drops `image` blocks on purpose, and its
/// comment says why: *"their `data` is a base64 copy of the file, one real
/// transcript carried 96 of them, and the picture is drawn from the path on
/// disk instead"*. That reader runs on a **two-second poll** for as long as a
/// session is on screen, so holding those blocks would mean re-materialising
/// megabytes of base64 every two seconds, forever. That decision is right and
/// this file does not touch it.
///
/// A panel is a different cost profile: it is opened deliberately, by someone
/// who wants to see the pictures. So this is a **second, separate pass** over
/// the same file, with four bounds that keep it affordable:
///
/// 1. **It only runs while the panel is open.** The provider is `autoDispose`;
///    closing the panel stops the poll outright.
/// 2. **Most lines are never parsed.** A line that mentions neither an image
///    block nor an image extension cannot hold a picture, so `jsonDecode` is
///    never called on it — and a transcript is overwhelmingly those lines.
/// 3. **Bytes are moved to disk, not held.** Each block is decoded, written,
///    and dropped one at a time, so peak memory is one picture, not ninety-six.
///    The panel then holds paths, which is what the transcript preview already
///    knows how to draw.
/// 4. **It resumes.** A manifest records how far the file was scanned; a
///    transcript is appended to, so the next pass reads only what is new and a
///    reopen reads nothing at all. Nothing is ever decoded twice.
///
/// The bound on *how much* is decoded is [kMaxSessionMediaBytes] per picture —
/// checked by arithmetic on the base64 length, before any decoding — and
/// [kSessionMediaCap] pictures kept.
class SessionMediaStore {
  SessionMediaStore(
    this.cacheRoot, {
    this.cap = kSessionMediaCap,
    this.maxItemBytes = kMaxSessionMediaBytes,
  });

  /// Where extracted pictures and the per-transcript manifest live — under the
  /// application support directory, not the temp directory, because a picture
  /// the panel is showing must outlive a reboot's temp sweep.
  final Directory cacheRoot;

  /// How many pictures to keep. The oldest are dropped, and their extracted
  /// copies deleted with them.
  final int cap;

  /// The largest single picture to extract.
  final int maxItemBytes;

  /// The manifest for [transcriptPath], or null when there is none to read.
  Future<SessionMediaScan?> load(String transcriptPath) async {
    final file = _manifestFile(transcriptPath);
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      if (decoded['version'] != _manifestVersion) return null;
      if (decoded['path'] != transcriptPath) return null;
      final items = <SessionMediaItem>[];
      for (final entry in (decoded['items'] as List? ?? const [])) {
        final item = SessionMediaItem.fromJson(entry);
        if (item != null) items.add(item);
      }
      return SessionMediaScan(
        transcriptPath: transcriptPath,
        items: items,
        scannedBytes: decoded['scannedBytes'] as int? ?? 0,
        nextSequence: decoded['nextSequence'] as int? ?? items.length,
        pendingTools: {
          for (final entry in (decoded['pending'] as Map? ?? const {}).entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        },
        pathedTools: {
          for (final id in (decoded['pathed'] as List? ?? const []))
            if (id is String) id,
        },
      );
    } catch (_) {
      // A manifest we cannot read is the same answer as one that is not there:
      // the transcript is the source of truth and can always be read again.
      return null;
    }
  }

  /// Everything [transcriptPath] holds, scanning only what has not been scanned
  /// already.
  ///
  /// Pass [previous] to continue from a scan already in hand — the provider
  /// keeps the last one so a poll costs a `stat()` and nothing else. Omit it
  /// and the manifest on disk is used instead.
  Future<SessionMediaScan> refresh(
    String transcriptPath,
    String cli, {
    SessionMediaScan? previous,
  }) async {
    final nothing = SessionMediaScan(
      transcriptPath: transcriptPath,
      items: const [],
      scannedBytes: 0,
    );
    // Antigravity's own file is a SQLite database whose message columns are
    // protobuf in an unpublished schema — refused by name for exactly the
    // reason `readCliTranscript` refuses it, rather than read as UTF-8 lines
    // and arriving at the same empty answer by throwing.
    if (cli == AgentIds.antigravity) return nothing;

    final file = File(transcriptPath);
    final int length;
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        return previous ?? nothing;
      }
      length = stat.size;
    } catch (_) {
      // A locked file, or a share that went away. Whatever we already had is a
      // better answer than an empty panel.
      return previous ?? nothing;
    }

    var base = previous ?? await load(transcriptPath);
    if (base != null &&
        (base.transcriptPath != transcriptPath || base.scannedBytes > length)) {
      // The file is shorter than what was scanned, so it is not the same file
      // grown — it was rewritten, and every position in it now means something
      // else.
      base = null;
    }
    if (base != null && base.scannedBytes == length) return base.unchanged();
    // A scan starting from zero has to start from zero on disk too: the
    // extracted copies are named by **position in the file**, so a rewritten
    // transcript would otherwise be given the old picture for the new position.
    if (base == null) await _purge(transcriptPath);

    final scan = await _scan(file, cli, from: base);
    await _writeManifest(scan);
    return scan;
  }

  // ---------------------------------------------------------------------------
  // The pass itself
  // ---------------------------------------------------------------------------

  Future<SessionMediaScan> _scan(
    File file,
    String cli, {
    required SessionMediaScan? from,
  }) async {
    final items = <SessionMediaItem>[...?from?.items];
    final pending = _PendingCalls(
      names: from?.pendingTools,
      pathed: from?.pathedTools,
    );
    var sequence = from?.nextSequence ?? 0;
    var scanned = from?.scannedBytes ?? 0;
    var bytesRead = 0;
    var linesDecoded = 0;
    var bytesExtracted = 0;

    Future<void> decode(String line) async {
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        return;
      }
      linesDecoded++;
      if (decoded is! Map) return;
      final at = _timestampOf(decoded);
      final found = cli == AgentIds.codex
          ? _codexBlocks(decoded)
          : _claudeBlocks(decoded, pending);
      for (final block in found) {
        final item = await _itemFor(
          block,
          sequence: sequence,
          at: at,
          transcriptPath: file.path,
        );
        sequence++;
        bytesExtracted += item.extracted;
        items.add(item.item);
      }
    }

    Future<void>? handle(String line, int endOffset) {
      scanned = endOffset;
      if (line.isEmpty || !_mightHoldMedia(line)) return null;
      return decode(line);
    }

    try {
      bytesRead = await _readLines(file, from: scanned, onLine: handle);
    } catch (_) {
      // Truncated or locked mid-read: keep whatever the pass reached. `scanned`
      // only ever advances past a *complete* line, so the next pass picks up
      // exactly where this one stopped.
    }

    await _pruneToCap(items);
    return SessionMediaScan(
      transcriptPath: file.path,
      items: items,
      scannedBytes: scanned,
      nextSequence: sequence,
      pendingTools: _bounded(pending.names),
      pathedTools: _boundedSet(pending.pathed),
      bytesRead: bytesRead,
      linesDecoded: linesDecoded,
      bytesExtracted: bytesExtracted,
    );
  }

  /// Walks [file] from byte [from], handing complete lines to [onLine] with the
  /// byte offset just past each one. Returns the bytes read from disk.
  ///
  /// Deliberately **not** `openRead().transform(utf8.decoder).transform(const
  /// LineSplitter())`, which is what the transcript reader uses: that pipeline
  /// throws the byte offsets away, and the offsets are what make a rescan cost
  /// the size of the append instead of the size of the file. A trailing partial
  /// line — a transcript caught mid-write — is left unscanned so the next pass
  /// reads it whole.
  static Future<int> _readLines(
    File file, {
    required int from,
    required Future<void>? Function(String line, int endOffset) onLine,
  }) async {
    var read = 0;
    var chunkOffset = from;
    final partial = BytesBuilder(copy: false);
    await for (final raw in file.openRead(from)) {
      final chunk = raw is Uint8List ? raw : Uint8List.fromList(raw);
      read += chunk.length;
      var lineStart = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        final segment = Uint8List.sublistView(chunk, lineStart, i);
        final String line;
        if (partial.isEmpty) {
          line = utf8.decode(segment, allowMalformed: true);
        } else {
          partial.add(segment);
          line = utf8.decode(partial.takeBytes(), allowMalformed: true);
        }
        // `\r\n` transcripts exist; the reader trims nothing, so neither can we.
        final work = onLine(
          line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
          chunkOffset + i + 1,
        );
        if (work != null) await work;
        lineStart = i + 1;
      }
      if (lineStart < chunk.length) {
        partial.add(Uint8List.sublistView(chunk, lineStart));
      }
      chunkOffset += chunk.length;
    }
    return read;
  }

  /// Whether [line] can possibly hold a picture, or name the tool that
  /// produced one.
  ///
  /// This is the saving that keeps a first open cheap: a conversation is mostly
  /// plain turns and tool *output*, and `jsonDecode` on one of those is pure
  /// cost — the big ones especially, since a `Read` of a large file is
  /// megabytes of result. Safe by construction on all three sources:
  ///
  /// * a base64 block always carries the word `image`, in its own `type` and
  ///   again in `media_type`;
  /// * a tool call whose input names an image always carries that extension;
  /// * a call that will *answer* with a picture is a `tool_use` block, and the
  ///   quoted token `"tool_use"` appears in one and in nothing else — notably
  ///   not in a result's `"tool_use_id"`, where the next character is `_`.
  ///   That last clause is what lets a screenshot be labelled with the tool
  ///   that took it instead of just "Screenshot".
  static bool _mightHoldMedia(String line) =>
      _mediaBlock.hasMatch(line) || _toolCall.hasMatch(line);

  /// A picture's own block `type`, never the bare word: a transcript about a
  /// Godot art project says "image" in prose on half its lines, and a file
  /// listing prints `.png` on hundreds more. Matching either of those parsed
  /// 5388 lines of one transcript where 36 held a picture.
  static final _mediaBlock = RegExp(r'"type"\s*:\s*"(input_)?image"');

  /// A **call**, never its answer. `"tool_use"` cannot match a result's
  /// `"tool_use_id"` (the next character is `_`), and neither can
  /// `"function_call"` match `"function_call_output"` — which matters, because
  /// results are the megabyte lines and calls are not.
  static final _toolCall = RegExp(
    r'"(tool_use|function_call|custom_tool_call)"',
  );

  /// When the line says it happened, normalised to UTC — the panel measures
  /// ages against `Clock.nowUtc`, and a timestamp written without a zone would
  /// otherwise be read as local and come out hours wrong.
  static DateTime? _timestampOf(Map<Object?, Object?> json) {
    final value = json['timestamp'];
    return value is String ? DateTime.tryParse(value)?.toUtc() : null;
  }

  // ---------------------------------------------------------------------------
  // What each CLI's record looks like
  // ---------------------------------------------------------------------------

  /// The pictures in one Claude Code line.
  ///
  /// Three shapes, which are the three ways a session acquires one — all three
  /// read off real transcripts in `~/.claude/projects`, not off the docs:
  ///
  /// * `tool_use` whose input names an image file — an agent **read** a
  ///   picture. Recognised by [toolActivityFor], so the panel and the
  ///   transcript agree on what counts as an image path.
  /// * an `image` block a person put into the conversation — a **paste**. Two
  ///   shapes, and the second is the common one: `message.content` on a `user`
  ///   line, *and* `attachment.prompt` on a line whose top-level `type` is
  ///   `attachment`. Eight of the nine pastes in one real 11 600-line
  ///   transcript are the latter, so reading only `message.content` finds
  ///   almost none of them — which would be the owner's complaint over again.
  /// * an `image` block inside a `tool_result` — a tool **answered** with a
  ///   picture. `device_screenshot`, `browser_screenshot` and `browser_capture`
  ///   all do this; only the first also leaves a copy in the temp directory, so
  ///   the block is the one source that covers all three.
  static List<_Block> _claudeBlocks(
    Map<Object?, Object?> json,
    _PendingCalls pending,
  ) {
    final blocks = <_Block>[];
    final message = json['message'];
    if (message is Map && message['content'] is List) {
      final before = blocks.length;
      _claudeContent(message['content']! as List, pending, blocks);
      _numberPastes(blocks, before, json['imagePasteIds']);
    }
    // A queued prompt is not a `user` line at all — see above.
    final attachment = json['attachment'];
    if (attachment is Map) {
      final before = blocks.length;
      for (final key in const ['prompt', 'content']) {
        final list = attachment[key];
        if (list is! List) continue;
        for (final part in list) {
          if (part is Map && part['type'] == 'image') {
            blocks.add(_Block.bytes(part, SessionMediaOrigin.pasted));
          }
        }
      }
      // The ids hang off the attachment on this shape, not off the record.
      _numberPastes(blocks, before, attachment['imagePasteIds']);
    }
    return blocks;
  }

  /// Gives the pastes found since [from] the numbers the CLI printed for them.
  ///
  /// `imagePasteIds` is Claude Code's own record of what it wrote into the pane
  /// as `[Image #N]` — the only exact key there is, because the counter is the
  /// CLI process's and agrees with no ordinal we could compute. See
  /// `session_image_reference.dart` for the transcripts that establish that.
  ///
  /// Paired **positionally**, and only when the two lists are the same length.
  /// A record that does not line up is left unnumbered rather than guessed at:
  /// an id on the wrong picture is a Ctrl+click that opens the wrong picture,
  /// which is the one outcome worse than a reference that will not resolve.
  static void _numberPastes(List<_Block> blocks, int from, Object? raw) {
    if (raw is! List) return;
    final ids = [
      for (final id in raw)
        if (id is int) id,
    ];
    if (ids.length != raw.length) return;
    final pasted = [
      for (var i = from; i < blocks.length; i++)
        if (blocks[i].origin == SessionMediaOrigin.pasted) blocks[i],
    ];
    if (pasted.length != ids.length) return;
    for (var i = 0; i < ids.length; i++) {
      pasted[i].pasteId = ids[i];
    }
  }

  static void _claudeContent(
    List<Object?> content,
    _PendingCalls pending,
    List<_Block> blocks,
  ) {
    for (final part in content) {
      if (part is! Map) continue;
      switch (part['type']) {
        case 'tool_use':
          final name = part['name'];
          if (name is! String) continue;
          final path = toolActivityFor(name, part['input']).imagePath;
          final id = part['id'];
          if (id is String) {
            pending.names[id] = name;
            if (path != null) pending.pathed.add(id);
          }
          if (path != null) blocks.add(_Block.path(path, tool: name));
        case 'image':
          blocks.add(_Block.bytes(part, SessionMediaOrigin.pasted));
        case 'tool_result':
          final id = part['tool_use_id'];
          final tool = id is String ? pending.names.remove(id) : null;
          // Claude Code answers `Read(shot.png)` with the file's bytes as an
          // `image` block, so the same picture is in the transcript twice: once
          // as a path in the call, once as ~300 KB of base64 in the answer.
          // Every one of the 20 tool_result images in one real transcript is a
          // `Read` like this. The **file wins**: it is already on disk under a
          // name that means something, listing both would double the panel, and
          // extracting the copies would have written 6 MB of cache for one
          // session. This is the same call `cli_transcript_reader.dart` makes,
          // for the same reason.
          if (id is String && pending.pathed.remove(id)) continue;
          final result = part['content'];
          if (result is! List) continue;
          for (final inner in result) {
            if (inner is Map && inner['type'] == 'image') {
              blocks.add(
                _Block.bytes(inner, SessionMediaOrigin.captured, tool: tool),
              );
            }
          }
      }
    }
  }

  /// The pictures in one Codex line. **Best effort.**
  ///
  /// Codex records a rollout as `payload`-wrapped response items; a picture
  /// arrives as an `input_image` whose `image_url` is a `data:` URI, and a tool
  /// call's `arguments` is a JSON string that may name a file. Neither shape
  /// has been checked against a real store the way the Claude one has, so this
  /// is written to find nothing rather than to guess wrong.
  static List<_Block> _codexBlocks(Map<Object?, Object?> json) {
    final payload = json['payload'];
    if (payload is! Map) return const [];
    final blocks = <_Block>[];
    switch (payload['type']) {
      case 'message':
        final content = payload['content'];
        if (content is! List) return const [];
        for (final part in content) {
          if (part is! Map) continue;
          if (part['type'] != 'input_image' && part['type'] != 'image') {
            continue;
          }
          final url = part['image_url'] ?? part['url'];
          if (url is! String) continue;
          final data = _dataUri(url);
          if (data != null) {
            blocks.add(
              _Block.inline(data.$1, data.$2, SessionMediaOrigin.pasted),
            );
          } else if (looksLikeImagePath(url)) {
            blocks.add(_Block.path(url));
          }
        }
      case 'function_call':
      case 'custom_tool_call':
        final name = payload['name'];
        final arguments = payload['arguments'];
        if (arguments is! String) return const [];
        final Object? decoded;
        try {
          decoded = jsonDecode(arguments);
        } on FormatException {
          return const [];
        }
        final path = toolActivityFor(
          name is String ? name : 'tool',
          decoded,
        ).imagePath;
        if (path != null) {
          blocks.add(_Block.path(path, tool: name is String ? name : null));
        }
    }
    return blocks;
  }

  /// The media type and payload of a `data:image/png;base64,…` URI.
  static (String, String)? _dataUri(String value) {
    if (!value.startsWith('data:')) return null;
    final comma = value.indexOf(',');
    if (comma < 0) return null;
    final head = value.substring(5, comma);
    if (!head.endsWith(';base64')) return null;
    return (head.substring(0, head.length - 7), value.substring(comma + 1));
  }

  // ---------------------------------------------------------------------------
  // Turning a block into something the panel can draw
  // ---------------------------------------------------------------------------

  Future<_Extracted> _itemFor(
    _Block block, {
    required int sequence,
    required DateTime? at,
    required String transcriptPath,
  }) async {
    final id = 'm$sequence';
    if (block.path != null) {
      return _Extracted(
        SessionMediaItem(
          id: id,
          origin: SessionMediaOrigin.read,
          sequence: sequence,
          path: block.path,
          // Written by the agent, in the agent's environment.
          fromAgentEnvironment: true,
          toolName: block.tool,
          at: at,
        ),
        0,
      );
    }

    final data = block.data;
    if (data == null || data.isEmpty) {
      // A `url` source, or a shape we do not know. Listed anyway: a picture the
      // panel cannot show is still one the session had.
      return _Extracted(
        SessionMediaItem(
          id: id,
          origin: block.origin,
          sequence: sequence,
          toolName: block.tool,
          at: at,
          problem: 'That image was not stored in the transcript.',
          pasteId: block.pasteId,
        ),
        0,
      );
    }

    // The size, before anything is decoded: base64 is four characters per three
    // bytes, so the file's weight is arithmetic on the string's length. This is
    // what stops a 40 MB paste from ever being materialised.
    final bytes = _base64Bytes(data);
    if (bytes > maxItemBytes) {
      return _Extracted(
        SessionMediaItem(
          id: id,
          origin: block.origin,
          sequence: sequence,
          toolName: block.tool,
          at: at,
          bytes: bytes,
          problem:
              'That image is too large to preview here '
              '(${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB).',
          pasteId: block.pasteId,
        ),
        0,
      );
    }

    final extension = kMediaTypeExtensions[block.mediaType?.toLowerCase()];
    // Named for what it is, not just numbered. The panel hands this path to
    // `TranscriptImagePreview`, whose accessible name is the file's — so
    // "Open image pasted-3.png" is what a screen reader announces, where a bare
    // "3.png" would say nothing at all.
    final file = File(
      '${_cacheDir(transcriptPath).path}/'
      '${_slug(block.tool ?? block.origin.name)}-$sequence.'
      '${extension ?? 'png'}',
    );
    var written = 0;
    try {
      // Already extracted by an earlier pass: the position in the file is what
      // names it, so this costs a `stat()` and no decode at all.
      if (!await file.exists()) {
        await file.parent.create(recursive: true);
        final decoded = base64Decode(data);
        await file.writeAsBytes(decoded, flush: true);
        written = decoded.length;
      }
    } catch (_) {
      return _Extracted(
        SessionMediaItem(
          id: id,
          origin: block.origin,
          sequence: sequence,
          toolName: block.tool,
          at: at,
          bytes: bytes,
          problem: 'That image could not be read.',
          pasteId: block.pasteId,
        ),
        0,
      );
    }
    return _Extracted(
      SessionMediaItem(
        id: id,
        origin: block.origin,
        sequence: sequence,
        path: file.path,
        toolName: block.tool,
        at: at,
        bytes: bytes,
        pasteId: block.pasteId,
      ),
      written,
    );
  }

  /// A file-name-safe form of a tool name: `mcp__karmashala__device_screenshot`
  /// becomes `device_screenshot`, and anything a file system would object to
  /// becomes an underscore.
  static String _slug(String value) {
    final last = value.lastIndexOf('__');
    final short = last < 0 ? value : value.substring(last + 2);
    final safe = short.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? 'image' : safe;
  }

  /// The decoded size of a base64 payload, without decoding it.
  static int _base64Bytes(String data) {
    final length = data.length;
    if (length < 4) return 0;
    var padding = 0;
    if (data.codeUnitAt(length - 1) == 0x3D) padding++;
    if (data.codeUnitAt(length - 2) == 0x3D) padding++;
    return (length ~/ 4) * 3 - padding;
  }

  // ---------------------------------------------------------------------------
  // Housekeeping
  // ---------------------------------------------------------------------------

  /// Bumped to 2 when [SessionMediaItem.pasteId] arrived: a manifest written
  /// before it has no ids in it, and an item with no id is one a `[Image #N]`
  /// cannot resolve to. A version change forces one rescan, which is the whole
  /// cost of making every existing session's references clickable.
  static const _manifestVersion = 2;

  /// How many outstanding tool calls to carry between passes. A `tool_use` and
  /// the `tool_result` that answers it can straddle the boundary of an append,
  /// so the name has to survive; an id whose result never arrives simply ages
  /// out instead of accumulating for the life of the session.
  static const _maxPendingTools = 64;

  static Map<String, String> _bounded(Map<String, String> pending) {
    if (pending.length <= _maxPendingTools) return pending;
    final keys = pending.keys.toList();
    return {
      for (final key in keys.sublist(keys.length - _maxPendingTools))
        key: pending[key]!,
    };
  }

  static Set<String> _boundedSet(Set<String> ids) {
    if (ids.length <= _maxPendingTools) return ids;
    final all = ids.toList();
    return all.sublist(all.length - _maxPendingTools).toSet();
  }

  /// Drops the oldest items past [cap], and the files they were pointing at.
  Future<void> _pruneToCap(List<SessionMediaItem> items) async {
    if (items.length <= cap) return;
    final dropped = items.sublist(0, items.length - cap);
    items.removeRange(0, items.length - cap);
    for (final item in dropped) {
      final path = item.path;
      // Only ever our own copies: a file the *agent* read is not ours to delete.
      if (path == null || item.fromAgentEnvironment) continue;
      if (!path.startsWith(cacheRoot.path)) continue;
      try {
        await File(path).delete();
      } catch (_) {
        // A copy we cannot delete is a few KB, not a correctness problem.
      }
    }
  }

  /// Forgets everything extracted for [transcriptPath].
  ///
  /// Called only when a full rescan is about to happen, and for a reason: the
  /// extracted copies are named by **position in the file**, so a transcript
  /// that was rewritten rather than appended to would otherwise hand the panel
  /// the old picture for the new position.
  Future<void> _purge(String transcriptPath) async {
    try {
      final dir = _cacheDir(transcriptPath);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Left behind rather than failing the open; the names are deterministic,
      // so the worst case is a stale copy that the next successful purge fixes.
    }
  }

  Future<void> _writeManifest(SessionMediaScan scan) async {
    try {
      final file = _manifestFile(scan.transcriptPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': _manifestVersion,
          'path': scan.transcriptPath,
          'scannedBytes': scan.scannedBytes,
          'nextSequence': scan.nextSequence,
          'pending': scan.pendingTools,
          'pathed': scan.pathedTools.toList(),
          'items': [for (final item in scan.items) item.toJson()],
        }),
        flush: true,
      );
    } catch (_) {
      // Without a manifest the next open re-reads the file, which is slower and
      // still correct. Not worth failing the panel for.
    }
  }

  Directory _cacheDir(String transcriptPath) =>
      Directory('${cacheRoot.path}/${_keyFor(transcriptPath)}');

  File _manifestFile(String transcriptPath) =>
      File('${cacheRoot.path}/${_keyFor(transcriptPath)}.json');

  /// A file-name-safe key for a transcript path. FNV-1a, because this names a
  /// cache directory and nothing depends on it being unguessable.
  static String _keyFor(String path) {
    var hash = 0xcbf29ce484222325;
    for (final unit in path.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
      hash &= 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

/// The result of one pass, plus what that pass cost.
///
/// The cost fields describe **this pass only** and are not written to the
/// manifest: they exist so `session_media_cost_test.dart` can assert the shape
/// of the work in a unit a busy machine cannot move — bytes read, lines parsed,
/// bytes written — rather than with a stopwatch.
class SessionMediaScan {
  const SessionMediaScan({
    required this.transcriptPath,
    required this.items,
    required this.scannedBytes,
    this.nextSequence = 0,
    this.pendingTools = const {},
    this.pathedTools = const {},
    this.bytesRead = 0,
    this.linesDecoded = 0,
    this.bytesExtracted = 0,
  });

  final String transcriptPath;

  /// Oldest first — the order the transcript records them, which is the order
  /// the next pass has to continue.
  final List<SessionMediaItem> items;

  /// How far into the transcript this scan got, in bytes, always at a line
  /// boundary. The next pass starts here.
  final int scannedBytes;

  /// The sequence the next picture found will be given.
  final int nextSequence;

  /// Outstanding `tool_use` ids and the tool that made them, so a `tool_result`
  /// in the next append can still be attributed.
  final Map<String, String> pendingTools;

  /// Outstanding `tool_use` ids whose call already named an image **file**, so
  /// the base64 copy in the answer is skipped even when a poll catches the file
  /// between the two lines.
  final Set<String> pathedTools;

  final int bytesRead;
  final int linesDecoded;
  final int bytesExtracted;

  /// What the panel shows: newest first, which is what the owner asked for.
  List<SessionMediaItem> get newestFirst =>
      items.reversed.toList(growable: false);

  /// The same scan, with this pass's cost zeroed — the answer for a transcript
  /// that has not changed since it was last read.
  SessionMediaScan unchanged() => SessionMediaScan(
    transcriptPath: transcriptPath,
    items: items,
    scannedBytes: scannedBytes,
    nextSequence: nextSequence,
    pendingTools: pendingTools,
    pathedTools: pathedTools,
  );
}

/// The `tool_use` calls this pass has seen but not yet seen answered.
///
/// Carried between passes through the manifest, because a poll can catch the
/// transcript between a call and its answer and both facts are needed when the
/// answer finally lands: which tool to name a screenshot after, and whether the
/// call already gave us the file so the copy in the answer can be skipped.
class _PendingCalls {
  _PendingCalls({Map<String, String>? names, Set<String>? pathed})
    : names = {...?names},
      pathed = {...?pathed};

  final Map<String, String> names;
  final Set<String> pathed;
}

/// A picture found in one line, before it is resolved to something drawable.
class _Block {
  _Block._({
    required this.origin,
    this.path,
    this.data,
    this.mediaType,
    this.tool,
  });

  /// A tool call that named an image file.
  factory _Block.path(String path, {String? tool}) =>
      _Block._(origin: SessionMediaOrigin.read, path: path, tool: tool);

  /// An Anthropic content block: `{type:'image', source:{type:'base64', …}}`,
  /// or the raw MCP shape `{type:'image', data, mimeType}` some records carry.
  factory _Block.bytes(
    Map<Object?, Object?> block,
    SessionMediaOrigin origin, {
    String? tool,
  }) {
    final source = block['source'];
    if (source is Map && source['type'] == 'base64') {
      return _Block._(
        origin: origin,
        data: source['data'] is String ? source['data'] as String : null,
        mediaType: source['media_type'] is String
            ? source['media_type'] as String
            : null,
        tool: tool,
      );
    }
    return _Block._(
      origin: origin,
      data: block['data'] is String ? block['data'] as String : null,
      mediaType: block['mimeType'] is String
          ? block['mimeType'] as String
          : null,
      tool: tool,
    );
  }

  factory _Block.inline(
    String mediaType,
    String data,
    SessionMediaOrigin origin,
  ) => _Block._(origin: origin, data: data, mediaType: mediaType);

  final SessionMediaOrigin origin;
  final String? path;
  final String? data;
  final String? mediaType;
  final String? tool;

  /// The `[Image #N]` number, filled in by [SessionMediaStore._numberPastes].
  ///
  /// Not final and not a constructor argument, because the id is a property of
  /// the **line** rather than of the block: it is only knowable once every
  /// picture on that line has been found and can be counted off against
  /// `imagePasteIds`.
  int? pasteId;
}

/// An item, and how many bytes producing it wrote out.
class _Extracted {
  const _Extracted(this.item, this.extracted);
  final SessionMediaItem item;
  final int extracted;
}
