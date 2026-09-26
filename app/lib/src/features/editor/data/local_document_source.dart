import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import '../../files/data/local_file_space.dart';
import '../domain/document_id.dart';
import '../domain/document_source.dart';
import '../domain/source_document.dart';

var _tempCounter = 0;

/// Files `dart:io` can reach: this machine's disk, or a WSL distribution over
/// its `\\wsl.localhost` share. Paths are in the environment's own spelling;
/// [bridge] turns one into what `dart:io` is given.
class LocalDocumentSource implements DocumentSource {
  LocalDocumentSource({
    required this.environmentId,
    required this.pathContext,
    required this.capabilities,
    this.bridge = HostPathBridge.same,
  });

  /// This machine. Windows replaces by rename; a POSIX host rewrites in place,
  /// because `dart:io` cannot put a file's mode back on a fresh one.
  factory LocalDocumentSource.host() => LocalDocumentSource(
    environmentId: localHostEnvironmentId,
    pathContext: p.context,
    capabilities: DocumentSourceCapabilities(
      atomicReplace: Platform.isWindows,
      cheapStat: true,
    ),
  );

  /// A distribution over the share. In place, for the same reason as a POSIX
  /// host: a renamed-in file would lose its executable bit.
  factory LocalDocumentSource.wsl(String distribution) => LocalDocumentSource(
    environmentId: 'wsl:$distribution',
    pathContext: p.posix,
    capabilities: const DocumentSourceCapabilities(
      atomicReplace: false,
      cheapStat: false,
    ),
    bridge: HostPathBridge(
      toHost: (path) => wslSharePath(distribution, path),
      fromHost: (hostPath) => wslPosixPath(distribution, hostPath),
    ),
  );

  @override
  final String environmentId;

  @override
  final p.Context pathContext;

  @override
  final DocumentSourceCapabilities capabilities;

  final HostPathBridge bridge;

  @override
  String? hostPathOf(String path) => bridge.toHost(path);

  @override
  Future<DocumentStat> stat(String path) => _statHost(bridge.toHost(path));

  Future<DocumentStat> _statHost(String host) async {
    final stat = await FileStat.stat(host);
    if (stat.type == FileSystemEntityType.notFound) {
      return const DocumentStat.absent();
    }
    return DocumentStat(
      isDirectory: stat.type == FileSystemEntityType.directory,
      size: stat.size,
      version: FileStamp(length: stat.size, modified: stat.modified),
    );
  }

  @override
  Future<Uint8List> read(String path, {int? length}) async {
    final file = File(bridge.toHost(path));
    if (length == null) return file.readAsBytes();
    final handle = await file.open();
    try {
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<FileStamp> write(
    String path,
    Uint8List bytes, {
    required WriteExpectation expect,
  }) async {
    final host = bridge.toHost(path);
    final before = await _statHost(host);
    if (before.isDirectory) {
      throw DocumentSourceException('$host is a folder, not a file.');
    }
    if (!expect.accepts(before.version)) {
      throw DocumentStaleException(before.version);
    }
    // This editor edits files that exist; creating a tree for a typo'd path
    // would be a worse answer than refusing.
    final parent = p.windows.dirname(host);
    if (!before.exists &&
        parent.isNotEmpty &&
        !await Directory(parent).exists()) {
      throw DocumentSourceException('$parent does not exist.');
    }
    try {
      if (capabilities.atomicReplace &&
          before.exists &&
          !await FileSystemEntity.isLink(host)) {
        await _replace(host, bytes, expect);
      } else {
        await File(host).writeAsBytes(bytes, flush: true);
      }
    } on FileSystemException catch (error) {
      throw DocumentSourceException(error.osError?.message ?? error.message);
    }
    final after = await _statHost(host);
    final version = after.version;
    if (version == null) {
      throw DocumentSourceException(
        'it was written and then could not be found at $host.',
      );
    }
    return version;
  }

  /// Temp file beside the target, then a rename over it. A rename Windows
  /// refuses — a reader holding the file without delete sharing — falls back
  /// to writing in place rather than failing a save that could land.
  Future<void> _replace(
    String host,
    Uint8List bytes,
    WriteExpectation expect,
  ) async {
    final context = p.windows;
    final temp = context.join(
      context.dirname(host),
      '.${context.basename(host)}.karmashala-$pid-${_tempCounter++}.tmp',
    );
    final file = File(temp);
    await file.writeAsBytes(bytes, flush: true);
    try {
      final now = await _statHost(host);
      if (!expect.accepts(now.version)) {
        throw DocumentStaleException(now.version);
      }
      await file.rename(host);
    } on FileSystemException {
      await _deleteQuietly(file);
      await File(host).writeAsBytes(bytes, flush: true);
    } on Object {
      await _deleteQuietly(file);
      rethrow;
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A temp file left behind is untidy, not a lost save.
    }
  }

  @override
  Future<void> close() async {}
}

/// The sources that need nothing but `dart:io`: this machine and every WSL
/// distribution. SSH needs a connection pool, so the app's resolver adds it.
class LocalDocumentSources implements DocumentSourceResolver {
  LocalDocumentSources();

  LocalDocumentSource? _host;
  final Map<String, LocalDocumentSource> _wsl = {};

  @override
  DocumentSource? sourceFor(String environmentId) {
    if (environmentId == localHostEnvironmentId) {
      return _host ??= LocalDocumentSource.host();
    }
    final distribution = wslDistributionOf(environmentId);
    if (distribution == null) return null;
    return _wsl[environmentId] ??= LocalDocumentSource.wsl(distribution);
  }
}

/// The file [documentId] names, spelled for `dart:io` here — null for a file
/// that can only be reached over a connection.
String? hostPathOfDocument(String documentId) {
  final path = documentPathOf(documentId);
  if (path.environmentId == localHostEnvironmentId) return path.path;
  final distribution = wslDistributionOf(path.environmentId);
  if (distribution == null) return null;
  return wslSharePath(distribution, path.path);
}
