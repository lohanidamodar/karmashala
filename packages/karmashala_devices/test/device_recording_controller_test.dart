// The recorder, driven entirely by fakes: no handset, no simulator, and no
// real video. What it writes is a real MPEG-TS stream, judged by the same
// validator the live view's muxer is judged by.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_media/media.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:path/path.dart' as p;

import 'support/fake_command_runner.dart';
import 'ts_stream_validator.dart';

/// A clock the test moves by hand, so a recording has a length without the
/// test measuring one.
class _Movable implements Clock {
  _Movable(this._now);
  DateTime _now;
  void advance(Duration by) => _now = _now.add(by);
  @override
  DateTime nowUtc() => _now.toUtc();
}

/// A destination that keeps the bytes in memory, and can be told to fail.
class _ListSink implements RecordingSink {
  _ListSink({this.failAfter});

  final builder = BytesBuilder();
  final _done = Completer<void>();

  /// Byte count after which the destination reports it could not be written —
  /// what running out of disk looks like from here.
  final int? failAfter;

  bool closed = false;

  @override
  void add(List<int> bytes) {
    builder.add(bytes);
    final limit = failAfter;
    if (limit != null && builder.length >= limit && !_done.isCompleted) {
      _done.completeError(
        const FileSystemException('There is not enough space on the disk'),
      );
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<int> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
    return builder.length;
  }
}

/// Stands in for the operating system's MP4 muxer.
class _FakeRemuxer implements VideoRemuxer {
  _FakeRemuxer({
    required this.path,
    required this.width,
    required this.height,
    required this.sequenceHeader,
  });

  final String path;
  final int width;
  final int height;
  final Uint8List sequenceHeader;
  final frames = <EncodedVideoFrame>[];
  bool finished = false;
  bool aborted = false;

  @override
  void add(EncodedVideoFrame frame) => frames.add(frame);

  @override
  int finish() {
    finished = true;
    return frames.isEmpty ? 0 : 20480;
  }

  @override
  void abort() => aborted = true;
}

AndroidTarget _android([String serial = 'emulator-5554']) => AndroidTarget(
  AndroidDevice(
    serial: serial,
    environmentId: 'windows',
    state: DeviceConnectionState.device,
  ),
);

SimulatorTarget _simulator([
  String udid = '70592006-11CD-44A3-96BC-25EE8E72CA3D',
]) => SimulatorTarget(
  IosSimulator(
    udid: udid,
    name: 'iPhone 17',
    state: SimulatorState.booted,
    runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-0',
    deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
    isAvailable: true,
  ),
);

Uint8List _unit(int length, [int fill = 0xAB]) =>
    Uint8List.fromList(List.filled(length, fill));

/// Stands in for one live view: a fresh [TsMuxer] per consumer, fed by hand.
///
/// Shaped exactly like `DeviceStreamSession.openTransportStream` — the first
/// event is the container tables, every event after it is one access unit —
/// because the contract that the first event carries no picture is what tells
/// "nothing was recorded" apart from "a header and no frames".
class _FakeLiveView {
  _FakeLiveView(this.target);

  final DeviceTarget target;
  final _frames = StreamController<Uint8List>.broadcast();
  final _sizes = StreamController<DeviceScreenSize>.broadcast();
  var _pts = 0;

  /// How many consumers have opened a stream — one for the picture, one more
  /// for a recording.
  int consumers = 0;

  LiveViewRecordingSource get source => LiveViewRecordingSource(
    target: target,
    openTransportStream: _open,
    openAccessUnits: _openUnits,
    geometryChanges: _sizes.stream,
  );

  /// The same frames unmuxed — `DeviceStreamSession.openAccessUnits`' shape.
  Stream<DeviceAccessUnit> _openUnits() async* {
    consumers += 1;
    var first = true;
    await for (final unit in _frames.stream) {
      yield DeviceAccessUnit(
        bytes: unit,
        ptsUs: _pts,
        keyframe: first,
        width: 1080,
        height: 2400,
        sequenceHeader: _unit(20, 0x67),
      );
      first = false;
    }
  }

