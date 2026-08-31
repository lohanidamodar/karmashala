import '../../agents/domain/agent_registry.dart';

/// The agent whose CLI [commandLine] starts, or `null` for anything else.
///
/// Read off the registry's own [AgentBinaries] rather than a list of names kept
/// here, so an agent added tomorrow is recognised by the same rule as the
/// shipped ones — the same reason discovery and store location read the
/// registry instead of hardcoding agent facts.
///
/// **Only the first token is considered.** `claude` is an agent session;
/// `git commit -m claude` is not, and a match anywhere in the line would make
/// those indistinguishable. A leading path (`C:\bin\claude.exe`, `./claude`) is
/// reduced to its base name, and a Windows executable suffix is dropped, so the
/// same invocation is recognised however it was typed.
String? agentIdForCommandLine(String commandLine, AgentRegistry registry) {
  final token = _firstToken(commandLine);
  if (token == null) return null;
  final name = _baseName(token);
  if (name.isEmpty) return null;
  for (final descriptor in registry.descriptors) {
    for (final binary in [
      ...descriptor.binaries.windows,
      ...descriptor.binaries.posix,
    ]) {
      if (_baseName(binary) == name) return descriptor.id;
    }
  }
  return null;
}

/// The first word of [line], honouring one level of quoting so a path with a
/// space in it is one token.
String? _firstToken(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('"')) {
    final end = trimmed.indexOf('"', 1);
    return end < 0 ? trimmed.substring(1) : trimmed.substring(1, end);
  }
  final space = trimmed.indexOf(RegExp(r'\s'));
  return space < 0 ? trimmed : trimmed.substring(0, space);
}

/// [path]'s last segment, lower-cased, with a Windows executable suffix off.
String _baseName(String path) {
  var name = path;
  final cut = name.lastIndexOf(RegExp(r'[\\/]'));
  if (cut >= 0) name = name.substring(cut + 1);
  name = name.toLowerCase();
  for (final suffix in const ['.exe', '.cmd', '.bat', '.ps1']) {
    if (name.endsWith(suffix)) {
      return name.substring(0, name.length - suffix.length);
    }
  }
  return name;
}
