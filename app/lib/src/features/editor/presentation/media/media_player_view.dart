import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/media_kind.dart';

/// A video or audio file played by media_kit, paused at the start until the
/// reader presses play. Only built where the client has a media backend
/// (`ClientCapabilities.mediaPlayback`): a [Player] elsewhere throws.
class MediaPlayerView extends StatefulWidget {
  const MediaPlayerView({
    required this.path,
    required this.kind,
    this.revision = 0,
    this.showing = true,
    super.key,
  }) : assert(kind != MediaKind.image, 'an image is the ImageViewer\'s');

  /// A path on this machine: the file itself, or its copy in the media cache.
  final String path;
  final MediaKind kind;

  /// A new revision is a new file on disk, opened again where it was.
  final int revision;

  /// Whether its tab is the one on screen. The stack keeps hidden tabs
  /// mounted, and a player left running there is sound nobody can stop and
  /// frames nobody sees — so going off screen pauses it. Coming back does not
  /// resume: playing is the reader's to ask for.
  final bool showing;

  @override
  State<MediaPlayerView> createState() => _MediaPlayerViewState();
}

class _MediaPlayerViewState extends State<MediaPlayerView> {
  late final Player _player = Player();

  /// Null for audio: there is no picture to draw.
  VideoController? _video;
  StreamSubscription<String>? _errors;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.kind == MediaKind.video) _video = VideoController(_player);
    _errors = _player.stream.error.listen((message) {
      if (mounted) setState(() => _error = message);
    });
    _open(resumeAt: _lastPositions.remove(widget.path) ?? Duration.zero);
  }

  /// Where each file was left when its player went — a tab evicted from the
  /// stack (`kMountedTabBudget`) and brought back resumes there, paused.
  /// Process-lifetime and small: a handful of positions keyed by path.
  static final Map<String, Duration> _lastPositions = {};

  @override
  void didUpdateWidget(MediaPlayerView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.revision != widget.revision) {
      _open(resumeAt: _player.state.position);
    }
    if (old.showing && !widget.showing) unawaited(_player.pause());
  }

  @override
  void dispose() {
    final at = _player.state.position;
    if (at > Duration.zero) {
      if (_lastPositions.length >= 32) {
        _lastPositions.remove(_lastPositions.keys.first);
      }
      _lastPositions[widget.path] = at;
    }
    unawaited(_errors?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  /// Opens the file paused. A reload of the file being watched — an agent
  /// re-rendering a recording — comes back at [resumeAt], not at 0:00, so
  /// watching a file being rewritten does not throw the reader to the start.
  void _open({Duration resumeAt = Duration.zero}) {
    _error = null;
    unawaited(_openAt(resumeAt));
  }

  Future<void> _openAt(Duration resumeAt) async {
    try {
      await _player.open(Media(widget.path), play: false);
      if (resumeAt <= Duration.zero) return;
      // A seek before the duration is known is dropped by the backend.
      final duration = _player.state.duration > Duration.zero
          ? _player.state.duration
          : await _player.stream.duration
                .firstWhere((d) => d > Duration.zero)
                .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      await _player.seek(resumeAt < duration ? resumeAt : duration);
    } on Object {
      // A file that will not open says so on the error stream; a resume that
      // could not happen leaves the player at the start, which is no harm.
    }
  }

  /// media_kit's default bindings, less Escape: outside fullscreen it would
  /// take the key from the shell (closing a dialog, leaving a mode) for an
  /// exit there is nothing to exit from. Fullscreen keeps its own defaults.
  late final Map<ShortcutActivator, VoidCallback> _shortcuts = {
    const SingleActivator(LogicalKeyboardKey.mediaPlay): () =>
        unawaited(_player.play()),
    const SingleActivator(LogicalKeyboardKey.mediaPause): () =>
        unawaited(_player.pause()),
    const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
        unawaited(_player.playOrPause()),
    const SingleActivator(LogicalKeyboardKey.space): () =>
        unawaited(_player.playOrPause()),
    const SingleActivator(LogicalKeyboardKey.keyJ): () =>
        _seekBy(const Duration(seconds: -10)),
    const SingleActivator(LogicalKeyboardKey.keyL): () =>
        _seekBy(const Duration(seconds: 10)),
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        _seekBy(const Duration(seconds: -2)),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _seekBy(const Duration(seconds: 2)),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _volumeBy(5),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _volumeBy(-5),
  };

  void _seekBy(Duration by) =>
      unawaited(_player.seek(_player.state.position + by));

  void _volumeBy(double by) => unawaited(
    _player.setVolume((_player.state.volume + by).clamp(0.0, 100.0)),
  );

  @override
  Widget build(BuildContext context) {
    final video = _video;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error case final error?)
          PaneNoticeBar(
            icon: AppIcons.warningCircle,
            tone: NoticeTone.danger,
            message: "Can't play this file: $error",
          ),
        Expanded(
          child: video != null
              ? MaterialDesktopVideoControlsTheme(
                  normal: MaterialDesktopVideoControlsThemeData(
                    keyboardShortcuts: _shortcuts,
                  ),
                  fullscreen: const MaterialDesktopVideoControlsThemeData(),
                  child: Video(
                    controller: video,
                    controls: MaterialDesktopVideoControls,
                  ),
                )
              : Center(child: _AudioCard(player: _player)),
        ),
      ],
    );
  }
}

/// Play, a seek bar and the time, for a file with nothing to look at.
class _AudioCard extends StatefulWidget {
  const _AudioCard({required this.player});

  final Player player;

  @override
  State<_AudioCard> createState() => _AudioCardState();
}

class _AudioCardState extends State<_AudioCard> {
  final List<StreamSubscription<Object>> _subscriptions = [];
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// Where the thumb is while it is dragged; the player's position would
  /// otherwise pull it back every tick.
  double? _dragging;

  @override
  void initState() {
    super.initState();
    final stream = widget.player.stream;
    final state = widget.player.state;
    _playing = state.playing;
    _position = state.position;
    _duration = state.duration;
    _subscriptions.addAll([
      stream.playing.listen((v) => _set(() => _playing = v)),
      stream.position.listen((v) => _set(() => _position = v)),
      stream.duration.listen((v) => _set(() => _duration = v)),
    ]);
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _duration.inMilliseconds.toDouble();
    final at = (_dragging ?? _position.inMilliseconds.toDouble()).clamp(
      0.0,
      total > 0 ? total : 0.0,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Row(
          children: [
            IconButton(
              tooltip: _playing ? 'Pause' : 'Play',
              icon: Icon(_playing ? AppIcons.pause : AppIcons.play),
              onPressed: () => unawaited(widget.player.playOrPause()),
            ),
            Expanded(
              child: Slider(
                value: at,
                max: total > 0 ? total : 1,
                onChanged: total > 0
                    ? (v) => setState(() => _dragging = v)
                    : null,
                onChangeEnd: (v) {
                  setState(() => _dragging = null);
                  unawaited(
                    widget.player.seek(Duration(milliseconds: v.round())),
                  );
                },
              ),
            ),
            Text(
              '${formatPlaybackTime(Duration(milliseconds: at.round()))} / '
              '${formatPlaybackTime(_duration)}',
              style: MonoStyles.small.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `m:ss`, or `h:mm:ss` past an hour.
String formatPlaybackTime(Duration time) {
  final seconds = time.inSeconds % 60;
  final minutes = time.inMinutes % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (time.inHours == 0) return '$minutes:$ss';
  return '${time.inHours}:${minutes.toString().padLeft(2, '0')}:$ss';
}