  Stream<List<int>> _open() async* {
    consumers += 1;
    final muxer = TsMuxer();
    yield muxer.tables();
    var first = true;
    await for (final unit in _frames.stream) {
      yield muxer.frame(unit, _pts, keyframe: first);
      first = false;
    }
  }

  Future<void> sendFrame([int size = 900]) async {
    // A consumer that has just been handed this stream has not subscribed to
    // the frame controller yet, and a broadcast controller drops what it has
    // no listener for — the same reason a live view starts from the cached
    // keyframe rather than from whatever was in flight.
    await pumpEventQueue();
    _pts += 50000;
    _frames.add(_unit(size));
    await pumpEventQueue();
  }

  Future<void> rotate() async {
    _sizes.add(const DeviceScreenSize(width: 1080, height: 2400));
    await pumpEventQueue();
  }

  /// The live view going away: the pane unmounted, the stream restarted, or
  /// the device was unplugged.
  Future<void> end() async {
    await _frames.close();
    await _sizes.close();
    await pumpEventQueue();
  }
}

/// Waits for the recorder to write an outcome, without asking it repeatedly
/// whether it has.
Future<DeviceRecordingOutcome> settled(ProviderContainer ref) async {
  final now = ref.read(deviceRecordingProvider);
  if (now is DeviceRecordingIdle && now.last != null) return now.last!;
  final done = Completer<DeviceRecordingOutcome>();
  final subscription = ref.listen<DeviceRecordingState>(
    deviceRecordingProvider,
    (_, next) {
      if (next is DeviceRecordingIdle &&
          next.last != null &&
          !done.isCompleted) {
        done.complete(next.last!);
      }
    },
  );
  final outcome = await done.future;
  subscription.close();
  return outcome;
}

void main() {
  late Directory directory;
  late _Movable clock;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('karmashala_rec_test');
    clock = _Movable(DateTime.utc(2026, 9, 8, 14, 3, 7));
  });

  tearDown(() async {
    try {
      if (directory.existsSync()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Windows refuses to delete a file another handle still holds. A leftover
      // temp file is the OS's to clean up and is not what any test is about.
    }
  });

  ProviderContainer container({
    RecordingSinkOpener? opener,
    SimctlService? simctl,
    Mp4WriterOpener? mp4,
  }) {
    final made = ProviderContainer(
      overrides: [
        deviceClockProvider.overrideWithValue(clock),
        deviceRecordingDirectoryProvider.overrideWithValue(
          () async => directory.path,
        ),
        if (opener != null) recordingSinkOpenerProvider.overrideWithValue(opener),
        if (mp4 != null) mp4WriterOpenerProvider.overrideWithValue(mp4),
        simctlServiceProvider.overrideWithValue(simctl),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  /// An MP4 writer with the operating system's muxer faked out.
  ({Mp4WriterOpener opener, List<_FakeRemuxer> made}) fakeMp4() {
    final made = <_FakeRemuxer>[];
    return (
      opener: (String path) => Mp4RecordingWriter.open(
        path,
        openRemuxer:
            ({
              required String path,
              required int width,
              required int height,
              required int frameRate,
              required Uint8List sequenceHeader,
            }) {
              final remuxer = _FakeRemuxer(
                path: path,
                width: width,
                height: height,
                sequenceHeader: sequenceHeader,
              );
              made.add(remuxer);
              return remuxer;
            },
      ),
      made: made,
    );
  }

  group('recording an Android live view', () {
    test('does nothing until a live view has been offered', () async {
      final sink = _ListSink();
      final ref = container(opener: (_) async => sink);

      await ref.read(deviceRecordingProvider.notifier).startLiveViewRecording();

      expect(ref.read(deviceRecordingProvider), isA<DeviceRecordingIdle>());
      expect(sink.closed, isFalse);
    });

    test('says which device it is recording and where the file is', () async {
      final ref = container(opener: (_) async => _ListSink());
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();

      final state = ref.read(deviceRecordingProvider);
      expect(state, isA<DeviceRecordingActive>());
      final active = state as DeviceRecordingActive;
      expect(active.target.id, 'emulator-5554');
      expect(active.receiving, isTrue);
      expect(p.basename(active.path), 'emulator-5554-20260908-140307.ts');
      expect(active.path, startsWith(directory.path));
    });

    test('a wireless serial never reaches the path', () async {
      final ref = container(opener: (_) async => _ListSink());
      final live = _FakeLiveView(_android('192.168.1.24:37129'));
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();

      final active =
          ref.read(deviceRecordingProvider) as DeviceRecordingActive;
      expect(p.basename(active.path), isNot(contains(':')));
      expect(p.basename(active.path), '192.168.1.24-37129-20260908-140307.ts');
    });

    test('the file is a valid transport stream a demuxer can read', () async {
      final ref = container(opener: FileRecordingSink.open);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      final path =
          (ref.read(deviceRecordingProvider) as DeviceRecordingActive).path;
      for (var i = 0; i < 5; i++) {
        await live.sendFrame(700 + i * 100);
      }
      clock.advance(const Duration(seconds: 12));
      await recorder.stop();

      final report = validateTransportStream(
        await File(path).readAsBytes(),
      );
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes, hasLength(5));
      expect(report.patPackets, isNotEmpty);
    });

    test('costs the device nothing: no process, and no second capture',
        () async {
      final before = processSpawnsOnThisIsolate;
      final ref = container(opener: (_) async => _ListSink());
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      await live.sendFrame();
      await recorder.stop();

      expect(processSpawnsOnThisIsolate - before, 0);
      // One consumer, and it is the recording's. The picture opens its own;
      // neither asks the device for a second stream.
      expect(live.consumers, 1);
    });

    test('a stopped recording names the file, its size and how long it ran',
        () async {
      final ref = container(opener: (_) async => _ListSink());
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      await live.sendFrame();
      clock.advance(const Duration(seconds: 12));
      await recorder.stop();

      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.result, DeviceRecordingResult.saved);
      expect(idle.last!.message, contains('over 12s'));
      expect(idle.last!.path, endsWith('.ts'));
    });

    test('a recording no frame ever reached is not offered as a file',
        () async {
      final ref = container(opener: FileRecordingSink.open);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      final path =
          (ref.read(deviceRecordingProvider) as DeviceRecordingActive).path;
      await recorder.stop();

      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.result, DeviceRecordingResult.empty);
      expect(idle.last!.path, isNull);
      expect(idle.last!.message, contains('Nothing was recorded'));
      expect(File(path).existsSync(), isFalse);
    });

    test('a destination that will not open ends before it starts', () async {
      final ref = container(
        opener: (_) async =>
            throw const FileSystemException('read-only file system'),
      );
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();

      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.result, DeviceRecordingResult.failed);
      expect(idle.last!.message, contains('read-only file system'));
    });

    test('running out of disk stops the recording and keeps what it had',
        () async {
      final sink = _ListSink(failAfter: 400);
      final ref = container(opener: (_) async => sink);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      await live.sendFrame();

      final outcome = await settled(ref);
      expect(outcome.result, DeviceRecordingResult.failed);
      expect(outcome.message, contains('not enough space'));
      expect(outcome.message, contains('was saved before it'));
      expect(sink.closed, isTrue);
    });
  });

  group('recording an Android live view into an MP4', () {
    test('names the file .mp4 and opens no container before a frame', () async {
      final fake = fakeMp4();
      final ref = container(mp4: fake.opener);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording(
        container: DeviceRecordingContainer.mp4,
      );

      final active = ref.read(deviceRecordingProvider) as DeviceRecordingActive;
      expect(p.basename(active.path), 'emulator-5554-20260908-140307.mp4');
      // Nothing is muxed until a frame says how big the picture is.
      expect(fake.made, isEmpty);
    });

    test('muxes the handset frames with no re-encode', () async {
      final fake = fakeMp4();
      final ref = container(mp4: fake.opener);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording(
        container: DeviceRecordingContainer.mp4,
      );
      await live.sendFrame(700);
      await live.sendFrame(500);
      await recorder.stop();

      final remuxer = fake.made.single;
      expect(remuxer.width, 1080);
      expect(remuxer.height, 2400);
      expect(remuxer.sequenceHeader, isNotEmpty);
      // The bytes go through untouched — a container change, not an encode.
      expect(remuxer.frames.map((frame) => frame.bytes.length), [700, 500]);
      expect(remuxer.frames.first.keyframe, isTrue);
      expect(remuxer.finished, isTrue);

      final outcome = await settled(ref);
      expect(outcome.result, DeviceRecordingResult.saved);
      expect(outcome.path, endsWith('.mp4'));
    });

    test('a rotation says the picture after it is stretched', () async {
      final fake = fakeMp4();
      final ref = container(mp4: fake.opener);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording(
        container: DeviceRecordingContainer.mp4,
      );
      await live.sendFrame();
      await live.rotate();
      await recorder.stop();

      final outcome = await settled(ref);
      // MP4 fixed the size in its sample entry, so this is what the file now
      // is — not a footnote about the device.
      expect(outcome.message, contains('keeps the size it started with'));
      expect(outcome.message, contains('record to MPEG-TS'));
    });

    test('no frame at all is nothing recorded, and no file', () async {
      final fake = fakeMp4();
      final ref = container(mp4: fake.opener);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording(
        container: DeviceRecordingContainer.mp4,
      );
      await recorder.stop();

      final outcome = await settled(ref);
      expect(outcome.result, DeviceRecordingResult.empty);
      expect(outcome.path, isNull);
      expect(fake.made, isEmpty);
    });
  });

  group('when the live view goes away under it', () {
    test('the recording stays open, and says it is not capturing', () async {
      final ref = container(opener: (_) async => _ListSink());
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      await live.sendFrame();
      await live.end();

      final state = ref.read(deviceRecordingProvider);
      expect(
        state,
        isA<DeviceRecordingActive>(),
        reason: 'a recording dropped on a pane switch is the bug',
      );
      expect((state as DeviceRecordingActive).receiving, isFalse);
    });

    test('a live view that comes back is recorded into the same file', () async {
      final sink = _ListSink();
      final ref = container(opener: (_) async => sink);
      final first = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(first.source);
      await recorder.startLiveViewRecording();
      await first.sendFrame();
      final afterFirst = sink.builder.length;
      await first.end();

      final second = _FakeLiveView(_android());
      recorder.offerLiveView(second.source);
      await second.sendFrame();

      final active =
          ref.read(deviceRecordingProvider) as DeviceRecordingActive;
      expect(active.receiving, isTrue);
      expect(active.gaps, 1);
      expect(sink.builder.length, greaterThan(afterFirst));
    });

    test('the gap is a sentence of its own when the recording ends', () async {
      final ref = container(opener: (_) async => _ListSink());
      final first = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(first.source);
      await recorder.startLiveViewRecording();
      await first.sendFrame();
      await first.end();
      final second = _FakeLiveView(_android());
      recorder.offerLiveView(second.source);
      await second.sendFrame();
      clock.advance(const Duration(seconds: 4));
      await recorder.stop();

      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.message, contains('the picture jumps once'));
    });

    test('a live view of another device is never spliced into the file',
        () async {
      final sink = _ListSink();
      final ref = container(opener: (_) async => sink);
      final first = _FakeLiveView(_android('emulator-5554'));
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(first.source);
      await recorder.startLiveViewRecording();
      await first.sendFrame();
      await first.end();

      final other = _FakeLiveView(_android('emulator-5556'));
      recorder.offerLiveView(other.source);
      await other.sendFrame();

      expect(other.consumers, 0);
      final active =
          ref.read(deviceRecordingProvider) as DeviceRecordingActive;
      expect(active.receiving, isFalse);
      expect(active.gaps, 0);
    });
  });

  group('when the device rotates', () {
    test('the recording carries on, and the file says it changes size',
        () async {
      final ref = container(opener: FileRecordingSink.open);
      final live = _FakeLiveView(_android());
      final recorder = ref.read(deviceRecordingProvider.notifier);

      recorder.offerLiveView(live.source);
      await recorder.startLiveViewRecording();
      await live.sendFrame();
      await live.rotate();
      await live.sendFrame();

      expect(
        (ref.read(deviceRecordingProvider) as DeviceRecordingActive)
            .geometryChanges,
        1,
      );
      clock.advance(const Duration(seconds: 3));
      await recorder.stop();

      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.result, DeviceRecordingResult.saved);
      expect(idle.last!.message, contains('changes size partway through'));
    });
  });

  group('recording a simulator', () {
    test('a host with no simulators records nothing and claims nothing',
        () async {
      final ref = container();

      await ref
          .read(deviceRecordingProvider.notifier)
          .startSimulatorRecording(_simulator());

      expect(ref.read(deviceRecordingProvider), isA<DeviceRecordingIdle>());
      expect(
        (ref.read(deviceRecordingProvider) as DeviceRecordingIdle).last,
        isNull,
      );
    });

    test('asks simctl to record, and names the file .mov', () async {
      final runner = FakeCommandRunner();
      final ref = container(simctl: SimctlService(runner: runner));

      await ref
          .read(deviceRecordingProvider.notifier)
          .startSimulatorRecording(_simulator());

      final active =
          ref.read(deviceRecordingProvider) as DeviceRecordingActive;
      expect(p.basename(active.path), endsWith('-20260908-140307.mov'));
      expect(runner.startRequests.single.arguments, [
        'simctl',
        'io',
        _simulator().id,
        'recordVideo',
        active.path,
      ]);
    });

    test('is stopped with an interrupt, because a kill loses the index',
        () async {
      late FakeProcessHandle handle;
      final runner = FakeCommandRunner(
        processFactory: (_) => handle = FakeProcessHandle(),
      );
      final ref = container(simctl: SimctlService(runner: runner));
      final recorder = ref.read(deviceRecordingProvider.notifier);

      await recorder.startSimulatorRecording(_simulator());
      final path =
          (ref.read(deviceRecordingProvider) as DeviceRecordingActive).path;
      // What simctl would have written by now.
      await File(path).writeAsBytes(List.filled(2048, 0));
      clock.advance(const Duration(seconds: 6));
      await recorder.stop();

      expect(handle.interrupted, isTrue);
      expect(handle.killed, isFalse);
      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.result, DeviceRecordingResult.saved);
      expect(idle.last!.message, contains('2.0 KB over 6s'));
    });

    test('simctl exiting on its own is reported as ending early', () async {
      late FakeProcessHandle handle;
      final runner = FakeCommandRunner(
        processFactory: (_) => handle = FakeProcessHandle(),
      );
      final ref = container(simctl: SimctlService(runner: runner));
      final recorder = ref.read(deviceRecordingProvider.notifier);

      await recorder.startSimulatorRecording(_simulator());
      final path =
          (ref.read(deviceRecordingProvider) as DeviceRecordingActive).path;
      await File(path).writeAsBytes(List.filled(1024, 0));
      clock.advance(const Duration(seconds: 2));
      handle.complete(1);

      final outcome = await settled(ref);
      expect(outcome.message, startsWith('Recording ended early:'));
      expect(outcome.message, contains('exited with 1'));
      expect(outcome.path, endsWith('.mov'));
    });

    test('a simctl that refused leaves no claim of a recording', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('xcrun could not be started'),
      );
      final ref = container(simctl: SimctlService(runner: runner));

      await ref
          .read(deviceRecordingProvider.notifier)
          .startSimulatorRecording(_simulator());

      final idle = ref.read(deviceRecordingProvider) as DeviceRecordingIdle;
      expect(idle.last!.result, DeviceRecordingResult.failed);
      expect(idle.last!.message, contains('xcrun could not be started'));
    });

    test('a second recording is refused while one is running', () async {
      final runner = FakeCommandRunner();
      final ref = container(simctl: SimctlService(runner: runner));
      final recorder = ref.read(deviceRecordingProvider.notifier);

      await recorder.startSimulatorRecording(_simulator());
      await recorder.startSimulatorRecording(_simulator('other-udid'));

      expect(runner.startRequests, hasLength(1));
    });
  });
}
