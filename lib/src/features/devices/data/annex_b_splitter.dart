// Splits an unframed H.264 Annex-B byte stream into access units.
//
// `idb_companion`'s gRPC `video_stream` hands back raw Annex-B with **no
// framing of its own**: no length prefixes, no packet headers, no timestamps.
// The chunk boundaries are wherever gRPC happened to cut, so a start code
// routinely arrives split across two chunks. That is the opposite of the scrcpy
// path, where `ScrcpyStreamParser` is handed an explicit length and flags per
// packet and only has to reassemble.
//
// Everything downstream — `TsMuxer`, the loopback server, the player — already
// eats `VideoAccessUnit`: Annex-B bytes, a microsecond PTS, a keyframe flag. So
// this class is the whole of the adaptation, and it is a pure, unit-tested
// parser rather than inline stream handling because every mistake here is
// silent: a start code missed at a chunk boundary splits one frame into two
// half-frames that the muxer happily wraps in valid PES packets, and the viewer
// sees a green smear with no error anywhere in the logs.

import 'dart:typed_data';

import '../domain/simulator_backend.dart';

/// NAL unit types this parser distinguishes (low 5 bits of the header byte).
const int _nalNonIdrSlice = 1;
const int _nalIdrSlice = 5;
const int _nalSps = 7;
const int _nalPps = 8;

/// How much unemitted data may pile up before the parser resyncs.
///
/// This is a safety valve, not a tuning knob. Bytes arriving *before* the first
/// start code cannot accumulate — they are compacted away on every chunk — so
/// the only shape that can grow without limit is a NAL that opens and never
/// closes: a stream that desynced onto a start code inside a payload, or bytes
/// that are not H.264 at all. A 1080p keyframe out of VideoToolbox is a few
/// hundred kB, so 8 MiB is roughly twenty keyframes of headroom and cannot be
/// reached by an honest frame. Past it we are holding data that will never be
/// delimited: keeping it leaks for the life of the session while emitting
/// nothing, so it is dropped and the parser hunts for the next start code.
const int kMaxPendingBytes = 8 * 1024 * 1024;

/// Cuts an Annex-B stream into [VideoAccessUnit]s as bytes arrive.
///
/// Feed it whatever the socket gives you; it returns the access units that are
/// now complete. An access unit is only complete once the *next* one's start
/// code has arrived — nothing in Annex-B marks an end — so the last frame of a
/// stream comes out of [flush], not [add].
///
/// **Timestamps are synthesised.** idb's stream carries none at all, so each
/// access unit is stamped with the value of [clockUs] at the moment it was
/// delimited, relative to the first unit emitted. Those are *arrival* times,
/// not capture times: they inherit the encoder's queueing, the gRPC hop and our
/// own scheduling, so playback jitters by however much those jitter, and a
/// frame that the simulator encoded early but delivered late is timed late. For
/// a live view that is the right trade — there is no other clock available and
/// the alternative is no PTS at all — but it is not good enough to record from.
class AnnexBSplitter {
  AnnexBSplitter({
    int Function()? clockUs,
    this.maxPendingBytes = kMaxPendingBytes,
  }) : _clockUs = clockUs ?? _wallClockUs;

  static int _wallClockUs() => DateTime.now().microsecondsSinceEpoch;

  final int Function() _clockUs;

  /// See [kMaxPendingBytes]. Injectable so the resync path is testable without
  /// pushing eight megabytes through a unit test.
  final int maxPendingBytes;

  /// Bytes received but not yet cut into a NAL unit. Compacted after every
  /// [add], so it only ever holds the NAL currently being received.
  Uint8List _buffer = Uint8List(0);

  /// Where the current, still-incomplete NAL's start code begins in [_buffer],
  /// or -1 while we are still hunting for the first start code of the stream.
  int _nalStart = -1;

  /// Where the next start-code search resumes. Never rewinds, so a chunk that
  /// arrives byte by byte costs the same scan as one that arrives whole.
  int _scanPos = 0;

  /// NALs collected for the access unit being assembled, start codes included.
  final BytesBuilder _pendingAu = BytesBuilder();
  bool _pendingHasVcl = false;
  bool _pendingIsKey = false;
  bool _auHasSps = false;
  bool _auHasPps = false;

  /// The most recent SPS and PPS seen anywhere in the stream, each with its own
  /// start code. Sticky across access units: idb sends them once at the head of
  /// the stream and then never again, so the copy kept here is the only one
  /// that will ever exist.
  Uint8List? _sps;
  Uint8List? _pps;

  /// The SPS+PPS pair already published as a codec-config unit. Compared by
  /// value so a stream that repeats identical parameter sets before every
  /// keyframe — which most encoders do — publishes them once, not once a
  /// second, while a genuine change (a rotation, a resolution change) does
  /// republish.
  Uint8List? _publishedConfig;

