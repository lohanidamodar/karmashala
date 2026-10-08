// What the composer attaches: its sources, uploads and image helpers.

part of '../message_composer.dart';

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
