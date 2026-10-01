import 'dart:async';

import 'package:flutter/material.dart';
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
    super.key,
  }) : assert(kind != MediaKind.image, 'an image is the ImageViewer\'s');

  /// A path on this machine: the file itself, or its copy in the media cache.
  final String path;
  final MediaKind kind;

  /// A new revision is a new file on disk, opened again from the start.
  final int revision;

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
    _open();
  }

  @override
  void didUpdateWidget(MediaPlayerView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.revision != widget.revision) _open();
  }

  @override
  void dispose() {
    unawaited(_errors?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  void _open() {
    _error = null;
    unawaited(_player.open(Media(widget.path), play: false));
  }

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
              ? Video(controller: video, controls: MaterialDesktopVideoControls)
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