  int? _baseUs;

  /// Feeds [chunk] and returns every access unit that is now complete.
  ///
  /// Order is stream order: a codec-config unit always precedes the access unit
  /// whose parameter sets it carries.
  List<VideoAccessUnit> add(List<int> chunk) {
    if (chunk.isEmpty) return const <VideoAccessUnit>[];
    final out = <VideoAccessUnit>[];
    _append(chunk);
    _scan(out);
    _compact();
    _enforceCap();
    return out;
  }

  /// Emits whatever is still pending at end of stream.
  ///
  /// The final NAL has no following start code, so only the end of the stream
  /// can delimit it. Without this the last frame — the one frozen on screen
  /// when a user stops the view — is silently dropped.
  List<VideoAccessUnit> flush() {
    final out = <VideoAccessUnit>[];
    if (_nalStart >= 0 && _buffer.length > _nalStart) {
      _consumeNal(_nalStart, _buffer.length, out);
    }
    _buffer = Uint8List(0);
    _nalStart = -1;
    _scanPos = 0;
    if (_pendingHasVcl) {
      _emitAccessUnit(out);
    } else {
      // Prefix NALs with no picture behind them decode to nothing. Their
      // parameter sets have already been published by _consumeNal if they were
      // new, so there is nothing left worth emitting.
      _resetPending();
    }
    return out;
  }

  void _append(List<int> chunk) {
    if (_buffer.isEmpty) {
      _buffer = Uint8List.fromList(chunk);
      return;
    }
    final grown = Uint8List(_buffer.length + chunk.length)
      ..setRange(0, _buffer.length, _buffer)
      ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
    _buffer = grown;
  }

  void _scan(List<VideoAccessUnit> out) {
    while (true) {
      final found = _findStartCode(_scanPos);
      if (found == null) break;
      final (index, length) = found;
      if (_nalStart < 0) {
        // Anything before the first start code is not a NAL — a truncated
        // stream, a reconnect mid-frame — and there is no honest way to decode
        // it, so it is dropped by _compact rather than prepended to the first
        // real frame.
        _nalStart = index;
      } else {
        _consumeNal(_nalStart, index, out);
        _nalStart = index;
      }
      _scanPos = index + length;
    }
    // The last two bytes can never complete a 3-byte start code, and a fourth
    // byte of context is needed to tell `00 00 00 01` from a NAL that merely
    // ends in a zero, so rewind the resume point to keep three bytes live.
    final tail = _buffer.length - 3;
    if (tail > _scanPos) _scanPos = tail;
  }

