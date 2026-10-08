import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_cli/process.dart' show formatBytes;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/menus.dart';

import '../../../app/widgets/adaptive_modal.dart';

/// How many lines of [style] fit [height], between 1 and 12. Unbounded means
/// the composer's full twelve.
@visibleForTesting
int composerLinesThatFit(
  double height, {
  required TextStyle? style,
  required TextScaler textScaler,
}) {
  const most = 12;
  if (!height.isFinite) return most;
  final painter = TextPainter(
    text: TextSpan(text: ' ', style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();
  final line = painter.preferredLineHeight;
  painter.dispose();
  return (height / line).floor().clamp(1, most);
}

/// Where an attachment came from, which is what its chip says of it.
enum _From {
  /// A client temp file, the server being on this machine.
  temp,

  /// This machine's own file, given by its path: the server is here too.
  local,

  /// This device's, uploaded to the server.
  uploaded,

  /// Already on the server.
  server,

  /// Already on the server, handed over from Files or an open file's tab
  /// (*Attach to chat*) rather than picked here.
  files,
}

/// A pasted/attached file, somewhere the agent can read it: a client temp
/// file when the server is on this machine, else a path on the server.
class _Attachment {
  _Attachment({
    required this.path,
    required this.name,
    required this.from,
    required this.serverName,
    required this.image,
    this.preview,
  });

  /// What the agent is sent: a path on the server's disk.
  final String path;
  final String name;
  final _From from;
  final String serverName;

  /// Listed to the agent under "Attached image(s):", else "Attached file(s):".
  final bool image;

  /// A thumbnail for a touch chip; null draws the file's glyph.
  final ImageProvider? preview;

  /// Where the file is, for the pointer chip's tooltip: an image goes to an
  /// agent that takes them [asImage], anything else by its path.
  String whereFor({required bool asImage}) =>
      image && asImage ? _whereAsImage : where;

  String get _whereAsImage => switch (from) {
    _From.temp => 'Saved to a temp folder and sent to the agent as an image.',
    _From.local => 'On this machine; the agent is sent it as an image.',
    _From.uploaded => 'Sent to $serverName; the agent is sent it as an image.',
    _From.server => 'On $serverName; the agent is sent it as an image.',
    _From.files =>
      serverName.isEmpty
          ? 'From Files; the agent is sent it as an image.'
          : 'From Files on $serverName; the agent is sent it as an image.',
  };

  String get where => switch (from) {
    _From.temp =>
      'Saved to a temp folder and sent to the agent as a file path.',
    _From.local => 'On this machine; the agent is given its path.',
    _From.uploaded => 'Sent to $serverName; the agent is given its path there.',
    _From.server => 'On $serverName; the agent is given its path there.',
    _From.files =>
      serverName.isEmpty
          ? 'From Files; the agent is given its path.'
          : 'From Files on $serverName; the agent is given its path there.',
  };

  /// The same, as a touch chip's second line.
  String get detail => switch (from) {
    _From.temp || _From.local => 'On this device',
    _From.uploaded => 'From this device → $serverName',
    _From.server => 'On $serverName',
    _From.files =>
      serverName.isEmpty ? 'From Files' : 'From Files · $serverName',
  };
}

/// A device file on its way to the server. Send waits while any is here; at
/// touch density a failed one stays, with *Try again*.
class _Upload {
  _Upload({
    required this.pick,
    required this.server,
    required this.image,
    this.preview,
  });

  final DevicePick pick;
  final PickServer server;
  final bool image;
  final ImageProvider? preview;

  int sent = 0;
  int? size;
  String? failure;
  bool cancelled = false;

  /// The app went to the background while this attempt ran.
  bool backgrounded = false;

  /// Bumped per attempt, so a dead attempt's late answer is ignored.
  int attempt = 0;

  /// Picked on a phone and waiting for Send: nothing has gone to the server.
  /// A phone uploads only what is actually sent (owner, 2026-10-01) — a file
  /// picked and then dropped costs no data and leaves nothing on the server.
  bool queued = false;

  bool get running => !queued && failure == null;
}

const _imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];

const _images = [XTypeGroup(label: 'Images', extensions: _imageExtensions)];

bool _looksLikeImage(String name) {
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _imageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// What a keyboard may insert, and the extension its bytes are saved under.
const _insertableImages = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

/// A touch chip's thumbnail edge, decoded at twice that for a sharp picture.
const _thumbnail = 40.0;

/// One entry of the composer's snippets menu: what it is called, and the text
/// it puts in the box. Plain values, so the composer knows nothing of where
/// the library lives.
class ComposerSnippet {
  const ComposerSnippet({required this.label, required this.text});

  final String label;
  final String text;
}

/// A slash command the agent accepts, offered when the box starts with "/".
class ComposerCommand {
  const ComposerCommand({
    required this.name,
    required this.description,
    this.hint,
  });

  /// Without the slash.
  final String name;
  final String description;

  /// What the agent says to type after it, when it takes input.
  final String? hint;
}

/// The session message box: text plus image attachments. On send the images are
/// saved and their paths appended, so the agent can read them.
///
/// Board N2 draws it as **one object**: the attachment chips, the text, and a
/// toolbar of attach, snippets and a round send, inside one rounded card. It
/// holds nothing else — mode, model and the view switch are the pane's status
/// line's (owner, 2026-09-28: one place per control).
class MessageComposer extends StatefulWidget {
  const MessageComposer({
    required this.onSend,
    required this.hintText,
    this.enabled = true,
    this.chips = const [],
    this.controller,
    this.snippets,
    this.commands,
    this.imagesGoAsImages,
    this.server,
    this.attaches = true,
    this.camera,
    this.droppedFiles,
    this.takeServerFiles,
    this.serverFilesWaiting,
    super.key,
  });

  /// Whether files may be attached at all: false hides Attach and ignores a
  /// pasted or keyboard-inserted image (a phone not granted `send_attachment`).
  final bool attaches;

  /// Sends the composed message (text + appended image paths). Awaited so the
  /// composer can show a busy state.
  final Future<void> Function(String text) onSend;
  final String hintText;
  final bool enabled;

  /// Controls shown in a row beneath the text box. A slot rather than a widget
  /// this class builds, so the composer keeps knowing nothing about sessions.
  final List<Widget> chips;

  /// The text box's controller, when the caller needs to put something in it.
  /// Supplied means owned: the caller disposes it, else the composer does.
  final TextEditingController? controller;

  /// The snippets the toolbar's menu offers, read each time it opens. Null
  /// hides the button: a host with no library has nothing to offer.
  final List<ComposerSnippet> Function()? snippets;

  /// The agent's slash commands, read as the box's text changes: typing "/"
  /// lists them and picking one puts it in the box. Null offers none.
  final List<ComposerCommand> Function()? commands;

  /// Whether an attached image reaches the agent as an image rather than as
  /// its path, read when the chips are drawn. Null is "as its path".
  final bool Function()? imagesGoAsImages;

  /// The server the agent runs on, read when an image is pasted or attached.
  /// Null, or one on this machine, keeps today's client temp files. One
  /// elsewhere (spec decision 11) has pasted images uploaded to it, offers
  /// "This device" or its own files to attach, and is sent its own paths.
  final PickServer Function()? server;

  /// Read when attach opens at touch density; [DevicePhotos] add "Photos"
  /// (the gallery) and "Take a photo", uploaded like any device file. Null,
  /// or answering null, offers neither.
  final DevicePhotos? Function()? camera;

  /// Paths on this machine dropped onto whatever hosts the composer, each
  /// batch attached as if picked from this device.
  final Stream<List<String>>? droppedFiles;

  /// Takes the files already on the server that wait for this composer — what
  /// *Attach to chat* on an open file queued — removing them from wherever
  /// they wait. Each is attached by path with nothing uploaded, and each path
  /// is **spelled for the agent** already, so it is sent exactly as it comes.
  ///
  /// **Pulled, never pushed**: the composer calls it only when it can attach
  /// at once — attaching allowed, enabled, not busy — so a file is never taken
  /// and then refused. Until then the files stay where they wait, and they are
  /// taken when the box mounts, when [serverFilesWaiting] says more arrived,
  /// and when the box becomes able again (enabled, attaching granted, or a
  /// send finished).
  final List<String> Function()? takeServerFiles;

  /// Notifies when files arrive for [takeServerFiles] to hand over.
  final Listenable? serverFilesWaiting;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  static final _log = AppLogger.named('composer');

  late TextEditingController _input;
  final _attachments = <_Attachment>[];

  /// Device files on their way to a server elsewhere. Send waits.
  final _uploads = <_Upload>[];
  bool _busy = false;

  /// Why the last send failed, kept over the box until the next one: a
  /// snackbar alone is gone in seconds.
  String? _sendError;
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _handleKey);
  late final AppLifecycleListener _lifecycle;

  int get _uploading => _uploads.where((upload) => upload.running).length;

  /// A thumb's composer: 48dp controls, any file, uploads drawn in the chips.
  bool get _touch => UiDensity.of(context).isTouch;

  @override
  void initState() {
    super.initState();
    // No listener on [_input] or [_focusNode] here: [_SendButton] and the
    // card's border listen for themselves, so neither rebuilds the text field.
    _input = widget.controller ?? TextEditingController();
    // Rebuilds only when the palette's matches change, not per keystroke.
    _input.addListener(_matchCommands);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _drops = widget.droppedFiles?.listen(_attachDropped);
    widget.serverFilesWaiting?.addListener(_scheduleDrain);
    // Files queued before this box existed — while the transcript loaded.
    _scheduleDrain();
  }

  StreamSubscription<List<String>>? _drops;

  /// Whether a server file taken now would be attached rather than refused.
  bool get _acceptsServerFiles => widget.attaches && widget.enabled && !_busy;

  /// [_drainServerFiles] after the current task, coalesced. From `initState`
  /// and `didUpdateWidget`, which run inside a build: taking writes the
  /// queue's provider, which a build may not, and a microtask never runs
  /// inside one.
  bool _drainScheduled = false;
  void _scheduleDrain() {
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      _drainServerFiles();
    });
  }

  /// Takes and attaches whatever server files wait, when — and only when —
  /// they would be attached; otherwise leaves them waiting for the next
  /// chance ([MessageComposer.takeServerFiles]).
  void _drainServerFiles() {
    if (!mounted || !_acceptsServerFiles) return;
    final paths = widget.takeServerFiles?.call();
    if (paths == null || paths.isEmpty) return;
    _attachServerFiles(paths);
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    for (final upload in _uploads) {
      if (upload.running) upload.backgrounded = true;
    }
  }

  @override
  void didUpdateWidget(MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _input.removeListener(_matchCommands);
      if (oldWidget.controller == null) {
        _input.dispose();
      }
      _input = widget.controller ?? TextEditingController();
      _input.addListener(_matchCommands);
    }
    if (oldWidget.droppedFiles != widget.droppedFiles) {
      unawaited(_drops?.cancel());
      _drops = widget.droppedFiles?.listen(_attachDropped);
    }
    if (oldWidget.serverFilesWaiting != widget.serverFilesWaiting) {
      oldWidget.serverFilesWaiting?.removeListener(_scheduleDrain);
      widget.serverFilesWaiting?.addListener(_scheduleDrain);
    }
    // Able again, or asked of a new source: what waited is taken now.
    if ((!oldWidget.enabled && widget.enabled) ||
        (!oldWidget.attaches && widget.attaches) ||
        oldWidget.takeServerFiles != widget.takeServerFiles) {
      _scheduleDrain();
    }
  }

  @override
  void dispose() {
    unawaited(_drops?.cancel());
    widget.serverFilesWaiting?.removeListener(_scheduleDrain);
    for (final upload in _uploads) {
      upload.cancelled = true;
    }
    _lifecycle.dispose();
    _focusNode.dispose();
    _input.removeListener(_matchCommands);
    if (widget.controller == null) _input.dispose();
    super.dispose();
  }

  /// The commands matching what follows a leading "/", while the command
  /// itself is still being typed; empty when the palette is shut.
  List<ComposerCommand> _commandMatches = const [];
  int _commandHighlight = 0;

  /// Esc shut the palette for this "/…": it opens again once the box no
  /// longer starts a command.
  bool _commandsDismissed = false;

  bool get _paletteOpen => _commandMatches.isNotEmpty;

  void _matchCommands() {
    final text = _input.text;
    final typing = text.startsWith('/') && !text.contains(RegExp(r'\s'));
    if (!typing) _commandsDismissed = false;
    var matches = const <ComposerCommand>[];
    final offered = widget.commands;
    if (typing && !_commandsDismissed && offered != null) {
      final query = text.substring(1);
      final found = [
        for (final c in offered())
          if (searchMatch(query, c.name) case final match?)
            (command: c, prefix: match.positions.firstOrNull == 0),
      ];
      // Names the query starts first, each half in the offered order.
      matches = [
        for (final f in found)
          if (f.prefix) f.command,
        for (final f in found)
          if (!f.prefix) f.command,
      ];
    }
    if (!mounted || _sameCommands(matches, _commandMatches)) return;
    setState(() {
      _commandMatches = matches;
      _commandHighlight = 0;
    });
  }

  static bool _sameCommands(List<ComposerCommand> a, List<ComposerCommand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i].name != b[i].name) return false;
    }
    return true;
  }

  /// Puts "/name " in the box, ready for its input; nothing is sent.
  void _pickCommand(ComposerCommand command) {
    final text = '/${command.name} ';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focusNode.requestFocus();
  }

  KeyEventResult _handlePaletteKey(KeyEvent event) {
    final key = event.logicalKey;
    final count = _commandMatches.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _commandHighlight = (_commandHighlight + 1) % count);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _commandHighlight = (_commandHighlight - 1 + count) % count,
      );
    } else if (key == LogicalKeyboardKey.tab ||
        ((key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) &&
            !HardwareKeyboard.instance.isShiftPressed)) {
      _pickCommand(_commandMatches[_commandHighlight]);
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _commandsDismissed = true;
        _commandMatches = const [];
      });
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Enter sends, Shift+Enter inserts a newline, and Ctrl/Cmd+V also attaches a
  /// clipboard image when one is present (text paste still proceeds).
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_paletteOpen && _handlePaletteKey(event) == KeyEventResult.handled) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (keys.isControlPressed || keys.isMetaPressed)) {
      if (widget.attaches) _pasteImageIfAny();
      return KeyEventResult.ignored;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter && !keys.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Ctrl/Cmd+V also attaches a clipboard image when there is one.
  ///
  /// **It used to swallow every failure**, so a paste that did not attach left
  /// nothing behind — not a message, not a log line — and there was no way to
  /// tell a clipboard holding no image from one that could not be read. Both
  /// now say so, and only the second is an error.
  Future<void> _pasteImageIfAny() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) {
        await _addImageBytes(img);
        return;
      }
      _log.debug('Paste: the clipboard holds no image.');
    } on Object catch (error, stack) {
      _log.warning('Paste: the clipboard could not be read.', error, stack);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('That image could not be pasted: $error')),
      );
    }
  }

  Future<Directory> _attachmentsDir() async {
    final dir = Directory(
      '${Directory.systemTemp.path}/karmashala/attachments',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// The server the agent runs on when it is **not** this machine; null when
  /// its disk is this one's, and the client's temp folder will do.
  PickServer? _serverElsewhere() {
    final server = widget.server?.call();
    return server == null || server.onThisMachine ? null : server;
  }

  Future<void> _addImageBytes(Uint8List bytes, {String ext = 'png'}) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final name = 'img_$stamp.$ext';
    final server = _serverElsewhere();
    // Only a touch chip draws a thumbnail; a pointer pill holds no bytes.
    final preview = mounted && _touch
        ? ResizeImage(MemoryImage(bytes), width: (_thumbnail * 2).round())
        : null;
    if (server != null) {
      // Straight to the server's uploads folder, with no temp file: a path
      // on this machine is nothing an agent there can read.
      await _startUpload(
        DevicePick(XFile.fromData(bytes, name: name)),
        server,
        image: true,
        preview: preview,
      );
      return;
    }
    final dir = await _attachmentsDir();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);
    if (mounted) {
      setState(
        () => _attachments.add(
          _Attachment(
            path: file.path,
            name: name,
            from: _From.temp,
            serverName: '',
            image: true,
            preview: preview,
          ),
        ),
      );
    }
  }

  /// Sends [pick] to [server], drawn as a chip until it lands and becomes an
  /// attachment. At touch density a failure stays as a chip with *Try
  /// again*; under a pointer it is said in a snack bar, as it always was.
  Future<void> _startUpload(
    DevicePick pick,
    PickServer server, {
    required bool image,
    ImageProvider? preview,
  }) async {
    // A clipboard or picker read before this yields; the composer may be gone.
    if (!mounted) return;
    final upload = _Upload(
      pick: pick,
      server: server,
      image: image,
      preview: preview,
    );
    if (_touch) {
      setState(() => _uploads.add(upload..queued = true));
      return;
    }
    setState(() => _uploads.add(upload));
    await _runUpload(upload);
  }

  /// Whether Send may go: nothing uploading and nothing failed. Files still
  /// queued are fine — Send is what uploads them.
  bool get _readyToSend => _uploads.every((upload) => upload.queued);

  /// Uploads every queued file, one at a time, each landing as an attachment.
  /// True when all of them landed; a failure stays on its chip, with the
  /// message, for *Try again* and another Send.
  Future<bool> _uploadQueued() async {
    for (final upload in [..._uploads]) {
      if (!mounted) return false;
      if (!upload.queued || upload.cancelled) continue;
      setState(() => upload.queued = false);
      await _runUpload(upload);
    }
    return mounted && _uploads.isEmpty;
  }

  Future<void> _runUpload(_Upload upload) async {
    final attempt = ++upload.attempt;
    final server = upload.server;
    final messenger = ScaffoldMessenger.of(context);
    final touch = _touch;
    setState(() {
      upload
        ..failure = null
        ..sent = 0
        ..backgrounded = false;
    });
    bool stale() => !mounted || attempt != upload.attempt || upload.cancelled;
    try {
      final landed = await uploadToServer(
        upload.pick,
        server,
        cancelled: stale,
        onProgress: (sent, size) {
          if (stale()) return;
          setState(() {
            upload
              ..sent = sent
              ..size = size;
          });
        },
      );
      if (stale()) return;
      setState(() {
        _uploads.remove(upload);
        _attachments.add(
          _Attachment(
            path: landed.path,
            name: upload.pick.name,
            from: _From.uploaded,
            serverName: server.name,
            image: upload.image,
            preview: upload.preview,
          ),
        );
      });
    } on UploadCancelled {
      return;
    } on Object catch (error, stack) {
      if (stale()) return;
      _log.warning(
        'Could not send ${upload.image ? 'a pasted image' : 'a file'} to the '
        'server.',
        error,
        stack,
      );
      if (touch) {
        setState(() {
          upload.failure = upload.backgrounded
              ? 'The upload stopped when the app was in the background.'
              : server.describe(error);
        });
        return;
      }
      setState(() => _uploads.remove(upload));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${upload.image ? 'The image' : upload.pick.name} could not be '
            'sent to ${server.name}: '
            '${server.describe(error)}',
          ),
        ),
      );
    }
  }

  /// Stops [upload]: `files.upload.abort` drops what the server staged.
  void _cancelUpload(_Upload upload) {
    setState(() {
      upload.cancelled = true;
      _uploads.remove(upload);
    });
  }

  /// A server elsewhere: an image from this device (uploaded) or one already
  /// on the server, whichever the person chooses.
  Future<void> _attachFrom(PickServer server) async {
    final landed = await pickFileToServer(
      context,
      what: 'an image to attach',
      server: server,
      purpose: 'composer attachment',
      acceptedTypeGroups: _images,
    );
    if (landed == null || !mounted) return;
    final path = landed.path;
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    setState(
      () => _attachments.add(
        _Attachment(
          path: path,
          name: cut < 0 ? path : path.substring(cut + 1),
          from: _From.server,
          serverName: server.name,
          image: true,
        ),
      ),
    );
  }

  /// The user's pictures on Windows, when there is such a folder; the picker
  /// falls back to somewhere local either way.
  String? _pictures() {
    if (!Platform.isWindows) return null;
    final home = Platform.environment['USERPROFILE'];
    return home == null || home.isEmpty ? null : '$home\\Pictures';
  }

  /// Attach: **any file**, from this device (uploaded, with its progress in
  /// the chip) or from the server (nothing sent). No clipboard read first — a
  /// phone's keyboard inserts its images itself, and Ctrl+V pastes one.
  Future<void> _attachAnyFile() async {
    final server = widget.server?.call();
    if (server == null) return _attach();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pick = await pickFileFrom(
        context,
        what: 'a file to attach',
        sources: FileSources.both,
        server: server,
        purpose: 'composer attachment',
        photos: widget.camera?.call(),
      );
      if (pick == null || !mounted) return;
      final image = _looksLikeImage(pick.name);
      switch (pick) {
        case ServerPick(:final path):
          setState(
            () => _attachments.add(
              _Attachment(
                path: path.path,
                name: pick.name,
                from: _From.server,
                serverName: server.name,
                image: image,
              ),
            ),
          );
        case DevicePick(:final file)
            when server.onThisMachine && file.path.isNotEmpty:
          // The device's disk is the server's: nothing to send.
          setState(
            () => _attachments.add(
              _Attachment(
                path: file.path,
                name: pick.name,
                from: _From.local,
                serverName: server.name,
                image: image,
                preview: image ? _previewOf(file.path) : null,
              ),
            ),
          );
        case final DevicePick device:
          await _startUpload(
            device,
            server,
            image: image,
            preview: image && device.file.path.isNotEmpty
                ? _previewOf(device.file.path)
                : null,
          );
      }
    } on Object catch (error, stack) {
      _log.warning('Could not attach a file.', error, stack);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not attach that file: $error')),
      );
    }
  }

  ImageProvider _previewOf(String path) =>
      ResizeImage(FileImage(File(path)), width: (_thumbnail * 2).round());

  /// Files dropped from this machine, attached as Attach would take them:
  /// by path when the server is here, else uploaded (queued until Send on a
  /// phone). A folder goes by path only — there is no uploading one.
  Future<void> _attachDropped(List<String> paths) async {
    if (!mounted || paths.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    void say(String message) =>
        messenger.showSnackBar(SnackBar(content: Text(message)));
    if (!widget.attaches) {
      return say('Files cannot be attached here.');
    }
    if (!widget.enabled || _busy) {
      return say('The message box is not taking anything right now.');
    }
    final server = _serverElsewhere();
    final folders = <String>[];
    for (final path in paths) {
      if (!mounted) return;
      final name = _leafOf(path);
      final folder = FileSystemEntity.isDirectorySync(path);
      final image = !folder && _looksLikeImage(name);
      if (server == null) {
        setState(
          () => _attachments.add(
            _Attachment(
              path: path,
              name: name,
              from: _From.local,
              serverName: '',
              image: image,
              preview: image ? _previewOf(path) : null,
            ),
          ),
        );
      } else if (folder) {
        folders.add(name);
      } else {
        await _startUpload(
          DevicePick(XFile(path)),
          server,
          image: image,
          preview: image ? _previewOf(path) : null,
        );
      }
    }
    if (folders.isNotEmpty && server != null) {
      say(
        'A folder cannot be sent to ${server.name}, so ${folders.join(', ')} '
        '${folders.length == 1 ? 'was' : 'were'} not attached. Drop the files '
        'in it instead.',
      );
    }
  }

  /// Files already on the server, attached by path as [_From.files]: nothing
  /// to upload, and no preview — the path is the agent's spelling, which this
  /// client may not be able to open. One already attached is not added twice.
  /// Reached only through [_drainServerFiles], which has already checked the
  /// box can take them: nothing here refuses, because a refusal would drop a
  /// file already taken from its queue.
  void _attachServerFiles(List<String> paths) {
    final serverName = widget.server?.call().name ?? '';
    final attached = {for (final a in _attachments) a.path};
    setState(() {
      for (final path in paths) {
        if (!attached.add(path)) continue;
        final name = _leafOf(path);
        _attachments.add(
          _Attachment(
            path: path,
            name: name,
            from: _From.files,
            serverName: serverName,
            image: _looksLikeImage(name),
          ),
        );
      }
    });
  }

  static String _leafOf(String path) {
    final trimmed = path.replaceFirst(RegExp(r'[\\/]+$'), '');
    final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
    return cut < 0 ? trimmed : trimmed.substring(cut + 1);
  }

  /// An image a soft keyboard inserted (Gboard's stickers, GIFs, a copied
  /// photo): taken as a pasted one. There is no Ctrl+V on a phone.
  void _onKeyboardContent(KeyboardInsertedContent content) {
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty) {
      _log.warning('The keyboard inserted ${content.mimeType} with no bytes.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The keyboard sent that image empty.')),
      );
      return;
    }
    unawaited(
      _addImageBytes(bytes, ext: _insertableImages[content.mimeType] ?? 'png'),
    );
  }

  Future<void> _attach() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Prefer an image already on the clipboard ("paste image").
      final clip = await Pasteboard.image;
      if (clip != null && clip.isNotEmpty) {
        await _addImageBytes(clip);
        return;
      }
      // Otherwise let the user pick an image file. The clipboard read above
      // yields, so the composer may already be gone.
      if (!mounted) return;
      final server = _serverElsewhere();
      if (server != null) return await _attachFrom(server);
      final file = await pickOneFile(
        context: context,
        what: 'an image to attach',
        // The composer knows nothing about sessions, so the nearest useful
        // place is the user's own pictures.
        startNear: _pictures(),
        acceptedTypeGroups: _images,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final ext = file.name.contains('.')
          ? file.name.split('.').last.toLowerCase()
          : 'png';
      await _addImageBytes(bytes, ext: ext);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not attach image: $e')),
      );
    }
  }

  Future<void> _send() async {
    // A file still on its way, or one that stopped, would go missing from
    // the message.
    if (_busy || !widget.enabled || !_readyToSend) return;
    final typed = _input.text;
    final text = typed.trim();
    if (text.isEmpty && _attachments.isEmpty && _uploads.isEmpty) return;
    if (_uploads.isNotEmpty) {
      setState(() => _busy = true);
      final landed = await _uploadQueued();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!landed) {
        // Not busy any more: a server file offered meanwhile is taken now.
        _scheduleDrain();
        return;
      }
    }

    final buffer = StringBuffer(text);
    void list(String heading, Iterable<_Attachment> attached) {
      if (attached.isEmpty) return;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(heading);
      for (final a in attached) {
        buffer.write('\n');
        buffer.write(a.path);
      }
    }

    list('Attached image(s):', _attachments.where((a) => a.image));
    list('Attached file(s):', _attachments.where((a) => !a.image));

    final messenger = ScaffoldMessenger.of(context);
    final touch = _touch;
    setState(() {
      _busy = true;
      _sendError = null;
    });
    try {
      await widget.onSend(buffer.toString());
      if (mounted) {
        // Only what went: text a note or a draft added meanwhile stays.
        final left = textLeftAfterSend(_input.text, typed);
        _input.value = TextEditingValue(
          text: left,
          selection: TextSelection.collapsed(offset: left.length),
        );
        setState(_attachments.clear);
        // The box was disabled while it sent, which closed the keyboard; a
        // keyboard that shuts after each message reads as the session ending.
        // After the frame that enables it again: a disabled field takes no
        // focus.
        if (touch) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNode.requestFocus();
          });
        }
      }
    } on Object catch (e, stack) {
      // Keep the text/attachments so the user can retry.
      final words = e is StateError ? e.message : '$e';
      _log.warning('Send failed: $words', e, stack);
      if (mounted) setState(() => _sendError = words);
      messenger.showSnackBar(SnackBar(content: Text(words)));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        // A server file offered while the message was sending waited in its
        // queue; it lands in the now-empty box for the next message.
        _scheduleDrain();
      }
    }
  }

  /// Puts a snippet's text where the caret is, replacing any selection, and
  /// leaves it unsent: a snippet is a start on a message, not a message.
  void _insertSnippet(String text) {
    final value = _input.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canType = widget.enabled && !_busy;
    final textScaler = MediaQuery.textScalerOf(context);
    final snippets = widget.snippets;
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final touch = _touch;

    return LayoutBuilder(
      builder: (context, box) {
        // As many lines as the pane leaves room for. The scroll view is the
        // last resort for a pane shorter than the chrome itself.
        final maxLines = composerLinesThatFit(
          box.maxHeight - _chromeHeight(box.maxWidth, textScaler, touch),
          style: theme.textTheme.bodyMedium,
          textScaler: textScaler,
        );
        final field = TextField(
          controller: _input,
          focusNode: _focusNode,
          enabled: canType,
          // **Three lines at rest, not one.** The glyphs got 19 of the
          // composer's 113 logical pixels. Fewer only when the pane has
          // no room for three. A phone starts at one: its keyboard
          // already takes half the screen from the conversation.
          minLines: touch ? 1 : math.min(3, maxLines),
          maxLines: maxLines,
          textInputAction: TextInputAction.newline,
          // Android keyboards insert images through the field, not a
          // clipboard the app can read.
          contentInsertionConfiguration: touch && widget.attaches
              ? ContentInsertionConfiguration(
                  allowedMimeTypes: _insertableImages.keys.toList(),
                  onContentInserted: _onKeyboardContent,
                )
              : null,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            // `filled` is on in the app's theme, and with no border it
            // painted a rectangle inside this card.
            filled: false,
            // Every state, not only the resting one: the theme's own
            // focused border drew a second ring inside the card's
            // (owner, 2026-10-01). The card's ring is the focus signal.
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            // The wrapper above already spends `Insets.sm` vertically;
            // a second helping here paid twice.
            contentPadding: EdgeInsets.zero,
            // Board N2: the prompt, then the keys in a dimmer voice.
            // Two texts in a wrap rather than one span, so a narrow pane
            // puts the keys on the next line instead of clipping them.
            hint: Wrap(
              children: [
                Text(widget.hintText, style: hintStyle),
                // A soft keyboard's Enter is a new line: Send sends.
                if (!touch)
                  Text(
                    ' (Enter sends · Shift Enter new line)',
                    style: hintStyle?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(
                        alpha: _dimAlpha,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (touch && (_attachments.isNotEmpty || _uploads.isNotEmpty))
              _TouchAttachmentList(
                attachments: _attachments,
                uploads: _uploads,
                onRemove: canType
                    ? (i) => setState(() => _attachments.removeAt(i))
                    : null,
                onCancel: _cancelUpload,
                // Queued again, not uploaded: Send uploads it.
                onRetry: (upload) => setState(
                  () => upload
                    ..failure = null
                    ..queued = true,
                ),
              )
            else if (_attachments.isNotEmpty || _uploading > 0)
              _AttachmentStrip(
                attachments: _attachments,
                uploading: _uploading,
                asImages: widget.imagesGoAsImages?.call() ?? false,
                onRemove: (i) => setState(() => _attachments.removeAt(i)),
              ),
            if (_sendError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.sm,
                  Insets.md,
                  0,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    key: const ValueKey('composer-send-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ),
            if (_paletteOpen && canType)
              _CommandPalette(
                commands: _commandMatches,
                highlighted: _commandHighlight,
                touch: touch,
                onPicked: _pickCommand,
              ),
            if (touch)
              _touchRow(field, canType: canType)
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.md,
                  vertical: Insets.sm,
                ),
                child: field,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.sm,
                  0,
                  Insets.sm,
                  Insets.sm,
                ),
                child: _ComposerToolbar(
                  chips: widget.chips,
                  touch: touch,
                  attaches: widget.attaches,
                  onAttach: canType ? _attachAnyFile : null,
                  snippets: snippets == null
                      ? null
                      : _SnippetsButton(
                          snippets: snippets,
                          touch: touch,
                          onPicked: canType ? _insertSnippet : null,
                        ),
                  send: _SendButton(
                    input: _input,
                    attachments: _attachments,
                    busy: _busy,
                    touch: touch,
                    queued: _uploads.isNotEmpty,
                    onSend: canType && _readyToSend ? _send : null,
                  ),
                ),
              ),
            ],
          ],
        );
        return SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Chrome.chatWidth),
            child: Padding(
              // No side padding: the chat's gutter already places it, so its
              // edges line up with the messages above (board N2).
              padding: const EdgeInsets.only(bottom: Insets.md),
              // Only the ring listens to focus: a click into the box must not
              // rebuild the field it landed in.
              child: ListenableBuilder(
                listenable: _focusNode,
                builder: (context, child) => AnimatedContainer(
                  duration: Motion.of(context).fast,
                  decoration: BoxDecoration(
                    color: SurfaceTones.of(context).raised,
                    borderRadius: BorderRadius.circular(_radius),
                    // Board N2's 1px ring; the accent is the whole focus
                    // signal. The 1.0→1.5 width it also grew relaid the
                    // composer out on every focus.
                    border: Border.all(
                      color: _focusNode.hasFocus
                          ? scheme.primary
                          : scheme.outlineVariant,
                    ),
                  ),
                  child: child,
                ),
                child: body,
              ),
            ),
          ),
        );
      },
    );
  }

  /// **The phone's composer is one row**: attach and snippets, the field,
  /// send — the shape every messaging app has. Stacked, the 48dp buttons
  /// under a one-line field left a band of nothing twice its height (owner,
  /// 2026-10-01). The buttons stay at the bottom as the text grows, where the
  /// thumb already is; any chips go on a line of their own under it.
  Widget _touchRow(Widget field, {required bool canType}) {
    final snippets = widget.snippets;
    final tools = widget.attaches || snippets != null;
    return Padding(
      padding: const EdgeInsets.all(Insets.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.attaches)
                _ToolbarIconButton(
                  tooltip: 'Attach a file',
                  icon: AppIcons.plus,
                  touch: true,
                  onPressed: canType ? _attachAnyFile : null,
                ),
              if (snippets != null)
                _SnippetsButton(
                  snippets: snippets,
                  touch: true,
                  onPicked: canType ? _insertSnippet : null,
                ),
              Expanded(
                // A thumb's height even for one line, the text centred in it,
                // so the row's controls line up with the words.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Touch.target),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        tools ? Insets.xs : Insets.md,
                        Insets.sm,
                        Insets.sm,
                        Insets.sm,
                      ),
                      child: field,
                    ),
                  ),
                ),
              ),
              _SendButton(
                input: _input,
                attachments: _attachments,
                busy: _busy,
                touch: true,
                queued: _uploads.isNotEmpty,
                onSend: canType && _readyToSend ? _send : null,
              ),
            ],
          ),
          if (widget.chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.sm,
                Insets.xs,
                Insets.sm,
                Insets.xs,
              ),
              child: Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: widget.chips,
              ),
            ),
        ],
      ),
    );
  }

  /// Board N2's card corner: 12px, between the row radius and the dialog's.
  static const _radius = Radii.md + Insets.hair * 2;

  /// The key hint's share of the muted colour: board N2's `--dim` under
  /// `--mut`, as a fraction rather than a second grey.
  static const _dimAlpha = 0.7;

  /// Everything but the text lines, near enough to size the box by: guessing
  /// low costs a few pixels of scroll, never an overflow.
  double _chromeHeight(double width, TextScaler textScaler, bool touch) {
    final palette = _paletteOpen
        ? _CommandPalette.heightFor(_commandMatches.length, touch: touch)
        : 0.0;
    // Bottom padding, the ring, the text's own padding, the toolbar.
    // The phone's one row: its padding, the ring and the row's lines of
    // text beside the buttons — which the lines are counted into, so only
    // the chips' own line is chrome.
    if (touch) {
      var height = palette + Insets.md + 2 + 2 * Insets.xs + 2 * Insets.sm;
      if (widget.chips.isNotEmpty) height += 2 * Insets.xs + Chrome.control;
      final rows = _attachments.length + _uploads.length;
      if (rows > 0) height += Insets.sm + rows * _TouchAttachmentRow.height;
      return height;
    }
    var height =
        palette +
        Insets.md +
        2 +
        2 * Insets.sm +
        _SendButton.diameterFor(touch: touch) +
        Insets.sm;
    final toolbarWidth = width - 2 * Insets.sm - 2;
    if (widget.chips.isNotEmpty &&
        toolbarWidth <= _ComposerToolbar.rowMinWidth) {
      height += Insets.xs + Chrome.control;
    }
    if (touch) {
      final rows = _attachments.length + _uploads.length;
      if (rows > 0) height += Insets.sm + rows * _TouchAttachmentRow.height;
    } else if (_attachments.isNotEmpty || _uploading > 0) {
      height += Insets.sm + _AttachmentChip.height;
    }
    return height;
  }
}

