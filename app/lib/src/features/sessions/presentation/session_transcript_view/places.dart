// Where the session runs, and opening the paths, pictures and links the chat names.

part of '../session_transcript_view.dart';

mixin _TranscriptPlaces on ConsumerState<SessionTranscriptView> {
  /// The resolver for [_resolverEnvironment], kept for the same reason.
  String? Function(String)? _resolver;
  String? _resolverEnvironment;

  /// Translates a path the agent wrote into one this process can open, or null
  /// when the environment is unknown: a WSL `/mnt/c/…` has to become `C:\…`.
  String? Function(String)? _hostPathResolver() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    final environmentId = ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.environmentId;
    if (environmentId == null) return null;
    if (_resolver != null && _resolverEnvironment == environmentId) {
      return _resolver;
    }
    _resolverEnvironment = environmentId;
    return _resolver = (path) => ref
        .read(editorActionsProvider)
        .windowsPathFor(
          EnvironmentPath(environmentId: environmentId, path: path),
        );
  }

  /// The agent this session is with, for the empty state's mark; null for a
  /// session whose installation is not known here.
  String? _agentId() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    return ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
  }

  /// Where this session's agent was standing. Null means **unknown**, never
  /// "the repository root", so the fallback is made here and out loud.
  EnvironmentPath? _workingDirectory() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    return session.workingDirectory ??
        ref.read(workspaceDataProvider).repository(session.repositoryId)?.path;
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// [token] placed in the session's environment with the line it names, or
  /// null when there is no record of where the session runs.
  (EnvironmentPath, int?)? _placeToken(String token) {
    final base = _workingDirectory();
    if (base == null) return null;
    return (
      placeTranscriptPath(
        token,
        folder: base,
        kind: _environmentKind(base.environmentId),
      ),
      tokenForMatch(token).line,
    );
  }

  EnvironmentKind? _environmentKind(String environmentId) =>
      ref.read(environmentsDataProvider).getById(environmentId)?.kind;

  /// The menu on every link, path, picture and code span in the chat.
  late final _targetMenu = ChatTargetMenu(
    folder: _workingDirectory,
    kindOf: _environmentKind,
    openPath: _openFromMenu,
    openLink: _openLink,
    canReveal: (path) => ref.read(revealInFileManagerProvider).canReveal(path),
    reveal: _revealFromMenu,
    imageClipboard: () => ref.read(imageClipboardProvider),
    saveImage: _saveImage,
  );

  /// Open, from a menu: a file opens as a tab; a folder is shown as a click
  /// on it shows it.
  Future<void> _openFromMenu(String token) async {
    final placed = _placeToken(token);
    if (placed == null) return _openPath(token);
    final (path, line) = placed;
    final FileStat stat;
    try {
      stat = await ref.read(filesClientProvider).stat(path);
    } on FilesException catch (error) {
      _say(error.message);
      return;
    }
    if (!mounted) return;
    if (!stat.exists) return _say('${path.path} is not on disk.');
    if (stat.isDirectory) return _openPath(token);
    ref.read(editorTabActionsProvider).openAt(path, line: line);
  }

  Future<void> _revealFromMenu(EnvironmentPath path) async {
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(path, select: true);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _saveImage(Uint8List bytes, String name) async {
    final said = await saveImageAs(bytes, name);
    if (said != null) _say(said);
  }

  /// A picture's path placed in the session's environment. A tear-off, so the
  /// rows below can tell it has not changed.
  EnvironmentPath? _placeImage(String path) => _placeToken(path)?.$1;

  /// Reveals a picture's path as a click on it would.
  void _openImage(String path) => unawaited(_openPath(path));

  /// The preview a tapped path opens under its message. A tear-off, so the
  /// rows it is handed to can tell it has not changed.
  Widget _filePreview(String token, VoidCallback onClose) {
    final placed = _placeToken(token);
    if (placed == null) {
      return Text(
        'Karmashala has no record of where this session runs, so it cannot '
        'place $token.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final (path, line) = placed;
    return TranscriptFilePreview(
      key: ValueKey('preview-$token'),
      path: path,
      line: line,
      onClose: onClose,
      onOpenInEditor: () =>
          ref.read(editorTabActionsProvider).openAt(path, line: line),
      onOpenInFiles: () => _openPath(token),
    );
  }

  /// What a click on a file path does: **it reveals; it does not open**. Also
  /// the only place the feature touches a disk — detection is by shape.
  Future<void> _openPath(String token) async {
    // The phone's page has no file panel beside it: a file opens as a tab.
    final compact = CompactWorkbenchScope.of(context);
    final parsed = tokenForMatch(token);
    final base = _workingDirectory();
    if (base == null) {
      _say(
        'Karmashala has no record of where this session runs, so it '
        'cannot place ${parsed.path}.',
      );
      return;
    }
    final path = placeTranscriptPath(
      token,
      folder: base,
      kind: _environmentKind(base.environmentId),
    );
    final resolved = path.path;

    // The server looks, wherever the session's files are: this machine, WSL
    // or an SSH host.
    final FileStat stat;
    try {
      stat = await ref.read(filesClientProvider).stat(path);
    } on FilesException catch (error) {
      _say(error.message);
      return;
    }
    if (!mounted) return;
    if (!stat.exists) {
      _say('$resolved is not on disk.');
      return;
    }
    final isDirectory = stat.isDirectory;

    if (compact) {
      if (isDirectory) {
        _say('$resolved is a folder.');
      } else {
        ref.read(editorTabActionsProvider).openAt(path, line: parsed.line);
      }
      return;
    }

    // Inside the checkout the panel is rooted at: show it there, where the
    // reader already is.
    final root = ref.read(fileTreeRootProvider);
    if (root != null && isUnderFileTreeRoot(root, path)) {
      ref
          .read(fileRevealTargetProvider.notifier)
          .reveal(FileRevealTarget(path: path, isDirectory: isDirectory));
      if (ref.read(sidePanelProvider) != SidePanelSurface.files) {
        ref.read(sidePanelProvider.notifier).select(SidePanelSurface.files);
      }
      return;
    }

    // Outside it there is no row to select, so the host's own file manager is
    // all that is left. `canReveal` starts no process, so asking first is free.
    final revealer = ref.read(revealInFileManagerProvider);
    if (!revealer.canReveal(path)) {
      _say(
        (await revealer.reveal(path)).error ??
            'There is no way to show '
                '$resolved on this machine.',
      );
      return;
    }
    final outcome = await revealer.reveal(path, select: !isDirectory);
    if (!outcome.ok) _say(outcome.error!);
  }

  /// A link the agent wrote, tapped on a touch screen: asked about first, since
  /// a stray tap while scrolling must not leave the app.
  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri != null && !uri.hasScheme) {
      await _openPath(href);
      return;
    }
    if (uri == null ||
        !(uri.isScheme('http') ||
            uri.isScheme('https') ||
            uri.isScheme('mailto'))) {
      _say('Only web links open from here: $href');
      return;
    }
    // A click is deliberate; a tap while scrolling a phone is easily not, so
    // only touch asks first.
    if (UiDensity.of(context).isTouch) {
      final go = await showAdaptiveModal<bool>(
        context: context,
        title: 'Open in the browser?',
        builder: (context) => _OpenLinkBody(uri: uri),
      );
      if (go != true || !mounted) return;
    }
    try {
      final opened = uri.isScheme('mailto')
          ? await launchUrl(uri, mode: LaunchMode.externalApplication)
          : await ref.read(openExternalUrlProvider)(uri.toString());
      if (!opened) {
        _say('Nothing on this device could open $href.');
      }
    } on Exception {
      _say('Nothing on this device could open $href.');
    }
  }

  /// A file an agent's edit names, placed where the session runs.
  EnvironmentPath? _placeEditedFile(String path) => _placeToken(path)?.$1;

  /// Opens a file an edit names in the editor, at its place.
  void _openEditedFile(String path) {
    final placed = _placeToken(path);
    if (placed == null) {
      _say('Karmashala has no record of where this session runs.');
      return;
    }
    ref.read(editorTabActionsProvider).openAt(placed.$1, line: placed.$2);
  }
}

/// The link in full, so the reader sees where it goes, and the two answers.
class _OpenLinkBody extends StatelessWidget {
  const _OpenLinkBody({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            '$uri',
            style: MonoStyles.body.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: Touch.gap),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Open'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
