/// Windows' own H.264 encoder and MP4 muxer, reached straight from Dart, so an
/// MP4 costs no added download. The bundled `libmpv-2.dll` cannot stand in: its
/// FFmpeg is built `--disable-encoders --disable-muxers`.
///
/// FFI rather than a channel to the runner because a method channel only
/// answers on the platform thread, and the encode must stay off the UI isolate.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'frame_sink.dart';
import 'video_writer.dart';

const int _mfVersion = 0x00020070;
const int _mfStartupFull = 0;

// IMFAttributes
const int _slotSetUint32 = 21;
const int _slotSetUint64 = 22;
const int _slotSetGuid = 24;
const int _slotSetBlob = 26;
// IUnknown
const int _release = 2;
// IMFSinkWriter
const int _addStream = 3;
const int _setInputMediaType = 4;
const int _beginWriting = 5;
const int _writeSample = 6;
const int _finalizeWriting = 11;
// IMFSample
const int _setSampleTime = 36;
const int _setSampleDuration = 38;
const int _addBuffer = 42;
// IMFMediaBuffer
const int _lock = 3;
const int _unlock = 4;
const int _setCurrentLength = 6;

typedef _Hr = Int32 Function(Pointer<Void>);
typedef _HrU32 = Int32 Function(Pointer<Void>, Uint32);
typedef _HrI64 = Int32 Function(Pointer<Void>, Int64);
typedef _HrPtr = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _HrAddStream =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Uint32>);
typedef _HrSetInput =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Void>);
typedef _HrWrite = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HrLock =
    Int32 Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    );
typedef _HrAttrU32 = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32);
typedef _HrAttrU64 = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint64);
typedef _HrAttrGuid =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);
typedef _HrAttrBlob =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, Uint32);
/// A COM call went wrong. Carries the `HRESULT` so a report can name it.
class MediaFoundationException implements Exception {
  MediaFoundationException(this.what, this.hresult);

  final String what;
  final int hresult;

  @override
  String toString() =>
      '$what failed (0x${(hresult & 0xFFFFFFFF).toRadixString(16)})';
}

/// The DLLs and the handful of exports we use, opened once per isolate.
class _Mf {
  _Mf._(this._plat, this._readWrite);

  static _Mf? _instance;
  static bool _started = false;

  final DynamicLibrary _plat;
  final DynamicLibrary _readWrite;

  static _Mf get instance {
    final existing = _instance;
    if (existing != null) return existing;
    if (!Platform.isWindows) {
      throw UnsupportedError('Media Foundation is Windows-only.');
    }
    final mf = _Mf._(
      DynamicLibrary.open('mfplat.dll'),
      DynamicLibrary.open('mfreadwrite.dll'),
    );
    _instance = mf;
    return mf;
  }

  late final int Function(int, int) startup = _plat
      .lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>(
        'MFStartup',
      );
  late final int Function(Pointer<Pointer<Void>>) createMediaType = _plat
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('MFCreateMediaType');
  late final int Function(int, Pointer<Pointer<Void>>) createBuffer = _plat
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Pointer<Void>>)
      >('MFCreateMemoryBuffer');
  late final int Function(Pointer<Pointer<Void>>) createSample = _plat
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('MFCreateSample');
  late final int Function(Pointer<Pointer<Void>>, int) createAttributes = _plat
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>, Uint32),
        int Function(Pointer<Pointer<Void>>, int)
      >('MFCreateAttributes');
  late final int Function(
    Pointer<Uint16>,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
  )
  createSinkWriter = _readWrite.lookupFunction<
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Void>>,
    ),
    int Function(
      Pointer<Uint16>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Void>>,
    )
  >('MFCreateSinkWriterFromURL');

  /// Refcounted by the OS, so once per isolate is both necessary and enough.
  void ensureStarted() {
    if (_started) return;
    _check(startup(_mfVersion, _mfStartupFull), 'MFStartup');
    _started = true;
  }
}

void _check(int hr, String what) {
  if (hr < 0) throw MediaFoundationException(what, hr);
}

