import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:xterm2/xterm.dart';

import '../../../app/theme/design_tokens.dart';
import '../../../core/media/frame_sink.dart';
import '../../../core/paths/app_support_directory.dart';
import '../data/cast_frame_renderer.dart';
import '../data/cast_recorder.dart';
import '../data/terminal_instance.dart';
import '../domain/terminal_cast.dart';
import 'terminal_sessions_controller.dart';

/// Where recordings are written.
///
/// Under the application support directory, beside the database and the logs,
/// for the same reason the media cache is: a recording has to survive a reboot's
/// sweep of the temp directory, and the user is told the path and offered a way
/// to open it.
final recordingsDirectoryProvider = FutureProvider<Directory>((ref) async {
  final support = await appSupportDirectory();
  final dir = Directory(p.join(support.path, 'recordings'));
  await dir.create(recursive: true);
  return dir;
});

/// A recording that has stopped and been written to disk.
class SavedRecording {
  const SavedRecording({
    required this.paneId,
    required this.cast,
    required this.file,
    required this.endedWithPane,
  });

  final String paneId;
  final TerminalCast cast;

  /// The `.cast` file. Written the moment recording stops, before anything is
  /// rendered: the cast is the recording, and everything else is a view of it.
  final File file;

  /// Whether the pane went away rather than the user pressing stop.
  final bool endedWithPane;
}

/// A render in flight, or the file one produced.
class RecordingExport {
  const RecordingExport({
    required this.format,
    this.rendered = 0,
    this.total = 0,
    this.result,
    this.error,
  });

  final RecordingFormat format;
  final int rendered;
  final int total;
  final FrameSinkResult? result;
  final String? error;

  bool get isRunning => result == null && error == null;

  /// Null until the first frame is planned — a bar that guesses is a bar that
  /// lies.
  double? get progress => total == 0 ? null : rendered / total;

  RecordingExport copyWith({
    int? rendered,
    int? total,
    FrameSinkResult? result,
    String? error,
  }) => RecordingExport(
    format: format,
    rendered: rendered ?? this.rendered,
    total: total ?? this.total,
    result: result ?? this.result,
    error: error ?? this.error,
  );
}

class TerminalRecordingState {
  const TerminalRecordingState({
    this.active = const {},
    this.saved,
    this.export,
  });

  /// Pane id to the recorder taping it.
  final Map<String, CastRecorder> active;

  /// The recording waiting for the user to say what to do with it.
  final SavedRecording? saved;

  final RecordingExport? export;

  bool isRecording(String paneId) => active.containsKey(paneId);

  bool get anyRecording => active.isNotEmpty;

  TerminalRecordingState copyWith({
    Map<String, CastRecorder>? active,
    SavedRecording? saved,
    RecordingExport? export,
    bool clearSaved = false,
    bool clearExport = false,
  }) => TerminalRecordingState(
    active: active ?? this.active,
    saved: clearSaved ? null : (saved ?? this.saved),
    export: clearExport ? null : (export ?? this.export),
  );
}

/// Starts, stops and renders terminal recordings.
///
/// **Not disposed with any pane.** A recording is a long-lived side effect and
/// must survive the pane being switched away from, stacked behind another tab
/// or dropped to the cold ingest tier — so it lives here, in a provider bound to
/// the container, and not in a widget's `State`. The device pane learned this
/// the expensive way with `_liveSerial`.
///
/// **A cast is not redactable, and this does not pretend otherwise.**
/// `LogRedactor` matches plain substrings; terminal output interleaves SGR
/// escapes through the middle of words, so every one of its patterns can be
/// defeated by the colour a shell puts on a token — and a redactor that rewrote
/// bytes inside an escape sequence would corrupt the replay. A recording is
/// exactly what was on the screen, and the only honest handling is to say so
/// before the user shares it, which the save dialog does. What is *not* in a
/// cast is anything the shell never echoed: only output is captured, so the
/// password `read -s` is waiting for never enters the file.
class TerminalRecordingController extends Notifier<TerminalRecordingState> {
  @override
  TerminalRecordingState build() => const TerminalRecordingState();

  /// Begins recording the pane [paneId]. A no-op for a pane with nothing to
  /// tape — an error pane, a dormant one, or one that is already recording.
  bool start(String paneId) {
    if (state.isRecording(paneId)) return false;
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null || instance is! RecordableTerminalInstance) {
      return false;
    }
    // Promotion across two unrelated interfaces does not survive the null test.
    final recordable = instance as RecordableTerminalInstance;