/// The attachments as board N2 draws them: a row of pills, each an image
/// glyph, the file's name and a remove button. Where the files go is the
/// pill's tooltip — a sentence under them, always drawn, cost 31px.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.uploading,
    required this.asImages,
    required this.onRemove,
  });

  final List<_Attachment> attachments;

  /// Whether the agent takes an image as an image, which the tooltip says.
  final bool asImages;

  /// Pasted images still being sent, each drawn as a chip that says so.
  final int uploading;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
    child: Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        for (var i = 0; i < attachments.length; i++)
          _AttachmentChip(
            name: attachments[i].name,
            where: attachments[i].whereFor(asImage: asImages),
            image: attachments[i].image,
            preview: attachments[i].preview,
            onRemove: () => onRemove(i),
          ),
        for (var i = 0; i < uploading; i++)
          const _AttachmentChip(
            name: 'Sending…',
            where: 'Uploading to the server; Send waits until it is there.',
          ),
      ],
    ),
  );
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.name,
    required this.where,
    this.image = false,
    this.preview,
    this.onRemove,
  });

  final String name;
  final String where;
  final bool image;

  /// Drawn in place of the glyph when there is one.
  final ImageProvider? preview;

  /// Null while the image is still being sent: a spinner stands in its place.
  final VoidCallback? onRemove;

  /// The pill's height, which the composer's sizing counts.
  static const height = Chrome.control;

  Widget _glyph(Color muted) {
    final icon = Icon(
      image ? AppIcons.image : AppIcons.file,
      size: Chrome.iconSmall,
      color: muted,
    );
    final preview = this.preview;
    if (preview == null) return icon;
    const edge = height - 2 * Insets.xs;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Image(
        image: preview,
        width: edge,
        height: edge,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => icon,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final onRemove = this.onRemove;
    return Tooltip(
      message: where,
      child: Container(
        height: height,
        padding: const EdgeInsets.only(left: Insets.sm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glyph(muted),
            const SizedBox(width: Insets.xs),
            ConstrainedBox(
              // A long generated name gives way before the remove button.
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            if (onRemove == null)
              const SizedBox.square(
                dimension: height,
                child: Center(child: InlineSpinner()),
              )
            else
              IconButton(
                tooltip: 'Remove',
                iconSize: Chrome.iconSmall,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: height,
                  minHeight: height,
                ),
                padding: EdgeInsets.zero,
                color: muted,
                icon: const Icon(AppIcons.x),
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    );
  }
}

/// The attachments at touch density: one 48dp row each, with a thumbnail for
/// a picture and where the file lives as a second line, not a tooltip. An
/// upload in flight shows its percentage and *Cancel*; one that stopped says
/// why, with *Try again*.
class _TouchAttachmentList extends StatelessWidget {
  const _TouchAttachmentList({
    required this.attachments,
    required this.uploads,
    required this.onRemove,
    required this.onCancel,
    required this.onRetry,
  });

  final List<_Attachment> attachments;
  final List<_Upload> uploads;

  /// Null while the composer is sending.
  final ValueChanged<int>? onRemove;
  final ValueChanged<_Upload> onCancel;
  final ValueChanged<_Upload> onRetry;

  @override
  Widget build(BuildContext context) {
    final onRemove = this.onRemove;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.xs, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < attachments.length; i++)
            _TouchAttachmentRow(
              name: attachments[i].name,
              detail: attachments[i].detail,
              image: attachments[i].image,
              preview: attachments[i].preview,
              actions: [
                _RowAction(
                  tooltip: 'Remove',
                  icon: AppIcons.x,
                  onPressed: onRemove == null ? null : () => onRemove(i),
                ),
              ],
            ),
          for (final upload in uploads) _uploadRow(upload),
        ],
      ),
    );
  }

  Widget _uploadRow(_Upload upload) {
    final failure = upload.failure;
    final size = upload.size;
    if (failure != null) {
      return _TouchAttachmentRow(
        name: upload.pick.name,
        detail: failure,
        failed: true,
        image: upload.image,
        preview: upload.preview,
        actions: [
          _RowAction(
            tooltip: 'Try again',
            icon: AppIcons.arrowClockwise,
            onPressed: () => onRetry(upload),
          ),
          _RowAction(
            tooltip: 'Remove',
            icon: AppIcons.x,
            onPressed: () => onCancel(upload),
          ),
        ],
      );
    }
    if (upload.queued) {
      return _TouchAttachmentRow(
        name: upload.pick.name,
        detail: size == null
            ? 'Uploaded to ${upload.server.name} when you send'
            : '${formatBytes(size)} · uploaded when you send',
        image: upload.image,
        preview: upload.preview,
        actions: [
          _RowAction(
            tooltip: 'Remove',
            icon: AppIcons.x,
            onPressed: () => onCancel(upload),
          ),
        ],
      );
    }
    final fraction = size == null || size == 0
        ? null
        : (upload.sent / size).clamp(0.0, 1.0);
    final server = upload.server.name;
    return _TouchAttachmentRow(
      name: upload.pick.name,
      detail: fraction == null
          ? 'Sending to $server…'
          : fraction >= 1
          ? 'Finishing on $server…'
          : '${(fraction * 100).floor()}% · ${formatBytes(upload.sent)} of '
                '${formatBytes(size!)}',
      progress: fraction ?? 0,
      indeterminate: fraction == null || fraction >= 1,
      image: upload.image,
      preview: upload.preview,
      actions: [
        _RowAction(
          tooltip: 'Cancel the upload',
          icon: AppIcons.x,
          onPressed: () => onCancel(upload),
        ),
      ],
    );
  }
}