/// A 16-byte GUID from its canonical spelling. Caller keeps it for the process.
Pointer<Uint8> _guid(String text) {
  final hex = text.replaceAll('-', '');
  final bytes = List<int>.generate(
    16,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
  final out = calloc<Uint8>(16);
  out.cast<Uint32>().value =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  (out + 4).cast<Uint16>().value = (bytes[4] << 8) | bytes[5];
  (out + 6).cast<Uint16>().value = (bytes[6] << 8) | bytes[7];
  for (var i = 8; i < 16; i++) {
    (out + i).value = bytes[i];
  }
  return out;
}

final _mtMajorType = _guid('48eba18e-f8c9-4687-bf11-0a74c9f96a8f');
final _mtSubtype = _guid('f7e34c9a-42e8-4714-b74b-cb29d72c35e5');
final _mediaTypeVideo = _guid('73646976-0000-0010-8000-00aa00389b71');
final _formatH264 = _guid('34363248-0000-0010-8000-00aa00389b71');
final _formatRgb32 = _guid('00000016-0000-0010-8000-00aa00389b71');
final _mtAvgBitrate = _guid('20332624-fb0d-4d9e-bd0d-cbf6786c102e');
final _mtFrameSize = _guid('1652c33d-d6b2-4012-b834-72030849a37d');
final _mtFrameRate = _guid('c459a2e8-3d2c-4e44-b132-fee5156c7bb0');
final _mtPixelAspect = _guid('c6376a1e-8d0a-4027-be45-6d9a0ad39bb6');
final _mtInterlaceMode = _guid('e2724bb8-e676-4806-b4b2-a8d6efb44ccd');
final _mtDefaultStride = _guid('644b4e48-1e02-4516-b0eb-c01ca9d49ac6');
final _mtAllSamplesIndependent = _guid('c9173739-5e56-461c-b713-46fb995cb95f');
final _mtSequenceHeader = _guid('3c036de7-3ad0-4c9e-9216-ee6d6ac21cb3');
final _sinkWriterDisableThrottling = _guid(
  '08b845d8-2b74-4afe-9d53-be16d2d5ae4f',
);
final _enableHardwareTransforms = _guid('a634a91c-822b-41b9-a494-4de4643612b0');

/// Whether a sink writer may use the vendor hardware encoder MFTs: true in the
/// app, false under `flutter test`, where loading `nvEncMFTH264x.dll` kills
/// `flutter_tester.exe` inside the MP4 probe.
///
/// Passed by every caller rather than read from the environment, so the library
/// never behaves differently when observed.
const bool appHardwareTransforms = true;
final _transcodeContainerType = _guid('150ff23f-4abc-478b-ac4f-e81916b8aaa5');
final _containerMpeg4 = _guid('dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a');
final _sampleCleanPoint = _guid('9154733f-e1bd-41bf-81d3-fcd918f71332');

Pointer<NativeFunction<T>> _slot<T extends Function>(Pointer<Void> com, int i) =>
    Pointer.fromAddress(
      com.cast<Pointer<Pointer<Void>>>().value[i].address,
    ).cast<NativeFunction<T>>();

int _call(Pointer<Void> com, int slot) =>
    _slot<_Hr>(com, slot).asFunction<int Function(Pointer<Void>)>()(com);

void _setU32(Pointer<Void> com, Pointer<Uint8> key, int value) => _check(
  _slot<_HrAttrU32>(com, _slotSetUint32)
      .asFunction<int Function(Pointer<Void>, Pointer<Uint8>, int)>()(
    com,
    key,
    value,
  ),
  'SetUINT32',
);

void _setU64(Pointer<Void> com, Pointer<Uint8> key, int value) => _check(
  _slot<_HrAttrU64>(com, _slotSetUint64)
      .asFunction<int Function(Pointer<Void>, Pointer<Uint8>, int)>()(
    com,
    key,
    value,
  ),
  'SetUINT64',
);

void _setGuid(Pointer<Void> com, Pointer<Uint8> key, Pointer<Uint8> value) =>
    _check(
      _slot<_HrAttrGuid>(com, _slotSetGuid)
          .asFunction<
            int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
          >()(com, key, value),
      'SetGUID',
    );

void _setBlobOn(Pointer<Void> com, Pointer<Uint8> key, Uint8List value) {
  final buffer = calloc<Uint8>(value.length);
  try {
    buffer.asTypedList(value.length).setAll(0, value);
    _check(
      _slot<_HrAttrBlob>(com, _slotSetBlob)
          .asFunction<
            int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, int)
          >()(com, key, buffer, value.length),
      'SetBlob',
    );
  } finally {
    calloc.free(buffer);
  }
}

