import 'dart:async';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';

/// One path on the fake host.
class FakeRemoteNode {
  FakeRemoteNode.file(
    this.bytes, {
    this.permissions = 0x1a4, // 0644
    this.userId = 1000,
    this.groupId = 1000,
    this.modified = 0,
    this.linkTo,
  }) : isDirectory = false;

  FakeRemoteNode.directory({this.modified = 0})
    : bytes = Uint8List(0),
      isDirectory = true,
      permissions = 0x1ed, // 0755
      userId = 1000,
      groupId = 1000,
      linkTo = null;

  Uint8List bytes;
  final bool isDirectory;
  int permissions;
  int userId;
  int groupId;

  /// Whole seconds, as SFTP v3 reports them.
  int modified;

  /// A symlink: every read and write goes to this path.
  final String? linkTo;
}

/// An SSH host's files in memory, behind the same verbs the real SFTP browser
/// has — so the save's version check, temp file, mode and rename run for real.
class FakeRemoteFiles implements RemoteDocumentFiles {
  FakeRemoteFiles({this.environmentId = 'ssh:box', this.atomic = true}) {
    nodes['/'] = FakeRemoteNode.directory();
  }

  @override
  final String environmentId;

  /// Whether the server offers `posix-rename@openssh.com`.
  bool atomic;

  /// The uid a file this client creates is owned by.
  int writerUserId = 1000;

  final Map<String, FakeRemoteNode> nodes = {};

  /// Every call, in order, as `verb path`.
  final List<String> log = [];

  /// The link is down: every call fails as a dropped connection does.
  bool offline = false;

  /// A stat that answers only when the test says so — a slow link.
  Completer<void>? statGate;

  /// Runs just before a replace.
  void Function()? beforeReplace;

  /// Runs once a file is created — to land another writer's change while a
  /// save's temp file is uploading.
  void Function(String path)? afterCreate;

  var _clock = 100;
  var stats = 0;

  /// Another writer on the host: a new version with a new modification time.
  void writeBehind(String path, String text) {
    final node = nodes[path];
    final bytes = Uint8List.fromList(text.codeUnits);
    if (node == null) {
      nodes[path] = FakeRemoteNode.file(bytes, modified: ++_clock);
    } else {
      node
        ..bytes = bytes
        ..modified = ++_clock;
    }
  }

  void addDirectory(String path) => nodes[path] = FakeRemoteNode.directory();

  void addFile(String path, List<int> bytes, {int permissions = 0x1a4}) =>
      nodes[path] = FakeRemoteNode.file(
        Uint8List.fromList(bytes),
        permissions: permissions,
        modified: ++_clock,
      );

  String textOf(String path) => String.fromCharCodes(_resolve(path)!.bytes);

  FakeRemoteNode? _resolve(String path) {
    final node = nodes[path];
    final target = node?.linkTo;
    return target == null ? node : nodes[target];
  }

  void _online(String what) {
    if (offline) {
      throw RemoteUnreachableException(
        'Cannot $what: the connection to box was lost',
      );
    }
  }

  static String _parent(String path) {
    final cut = path.lastIndexOf('/');
    return cut <= 0 ? '/' : path.substring(0, cut);
  }

  @override
  Future<RemoteFileStat?> statFile(EnvironmentPath path) async {
    stats++;
    log.add('stat ${path.path}');
    if (statGate != null) await statGate!.future;
    _online('read ${path.path}');
    final node = _resolve(path.path);
    if (node == null) return null;
    return RemoteFileStat(
      isDirectory: node.isDirectory,
      size: node.bytes.length,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        node.modified * 1000,
        isUtc: true,
      ),
      permissions: node.permissions,
      userId: node.userId,
      groupId: node.groupId,
    );
  }

  @override
  Future<bool> isSymlink(EnvironmentPath path) async {
    _online('read ${path.path}');
    return nodes[path.path]?.linkTo != null;
  }

  @override
  Future<Uint8List> readBytes(EnvironmentPath path, {int? length}) async {
    log.add('read ${path.path}');
    _online('read ${path.path}');
    final node = _resolve(path.path);
    if (node == null || node.isDirectory) {
      throw RemoteBrowseException('Cannot read ${path.path} on box');
    }
    final bytes = node.bytes;
    return length == null || length >= bytes.length
        ? Uint8List.fromList(bytes)
        : Uint8List.fromList(bytes.sublist(0, length));
  }

  @override
  Future<void> writeNewFile(EnvironmentPath path, Uint8List bytes) async {
    log.add('create ${path.path}');
    _online('write ${path.path}');
    if (nodes.containsKey(path.path)) {
      throw RemoteBrowseException('Cannot write ${path.path} on box');
    }
    if (!(nodes[_parent(path.path)]?.isDirectory ?? false)) {
      throw RemoteBrowseException('Cannot write ${path.path} on box');
    }
    nodes[path.path] = FakeRemoteNode.file(
      Uint8List.fromList(bytes),
      userId: writerUserId,
      modified: ++_clock,
    );
    afterCreate?.call(path.path);
  }

  @override
  Future<void> overwriteFile(EnvironmentPath path, Uint8List bytes) async {
    log.add('overwrite ${path.path}');
    _online('write ${path.path}');
    final node = _resolve(path.path);
    if (node == null) {
      nodes[path.path] = FakeRemoteNode.file(
        Uint8List.fromList(bytes),
        userId: writerUserId,
        modified: ++_clock,
      );
      return;
    }
    node
      ..bytes = Uint8List.fromList(bytes)
      ..modified = ++_clock;
  }

  @override
  Future<void> setPermissions(EnvironmentPath path, int permissions) async {
    log.add('chmod ${path.path} ${permissions.toRadixString(8)}');
    _online('set the mode of ${path.path}');
    nodes[path.path]!.permissions = permissions;
  }

  @override
  Future<bool> replacesAtomically() async => atomic;

  @override
  Future<void> replace(EnvironmentPath from, EnvironmentPath to) async {
    beforeReplace?.call();
    log.add('replace ${from.path} ${to.path}');
    _online('rename ${from.path}');
    final node = nodes.remove(from.path);
    if (node == null) throw RemoteBrowseException('Cannot rename ${from.path}');
    nodes[to.path] = node;
  }

  @override
  Future<void> removeFile(EnvironmentPath path) async {
    log.add('remove ${path.path}');
    _online('delete ${path.path}');
    nodes.remove(path.path);
  }

  /// Paths of temp files a save left behind.
  List<String> get leftovers => [
    for (final path in nodes.keys)
      if (path.contains('.karmashala-')) path,
  ];
}