class _RowAction {
  const _RowAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
}

class _TouchAttachmentRow extends StatelessWidget {
  const _TouchAttachmentRow({
    required this.name,
    required this.detail,
    required this.image,
    required this.actions,
    this.preview,
    this.failed = false,
    this.progress,
    this.indeterminate = false,
  });

  /// One row, which the composer's sizing counts.
  static const height = Touch.target + Insets.xs;

  final String name;
  final String detail;
  final bool image;
  final ImageProvider? preview;
  final bool failed;

  /// Drawn as a bar under the words while an upload runs; null otherwise.
  final double? progress;
  final bool indeterminate;
  final List<_RowAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final glyph = Icon(
      image ? AppIcons.image : AppIcons.file,
      size: Touch.icon,
      color: muted,
    );
    final preview = this.preview;
    final progress = this.progress;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: SizedBox.square(
                dimension: _thumbnail,
                child: preview == null
                    ? Center(child: glyph)
                    : Image(
                        image: preview,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => Center(child: glyph),
                      ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: failed ? scheme.error : muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (progress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.xs),
                      child: LinearProgressIndicator(
                        value: indeterminate ? null : progress,
                        semanticsLabel: 'Sending $name',
                        semanticsValue: indeterminate
                            ? null
                            : '${(progress * 100).floor()}%',
                      ),
                    ),
                ],
              ),
            ),
            for (final action in actions)
              IconButton(
                tooltip: action.tooltip,
                onPressed: action.onPressed,
                constraints: const BoxConstraints(
                  minWidth: Touch.target,
                  minHeight: Touch.target,
                ),
                iconSize: Touch.icon,
                color: muted,
                icon: Icon(action.icon),
              ),
          ],
        ),
      ),
    );
  }
}

