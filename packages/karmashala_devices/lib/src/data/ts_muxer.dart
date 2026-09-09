import 'dart:typed_data';

/// Packet identifier carrying the Program Map Table.
const int kPmtPid = 0x1000;

/// Packet identifier carrying the H.264 elementary stream.
const int kVideoPid = 0x0100;

/// Size of one MPEG-TS packet. Every packet is exactly this long.
const int kTsPacketSize = 188;

/// Largest value the 16-bit `PES_packet_length` field can hold.
const int kMaxPesPacketLength = 0xFFFF;

/// Bytes a PES header costs on top of the access unit: 6 for the start code,
/// stream id and length, 3 for the flags and header length, 5 for the PTS.
const int kPesOverhead = 14;

/// How often PAT/PMT are repeated, in stream microseconds.
///
/// FFmpeg's own muxer repeats them every 100 ms. Repeating them only on
/// keyframes is not enough: this emulator emits a keyframe roughly every 4 s
/// even with `i-frame-interval=1`, so a demuxer that joins the stream (or loses
/// the tables) waits seconds before it can name the program.
const int kTablePeriodUs = 100000;

/// How far the device's clock may jump between two frames and still be taken
/// as elapsed presentation time.
///
/// Beyond this it is a gap in *capture*, not in presentation. scrcpy encodes on
/// change, so an untouched phone sends nothing for minutes and the next frame's
/// timestamp is minutes later; the cached keyframe a new viewer starts from can
/// be older still. Honouring those puts a minutes-long jump in the stream's
/// clock — measured at **120 s of PCR in a single step** for a viewer attaching
/// after a two-minute idle — which is a far worse thing to hand a demuxer than
/// a missing frame.
const int kMaxBelievableStepUs = 1000000;

/// What the clock advances by when the device's cannot be believed. One frame
/// at 60 fps: enough to keep PTS and PCR moving, small enough that no player
/// waits for it.
const int kNominalStepUs = 16000;

/// CRC-32/MPEG-2: polynomial 0x04C11DB7, init 0xFFFFFFFF, MSB-first, no final
/// XOR. Required by the PSI table format.
int mpegCrc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte << 24;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80000000) != 0
          ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
          : (crc << 1) & 0xFFFFFFFF;
    }
  }
  return crc & 0xFFFFFFFF;
}

/// Muxes H.264 access units into an MPEG-TS stream.
///
/// This exists because **libmpv's bundled FFmpeg has no raw-H.264 demuxer**: a
/// bare Annex-B elementary stream cannot be opened at all (verified — it reports
/// `Unknown lavf format h264`). MPEG-TS is a container it does demux, is the
/// standard choice for low-latency streaming, and carries the per-frame PTS
/// scrcpy gives us.
///
/// One muxer instance owns the continuity counters and the timestamp base for
/// one output stream, so a new consumer must get a **new** muxer — replaying
/// previously emitted packets to a second consumer duplicates continuity
/// counters and the demuxer reports corrupt packets.
class TsMuxer {
  TsMuxer({
    this.tablePeriodUs = kTablePeriodUs,
    this.maxBelievableStepUs = kMaxBelievableStepUs,
    this.nominalStepUs = kNominalStepUs,
  });

  /// How often PAT/PMT are repeated, in stream microseconds.
  final int tablePeriodUs;

  /// See [kMaxBelievableStepUs] and [kNominalStepUs].
  final int maxBelievableStepUs;
  final int nominalStepUs;

  int _videoContinuity = 0;
  int _patContinuity = 0;
  int _pmtContinuity = 0;

  /// PTS of the first frame muxed. Everything is emitted relative to it, so the
  /// stream starts at zero and the 33-bit timestamp cannot wrap inside any
  /// plausible session — scrcpy hands us the device's monotonic clock, which on
  /// a device up for more than ~26 h would otherwise overflow mid-stream.
  int? _basePtsUs;

  /// The device timestamp of the previous frame, for measuring its step.
  int? _lastDevicePtsUs;

  /// **Our** clock, not the device's.
  int _lastPtsUs = 0;
  int _lastTablesUs = 0;
  bool _startedVideo = false;