/// Two 32-bit halves in one attribute — how MF stores sizes and ratios.
int _pack(int high, int low) => (high << 32) | (low & 0xFFFFFFFF);

Pointer<Uint16> _wide(String text) {
  final out = calloc<Uint16>(text.length + 1);
  for (var i = 0; i < text.length; i++) {
    (out + i).value = text.codeUnitAt(i);
  }
  return out;
}

/// Everything both writers share: one MP4 sink, one video stream, samples in.
/// The media types come from the writer above, which is what lets the same sink
/// both encode and stream-copy.
class _Mp4Sink {
  _Mp4Sink(this.path);

  final String path;

  final _mf = _Mf.instance;
  Pointer<Void> _writer = nullptr;
  int _stream = 0;
  bool _closed = false;
  int _samples = 0;

  /// Opens the file. [configureOutput] fills in the H.264 type; [passthrough]
  /// sets it as the input too, which is what tells MF to mux without encoding.
  void open({
    required void Function(Pointer<Void> mediaType) configureOutput,
    required bool passthrough,
    required bool hardwareTransforms,
    void Function(Pointer<Void> mediaType)? configureInput,
  }) {
    _mf.ensureStarted();
    File(path).parent.createSync(recursive: true);
    final attributes = calloc<Pointer<Void>>();
    final writer = calloc<Pointer<Void>>();
    final url = _wide(path);
    try {
      // The count is a sizing hint, short by one without the hardware attribute.
      _check(
        _mf.createAttributes(attributes, hardwareTransforms ? 3 : 2),
        'MFCreateAttributes',
      );
      _setU32(attributes.value, _sinkWriterDisableThrottling, 1);
      // Omitted rather than set to 0: an absent attribute is MF's own default.
      if (hardwareTransforms) {
        _setU32(attributes.value, _enableHardwareTransforms, 1);
      }
      _setGuid(attributes.value, _transcodeContainerType, _containerMpeg4);
      _check(
        _mf.createSinkWriter(url, nullptr, attributes.value, writer),
        'MFCreateSinkWriterFromURL',
      );
      _writer = writer.value;
      _call(attributes.value, _release);

      final output = calloc<Pointer<Void>>();
      final stream = calloc<Uint32>();
      try {
        _check(_mf.createMediaType(output), 'MFCreateMediaType');
        configureOutput(output.value);
        _check(
          _slot<_HrAddStream>(_writer, _addStream)
              .asFunction<
                int Function(Pointer<Void>, Pointer<Void>, Pointer<Uint32>)
              >()(_writer, output.value, stream),
          'AddStream',
        );
        _stream = stream.value;
        if (passthrough) {
          _setInput(output.value);
        } else {
          final input = calloc<Pointer<Void>>();
          try {
            _check(_mf.createMediaType(input), 'MFCreateMediaType');
            configureInput!(input.value);
            _setInput(input.value);
            _call(input.value, _release);
          } finally {
            calloc.free(input);
          }
        }
        _call(output.value, _release);
      } finally {
        calloc.free(output);
        calloc.free(stream);
      }
      _check(_call(_writer, _beginWriting), 'BeginWriting');
    } finally {
      calloc.free(attributes);
      calloc.free(writer);
      calloc.free(url);
    }
  }