/// Attach, snippets, any chips a host adds, and the round send at the far
/// end. At a pane's narrowest the chips take a row to themselves.
class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.chips,
    required this.attaches,
    required this.onAttach,
    required this.snippets,
    required this.send,
    required this.touch,
  });

  static const rowMinWidth = 380.0;

  final List<Widget> chips;

  /// False hides Attach altogether.
  final bool attaches;

  /// Null while the composer cannot take input.
  final VoidCallback? onAttach;

  /// The snippets button, when the host offers a library.
  final Widget? snippets;
  final Widget send;

  /// Attach takes any file, and every control is a thumb's size.
  final bool touch;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tools = [
        if (attaches)
          _ToolbarIconButton(
            tooltip: touch
                ? 'Attach a file'
                : 'Attach a file (paste an image with Ctrl+V)',
            icon: AppIcons.plus,
            touch: touch,
            onPressed: onAttach,
          ),
        ?snippets,
      ];

      if (constraints.maxWidth > rowMinWidth || chips.isEmpty) {
        return Row(
          children: [
            ...tools,
            if (chips.isNotEmpty)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                  child: Wrap(
                    spacing: Insets.xs,
                    runSpacing: Insets.xs,
                    children: chips,
                  ),
                ),
              )
            else
              const Spacer(),
            send,
          ],
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [...tools, const Spacer(), send]),
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: chips,
            ),
          ),
        ],
      );
    },
  );
}