  /// Stream time of the most recently muxed frame, relative to the first.
  int get streamTimeUs => _lastPtsUs;

  /// PTS of the first frame muxed, or `null` before any frame.
  ///
  /// A caller measuring latency needs this: the player reports its position
  /// relative to the start of the stream, and this is what that start was.
  int? get basePtsUs => _basePtsUs;

  /// PAT + PMT. Emit before any frame so the demuxer can identify the program.
  Uint8List tables() {
    final out = BytesBuilder(copy: false);
    out.add(_pat());
    out.add(_pmt());
    return out.toBytes();
  }

  Uint8List _pat() {
    final section = <int>[
      0x00, // table_id: program association
      0xB0, 0x0D, // section syntax indicator + length (13)
      0x00, 0x01, // transport_stream_id
      0xC1, // version 0, current
      0x00, 0x00, // section_number, last_section_number
      0x00, 0x01, // program_number 1
      0xE0 | (kPmtPid >> 8), kPmtPid & 0xFF,
    ];
    _appendCrc(section);
    return _sectionPacket(0x0000, section, _patContinuity++);
  }

  Uint8List _pmt() {
    final section = <int>[
      0x02, // table_id: program map
      0xB0, 0x12, // section length (18)
      0x00, 0x01, // program_number
      0xC1, 0x00, 0x00,
      0xE0 | (kVideoPid >> 8), kVideoPid & 0xFF, // PCR pid
      0xF0, 0x00, // program_info_length 0
      0x1B, // stream_type: H.264
      0xE0 | (kVideoPid >> 8), kVideoPid & 0xFF,
      0xF0, 0x00, // ES_info_length 0
    ];
    _appendCrc(section);
    return _sectionPacket(kPmtPid, section, _pmtContinuity++);
  }

