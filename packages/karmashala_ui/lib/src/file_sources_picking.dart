/// A file picked from one of two places (spec decision 11): the server's
/// files, or this device's, which are uploaded before the server can use them.
///
/// `karmashala_ui` knows no `FilesClient`: the upload is handed in as a
/// [DeviceUpload], the way [BrowseSources.lookup] hands in the listings.
library;

import 'dart:async';

import 'package:agent_cli/process.dart'
    show EnvironmentPath, formatBytes, localHostEnvironmentId;
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'desktop_dialog.dart';
import 'file_picking.dart';

/// Where a pick may come from.
enum FileSources {
  server,
  device,
  both;

  bool get offersServer => this != device;
  bool get offersDevice => this != server;
}

/// The one place a pick came from, and what [pickFileFrom] remembers.
/// [camera] and [gallery] are device files too: one taken just now, one
/// chosen from the device's photos.
enum FileSource { server, device, camera, gallery }

/// Takes a photo with this device's camera, or chooses one from its photos;
/// null when none was given. The app's to give: this package knows no camera
/// plugin.
typedef TakePhoto = Future<XFile?> Function();

/// A phone's own photos, offered beside its files: [take] opens the camera,
/// [choose] the system photo picker (the gallery).
final class DevicePhotos {
  const DevicePhotos({required this.take, required this.choose});

  final TakePhoto take;
  final TakePhoto choose;
}

/// What [pickFileFrom] answers.
sealed class PickedFile {
  const PickedFile();

  /// The file's own name, for a chip or a progress line.
  String get name;
}

/// A file already on the server's disk, spelled for its environment.
final class ServerPick extends PickedFile {
  const ServerPick(this.path);

  final EnvironmentPath path;

  @override
  String get name => _leafOf(path.path);
}

/// A file on this device. [ensureOnServer] uploads it.
final class DevicePick extends PickedFile {
  const DevicePick(this.file);

  final XFile file;

  @override
  String get name {
    final named = _leafOf(file.name);
    if (named.isNotEmpty) return named;
    final leaf = _leafOf(file.path);
    return leaf.isEmpty ? 'file' : leaf;
  }
}

/// Puts [size] bytes named [name] on the server — in [directory], or its
/// uploads folder when null — and answers where they landed.
typedef DeviceUpload =
    Future<EnvironmentPath> Function(
      String name,
      int size,
      Stream<List<int>> content, {
      EnvironmentPath? directory,
    });

/// The server a pick is for, as the caller knows it.
@immutable
class PickServer {
  const PickServer({
    required this.name,
    required this.onThisMachine,
    required this.upload,
    this.environmentId = localHostEnvironmentId,
    this.maxUploadBytes,
    this.describeError,
  });

  /// How the server is named on screen: "Studio", "pi@box".
  final String name;

  /// Whether the server's disk is this device's: then there is one source and
  /// nothing is ever uploaded.
  final bool onThisMachine;

  final DeviceUpload upload;

  /// The environment a server pick is browsed in and spelled for.
  final String environmentId;

  /// Refused before a byte is sent; null leaves it to the server.
  final int? maxUploadBytes;

  /// A failure in the words a person is shown; `toString` when null.
  final String Function(Object error)? describeError;

  String describe(Object error) => switch (error) {
    UploadRefused(:final message) => message,
    _ => describeError?.call(error) ?? '$error',
  };
}

/// An upload stopped by the person who started it.
class UploadCancelled implements Exception {
  const UploadCancelled();

  @override
  String toString() => 'The upload was cancelled.';
}