/// A quiet toolbar glyph (board N2's 26 by 22 tab button): muted, a wash
/// under the pointer, no fill of its own. [touch] makes it a thumb's 48dp.
class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.touch,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool touch;

  /// Shared with the snippets menu button, which is not an [IconButton].
  static ButtonStyle styleOf(BuildContext context, {bool touch = false}) =>
      IconButton.styleFrom(
        // `VisualDensity.compact` is already the app-wide default; restating
        // it subtracted its 8px twice and left the button 18 logical pixels
        // tall.
        visualDensity: VisualDensity.standard,
        minimumSize: Size.square(touch ? Touch.target : Chrome.control),
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      );

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: styleOf(context, touch: touch),
    iconSize: touch ? Touch.icon : Chrome.icon,
    icon: Icon(icon),
  );
}

/// The snippet library, read when it opens. Picking one types it into the
/// box at the caret, unsent. A menu under a pointer, a sheet under a thumb.
class _SnippetsButton extends StatelessWidget {
  const _SnippetsButton({
    required this.snippets,
    required this.onPicked,
    required this.touch,
  });

  final List<ComposerSnippet> Function() snippets;

  /// Null while the composer cannot take input.
  final ValueChanged<String>? onPicked;
  final bool touch;

  static const _empty = 'No snippets yet — add them in Settings › Snippets';