  static void _appendCrc(List<int> section) {
    final crc = mpegCrc32(section);
    section.addAll([
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
  }

  /// Wraps a (small) PSI section in one packet, padded with 0xFF.
  Uint8List _sectionPacket(int pid, List<int> section, int continuity) {
    final packet = Uint8List(kTsPacketSize)..fillRange(0, kTsPacketSize, 0xFF);
    packet[0] = 0x47;
    packet[1] = 0x40 | ((pid >> 8) & 0x1F); // payload_unit_start
    packet[2] = pid & 0xFF;
    packet[3] = 0x10 | (continuity & 0x0F); // payload only
    packet[4] = 0x00; // pointer_field
    packet.setRange(5, 5 + section.length, section);
    return packet;
  }

  /// Encodes a 33-bit timestamp in the 5-byte PES form.
  static List<int> encodeTimestamp(int value90kHz, int prefix) {
    final v = value90kHz & 0x1FFFFFFFF;
    return [
      (prefix << 4) | (((v >> 30) & 0x07) << 1) | 1,
      (v >> 22) & 0xFF,
      (((v >> 15) & 0x7F) << 1) | 1,
      (v >> 7) & 0xFF,
      ((v & 0x7F) << 1) | 1,
    ];
  }

  /// Muxes one access unit (Annex-B) presented at [ptsUs].
  ///
  /// PAT/PMT are repeated on every keyframe and at least every
  /// [tablePeriodUs] so a consumer joining mid-stream can start quickly.
  Uint8List frame(Uint8List accessUnit, int ptsUs, {required bool keyframe}) {
    // The output has its own clock, advanced by each frame's *step* rather than
    // rebased from the device's. Echoing the device clock is what made this
    // muxer the reason the live view froze.
    //
    // The rule it replaced clamped a backwards step to the highest timestamp
    // seen — which does not clamp one frame, it **latches**: every frame after
    // it is stamped with that same value, so PTS and PCR stop advancing for the
    // rest of the session while bytes keep flowing. Measured: four frames after
    // a clock restart all carried PCR 2880. A stream whose time has stopped is
    // exactly the frozen picture with a healthy socket the owner reported, and
    // scrcpy had nothing to do with it.
    //
    // A step that is negative, zero or implausibly large is a discontinuity —
    // a capture reset, an idle gap, a bad timestamp — and the honest thing to
    // do with a discontinuity is to carry on, one nominal frame later.
    final previous = _lastDevicePtsUs;
    _lastDevicePtsUs = ptsUs;
    if (previous == null) {
      _basePtsUs = ptsUs;
    } else {
      final step = ptsUs - previous;
      _lastPtsUs += (step <= 0 || step > maxBelievableStepUs)
          ? nominalStepUs
          : step;
    }
    final ptsRelUs = _lastPtsUs;

    final out = BytesBuilder(copy: false);
    if (keyframe ||
        !_startedVideo ||
        ptsRelUs - _lastTablesUs >= tablePeriodUs) {
      out.add(tables());
      _lastTablesUs = ptsRelUs;
    }

    final pts90 = (ptsRelUs * 9) ~/ 100; // microseconds -> 90 kHz

    // A **known** PES_packet_length is what makes this stream low latency.
    // With the unbounded form (0) FFmpeg's MPEG-TS demuxer cannot tell a PES is
    // finished until the *next* one starts, so every frame is held back by a
    // whole inter-frame gap — 65 ms median and 267 ms at worst from this
    // emulator. With the length set it emits the frame on its last byte.
    final pesBodyLength = 3 + 5 + accessUnit.length;
    final declaredLength = pesBodyLength <= kMaxPesPacketLength
        ? pesBodyLength
        : 0;

    final pes = <int>[
      0x00, 0x00, 0x01, 0xE0, // PES start code, stream_id = video
      (declaredLength >> 8) & 0xFF, declaredLength & 0xFF,
      0x84, // marker bits + data_alignment_indicator
      0x80, // PTS present, no DTS
      0x05, // PES header data length
      ...encodeTimestamp(pts90, 0x2),
      ...accessUnit,
    ];

    var offset = 0;
    var first = true;
    while (offset < pes.length) {
      final packet = Uint8List(kTsPacketSize);
      packet[0] = 0x47;
      packet[1] = (first ? 0x40 : 0x00) | ((kVideoPid >> 8) & 0x1F);
      packet[2] = kVideoPid & 0xFF;

      final remaining = pes.length - offset;
      // The first packet of a frame carries the PCR; the last is padded with a
      // stuffing adaptation field so every packet is exactly 188 bytes.
      var adaptation = first ? 8 : 0;
      if (remaining < kTsPacketSize - 4 - adaptation) {
        adaptation = kTsPacketSize - 4 - remaining;
      }

      if (adaptation > 0) {
        packet[3] = 0x30 | (_videoContinuity & 0x0F);
        packet[4] = adaptation - 1;
        if (adaptation >= 2) {
          var written = 6;
          if (first && adaptation >= 8) {
            // The very first video packet is flagged discontinuous so a demuxer
            // that was reading an earlier stream on this PID does not fail its
            // continuity check against our counter, which restarts at zero.
            packet[5] =
                (_startedVideo ? 0x00 : 0x80) | // discontinuity_indicator
                (keyframe ? 0x40 : 0x00) | // random_access_indicator
                0x10; // PCR present
            packet[6] = (pts90 >> 25) & 0xFF;
            packet[7] = (pts90 >> 17) & 0xFF;
            packet[8] = (pts90 >> 9) & 0xFF;
            packet[9] = (pts90 >> 1) & 0xFF;
            packet[10] = ((pts90 & 0x01) << 7) | 0x7E;
            packet[11] = 0x00;
            written = 12;
          } else {
            packet[5] = 0x00; // no flags
          }
          for (var i = written; i < 4 + adaptation; i++) {
            packet[i] = 0xFF; // stuffing
          }
        }
      } else {
        packet[3] = 0x10 | (_videoContinuity & 0x0F); // payload only
      }
      _videoContinuity++;

      final start = 4 + adaptation;
      final count = kTsPacketSize - start;
      packet.setRange(
        start,
        kTsPacketSize,
        pes.sublist(offset, offset + count),
      );
      offset += count;
      first = false;
      out.add(packet);
    }
    _startedVideo = true;
    return out.toBytes();
  }
}
