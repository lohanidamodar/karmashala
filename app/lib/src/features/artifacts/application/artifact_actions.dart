import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod/riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/artifacts_data.dart';

/// What a person can do with an artifact beyond looking at it here: open a
/// copy in their browser — outside the sandbox, by their choice — or save
/// one. Both work from the bytes the server serves, so a desktop on another
/// machine or a phone does them as this machine does.
class ArtifactActions {
  ArtifactActions(
    this._data, {
    Future<bool> Function(Uri uri)? launch,
    Future<String?> Function(String suggestedName)? saveLocation,
    Future<Directory> Function()? scratch,
    Future<Directory> Function()? documents,
  }) : _launch = launch ?? _launchFile,
       _saveLocation = saveLocation ?? _askWhere,
       _scratch = scratch ?? (() async => Directory.systemTemp),
       _documents = documents ?? getApplicationDocumentsDirectory;

  final ArtifactsData _data;
  final Future<bool> Function(Uri uri) _launch;
  final Future<String?> Function(String suggestedName) _saveLocation;
  final Future<Directory> Function() _scratch;
  final Future<Directory> Function() _documents;

  /// Writes [revision] to a private temporary folder and opens it with the
  /// system's handler. Answers what happened, in words.
  Future<String> openInBrowser(Artifact artifact, int revision) async {
    final bytes = await _data.content(artifact.id, revision);
    final root = await _scratch();
    final folder = Directory(
      p.join(root.path, 'karmashala-artifacts', '${artifact.id}-r$revision'),
    );
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, _safeName(artifact.fileName)));
    await file.writeAsBytes(bytes, flush: true);
    final opened = await _launch(Uri.file(file.path));
    return opened
        ? 'Opened ${artifact.fileName} outside Karmashala.'
        : 'Nothing on this device opens ${artifact.fileName}; it was written '
              'to ${file.path}.';
  }

  /// Asks where to save [revision], or — where this platform has no save
  /// dialog — keeps it in the app's documents folder and says where.
  Future<String?> save(Artifact artifact, int revision) async {
    final bytes = await _data.content(artifact.id, revision);
    final name = _safeName(artifact.fileName);
    String? where;
    try {
      where = await _saveLocation(name);
      if (where == null) return null;
    } on UnimplementedError {
      final folder = Directory(p.join((await _documents()).path, 'artifacts'));
      await folder.create(recursive: true);
      where = p.join(folder.path, name);
    }
    await _write(where, bytes);
    return 'Saved to $where.';
  }

  static Future<void> _write(String path, Uint8List bytes) =>
      File(path).writeAsBytes(bytes, flush: true);

  /// A file name with nothing that walks out of its folder.
  static String _safeName(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final clean = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
    return clean.isEmpty || clean == '.' || clean == '..' ? 'artifact' : clean;
  }

  static Future<bool> _launchFile(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static Future<String?> _askWhere(String suggestedName) async {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      throw UnimplementedError('no save dialog');
    }
    return (await getSaveLocation(suggestedName: suggestedName))?.path;
  }
}

final artifactActionsProvider = Provider<ArtifactActions>(
  (ref) => ArtifactActions(ref.watch(artifactsDataProvider)),
);
