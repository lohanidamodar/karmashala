import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/media/frame_sink.dart';
import 'package:karmashala/src/core/media/media_foundation.dart';

import 'mp4_reader.dart';

/// A 4x4 frame of one flat colour.
RgbaFrame _frame(int r, int g, int b, {int size = 64}) {
  final rgba = Uint8List(size * size * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return RgbaFrame(
    rgba: rgba,
    width: size,
    height: size,
    hold: const Duration(milliseconds: 83),
  );
}

void main() {
  group('video support', () {
    test('says which platform it is speaking for either way', () {
      final support = probeVideoSupport();
      expect(support.detail, isNotEmpty);
      if (!Platform.isWindows) {
        expect(support.available, isFalse);
        // §19: the reason names the platform, not a shrug.
        expect(support.detail.toLowerCase(), contains(Platform.operatingSystem));
      }
    });

    test('on Windows it names the encoder it found', () {
      final support = probeVideoSupport();
      expect(support.available, isTrue, reason: support.detail);
      expect(support.detail.toLowerCase(), contains('h.264'));
    }, skip: !Platform.isWindows);
  });

  group('Media Foundation encoder', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mf-encode'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes an MP4 that starts with an ftyp box', () {
      final path = '${dir.path}${Platform.pathSeparator}out.mp4';
      final encoder = openMediaFoundationEncoder(
        path: path,
        width: 64,
        height: 64,
        frameRate: 12,
      );
      for (var i = 0; i < 12; i++) {
        encoder.add(_frame(i * 20, 255 - i * 20, 128));
      }
      final bytes = encoder.finish();
      expect(bytes, greaterThan(0));
      final head = File(path).readAsBytesSync().sublist(4, 8);
      expect(String.fromCharCodes(head), 'ftyp');
      expect(File(path).lengthSync(), bytes);
    }, skip: !Platform.isWindows);

    test('abort leaves no file behind', () {
      final path = '${dir.path}${Platform.pathSeparator}gone.mp4';
      final encoder = openMediaFoundationEncoder(
        path: path,
        width: 64,
        height: 64,
        frameRate: 12,
      );
      encoder.add(_frame(10, 20, 30));
      encoder.abort();
      expect(File(path).existsSync(), isFalse);
    }, skip: !Platform.isWindows);

    test('a remux of its own output is byte-identical in the payload', () {
      final source = '${dir.path}${Platform.pathSeparator}src.mp4';
      final encoder = openMediaFoundationEncoder(
        path: source,
        width: 64,
        height: 64,
        frameRate: 12,
      );
      for (var i = 0; i < 12; i++) {
        encoder.add(_frame(i * 20, 255 - i * 20, 128));
      }
      encoder.finish();

      final track = readMp4Track(File(source).readAsBytesSync());
      final copy = '${dir.path}${Platform.pathSeparator}copy.mp4';
      final remuxer = openMediaFoundationRemuxer(
        path: copy,
        width: 64,
        height: 64,
        frameRate: 12,
        sequenceHeader: track.sequenceHeader,
      );
      for (final frame in track.frames) {
        remuxer.add(frame);
      }
      expect(remuxer.finish(), greaterThan(0));

      final before = readMp4Track(File(source).readAsBytesSync());
      final after = readMp4Track(File(copy).readAsBytesSync());
      expect(after.frames.length, before.frames.length);
      for (var i = 0; i < after.frames.length; i++) {
        expect(after.frames[i].bytes, before.frames[i].bytes);
      }
    }, skip: !Platform.isWindows);
  });
}