/// An upload refused before it began.
class UploadRefused implements Exception {
  const UploadRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The source each purpose last took, this run only.
final Map<String, FileSource> _lastSource = {};

@visibleForTesting
void forgetLastFileSources() => _lastSource.clear();

/// Asks for one file from [sources]. When both are offered and the server is
/// elsewhere, the person first chooses "This device" or the server, and the
/// choice is remembered per [purpose] (default [what]).
///
/// On the server's own machine there is one disk and no choice: today's
/// picker, answering a [DevicePick] for `device` and a [ServerPick] otherwise.
///
/// [photos] adds "Photos" and "Take a photo" to the choice of
/// [FileSources.both]; either photo is a [DevicePick].
Future<PickedFile?> pickFileFrom(
  BuildContext context, {
  required String what,
  required FileSources sources,
  required PickServer server,
  String? purpose,
  String? startNear,
  List<XTypeGroup> acceptedTypeGroups = const [],
  DevicePhotos? photos,
}) async {
  if (server.onThisMachine) {
    final file = await pickOneFile(
      what: what,
      context: context,
      environmentId: sources.offersServer ? server.environmentId : null,
      startNear: startNear,
      acceptedTypeGroups: acceptedTypeGroups,
      sources: sources.offersServer ? _serverSources(server) : null,
    );
    if (file == null) return null;
    return sources == FileSources.device
        ? DevicePick(file)
        : ServerPick(
            EnvironmentPath(
              environmentId: server.environmentId,
              path: file.path,
            ),
          );
  }

  final key = purpose ?? what;
  final FileSource source;
  switch (sources) {
    case FileSources.server:
      source = FileSource.server;
    case FileSources.device:
      source = FileSource.device;
    case FileSources.both:
      final chosen = await _askSource(
        context,
        what: what,
        server: server,
        last: _lastSource[key],
        photos: photos != null,
      );
      if (chosen == null) return null;
      _lastSource[key] = chosen;
      source = chosen;
  }
  if (!context.mounted) return null;

  switch (source) {
    case FileSource.device:
      final file = await pickDeviceFile(
        what: what,
        context: context,
        acceptedTypeGroups: acceptedTypeGroups,
      );
      return file == null ? null : DevicePick(file);
    case FileSource.camera:
      final photo = await photos?.take();
      return photo == null ? null : DevicePick(photo);
    case FileSource.gallery:
      final photo = await photos?.choose();
      return photo == null ? null : DevicePick(photo);
    case FileSource.server:
      final file = await pickOneFile(
        what: what,
        context: context,
        environmentId: server.environmentId,
        startNear: startNear,
        acceptedTypeGroups: acceptedTypeGroups,
        sources: _serverSources(server),
      );
      return file == null
          ? null
          : ServerPick(
              EnvironmentPath(
                environmentId: server.environmentId,
                path: file.path,
              ),
            );
  }
}

/// [pick] as a path on the server, uploading a [DevicePick] first — into
/// [directory], or the server's uploads folder — behind a progress dialog
/// that shows any failure and offers another try. Null when cancelled.
Future<EnvironmentPath?> ensureOnServer(
  BuildContext context,
  PickedFile pick,
  PickServer server, {
  EnvironmentPath? directory,
}) async {
  switch (pick) {
    case ServerPick(:final path):
      return path;
    case DevicePick(:final file)
        when server.onThisMachine && directory == null && file.path.isNotEmpty:
      // The device's disk is the server's: nothing to send.
      return EnvironmentPath(
        environmentId: localHostEnvironmentId,
        path: file.path,
      );
    case final DevicePick device:
      return _showAdaptive<EnvironmentPath>(
        context,
        dismissible: false,
        builder: (_) =>
            _UploadPanel(pick: device, server: server, directory: directory),
      );
  }
}

/// [pickFileFrom] then [ensureOnServer]: the server path of a file picked
/// from either source, or null when either step was dismissed.
Future<EnvironmentPath?> pickFileToServer(
  BuildContext context, {
  required String what,
  required PickServer server,
  FileSources sources = FileSources.both,
  String? purpose,
  String? startNear,
  EnvironmentPath? directory,
  List<XTypeGroup> acceptedTypeGroups = const [],
}) async {
  final pick = await pickFileFrom(
    context,
    what: what,
    sources: sources,
    server: server,
    purpose: purpose,
    startNear: startNear,
    acceptedTypeGroups: acceptedTypeGroups,
  );
  if (pick == null || !context.mounted) return null;
  return ensureOnServer(context, pick, server, directory: directory);
}

/// Sends [pick] to [server] with no UI of its own — for a caller that draws
/// progress itself. [onProgress] hears bytes the server has taken; throws
/// [UploadCancelled] once [cancelled] answers true, [UploadRefused] when over
/// [PickServer.maxUploadBytes].
Future<EnvironmentPath> uploadToServer(
  DevicePick pick,
  PickServer server, {
  EnvironmentPath? directory,
  void Function(int sent, int size)? onProgress,
  bool Function()? cancelled,
}) async {
  final file = pick.file;
  final size = await file.length();
  final limit = server.maxUploadBytes;
  if (limit != null && size > limit) {
    throw UploadRefused(
      '${pick.name} is ${formatBytes(size)}; ${server.name} takes files up '
      'to ${formatBytes(limit)}.',
    );
  }
  var sent = 0;
  // Counted after each yield resumes: the upload pulls the next piece only
  // once the last is on the wire, so this trails the server by one chunk.
  Stream<List<int>> content() async* {
    await for (final piece in file.openRead()) {
      if (cancelled?.call() ?? false) throw const UploadCancelled();
      yield piece;
      sent += piece.length;
      onProgress?.call(sent, size);
    }
  }

  return server.upload(pick.name, size, content(), directory: directory);
}

List<BrowseSource>? _serverSources(PickServer server) {
  final all = BrowseSources.all;
  final mine = [
    for (final source in all)
      if (source.id == server.environmentId) source,
  ];
  // Only the server's own environment, so a path picked is spelled for it.
  return mine.isEmpty ? null : mine;
}

String _leafOf(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? trimmed : trimmed.substring(cut + 1);
}

/// A dialog on a wide window, a bottom sheet on a compact one (PROJECT.md §6).
Future<T?> _showAdaptive<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  final media = MediaQuery.of(context);
  final compact = WidthClass.of(
    media.size.width,
    textScaler: media.textScaler,
  ).isCompact;
  if (compact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      showDragHandle: dismissible,
      builder: (context) => _SheetFrame(child: builder(context)),
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    builder: builder,
  );
}

