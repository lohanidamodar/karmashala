import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/media.dart';
import 'package:karmashala/src/features/devices/data/recording_sink.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/testing.dart';

/// The device path with the operating system's real muxer, and real H.264.
///
/// The frames a handset sends are already encoded, so recording one is a
/// container change. This proves it is only that: the payload the writer put in
/// the MP4 is the payload it was handed, byte for byte.
///
/// **This file used to take the tester process down under load**, until every
/// open here stopped asking for the hardware encoder. The crash, the fix and
/// the before/after measurement are recorded once, in
/// `test/core/media/video_writer_test.dart`.
/// The real remuxer, without the vendor MFTs that take the tester down.
VideoRemuxer _softwareRemuxer({
  required String path,
  required int width,
  required int height,
  required int frameRate,
  required Uint8List sequenceHeader,
}) => openMediaFoundationRemuxer(
  path: path,
  width: width,
  height: height,
  frameRate: frameRate,
  sequenceHeader: sequenceHeader,
  hardwareTransforms: false,
);

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('dev-mp4'));
  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on Object {
      // Windows may still hold a handle; the temp directory is disposable.
    }
  });

  /// Real H.264 to stand in for a handset's, made by the same OS encoder.
  Mp4Track sourceTrack() {
    final path = p.join(temp.path, 'source.mp4');
    final encoder = openMediaFoundationEncoder(
      path: path,
      width: 320,
      height: 240,
      frameRate: 30,
      hardwareTransforms: false,
    );
    for (var i = 0; i < 20; i++) {
      final rgba = Uint8List(320 * 240 * 4);
      for (var b = 0; b < rgba.length; b += 4) {
        rgba[b] = (i * 11) & 0xFF;
        rgba[b + 1] = (b ~/ 4) & 0xFF;
        rgba[b + 2] = 0x60;
        rgba[b + 3] = 255;
      }
      encoder.add(
        RgbaFrame(
          rgba: rgba,
          width: 320,
          height: 240,
          hold: const Duration(milliseconds: 33),
        ),
      );
    }
    encoder.finish();
    return readMp4Track(File(path).readAsBytesSync());
  }

  test('a recording is a container change and nothing else', () async {
    final source = sourceTrack();
    final path = p.join(temp.path, 'recording.mp4');
    final writer = Mp4RecordingWriter.open(path, openRemuxer: _softwareRemuxer);
    for (var i = 0; i < source.frames.length; i++) {
      final frame = source.frames[i];
      writer.add(
        DeviceAccessUnit(
          // A handset re-sends SPS/PPS ahead of every keyframe, as scrcpy does.
          bytes: frame.keyframe
              ? Uint8List.fromList([...source.sequenceHeader, ...frame.bytes])
              : frame.bytes,
          ptsUs: frame.at.inMicroseconds,
          keyframe: frame.keyframe,
          width: 320,
          height: 240,
          sequenceHeader: source.sequenceHeader,
        ),
      );
    }
    expect(writer.units, source.frames.length);
    expect(writer.committedSize, (width: 320, height: 240));

    expect(await writer.close(), greaterThan(0));

    final written = File(path).readAsBytesSync();
    expect(String.fromCharCodes(written.sublist(4, 8)), 'ftyp');
    final back = readMp4Track(written);
    expect(back.frames.length, source.frames.length);
    for (var i = 0; i < back.frames.length; i++) {
      expect(back.frames[i].bytes, source.frames[i].bytes);
    }
    // The in-band parameter sets went into the sample entry rather than into
    // every keyframe, which is what makes the payload identical.
    expect(back.sequenceHeader, source.sequenceHeader);
  }, skip: !Platform.isWindows);

  test('nothing recorded writes no file at all', () async {
    final path = p.join(temp.path, 'empty.mp4');
    final writer = Mp4RecordingWriter.open(path, openRemuxer: _softwareRemuxer);
    expect(await writer.close(), 0);
    expect(File(path).existsSync(), isFalse);
  }, skip: !Platform.isWindows);
}
