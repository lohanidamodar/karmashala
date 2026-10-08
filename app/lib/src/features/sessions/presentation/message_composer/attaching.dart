// The composer's attaching: paste, pick, drop, upload and server files.

part of '../message_composer.dart';

mixin _ComposerAttaching on State<MessageComposer> {
  final _attachments = <_Attachment>[];

  /// Device files on their way to a server elsewhere. Send waits.
  final _uploads = <_Upload>[];

  bool get _busy;
  bool get _touch;

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
}