/// Whether [context] sits in a bottom sheet rather than a dialog.
class _SheetFrame extends InheritedWidget {
  const _SheetFrame({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SheetFrame>() != null;

  @override
  bool updateShouldNotify(_SheetFrame oldWidget) => false;
}

/// One titled body with its actions, drawn as a dialog or as a sheet.
class _AdaptivePanel extends StatelessWidget {
  const _AdaptivePanel({
    required this.title,
    required this.body,
    this.actions = const [],
  });

  final Widget title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (!_SheetFrame.of(context)) {
      return AlertDialog(
        title: title,
        content: BoundedDialogContent(width: DialogWidth.narrow, child: body),
        actions: actions.isEmpty ? null : actions,
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.lg),
        child: FocusRevealGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: Insets.md),
              Flexible(child: SingleChildScrollView(child: body)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: Insets.md),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<FileSource?> _askSource(
  BuildContext context, {
  required String what,
  required PickServer server,
  FileSource? last,
  bool photos = false,
}) => _showAdaptive<FileSource>(
  context,
  builder: (context) => _AdaptivePanel(
    title: DesktopDialogTitle(
      icon: AppIcons.file,
      title: 'Choose $what',
      subtitle: 'From this device or from ${server.name}',
    ),
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SourceRow(
          icon: AppIcons.uploadSimple,
          title: 'This device',
          detail: 'Sent to ${server.name} once chosen',
          last: last == FileSource.device,
          autofocus:
              last == null ||
              last == FileSource.device ||
              ((last == FileSource.camera || last == FileSource.gallery) &&
                  !photos),
          onTap: () => Navigator.of(context).pop(FileSource.device),
        ),
        const SizedBox(height: Insets.xs),
        _SourceRow(
          icon: AppIcons.folders,
          title: server.name,
          detail: 'Its own files; nothing is sent',
          last: last == FileSource.server,
          autofocus: last == FileSource.server,
          onTap: () => Navigator.of(context).pop(FileSource.server),
        ),
        if (photos) ...[
          const SizedBox(height: Insets.xs),
          _SourceRow(
            icon: AppIcons.image,
            title: 'Photos',
            detail: 'From the gallery; sent to ${server.name} once chosen',
            last: last == FileSource.gallery,
            autofocus: last == FileSource.gallery,
            onTap: () => Navigator.of(context).pop(FileSource.gallery),
          ),
          const SizedBox(height: Insets.xs),
          _SourceRow(
            icon: AppIcons.camera,
            title: 'Take a photo',
            detail: 'Sent to ${server.name} once taken',
            last: last == FileSource.camera,
            autofocus: last == FileSource.camera,
            onTap: () => Navigator.of(context).pop(FileSource.camera),
          ),
        ],
      ],
    ),
  ),
);

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.last,
    required this.autofocus,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool last;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      autofocus: autofocus,
      minTileHeight: Touch.target,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      leading: Icon(icon, size: Chrome.iconTitle),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail),
      // Words, not only a highlight: the remembered row says so.
      trailing: last
          ? Text('Last used', style: theme.textTheme.labelSmall)
          : null,
      onTap: onTap,
    );
  }
}