    // Resolved now, while there is certainly a container to resolve it in. A
    // pane that ends during app quit still has to know where to write, and by
    // then this provider is gone — see [_paneEnded].
    final destination = ref.read(recordingsDirectoryProvider.future);
    final terminal = instance.terminal;
    late final CastRecorder recorder;
    recorder = CastRecorder(
      columns: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
      rows: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
      title: instance.title,
      onSourceEnded: () => _paneEnded(paneId, recorder, destination),
    );
    recordable.startRecording(recorder);
    state = state.copyWith(active: {...state.active, paneId: recorder});
    return true;
  }

  Future<SavedRecording?>? _pendingSave;

  /// The write the last stop started, so a caller can wait for it.
  ///
  /// A pane that ends mid-recording does so from inside its own `dispose()`,
  /// which cannot await anything — the write is still in flight when the pane
  /// is already gone. Null before the first stop.
  Future<SavedRecording?>? get pendingSave => _pendingSave;

  /// Stops recording [paneId] and writes the cast.
  ///
  /// The pane is released synchronously, before the write: a user who pressed
  /// stop must not see a banner that is still claiming to record while a file
  /// is written.
  Future<SavedRecording?> stop(String paneId) {
    final recorder = state.active[paneId];
    if (recorder == null) return Future.value();
    _release(paneId);
    final save = _write(
      paneId,
      recorder,
      ref.read(recordingsDirectoryProvider.future),
      endedWithPane: false,
    );
    _pendingSave = save;
    return save;
  }

  /// The pane went away rather than the user pressing stop.
  ///
  /// Deferred by a microtask, and that is not tidiness. This is called from a
  /// pane's `dispose()`, which on quit runs inside the provider container's own
  /// teardown — and Riverpod forbids reading or writing any provider's state
  /// from inside a life-cycle. Everything here therefore waits for that to
  /// unwind, and then checks whether there is still a container at all.
  void _paneEnded(
    String paneId,
    CastRecorder recorder,
    Future<Directory> destination,
  ) {
    final save = Future.microtask(() {
      if (ref.mounted) _release(paneId);
      return _write(paneId, recorder, destination, endedWithPane: true);
    });
    _pendingSave = save;
    unawaited(save);
  }

  /// Takes the pane off the recording list and off the tap.
  void _release(String paneId) {
    if (state.active.containsKey(paneId)) {
      state = state.copyWith(active: {...state.active}..remove(paneId));
    }
    if (ref.read(terminalSessionsControllerProvider.notifier).instanceFor(
          paneId,
        )
        case final RecordableTerminalInstance recordable) {
      recordable.stopRecording();
    }
  }

  Future<SavedRecording?> _write(
    String paneId,
    CastRecorder recorder,
    Future<Directory> destination, {
    required bool endedWithPane,
  }) async {
    final cast = recorder.stop();
    final directory = await destination;
    final file = File(
      p.join(directory.path, recordingFileName(recorder.title, cast.recordedAt)),
    );
    await file.writeAsString(encodeCast(cast));

    final saved = SavedRecording(
      paneId: paneId,
      cast: cast,
      file: file,
      endedWithPane: endedWithPane,
    );
    // The file is on disk either way; only the announcement needs a container
    // still to announce into. Quitting mid-recording is exactly this path.
    if (ref.mounted) state = state.copyWith(saved: saved, clearExport: true);
    return saved;
  }

  /// Which resolution goes with which format.
  ///
  /// Here rather than in the dialog because the export dialog and the MCP tool
  /// both need it, and two definitions would let an agent's MP4 come out a
  /// different size from the user's.
  ///
  /// [theme] is the app's terminal colours when there is a widget to ask; the
  /// default terminal theme otherwise, which is all an agent can honestly use.
  static CastFrameStyle styleFor({
    required RecordingFormat format,
    required TerminalCast cast,
    TerminalTheme? theme,
    String fontFamily = kMonoFamily,
  }) => switch (format) {
    RecordingFormat.gif => CastFrameStyle.gif(
      theme: theme ?? TerminalThemes.defaultTheme,
      fontFamily: fontFamily,
      title: cast.title,
    ),
    RecordingFormat.mp4 || RecordingFormat.pngSequence => CastFrameStyle.fullHd(
      theme: theme ?? TerminalThemes.defaultTheme,
      fontFamily: fontFamily,
      title: cast.title,
    ),
  };

  /// Renders [saved] into a video file, one frame at a time.
  Future<void> render(
    SavedRecording saved, {
    required RecordingFormat format,
    required CastFrameStyle style,
  }) async {
    if (state.export?.isRunning ?? false) return;
    state = state.copyWith(export: RecordingExport(format: format));

    final base = p.withoutExtension(saved.file.path);
    final sink = IsolateFrameSink(
      format: format,
      outputPath: switch (format) {
        RecordingFormat.gif => '$base.gif',
        RecordingFormat.mp4 => '$base.mp4',
        RecordingFormat.pngSequence => '$base-frames',
      },
    );
    try {
      final result = await CastFrameRenderer(
        cast: saved.cast,
        style: style,
      ).renderTo(
        sink,
        onProgress: (rendered, total) {
          final export = state.export;
          if (export == null || !export.isRunning) return;
          state = state.copyWith(
            export: export.copyWith(rendered: rendered, total: total),
          );
        },
        cancelled: () => state.export == null,
      );
      final export = state.export;
      if (export != null) {
        state = state.copyWith(export: export.copyWith(result: result));
      }
    } on CastRenderCancelled {
      // The user asked; the state was already cleared by [cancelRender].
    } catch (error) {
      final export = state.export;
      if (export != null) {
        state = state.copyWith(export: export.copyWith(error: '$error'));
      }
    }
  }

  /// Abandons the render in flight. The `.cast` file is untouched — it was
  /// written when recording stopped.
  void cancelRender() => state = state.copyWith(clearExport: true);

  /// Puts the finished recording away.
  void dismiss() =>
      state = state.copyWith(clearSaved: true, clearExport: true);
}

final terminalRecordingProvider =
    NotifierProvider<TerminalRecordingController, TerminalRecordingState>(
      TerminalRecordingController.new,
    );

/// `pwsh-20260908-143005.cast`, from the pane's title and when it started.
///
/// The title is squeezed to what a file name can hold on every platform this
/// runs on, because a pane can be called anything a shell's OSC 0 says it is.
String recordingFileName(String? title, DateTime recordedAt) {
  final at = recordedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  final safe = (title ?? 'terminal')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final stem = safe.isEmpty ? 'terminal' : safe;
  return '${stem.length > 40 ? stem.substring(0, 40) : stem}-$stamp.cast';
}