  void _setInput(Pointer<Void> mediaType) => _check(
    _slot<_HrSetInput>(_writer, _setInputMediaType)
        .asFunction<
          int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Void>)
        >()(_writer, _stream, mediaType, nullptr),
    'SetInputMediaType',
  );

  /// Writes one sample, filling its buffer through [fill].
  void writeSample({
    required int length,
    required Duration at,
    required Duration hold,
    required bool keyframe,
    required void Function(Pointer<Uint8> destination) fill,
  }) {
    if (_closed) throw StateError('the MP4 is already closed');
    final buffer = calloc<Pointer<Void>>();
    final sample = calloc<Pointer<Void>>();
    final data = calloc<Pointer<Uint8>>();
    try {
      _check(_mf.createBuffer(length, buffer), 'MFCreateMemoryBuffer');
      _check(
        _slot<_HrLock>(buffer.value, _lock)
            .asFunction<
              int Function(
                Pointer<Void>,
                Pointer<Pointer<Uint8>>,
                Pointer<Uint32>,
                Pointer<Uint32>,
              )
            >()(buffer.value, data, nullptr, nullptr),
        'Lock',
      );
      fill(data.value);
      _check(_call(buffer.value, _unlock), 'Unlock');
      _check(
        _slot<_HrU32>(buffer.value, _setCurrentLength)
            .asFunction<int Function(Pointer<Void>, int)>()(
          buffer.value,
          length,
        ),
        'SetCurrentLength',
      );

      _check(_mf.createSample(sample), 'MFCreateSample');
      _check(
        _slot<_HrPtr>(sample.value, _addBuffer)
            .asFunction<int Function(Pointer<Void>, Pointer<Void>)>()(
          sample.value,
          buffer.value,
        ),
        'AddBuffer',
      );
      // MF counts in 100-nanosecond units.
      _check(
        _slot<_HrI64>(sample.value, _setSampleTime)
            .asFunction<int Function(Pointer<Void>, int)>()(
          sample.value,
          at.inMicroseconds * 10,
        ),
        'SetSampleTime',
      );
      _check(
        _slot<_HrI64>(sample.value, _setSampleDuration)
            .asFunction<int Function(Pointer<Void>, int)>()(
          sample.value,
          hold.inMicroseconds * 10,
        ),
        'SetSampleDuration',
      );
      if (keyframe) _setU32(sample.value, _sampleCleanPoint, 1);
      _check(
        _slot<_HrWrite>(_writer, _writeSample)
            .asFunction<int Function(Pointer<Void>, int, Pointer<Void>)>()(
          _writer,
          _stream,
          sample.value,
        ),
        'WriteSample',
      );
      _samples++;
    } finally {
      if (sample.value != nullptr) _call(sample.value, _release);
      if (buffer.value != nullptr) _call(buffer.value, _release);
      calloc.free(buffer);
      calloc.free(sample);
      calloc.free(data);
    }
  }

  int finish() {
    if (_closed) return _lengthOf(path);
    _closed = true;
    if (_samples == 0) {
      _releaseWriter();
      _remove();
      throw StateError('no frames were encoded');
    }
    _check(_call(_writer, _finalizeWriting), 'Finalize');
    _releaseWriter();
    return _lengthOf(path);
  }

  void abort() {
    if (_closed) return;
    _closed = true;
    _releaseWriter();
    _remove();
  }

  void _releaseWriter() {
    if (_writer == nullptr) return;
    _call(_writer, _release);
    _writer = nullptr;
  }

  void _remove() {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // A part-written file on disk is a smaller problem than a failed delete.
    }
  }
}

int _lengthOf(String path) {
  try {
    return File(path).lengthSync();
  } on Object {
    return 0;
  }
}

/// RGBA frames in, H.264 in an MP4 out. Windows' encoder does the work.
class MediaFoundationEncoder implements VideoEncoder {
  MediaFoundationEncoder({
    required String path,
    required int width,
    required int height,
    required this.frameRate,
    required bool hardwareTransforms,
  }) : // H.264 needs even dimensions; a spare row or column is cropped rather
       // than refused.
       width = width - (width % 2),
       height = height - (height % 2),
       _sink = _Mp4Sink(path) {
    _sink.open(
      passthrough: false,
      hardwareTransforms: hardwareTransforms,
      configureOutput: (type) {
        _setGuid(type, _mtMajorType, _mediaTypeVideo);
        _setGuid(type, _mtSubtype, _formatH264);
        _setU32(type, _mtAvgBitrate, _bitrateFor(this.width, this.height));
        _setU32(type, _mtInterlaceMode, 2);
        _setU64(type, _mtFrameSize, _pack(this.width, this.height));
        _setU64(type, _mtFrameRate, _pack(frameRate, 1));
        _setU64(type, _mtPixelAspect, _pack(1, 1));
      },
      configureInput: (type) {
        _setGuid(type, _mtMajorType, _mediaTypeVideo);
        _setGuid(type, _mtSubtype, _formatRgb32);
        _setU32(type, _mtInterlaceMode, 2);
        _setU32(type, _mtAllSamplesIndependent, 1);
        // Positive stride means top-down, which is how our rows are laid out.
        _setU32(type, _mtDefaultStride, this.width * 4);
        _setU64(type, _mtFrameSize, _pack(this.width, this.height));
        _setU64(type, _mtFrameRate, _pack(frameRate, 1));
        _setU64(type, _mtPixelAspect, _pack(1, 1));
      },
    );
  }

