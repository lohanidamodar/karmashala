// A structural validator for MPEG-TS, written to catch exactly what FFmpeg's
// demuxer complains about.
//
// The checks mirror `libavformat/mpegts.c`: the continuity-counter test whose
// failure sets `AV_PKT_FLAG_CORRUPT` (which surfaces in mpv's log as
// `mpegts: Packet corrupt`), the PES size-mismatch test in `new_pes_packet`,
// and the transport-error indicator. The rest is ISO 13818-1 structure.
//
// It lives in the tests because it is a test oracle, not app behaviour — but it
// is the thing standing in for `ffprobe`, which is not installed on this
// machine.
import 'dart:typed_data';

import 'package:chitragupta/src/features/devices/data/ts_muxer.dart';

/// One reassembled PES packet.
class PesPacket {
  PesPacket({
    required this.pid,
    required this.streamId,
    required this.declaredLength,
    required this.pts90,
    required this.payload,
    required this.emittedImmediately,
  });

  final int pid;
  final int streamId;

  /// `PES_packet_length` as written; 0 means unbounded.
  final int declaredLength;
  final int? pts90;
  final Uint8List payload;

  /// True when the declared length let the demuxer emit this packet on its last
  /// byte, rather than having to wait for the next PES to start.
  final bool emittedImmediately;
}

/// What [validateTransportStream] found.
class TsValidation {
  final List<String> errors = [];
  final List<PesPacket> pes = [];
  final List<int> pcr90 = [];

  /// Indices (in packets) at which a PAT was seen.
  final List<int> patPackets = [];
  final List<int> pmtPackets = [];

  /// Largest gap between successive PCRs, in 90 kHz ticks.
  int maxPcrGap90 = 0;

  /// Largest gap between successive PATs, in 90 kHz ticks of stream time.
  int maxTableGap90 = 0;

  int packets = 0;
  int? videoPid;
  int? pcrPid;

  bool get ok => errors.isEmpty;

  @override
  String toString() => ok
      ? 'TsValidation(ok, $packets packets, ${pes.length} PES)'
      : 'TsValidation(${errors.length} errors)\n${errors.take(20).join('\n')}';
}

int _crcOf(List<int> section) => mpegCrc32(section);