/// Runs one upload: progress while it goes, the failure and "Try again" when
/// it stops, and the landed path popped when it is done.
class _UploadPanel extends StatefulWidget {
  const _UploadPanel({
    required this.pick,
    required this.server,
    required this.directory,
  });

  final DevicePick pick;
  final PickServer server;
  final EnvironmentPath? directory;

  @override
  State<_UploadPanel> createState() => _UploadPanelState();
}

class _UploadPanelState extends State<_UploadPanel> {
  int _sent = 0;
  int? _size;
  String? _failure;
  bool _cancelled = false;

  /// Bumped per attempt, so a dead attempt's late answer is ignored.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    // Dismissed any way at all — Cancel, Back, a closed route — stops sending.
    _cancelled = true;
    super.dispose();
  }

  Future<void> _run() async {
    final attempt = ++_attempt;
    setState(() {
      _failure = null;
      _sent = 0;
    });
    try {
      final landed = await uploadToServer(
        widget.pick,
        widget.server,
        directory: widget.directory,
        cancelled: () => _cancelled || attempt != _attempt,
        onProgress: (sent, size) {
          if (!mounted || attempt != _attempt) return;
          setState(() {
            _sent = sent;
            _size = size;
          });
        },
      );
      if (!mounted || attempt != _attempt) return;
      Navigator.of(context).pop(landed);
    } on UploadCancelled {
      return;
    } on Object catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _failure = widget.server.describe(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = widget.server.name;
    final failure = _failure;
    final size = _size;
    final done = size != null && _sent >= size;
    final fraction = size == null || size == 0 || done ? null : _sent / size;
    final status = failure != null
        ? null
        : size == null
        ? 'Starting…'
        : done
        ? 'Finishing on $server…'
        : '${formatBytes(_sent)} of ${formatBytes(size)}';
    return _AdaptivePanel(
      title: Text(
        failure == null ? 'Sending to $server' : 'Could not send to $server',
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.pick.name,
            style: theme.textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Insets.sm),
          if (failure != null)
            DesktopErrorBanner(failure)
          else ...[
            LinearProgressIndicator(
              value: fraction,
              semanticsLabel: 'Sending ${widget.pick.name}',
              semanticsValue: fraction == null
                  ? null
                  : '${(fraction * 100).round()}%',
            ),
            const SizedBox(height: Insets.xs),
            Text(
              status!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          autofocus: failure == null,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (failure != null)
          FilledButton(
            autofocus: true,
            onPressed: () => unawaited(_run()),
            child: const Text('Try again'),
          ),
      ],
    );
  }
}
