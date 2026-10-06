/// **The applications the operating system already knows about**, so a picker
/// can offer them instead of asking for a path.
///
/// Every desktop keeps such a list and this reads it rather than guessing: the
/// Start Menu on Windows, `/Applications` on macOS, `.desktop` entries on
/// Linux. A curated catalogue of editors can never know about the one somebody
/// installed yesterday — measured on the owner's machine, three of the five
/// editors present (Antigravity, T3 Code, Visual Studio) put nothing on `PATH`.
library;

import 'package:path/path.dart' as p;

import '../util/search_match.dart';

/// One application, as its own desktop lists it.
class InstalledApplication {
  const InstalledApplication({
    required this.name,
    required this.launchPath,
    required this.source,
    this.arguments = const [],
  });

  /// What the OS calls it — the shortcut's name, the bundle's, the `Name=`.
  final String name;

  /// The executable, or the `.app` bundle on macOS. What gets stored when the
  /// user picks it, so nothing has to be re-resolved at launch.
  final String launchPath;

  /// Where it was read off, shown under the name so a duplicate is
  /// distinguishable — two Start Menus really do list VS Code twice.
  final String source;

  /// What the entry asks to be run with, minus its field codes. Only Linux
  /// `.desktop` entries carry any.
  final List<String> arguments;

  /// A macOS bundle is *opened*, never executed: it is a directory.
  bool get isMacBundle => isMacApplicationBundle(launchPath);

  /// Two entries for the same program are one application, whichever menu
  /// listed them. Case-insensitive, because Windows paths are.
  String get key => launchPath.toLowerCase();

  @override
  String toString() => 'InstalledApplication($name at $launchPath)';
}

/// Whether [path] names a macOS `.app`, which `open -a` launches and
/// `Process.start` cannot: it is a directory, not a program.
bool isMacApplicationBundle(String path) =>
    p.extension(path).toLowerCase() == '.app';

/// What a picker shows for a path the user chose by hand or in an earlier
/// build — the file's own name, since nothing recorded a label.
String applicationNameFor(String launchPath) {
  // Either desktop's spelling: the windows context reads `/` and `\` alike.
  final base = p.windows.basename(launchPath);
  final name = p.windows.basenameWithoutExtension(launchPath);
  // `Code.exe` reads better as `Code`; a bundle keeps everything but `.app`.
  return name.isEmpty ? base : name;
}

/// **The Start Menu pass's output**, one `name<TAB>target` per line.
///
/// Deduplicated on the target: the per-machine and per-user menus both list
/// anything installed for everyone.
List<InstalledApplication> windowsApplicationsIn(String stdout) {
  final byKey = <String, InstalledApplication>{};
  for (final line in stdout.split('\n')) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) continue;
    final tab = trimmed.indexOf('\t');
    if (tab <= 0) continue;
    final name = trimmed.substring(0, tab).trim();
    final target = trimmed.substring(tab + 1).trim();
    if (name.isEmpty || target.isEmpty) continue;
    final app = InstalledApplication(
      name: name,
      launchPath: target,
      source: 'Start Menu',
    );
    byKey.putIfAbsent(app.key, () => app);
  }
  return byKey.values.toList()..sort(byApplicationName);
}

/// One `.desktop` entry, or `null` when it is not something to offer — another
/// group's file, a link, or one the desktop itself is told to hide.
InstalledApplication? desktopEntryIn(
  String contents, {
  required String source,
}) {
  var inEntry = false;
  String? name;
  String? exec;
  var hidden = false;
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inEntry = line == '[Desktop Entry]';
      continue;
    }
    if (!inEntry || line.isEmpty || line.startsWith('#')) continue;
    final equals = line.indexOf('=');
    if (equals <= 0) continue;
    final key = line.substring(0, equals).trim();
    final value = line.substring(equals + 1).trim();
    switch (key) {
      // Bare `Name`, never `Name[de]`: a localised one would overwrite it with
      // whichever translation happened to come last in the file.
      case 'Name':
        name ??= value;
      case 'Exec':
        exec ??= value;
      case 'Type':
        if (value != 'Application') return null;
      case 'NoDisplay' || 'Hidden':
        if (value.toLowerCase() == 'true') hidden = true;
    }
  }
  if (hidden || name == null || exec == null || name.isEmpty) return null;
  final words = splitDesktopExec(exec);
  if (words.isEmpty) return null;
  return InstalledApplication(
    name: name,
    launchPath: words.first,
    source: source,
    arguments: words.skip(1).toList(),
  );
}

/// An `Exec=` line as words, **with its field codes dropped**.
///
/// `%f`, `%U` and the rest are where the desktop would substitute the files it
/// is opening; passing them through literally makes an editor open a file
/// called `%F`. `%%` is an escaped percent and stays.
List<String> splitDesktopExec(String exec) {
  final words = <String>[];
  final word = StringBuffer();
  String? quote;
  var started = false;
  for (var i = 0; i < exec.length; i++) {
    final c = exec[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        word.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      started = true;
      continue;
    }
    if (c == ' ' || c == '\t') {
      if (started) words.add(word.toString());
      word.clear();
      started = false;
      continue;
    }
    if (c == '%' && i + 1 < exec.length) {
      final code = exec[i + 1];
      i++;
      if (code == '%') {
        word.write('%');
        started = true;
      }
      continue;
    }
    word.write(c);
    started = true;
  }
  if (started) words.add(word.toString());
  return [
    for (final w in words)
      if (w.isNotEmpty) w,
  ];
}

/// Alphabetical, case-insensitively — the order a list of applications is
/// looked through in.
int byApplicationName(InstalledApplication a, InstalledApplication b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());

/// The applications whose name or path contains [query], in order. An empty
/// query is everything: the dialog opens on the whole list.
List<InstalledApplication> matchingApplications(
  List<InstalledApplication> apps,
  String query,
) {
  if (query.trim().isEmpty) return apps;
  return [
    for (final app in apps)
      if (matchesSearchAny(query, [app.name, app.launchPath])) app,
  ];
}
