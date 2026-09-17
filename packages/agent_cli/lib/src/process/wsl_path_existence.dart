import './command_runner.dart';

/// Marks the one line of [wslDirectoriesExistScript]'s output that is ours.
const String kWslExistsMarker = '__karmashala_exists:';

/// The `sh` that says which of its arguments are directories, **from inside
/// the distribution**: one `1` or `0` per argument, in order, on one marked
/// line. The paths are `"$@"` and never part of the script, and none is echoed
/// back, so a path's own bytes — a space, a quote, `$`, a newline — can
/// neither run nor break the framing.
const String wslDirectoriesExistScript = r'''
out=
for p in "$@"; do
  if [ -d "$p" ]; then out="${out}1"; else out="${out}0"; fi
done
printf '__karmashala_exists:%s\n' "$out"
''';

/// The `wsl.exe` arguments asking [distribution] whether each of [paths] is a
/// directory. `--exec`, so no login shell re-parses a path; `$0` is a name.
///
/// This is how a Windows host learns that a WSL folder is still there: a stat
/// over `\\wsl.localhost` is slow and is what on-access antivirus scans
/// (docs/windows-antivirus.md).
List<String> wslDirectoriesExistArguments({
  required String distribution,
  required List<String> paths,
}) => [
  '-d',
  distribution,
  '--exec',
  'sh',
  '-c',
  wslDirectoriesExistScript,
  'karmashala-exists',
  ...paths,
];

/// [wslDirectoriesExistArguments] as a request for the **Windows host**.
CommandRequest wslDirectoriesExistRequest({
  required String distribution,
  required List<String> paths,
  Duration timeout = const Duration(seconds: 20),
}) => CommandRequest(
  executable: 'wsl.exe',
  arguments: wslDirectoriesExistArguments(
    distribution: distribution,
    paths: paths,
  ),
  timeout: timeout,
);

/// [paths] cut into calls that fit a Windows command line (32,767 characters,
/// the script and the quoting included), in order.
List<List<String>> wslExistenceBatches(
  List<String> paths, {
  int maxCharacters = 24000,
}) {
  final batches = <List<String>>[];
  var current = <String>[];
  var size = 0;
  for (final path in paths) {
    // Quotes around it, a space after, and room for every `"` to be escaped.
    final cost = path.length + 3 + '"'.allMatches(path).length;
    if (current.isNotEmpty && size + cost > maxCharacters) {
      batches.add(current);
      current = <String>[];
      size = 0;
    }
    current.add(path);
    size += cost;
  }
  if (current.isNotEmpty) batches.add(current);
  return batches;
}

/// What [wslDirectoriesExistScript] printed, as one answer per path asked — or
/// **null when the output is not an answer**: no marked line, or not exactly
/// [count] digits. Nothing is then known, which is not "missing".
List<bool>? parseWslDirectoriesExist(String output, {required int count}) {
  for (final raw in output.split('\n')) {
    final line = raw.replaceAll('\u0000', '').trim();
    if (!line.startsWith(kWslExistsMarker)) continue;
    final digits = line.substring(kWslExistsMarker.length);
    if (digits.length != count || !RegExp(r'^[01]*$').hasMatch(digits)) {
      return null;
    }
    return [for (final digit in digits.split('')) digit == '1'];
  }
  return null;
}