  final int width;
  final int height;
  final int frameRate;
  final _Mp4Sink _sink;
  Duration _at = Duration.zero;

  @override
  void add(RgbaFrame frame) {
    if (frame.width < width || frame.height < height) {
      throw ArgumentError(
        'frame is ${frame.width}x${frame.height}, expected ${width}x$height',
      );
    }
    final hold = frame.hold > Duration.zero
        ? frame.hold
        : Duration(microseconds: 1000000 ~/ frameRate);
    _sink.writeSample(
      length: width * height * 4,
      at: _at,
      hold: hold,
      // Every frame is a candidate; the encoder decides what is really an IDR.
      keyframe: false,
      fill: (destination) => _writeBgra(frame, destination),
    );
    _at += hold;
  }

  /// MF's RGB32 is B, G, R, A; swapping the outer bytes of the word is one
  /// integer op per pixel instead of four byte moves.
  void _writeBgra(RgbaFrame frame, Pointer<Uint8> destination) {
    final aligned =
        frame.rgba.offsetInBytes % 4 == 0 && destination.address % 4 == 0;
    if (aligned) {
      final source = Uint32List.sublistView(frame.rgba);
      final target = destination.cast<Uint32>().asTypedList(width * height);
      for (var row = 0; row < height; row++) {
        final from = row * frame.width;
        final to = row * width;
        for (var x = 0; x < width; x++) {
          final pixel = source[from + x];
          target[to + x] =
              (pixel & 0xFF00FF00) |
              ((pixel & 0xFF) << 16) |
              ((pixel >> 16) & 0xFF);
        }
      }
      return;
    }
    final target = destination.asTypedList(width * height * 4);
    for (var row = 0; row < height; row++) {
      var from = row * frame.width * 4;
      var to = row * width * 4;
      for (var x = 0; x < width; x++) {
        target[to] = frame.rgba[from + 2];
        target[to + 1] = frame.rgba[from + 1];
        target[to + 2] = frame.rgba[from];
        target[to + 3] = 255;
        from += 4;
        to += 4;
      }
    }
  }

  @override
  int finish() => _sink.finish();

  @override
  void abort() => _sink.abort();
}

/// Already-encoded H.264 into an MP4, with no re-encode: the input media type
/// is the output media type, and the payload comes out byte-identical.
class MediaFoundationRemuxer implements VideoRemuxer {
  MediaFoundationRemuxer({
    required String path,
    required this.width,
    required this.height,
    required this.frameRate,
    required Uint8List sequenceHeader,
    required bool hardwareTransforms,
  }) : _sink = _Mp4Sink(path) {
    _sink.open(
      passthrough: true,
      hardwareTransforms: hardwareTransforms,
      configureOutput: (type) {
        _setGuid(type, _mtMajorType, _mediaTypeVideo);
        _setGuid(type, _mtSubtype, _formatH264);
        _setU32(type, _mtInterlaceMode, 2);
        _setU64(type, _mtFrameSize, _pack(width, height));
        _setU64(type, _mtFrameRate, _pack(frameRate, 1));
        _setU64(type, _mtPixelAspect, _pack(1, 1));
        // The SPS/PPS the sample entry is built from.
        if (sequenceHeader.isNotEmpty) {
          _setBlobOn(type, _mtSequenceHeader, sequenceHeader);
        }
      },
    );
  }

  final int width;
  final int height;
  final int frameRate;
  final _Mp4Sink _sink;
  Duration? _first;
  Duration _last = Duration.zero;