  /// Finds the next start code at or after [from], as `(index, length)`.
  ///
  /// Returns the index of its **first** byte: on `00 00 00 01` that is the
  /// leading zero, not the `00 00 01` a naive scan lands on. Getting that wrong
  /// leaves a stray zero on the tail of the previous access unit and strips a
  /// byte off the front of the next one, which is exactly the kind of
  /// off-by-one that still muxes cleanly and still decodes to garbage.
  (int, int)? _findStartCode(int from) {
    final buf = _buffer;
    for (var i = from < 0 ? 0 : from; i + 2 < buf.length; i++) {
      if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) {
        if (i > 0 && buf[i - 1] == 0) return (i - 1, 4);
        return (i, 3);
      }
    }
    return null;
  }

  /// Handles one complete NAL unit, `_buffer[start, end)`, start code included.
  void _consumeNal(int start, int end, List<VideoAccessUnit> out) {
    final startCodeLength = _buffer[start + 2] == 1 ? 3 : 4;
    final headerIndex = start + startCodeLength;
    if (headerIndex >= end) {
      // A start code with no payload byte. Keep the bytes so the stream stays
      // reproducible, but it names no NAL type, so it changes no grouping.
      _pendingAu.add(Uint8List.sublistView(_buffer, start, end));
      return;
    }

    final type = _buffer[headerIndex] & 0x1F;
    final isVcl = type == _nalNonIdrSlice || type == _nalIdrSlice;

    if (isVcl) {
      // A second slice of the *same* picture continues this access unit; a
      // slice that starts at macroblock 0 begins a new one. Splitting a
      // multi-slice frame into two access units would give each half its own
      // PTS and the decoder two half-pictures to show.
      if (_pendingHasVcl && _startsNewPicture(headerIndex, end)) {
        _emitAccessUnit(out);
      }
      _pendingHasVcl = true;
      if (type == _nalIdrSlice) _pendingIsKey = true;
    } else {
      // SPS/PPS/SEI/AUD are prefixes: they belong to the picture that follows,
      // never the one behind them. Seeing one after a slice therefore closes
      // the access unit under construction.
      if (_pendingHasVcl) _emitAccessUnit(out);
    }

    final bytes = Uint8List.sublistView(_buffer, start, end);
    _pendingAu.add(bytes);

    if (type == _nalSps) {
      _sps = Uint8List.fromList(bytes);
      _auHasSps = true;
    } else if (type == _nalPps) {
      _pps = Uint8List.fromList(bytes);
      _auHasPps = true;
    }
    if (type == _nalSps || type == _nalPps) _publishConfig(out);
  }

  /// True when this slice begins a new coded picture.
  ///
  /// `first_mb_in_slice` is the first field of the slice header, an unsigned
  /// Exp-Golomb value, and zero encodes as the single bit `1` — so the top bit
  /// of the byte after the NAL header answers the question without a bit
  /// reader.
  bool _startsNewPicture(int headerIndex, int end) {
    final i = headerIndex + 1;
    if (i >= end) return true;
    return (_buffer[i] & 0x80) != 0;
  }

  /// Publishes SPS+PPS as a codec-config unit the first time they are seen, and
  /// again whenever their bytes change.
  ///
  /// Both are required: an SPS on its own cannot configure a decoder, and
  /// publishing after the SPS and again after the PPS would make the output
  /// depend on where the chunk boundary fell — the one property this parser
  /// exists to guarantee.
  void _publishConfig(List<VideoAccessUnit> out) {
    final sps = _sps;
    final pps = _pps;
    if (sps == null || pps == null) return;
    final candidate = Uint8List(sps.length + pps.length)
      ..setRange(0, sps.length, sps)
      ..setRange(sps.length, sps.length + pps.length, pps);
    final published = _publishedConfig;
    if (published != null && _sameBytes(published, candidate)) return;
    _publishedConfig = candidate;
    out.add(
      VideoAccessUnit(
        bytes: candidate,
        ptsUs: _nextPtsUs(),
        isKeyFrame: false,
        isCodecConfig: true,
      ),
    );
  }

  void _emitAccessUnit(List<VideoAccessUnit> out) {
    if (_pendingAu.isEmpty) {
      _resetPending();
      return;
    }
    var bytes = _pendingAu.toBytes();
    final isKey = _pendingIsKey;

    // Prepend the cached parameter sets to a keyframe that lacks them, the same
    // way `accessUnitFor` in device_stream.dart does for the scrcpy path: a
    // viewer that joins mid-stream gets handed the most recent keyframe, and
    // without SPS/PPS in front of it there is nothing to configure the decoder
    // with. It is done *here* rather than at the muxer because only this class
    // can see whether the keyframe already carries them — idb sends parameter
    // sets exactly once, at the head of the stream, so every later keyframe
    // needs them and the first one does not. Prepending unconditionally would
    // duplicate them on that first keyframe; leaving it to the caller would
    // duplicate them on every keyframe, since the caller cannot look inside.
    final config = _publishedConfig;
    if (isKey && config != null && !(_auHasSps && _auHasPps)) {
      final joined = Uint8List(config.length + bytes.length)
        ..setRange(0, config.length, config)
        ..setRange(config.length, config.length + bytes.length, bytes);
      bytes = joined;
    }

    out.add(
      VideoAccessUnit(
        bytes: bytes,
        ptsUs: _nextPtsUs(),
        isKeyFrame: isKey,
        isCodecConfig: false,
      ),
    );
    _resetPending();
  }

  void _resetPending() {
    _pendingAu.clear();
    _pendingHasVcl = false;
    _pendingIsKey = false;
    _auHasSps = false;
    _auHasPps = false;
  }

  /// Samples the clock once per emitted unit.
  ///
  /// Per *unit* and not per chunk on purpose: the number of chunks depends on
  /// how the socket fragmented, so a per-chunk sample would make the PTS of a
  /// frame depend on the size of the reads, and the same stream would time
  /// differently on a slow link than a fast one.
  int _nextPtsUs() {
    final now = _clockUs();
    final base = _baseUs ??= now;
    return now - base;
  }

  /// Drops everything before the NAL under construction, so the buffer holds
  /// one NAL rather than the whole session.
  void _compact() {
    final keepFrom = _nalStart < 0 ? _scanPos : _nalStart;
    if (keepFrom <= 0) return;
    _buffer = _buffer.sublist(keepFrom);
    _scanPos -= keepFrom;
    if (_scanPos < 0) _scanPos = 0;
    if (_nalStart >= 0) _nalStart = 0;
  }

  void _enforceCap() {
    if (_buffer.length + _pendingAu.length <= maxPendingBytes) return;
    _buffer = Uint8List(0);
    _scanPos = 0;
    _nalStart = -1;
    _resetPending();
    // The cached parameter sets survive: they are still the right ones for
    // whatever we resync onto, and throwing them away would leave the next
    // keyframe undecodable for a viewer who joined during the garbage.
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
