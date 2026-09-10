import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/stream.dart';
import '../domain/session_media_item.dart';

/// A session's pictures, with base64-only ones written to disk one at a time;
/// resumable, and bounded by [kMaxSessionMediaBytes] and [kSessionMediaCap].
class SessionMediaStore {
  SessionMediaStore(
    this.cacheRoot, {
    this.cap = kSessionMediaCap,
    this.maxItemBytes = kMaxSessionMediaBytes,
  });

  /// Where extracted pictures and the manifest live — application support, not
  /// temp, so a picture on screen outlives a reboot's temp sweep.
  final Directory cacheRoot;

  /// How many pictures to keep; the oldest are dropped with their copies.
  final int cap;

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
      // Unreadable manifest reads the same as none: the transcript is truth.
      return null;
    }
  }

  /// Everything [transcriptPath] holds, scanning only what is new. Pass
  /// [previous] to continue from a scan in hand; omit it to read the manifest.
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
    // Antigravity's transcript is a SQLite database of protobuf in an
    // unpublished schema; refused by name, as `readCliTranscript` refuses it.
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
      // Locked file, or a share that went away; what we had beats an empty
      // panel.
      return previous ?? nothing;
    }

    var base = previous ?? await load(transcriptPath);
    if (base != null &&
        (base.transcriptPath != transcriptPath || base.scannedBytes > length)) {
      // Shorter than what was scanned: rewritten, so every offset now lies.
      base = null;
    }
    if (base != null && base.scannedBytes == length) return base.unchanged();
    // Copies are named by position in the file, so a rewrite must start clean.
    if (base == null) await _purge(transcriptPath);

    final scan = await _scan(file, cli, from: base);
    await _writeManifest(scan);
    return scan;
  }

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
      // `scanned` only advances past a complete line, so the next pass resumes
      // exactly here.
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

  /// Complete lines of [file] from byte [from] to [onLine], with the offset
  /// past each; hand-rolled so a rescan costs the append, not the file.
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

  /// Whether [line] can possibly hold a picture or name the tool that made
  /// one — the filter that keeps `jsonDecode` off the megabyte result lines.
  static bool _mightHoldMedia(String line) =>
      _mediaBlock.hasMatch(line) || _toolCall.hasMatch(line);

  /// A picture's own block `type`, never the bare word: matching prose "image"
  /// or `.png` parsed 5388 lines of one transcript where 36 held a picture.
  static final _mediaBlock = RegExp(r'"type"\s*:\s*"(input_)?image"');

  /// A **call**, never its answer: `"tool_use"` cannot match `"tool_use_id"`,
  /// and results are the megabyte lines while calls are not.
  static final _toolCall = RegExp(
    r'"(tool_use|function_call|custom_tool_call)"',
  );

  /// When the line says it happened, in UTC — a zone-less timestamp read as
  /// local comes out hours wrong against `Clock.nowUtc`.
  static DateTime? _timestampOf(Map<Object?, Object?> json) {
    final value = json['timestamp'];
    return value is String ? DateTime.tryParse(value)?.toUtc() : null;
  }

  /// The pictures in one line: a `tool_use` naming a file, a paste (usually on
  /// `attachment.prompt`, not `message.content`), or a `tool_result` image.
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
    // A queued prompt is not a `user` line at all.
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

  /// Gives pastes since [from] the `[Image #N]` ids the CLI printed, paired
  /// positionally and only on equal lengths — a wrong id opens a wrong picture.
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
          // Claude answers `Read(shot.png)` with the file's bytes too, so the
          // same picture is in the transcript twice; the file on disk wins.
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

  /// The pictures in one Codex line. Best effort: unverified against a real
  /// store, so written to find nothing rather than to guess wrong.
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

  static (String, String)? _dataUri(String value) {
    if (!value.startsWith('data:')) return null;
    final comma = value.indexOf(',');
    if (comma < 0) return null;
    final head = value.substring(5, comma);
    if (!head.endsWith(';base64')) return null;
    return (head.substring(0, head.length - 7), value.substring(comma + 1));
  }

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
          fromAgentEnvironment: true,
          toolName: block.tool,
          at: at,
        ),
        0,
      );
    }

    final data = block.data;
    if (data == null || data.isEmpty) {
      // A `url` source, or a shape we do not know; listed anyway.
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

    // Arithmetic on the base64 length, so a huge paste is never materialised.
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
    // Named, not just numbered: the panel hands this path to
    // `TranscriptImagePreview`, whose accessible name is the file's.
    final file = File(
      '${_cacheDir(transcriptPath).path}/'
      '${_slug(block.tool ?? block.origin.name)}-$sequence.'
      '${extension ?? 'png'}',
    );
    var written = 0;
    try {
      // Named by position in the file, so an earlier pass's copy is reusable.
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

  /// A file-name-safe tool name: `mcp__karmashala__device_screenshot` becomes
  /// `device_screenshot`.
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

  /// Bumped to 2 for [SessionMediaItem.pasteId]: an older manifest has no ids,
  /// so a version change forces the one rescan that makes them clickable.
  static const _manifestVersion = 2;

  /// How many outstanding tool calls carry between passes; a call and its
  /// result can straddle an append, and unanswered ids age out.
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

  /// Forgets everything extracted for [transcriptPath]. Only before a full
  /// rescan: copies are named by position, so a rewrite would mismatch them.
  Future<void> _purge(String transcriptPath) async {
    try {
      final dir = _cacheDir(transcriptPath);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // The names are deterministic, so the next successful purge fixes this.
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
      // The next open re-reads the file: slower, still correct.
    }
  }

  Directory _cacheDir(String transcriptPath) =>
      Directory('${cacheRoot.path}/${_keyFor(transcriptPath)}');

  File _manifestFile(String transcriptPath) =>
      File('${cacheRoot.path}/${_keyFor(transcriptPath)}.json');

  /// A file-name-safe key for a transcript path; FNV-1a, not a secret.
  static String _keyFor(String path) {
    var hash = 0xcbf29ce484222325;
    for (final unit in path.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
      hash &= 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

/// The result of one pass, plus what that pass cost. The cost fields describe
/// this pass only and are not written to the manifest.
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

  /// Oldest first — the order the next pass has to continue from.
  final List<SessionMediaItem> items;

  /// How far this scan got, in bytes, always at a line boundary.
  final int scannedBytes;

  final int nextSequence;

  /// Outstanding `tool_use` ids and their tool, so a `tool_result` in the next
  /// append is still attributable.
  final Map<String, String> pendingTools;

  /// Outstanding ids whose call already named an image file, so the base64
  /// copy in the answer is skipped.
  final Set<String> pathedTools;

  final int bytesRead;
  final int linesDecoded;
  final int bytesExtracted;

  List<SessionMediaItem> get newestFirst =>
      items.reversed.toList(growable: false);

  /// The same scan with this pass's cost zeroed — the unchanged answer.
  SessionMediaScan unchanged() => SessionMediaScan(
    transcriptPath: transcriptPath,
    items: items,
    scannedBytes: scannedBytes,
    nextSequence: nextSequence,
    pendingTools: pendingTools,
    pathedTools: pathedTools,
  );
}

/// The `tool_use` calls seen but not yet answered; carried between passes so a
/// screenshot can still be named and a duplicated file copy still skipped.
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

  /// The `[Image #N]` number, filled in by [SessionMediaStore._numberPastes];
  /// mutable because it is knowable only once the whole line has been read.
  int? pasteId;
}

/// An item, and how many bytes producing it wrote out.
class _Extracted {
  const _Extracted(this.item, this.extracted);
  final SessionMediaItem item;
  final int extracted;
}
