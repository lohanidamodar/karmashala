import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';

/// Opens a shell on [host] the way its card's "Terminal" does. With [typed],
/// the command is put at the prompt and **not run**: the person presses Enter
/// and gives `sudo` its password there, in a real terminal — never to this app.
/// Answers whether the text will be typed; the caller still shows the command.
typedef OpenSshTerminal = bool Function(SshHost host, {String? typed});

final sshTerminalOpenerProvider = Provider<OpenSshTerminal>(
  (ref) => (host, {typed}) {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final profile = TerminalProfile.ssh(host.id, hostName: host.name);
    final directory = host.defaultDirectory?.path;
    var willType = false;
    if (typed == null) {
      terminals.openTab(profile, workingDirectory: directory);
    } else {
      willType = terminals
          .openTabTyping(profile, typed, workingDirectory: directory)
          .typed;
    }
    // A new shell opens in the group the keyboard is in.
    terminals.showTerminalHere();
    return willType;
  },
);

/// The commands a terminal was opened for since this launch, by host. "Check
/// again" after one means the rule is presumed added, so a port that is still
/// shut is not answered with the same command a second time.
class SudoTerminalsOpened extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void mark(String hostId, String command) =>
      state = {...state, keyOf(hostId, command)};

  /// Whether a terminal was opened on [hostId] for the command that opens
  /// [port]. By port, so a dialog that was closed for the terminal and opened
  /// again — holding no reading yet — still knows.
  bool openedForPort(String hostId, int port) => state.any(
    (key) => key.startsWith('$hostId\n') && key.contains('$port/tcp'),
  );

  static String keyOf(String hostId, String command) => '$hostId\n$command';
}

final sudoTerminalsOpenedProvider =
    NotifierProvider<SudoTerminalsOpened, Set<String>>(SudoTerminalsOpened.new);