  Future<void> _showSheet(
    BuildContext context,
    ValueChanged<String> onPicked,
  ) async {
    final list = snippets();
    final picked = await showAdaptiveModal<String>(
      context: context,
      title: 'Insert a snippet',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (list.isEmpty)
            const ListTile(
              minTileHeight: Touch.target,
              enabled: false,
              leading: Icon(AppIcons.code, size: Touch.icon),
              title: Text(_empty),
            ),
          for (final snippet in list)
            ListTile(
              minTileHeight: Touch.target,
              leading: const Icon(AppIcons.code, size: Touch.icon),
              title: Text(snippet.label),
              onTap: () => Navigator.of(context).pop(snippet.text),
            ),
        ],
      ),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final onPicked = this.onPicked;
    if (touch) {
      return _ToolbarIconButton(
        tooltip: 'Insert a snippet',
        icon: AppIcons.code,
        touch: true,
        onPressed: onPicked == null
            ? null
            : () => unawaited(_showSheet(context, onPicked)),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Insert a snippet',
      enabled: onPicked != null,
      onSelected: onPicked,
      itemBuilder: (context) {
        final list = snippets();
        if (list.isEmpty) {
          return [
            DesktopMenuItem<String>(
              value: '',
              label: _empty,
              icon: AppIcons.code,
              enabled: false,
            ),
          ];
        }
        return [
          for (final snippet in list)
            DesktopMenuItem<String>(
              value: snippet.text,
              label: snippet.label,
              icon: AppIcons.code,
            ),
        ];
      },
      icon: const Icon(AppIcons.code),
      iconSize: Chrome.icon,
      // The same quiet glyph as Attach beside it.
      style: _ToolbarIconButton.styleOf(context),
    );
  }
}

