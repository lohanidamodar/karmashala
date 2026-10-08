// A step's tile and its screenshot and file attachments.

part of '../verification_pane.dart';

class _StepTile extends StatelessWidget {
  const _StepTile({required this.run, required this.step});

  final VerificationRun run;
  final VerificationStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final files = run.artifacts
        .where((a) => a.stepOrdinal == step.ordinal)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${step.ordinal}',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${step.kind.label}  ',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: step.ok
                              ? theme.colorScheme.onSurfaceVariant
                              : semantic.failure,
                        ),
                      ),
                      TextSpan(
                        text: step.summary,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (step.detail != null)
                  Text(
                    step.detail!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: step.ok
                          ? theme.colorScheme.onSurfaceVariant
                          : semantic.failure,
                    ),
                  ),
                if (files.isNotEmpty)
                  Text(
                    files.map((f) => f.relativePath).join('  '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenshotTile extends ConsumerStatefulWidget {
  const _ScreenshotTile({required this.run, required this.artifact});

  final VerificationRun run;
  final VerificationArtifact artifact;

  @override
  ConsumerState<_ScreenshotTile> createState() => _ScreenshotTileState();
}

class _ScreenshotTileState extends ConsumerState<_ScreenshotTile> {
  /// Asked once per tile, not per build: the pane rebuilds on every scroll.
  late Future<ImageProvider?> _image;

  String get _path =>
      p.join(widget.run.artifactDirectory, widget.artifact.relativePath);

  @override
  void initState() {
    super.initState();
    _image = ref.read(verificationEvidenceReaderProvider).image(_path);
  }

  @override
  void didUpdateWidget(_ScreenshotTile old) {
    super.didUpdateWidget(old);
    if (old.run.artifactDirectory != widget.run.artifactDirectory ||
        old.artifact.relativePath != widget.artifact.relativePath) {
      _image = ref.read(verificationEvidenceReaderProvider).image(_path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artifact = widget.artifact;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${artifact.label} · ${artifact.sizeLabel}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: FutureBuilder<ImageProvider?>(
              future: _image,
              builder: (context, snapshot) {
                // A tile that guessed "missing" would flash over real evidence.
                if (snapshot.connectionState != ConnectionState.done ||
                    snapshot.hasError) {
                  return const SizedBox.shrink();
                }
                final image = snapshot.data;
                if (image == null) {
                  return _MissingFile(path: artifact.relativePath);
                }
                return Image(
                  image: image,
                  fit: BoxFit.contain,
                  // A half-written PNG shows as a note, not a red box.
                  errorBuilder: (context, _, _) =>
                      _MissingFile(path: artifact.relativePath),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingFile extends StatelessWidget {
  const _MissingFile({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.sm),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Text(
        '$path is not on disk any more.',
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

class _FileTile extends ConsumerStatefulWidget {
  const _FileTile({required this.run, required this.artifact});

  final VerificationRun run;
  final VerificationArtifact artifact;

  @override
  ConsumerState<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends ConsumerState<_FileTile> {
  /// How much of a file is shown inline; a backstop, since a logcat slice is
  /// already capped at 400 lines when captured.
  static const _maxCharacters = 200 * 1024;

  bool _open = false;
  String? _text;

  /// Which open this text belongs to, so a slow read cannot land on a newer one.
  int _generation = 0;

  /// **Read off the frame.** On a `\\wsl.localhost` share the synchronous
  /// `existsSync()` + `readAsStringSync()` pair costs 1.19 ms against 0.07 ms
  /// locally before the file is read at all.
  Future<void> _toggle() async {
    if (_open) {
      setState(() => _open = false);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _open = true;
      _text = null;
    });
    final path = p.join(
      widget.run.artifactDirectory,
      widget.artifact.relativePath,
    );
    String body;
    try {
      final whole = await ref
          .read(verificationEvidenceReaderProvider)
          .read(path);
      if (whole == null) {
        body = '${widget.artifact.relativePath} is not on disk any more.';
      } else {
        body = whole.length <= _maxCharacters
            ? whole
            : '${whole.substring(0, _maxCharacters)}\n\n… truncated; the whole '
                  'file is ${widget.artifact.relativePath}.';
      }
    } on Object catch (error) {
      body = 'Could not read it: $error';
    }
    if (!mounted || generation != _generation) return;
    setState(() => _text = body);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.xs),
            child: Row(
              children: [
                Icon(
                  _open ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Chrome.iconSmall,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    '${widget.artifact.kind.label} — ${widget.artifact.label}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Text(
                  widget.artifact.sizeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: Insets.sm),
            padding: const EdgeInsets.all(Insets.sm),
            color: theme.colorScheme.surfaceContainerHigh,
            child: SelectableText(
              _text ?? 'Reading ${widget.artifact.relativePath}…',
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ),
      ],
    );
  }
}
