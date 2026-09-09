import 'dart:typed_data';

import 'package:karmashala_media/media.dart';

/// The H.264 out of an MP4, in the Annex-B shape a remuxer takes back.
///
/// Test-only: the app never reads an MP4, it only writes them. This exists so a
/// round-trip can prove the remux changed no bytes.
class Mp4Track {
  const Mp4Track({required this.sequenceHeader, required this.frames});

  final Uint8List sequenceHeader;
  final List<EncodedVideoFrame> frames;
}

const List<int> _startCode = [0, 0, 0, 1];

Mp4Track readMp4Track(Uint8List file) {
  final view = ByteData.sublistView(file);
  final boxes = <String, int>{};

  void walk(int offset, int end) {
    var at = offset;
    while (at + 8 <= end) {
      final size = view.getUint32(at);
      final type = String.fromCharCodes(file.sublist(at + 4, at + 8));
      if (size < 8) return;
      boxes.putIfAbsent(type, () => at);
      if (const ['moov', 'trak', 'mdia', 'minf', 'stbl'].contains(type)) {
        walk(at + 8, at + size);
      }
      if (type == 'stsd') {
        var entry = at + 16;
        for (var i = 0; i < view.getUint32(at + 12); i++) {
          final entrySize = view.getUint32(entry);
          // 78 bytes of VisualSampleEntry before the codec-specific boxes.
          walk(entry + 8 + 78, entry + entrySize);
          entry += entrySize;
        }
      }
      at += size;
    }
  }

  walk(0, file.length);
  final avcC = file.sublist(
    boxes['avcC']! + 8,
    boxes['avcC']! + view.getUint32(boxes['avcC']!),
  );
  final lengthSize = (avcC[4] & 3) + 1;
  var at = 5;
  final header = <int>[];
  for (final count in [avcC[at++] & 0x1F, 0]) {
    for (var i = 0; i < count; i++) {
      final length = (avcC[at] << 8) | avcC[at + 1];
      at += 2;
      header
        ..addAll(_startCode)
        ..addAll(avcC.sublist(at, at + length));
      at += length;
    }
    if (count == 0) break;
  }
  final pps = avcC[at++];
  for (var i = 0; i < pps; i++) {
    final length = (avcC[at] << 8) | avcC[at + 1];
    at += 2;
    header
      ..addAll(_startCode)
      ..addAll(avcC.sublist(at, at + length));
    at += length;
  }

  final stsz = boxes['stsz']!;
  final sizes = [
    for (var i = 0; i < view.getUint32(stsz + 16); i++)
      view.getUint32(stsz + 20 + i * 4),
  ];
  final stss = boxes['stss'];
  final sync = <int>{
    if (stss != null)
      for (var i = 0; i < view.getUint32(stss + 12); i++)
        view.getUint32(stss + 16 + i * 4) - 1,
  };

  var payload = view.getUint32(boxes['stco']! + 16);
  final frames = <EncodedVideoFrame>[];
  for (var i = 0; i < sizes.length; i++) {
    final sample = file.sublist(payload, payload + sizes[i]);
    final annexB = <int>[];
    var cursor = 0;
    while (cursor + lengthSize <= sample.length) {
      var length = 0;
      for (var b = 0; b < lengthSize; b++) {
        length = (length << 8) | sample[cursor + b];
      }
      cursor += lengthSize;
      annexB
        ..addAll(_startCode)
        ..addAll(sample.sublist(cursor, cursor + length));
      cursor += length;
    }
    frames.add(
      EncodedVideoFrame(
        bytes: Uint8List.fromList(annexB),
        at: Duration(milliseconds: i * 1000 ~/ 12),
        keyframe: sync.contains(i),
      ),
    );
    payload += sizes[i];
  }
  return Mp4Track(
    sequenceHeader: Uint8List.fromList(header),
    frames: frames,
  );
}