/// Send, and the one thing in the composer that knows what has been typed. Its
/// own widget so a keystroke rebuilds one button, not the composer. Board N2
/// draws it as a round accent button at the toolbar's far end.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.input,
    required this.attachments,
    required this.busy,
    required this.onSend,
    required this.touch,
    this.queued = false,
  });

  /// Files picked on a phone and waiting to be uploaded by this press.
  final bool queued;

  /// Board N2's 30px circle; a thumb's 48dp at touch density, where it is the
  /// only way to send — a soft keyboard's Enter is a new line.
  static double diameterFor({required bool touch}) =>
      touch ? Touch.target : 30.0;

  final TextEditingController input;
  final List<_Attachment> attachments;
  final bool busy;
  final bool touch;

  /// Null when the composer cannot send at all — disabled, or mid-send.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = diameterFor(touch: touch);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: input,
      builder: (context, value, _) {
        final ready =
            onSend != null &&
            (value.text.trim().isNotEmpty || attachments.isNotEmpty || queued);
        return IconButton.filled(
          // Named, because it is icon-only and Narrator reads the semantics
          // tree. The chord is in the label as the only place that says so.
          tooltip: busy
              ? 'Sending…'
              : touch
              ? 'Send'
              : 'Send (Enter) · Shift + Enter for a new line',
          onPressed: onSend,
          iconSize: touch ? Touch.icon : Chrome.iconAction,
          style: IconButton.styleFrom(
            visualDensity: VisualDensity.standard,
            padding: EdgeInsets.zero,
            fixedSize: Size.square(diameter),
            minimumSize: Size.square(diameter),
            shape: const CircleBorder(),
            backgroundColor: ready
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            foregroundColor: ready ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          icon: busy ? const InlineSpinner() : const Icon(AppIcons.arrowUp),
        );
      },
    );
  }
}