  @override
  void add(EncodedVideoFrame frame) {
    // Timestamps arrive from the handset's clock; the file starts at zero.
    _first ??= frame.at;
    final at = frame.at - _first!;
    // A sample's duration is the gap it *closes* — the one it opens is unknown
    // until the next frame — so the track sits one frame late by a fixed
    // offset, which is cheaper than buffering a frame to get it exact.
    final step = at > _last
        ? at - _last
        : Duration(microseconds: 1000000 ~/ frameRate);
    _sink.writeSample(
      length: frame.bytes.length,
      at: at,
      hold: step,
      keyframe: frame.keyframe,
      fill: (destination) =>
          destination.asTypedList(frame.bytes.length).setAll(0, frame.bytes),
    );
    _last = at;
  }

  @override
  int finish() => _sink.finish();

  @override
  void abort() => _sink.abort();
}

/// [hardwareTransforms] has a default only because [VideoEncoderOpener] forbids
/// a required parameter; tests pass `false`.
VideoEncoder openMediaFoundationEncoder({
  required String path,
  required int width,
  required int height,
  required int frameRate,
  bool hardwareTransforms = appHardwareTransforms,
}) => MediaFoundationEncoder(
  path: path,
  width: width,
  height: height,
  frameRate: frameRate,
  hardwareTransforms: hardwareTransforms,
);

/// Same as [openMediaFoundationEncoder] on [hardwareTransforms].
VideoRemuxer openMediaFoundationRemuxer({
  required String path,
  required int width,
  required int height,
  required int frameRate,
  required Uint8List sequenceHeader,
  bool hardwareTransforms = appHardwareTransforms,
}) => MediaFoundationRemuxer(
  path: path,
  width: width,
  height: height,
  frameRate: frameRate,
  sequenceHeader: sequenceHeader,
  hardwareTransforms: hardwareTransforms,
);

/// Roughly 0.1 bits per pixel per frame at 12 fps, which is where a terminal
/// recording stops looking soft without the file growing for nothing.
int _bitrateFor(int width, int height) {
  final pixels = width * height;
  return (pixels * 2).clamp(800000, 12000000);
}

/// Whether this machine can write an MP4 — measured by opening a real sink and
/// asking it to take RGB32, then throwing the file away. `MFTEnumEx` is not the
/// question and answers it wrongly (see docs/SETTLED.md).
VideoSupport probeVideoSupport({required bool hardwareTransforms}) {
  if (!Platform.isWindows) {
    return VideoSupport.unavailable(
      'MP4 needs an encoder from the operating system, and only the Windows '
      'one is wired up here — ${Platform.operatingSystem} is not. '
      'GIF works everywhere.',
    );
  }
  final probe = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'karmashala-mp4-probe-$pid.mp4',
  );
  // 64x64: the H.264 MFT answers MF_E_INVALIDMEDIATYPE to a 16x16 frame, which
  // would read as "no encoder here".
  try {
    _Mp4Sink(probe.path)
      ..open(
        passthrough: false,
        hardwareTransforms: hardwareTransforms,
        configureOutput: (type) {
          _setGuid(type, _mtMajorType, _mediaTypeVideo);
          _setGuid(type, _mtSubtype, _formatH264);
          _setU32(type, _mtAvgBitrate, 800000);
          _setU32(type, _mtInterlaceMode, 2);
          _setU64(type, _mtFrameSize, _pack(64, 64));
          _setU64(type, _mtFrameRate, _pack(12, 1));
          _setU64(type, _mtPixelAspect, _pack(1, 1));
        },
        configureInput: (type) {
          _setGuid(type, _mtMajorType, _mediaTypeVideo);
          _setGuid(type, _mtSubtype, _formatRgb32);
          _setU32(type, _mtInterlaceMode, 2);
          _setU32(type, _mtDefaultStride, 256);
          _setU64(type, _mtFrameSize, _pack(64, 64));
          _setU64(type, _mtFrameRate, _pack(12, 1));
          _setU64(type, _mtPixelAspect, _pack(1, 1));
        },
      )
      ..abort();
    return const VideoSupport.available(
      'Windows encoded H.264 into MP4 when asked — nothing to install.',
    );
  } on Object catch (error) {
    // One message for every refusal: nothing here can tell "no encoder
    // installed" from "the encoder would not take this".
    return VideoSupport.unavailable(
      'Windows would not open an MP4 encoder here ($error), so use GIF.',
    );
  } finally {
    try {
      if (probe.existsSync()) probe.deleteSync();
    } on Object {
      // A stray probe file in the temp directory is not worth a failure.
    }
  }
}