/// Walks [bytes] as an MPEG-TS stream and reports every structural fault.
TsValidation validateTransportStream(Uint8List bytes) {
  final report = TsValidation();

  if (bytes.length % kTsPacketSize != 0) {
    report.errors.add(
      'stream is ${bytes.length} bytes, not a whole number of '
      '$kTsPacketSize-byte packets',
    );
  }

  final lastCc = <int, int>{};
  // Per-PID PES reassembly state.
  final open = <int, _PesBuilder>{};
  int? lastPcr;
  int? lastPatPcrTime;
  int? lastPts;

  final count = bytes.length ~/ kTsPacketSize;
  for (var index = 0; index < count; index++) {
    final base = index * kTsPacketSize;
    final packet = Uint8List.sublistView(bytes, base, base + kTsPacketSize);
    report.packets++;

    if (packet[0] != 0x47) {
      report.errors.add(
        'packet $index: sync byte is 0x${packet[0].toRadixString(16)}, not 0x47',
      );
      continue;
    }
    if (packet[1] & 0x80 != 0) {
      report.errors.add('packet $index: transport_error_indicator set');
    }
    final start = packet[1] & 0x40 != 0;
    final pid = ((packet[1] & 0x1F) << 8) | packet[2];
    final afc = (packet[3] >> 4) & 0x03;
    if (afc == 0) {
      report.errors.add('packet $index: reserved adaptation_field_control 0');
      continue;
    }
    final hasAdaptation = afc & 0x02 != 0;
    final hasPayload = afc & 0x01 != 0;
    final cc = packet[3] & 0x0F;

    var payloadStart = 4;
    var discontinuity = false;
    if (hasAdaptation) {
      final length = packet[4];
      if (4 + 1 + length > kTsPacketSize) {
        report.errors.add(
          'packet $index: adaptation_field_length $length overruns the packet',
        );
        continue;
      }
      if (length > 0) {
        final flags = packet[5];
        discontinuity = flags & 0x80 != 0;
        if (flags & 0x10 != 0) {
          if (length < 7) {
            report.errors.add(
              'packet $index: PCR flagged but adaptation field is only $length bytes',
            );
          } else {
            final high =
                (packet[6] << 25) |
                (packet[7] << 17) |
                (packet[8] << 9) |
                (packet[9] << 1) |
                ((packet[10] >> 7) & 0x01);
            final ext = ((packet[10] & 0x01) << 8) | packet[11];
            if (ext > 299) {
              report.errors.add(
                'packet $index: PCR extension $ext exceeds 299',
              );
            }
            if (pid != report.pcrPid && report.pcrPid != null) {
              report.errors.add(
                'packet $index: PCR on pid $pid but the PMT names ${report.pcrPid}',
              );
            }
            if (lastPcr != null) {
              if (high < lastPcr) {
                report.errors.add(
                  'packet $index: PCR went backwards ($lastPcr -> $high)',
                );
              }
              final gap = high - lastPcr;
              if (gap > report.maxPcrGap90) report.maxPcrGap90 = gap;
            }
            lastPcr = high;
            report.pcr90.add(high);
          }
        }
        // Everything after the flags and any indicated fields must be stuffing.
        var consumed = 1;
        if (flags & 0x10 != 0) consumed += 6;
        if (flags & 0x08 != 0) consumed += 6;
        if (flags & 0x04 != 0) consumed += 1;
        for (var i = 5 + consumed; i < 5 + length; i++) {
          if (packet[i] != 0xFF) {
            report.errors.add(
              'packet $index: stuffing byte at $i is 0x${packet[i].toRadixString(16)}, not 0xFF',
            );
            break;
          }
        }
      }
      payloadStart = 5 + length;
    }

    // FFmpeg's continuity test, verbatim in intent.
    final previous = lastCc[pid];
    if (previous != null && !discontinuity) {
      final expected = hasPayload ? (previous + 1) & 0x0F : previous;
      if (expected != cc) {
        report.errors.add(
          'packet $index pid $pid: continuity expected $expected, got $cc',
        );
      }
    }
    lastCc[pid] = cc;

    if (!hasPayload || payloadStart >= kTsPacketSize) continue;
    final payload = Uint8List.sublistView(packet, payloadStart, kTsPacketSize);

    if (pid == 0x0000) {
      report.patPackets.add(index);
      if (lastPcr != null) {
        if (lastPatPcrTime != null) {
          final gap = lastPcr - lastPatPcrTime;
          if (gap > report.maxTableGap90) report.maxTableGap90 = gap;
        }
        lastPatPcrTime = lastPcr;
      }
      final section = _section(payload, report, index, 'PAT');
      if (section != null && section.length >= 12) {
        for (var i = 8; i + 4 <= section.length - 4; i += 4) {
          final program = (section[i] << 8) | section[i + 1];
          final mapPid = ((section[i + 2] & 0x1F) << 8) | section[i + 3];
          if (program != 0 && mapPid != kPmtPid) {
            report.errors.add(
              'PAT at $index maps program $program to pid $mapPid, expected $kPmtPid',
            );
          }
        }
      }
      continue;
    }

    if (pid == kPmtPid) {
      report.pmtPackets.add(index);
      final section = _section(payload, report, index, 'PMT');
      if (section != null && section.length >= 16) {
        report.pcrPid = ((section[8] & 0x1F) << 8) | section[9];
        final programInfo = ((section[10] & 0x0F) << 8) | section[11];
        var i = 12 + programInfo;
        while (i + 5 <= section.length - 4) {
          final streamType = section[i];
          final esPid = ((section[i + 1] & 0x1F) << 8) | section[i + 2];
          final esInfo = ((section[i + 3] & 0x0F) << 8) | section[i + 4];
          if (streamType == 0x1B) report.videoPid = esPid;
          i += 5 + esInfo;
        }
        if (report.videoPid == null) {
          report.errors.add(
            'PMT at $index declares no H.264 (stream_type 0x1B) stream',
          );
        }
      }
      continue;
    }

    // Elementary stream.
    if (start) {
      final builder = open.remove(pid);
      if (builder != null) {
        final packet = builder.finish(report, immediate: false);
        if (packet != null) report.pes.add(packet);
      }
      final fresh = _PesBuilder(pid);
      fresh.add(payload);
      if (fresh.complete) {
        final done = fresh.finish(report, immediate: true);
        if (done != null) report.pes.add(done);
      } else {
        open[pid] = fresh;
      }
    } else {
      final builder = open[pid];
      if (builder == null) {
        report.errors.add(
          'packet $index pid $pid: continuation with no PES start',
        );
        continue;
      }
      builder.add(payload);
      if (builder.complete) {
        open.remove(pid);
        final done = builder.finish(report, immediate: true);
        if (done != null) report.pes.add(done);
      }
    }
  }

  for (final builder in open.values) {
    final packet = builder.finish(report, immediate: false);
    if (packet != null) report.pes.add(packet);
  }

  for (final packet in report.pes) {
    final pts = packet.pts90;
    if (pts == null) {
      report.errors.add('PES on pid ${packet.pid} carries no PTS');
      continue;
    }
    if (lastPts != null && pts < lastPts) {
      report.errors.add('PES PTS went backwards ($lastPts -> $pts)');
    }
    lastPts = pts;
  }

  if (report.patPackets.isEmpty) report.errors.add('no PAT in the stream');
  if (report.pmtPackets.isEmpty) report.errors.add('no PMT in the stream');
  return report;
}