/// The agent's slash commands matching what follows the "/", over the text:
/// the name, its input hint, and the agent's description. Up and Down move,
/// Enter or Tab picks, Esc shuts; a tap picks too.
class _CommandPalette extends StatelessWidget {
  const _CommandPalette({
    required this.commands,
    required this.highlighted,
    required this.touch,
    required this.onPicked,
  });

  final List<ComposerCommand> commands;
  final int highlighted;
  final bool touch;
  final ValueChanged<ComposerCommand> onPicked;

  /// Rows shown before the list scrolls.
  static const _shown = 6;

  static double _rowHeight({required bool touch}) =>
      touch ? Touch.target : Chrome.menuRow;

  /// What the palette adds to the composer, for its sizing.
  static double heightFor(int count, {required bool touch}) =>
      math.min(count, _shown) * _rowHeight(touch: touch) + Insets.sm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final rowHeight = _rowHeight(touch: touch);
    return Padding(
      key: const ValueKey('composer-command-palette'),
      padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.sm, Insets.xs, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _shown * rowHeight),
        child: ListView.builder(
          shrinkWrap: true,
          primary: false,
          padding: EdgeInsets.zero,
          itemCount: commands.length,
          itemExtent: rowHeight,
          itemBuilder: (context, i) {
            final command = commands[i];
            final hint = command.hint;
            return Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('composer-command-${command.name}'),
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: () => onPicked(command),
                child: Ink(
                  decoration: BoxDecoration(
                    color: i == highlighted
                        ? StateLayers.selected(scheme)
                        : null,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Text(
                        '/${command.name}',
                        style: MonoStyles.label.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                      if (hint != null && hint.isNotEmpty) ...[
                        const SizedBox(width: Insets.xs),
                        Flexible(
                          child: Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: MonoStyles.body.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          command.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// What stays in a box that held [now] once [sent] — the box's text when Send
/// was pressed — has gone: anything added meanwhile, never the sent words.
String textLeftAfterSend(String now, String sent) {
  if (now == sent) return '';
  if (sent.isNotEmpty && now.startsWith(sent)) {
    return now.substring(sent.length).trimLeft();
  }
  return now;
}
