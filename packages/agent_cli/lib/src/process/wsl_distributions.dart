/// Parses the output of `wsl.exe --list --quiet` into distribution names.
///
/// Pure and testable. `wsl.exe` emits UTF-16, so after decoding the text often
/// contains interleaved NUL (`0x00`) bytes and a leading byte-order mark
/// (`0xFEFF`); both are stripped here. Blank lines are dropped.
///
/// **There is exactly one of these on purpose.** Two parses that disagree about
/// the same output match nothing while looking correct, and that failure is
/// silent: environment discovery stores the name `Docker Desktop`, and a second
/// parser that also stripped the space would ask whether `DockerDesktop` is
/// running, be told no, and skip that distribution for the life of the process
/// without a word. It lives in `core/process` rather than beside either caller
/// because both `EnvironmentDiscoveryService` and `wslRunningDistributions`
/// have to mean the same thing by a distribution's name.
List<String> parseWslDistributions(String rawOutput) {
  final cleaned = String.fromCharCodes(
    rawOutput.codeUnits.where((c) => c != 0x00 && c != 0xFEFF),
  );
  final names = <String>[];
  for (final raw in cleaned.split(RegExp(r'[\r\n]+'))) {
    // Strip a leading default-distro marker ("* Ubuntu") if `--quiet` was
    // omitted, then trim surrounding whitespace.
    final line = raw.replaceFirst(RegExp(r'^\s*\*\s*'), '').trim();
    if (line.isEmpty) continue;
    // Drop the header `wsl --list` prints without `--quiet`.
    if (line.toLowerCase().startsWith('windows subsystem for linux')) continue;
    names.add(line);
  }
  return names;
}
