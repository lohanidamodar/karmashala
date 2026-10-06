import 'package:agent_cli/process.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;

import '../../files/data/pick_server.dart' show serverDisplayName;

/// Where something runs, in the words the sidebar uses for its machines.
class EnvironmentLocation {
  const EnvironmentLocation({
    required this.kind,
    required this.label,
    required this.name,
    this.folder,
  });

  final EnvironmentKind kind;

  /// The short form, for a bar with room for a word: `Windows`,
  /// `WSL · archlinux`, or the server's name when the host is another machine.
  final String label;

  /// The full form: [label], qualified with the server when it is elsewhere.
  final String name;

  /// The directory there, as that machine spells it.
  final String? folder;

  /// [name] as a screen reader should hear it.
  String get spokenName => spokenEnvironmentLabel(name);

  EnvironmentLocation inFolder(String? folder) =>
      EnvironmentLocation(kind: kind, label: label, name: name, folder: folder);
}

/// Where [environment] is, as this window should name it. On a server
/// elsewhere ([machine] set) its own host is called by the server's name:
/// "Windows" alone would read as the computer in front of you.
EnvironmentLocation? locationOf(
  ExecutionEnvironment environment, {
  CompanionPairing? machine,
  String? folder,
}) {
  final own = environmentLabel(environment) ?? environment.name.trim();
  if (own.isEmpty) return null;
  final server = machine == null ? null : serverDisplayName(machine);
  return EnvironmentLocation(
    kind: environment.kind,
    label: server != null && isLocalHost(environment.kind) ? server : own,
    name: server == null ? own : '$own on $server',
    folder: folder,
  );
}