List<int>? _section(
  Uint8List payload,
  TsValidation report,
  int index,
  String what,
) {
  final pointer = payload[0];
  if (1 + pointer >= payload.length) {
    report.errors.add(
      '$what at $index: pointer_field $pointer overruns the payload',
    );
    return null;
  }
  final body = payload.sublist(1 + pointer);
  if (body.length < 3) {
    report.errors.add('$what at $index: section shorter than its header');
    return null;
  }
  final length = ((body[1] & 0x0F) << 8) | body[2];
  if (body[1] & 0x80 == 0) {
    report.errors.add('$what at $index: section_syntax_indicator not set');
  }
  if (3 + length > body.length) {
    report.errors.add(
      '$what at $index: section_length $length overruns the packet',
    );
    return null;
  }
  final section = body.sublist(0, 3 + length);
  final crc =
      (section[section.length - 4] << 24) |
      (section[section.length - 3] << 16) |
      (section[section.length - 2] << 8) |
      section[section.length - 1];
  if (_crcOf(section.sublist(0, section.length - 4)) != crc) {
    report.errors.add('$what at $index: CRC-32 mismatch');
  }
  return section;
}

class _PesBuilder {
  _PesBuilder(this.pid);

  final int pid;
  final BytesBuilder _bytes = BytesBuilder();

  void add(Uint8List data) => _bytes.add(data);

  int get _length {
    final b = _bytes.toBytes();
    if (b.length < 6) return -1;
    return (b[4] << 8) | b[5];
  }

  /// True once every byte the header promised has arrived, mirroring FFmpeg's
  /// `pes_header_size + data_index == total_size + 6` test.
  bool get complete {
    final declared = _length;
    if (declared <= 0) return false;
    return _bytes.length >= declared + 6;
  }

  PesPacket? finish(TsValidation report, {required bool immediate}) {
    final bytes = _bytes.toBytes();
    if (bytes.length < 9) {
      report.errors.add(
        'pid $pid: PES shorter than a header (${bytes.length} bytes)',
      );
      return null;
    }
    if (bytes[0] != 0x00 || bytes[1] != 0x00 || bytes[2] != 0x01) {
      report.errors.add('pid $pid: PES start code is not 00 00 01');
      return null;
    }
    final streamId = bytes[3];
    final declared = (bytes[4] << 8) | bytes[5];
    if (bytes[6] & 0xC0 != 0x80) {
      report.errors.add('pid $pid: PES optional header marker bits wrong');
    }
    final headerDataLength = bytes[8];
    final ptsFlags = (bytes[7] >> 6) & 0x03;
    int? pts;
    if (ptsFlags & 0x02 != 0) {
      if (bytes.length < 14) {
        report.errors.add('pid $pid: PTS flagged but the header is truncated');
      } else {
        final p = bytes.sublist(9, 14);
        if (p[0] >> 4 != (ptsFlags == 0x03 ? 0x3 : 0x2)) {
          report.errors.add(
            'pid $pid: PTS prefix nibble is 0x${(p[0] >> 4).toRadixString(16)}',
          );
        }
        if (p[0] & 1 != 1 || p[2] & 1 != 1 || p[4] & 1 != 1) {
          report.errors.add('pid $pid: PTS marker bits missing');
        }
        pts =
            ((p[0] >> 1) & 0x07) << 30 |
            p[1] << 22 |
            ((p[2] >> 1) & 0x7F) << 15 |
            p[3] << 7 |
            ((p[4] >> 1) & 0x7F);
      }
    }
    final payload = bytes.sublist(9 + headerDataLength);
    if (declared != 0) {
      // FFmpeg: pes_header_size + data_index == total_size + 6.
      final actual = (9 + headerDataLength) + payload.length;
      if (actual != declared + 6) {
        report.errors.add(
          'pid $pid: PES packet size mismatch — declared ${declared + 6}, wrote $actual',
        );
      }
    }
    return PesPacket(
      pid: pid,
      streamId: streamId,
      declaredLength: declared,
      pts90: pts,
      payload: payload,
      emittedImmediately: immediate,
    );
  }
}
