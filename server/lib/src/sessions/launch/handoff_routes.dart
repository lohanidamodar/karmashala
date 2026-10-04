import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_launch/karmashala_launch.dart'
    show survivesWindowsNativeArgv;
import 'package:karmashala_session_engine/store.dart' show HandoffRoute;

/// The longest text handed over as one argument off a Windows-native launch.
/// A WSL agent started from Windows crosses `wsl.exe`, whose whole command
/// line is capped at 32,767 characters.
const kPosixArgvTextLimit = 16 * 1024;

/// Whether [text] arrives intact as one argument of a launch that does, or
/// does not, cross PowerShell and `cmd.exe` ([throughPowerShell]).
bool argvCarries(String text, {required bool throughPowerShell}) =>
    throughPowerShell
    ? survivesWindowsNativeArgv(text)
    : text.isNotEmpty && text.length <= kPosixArgvTextLimit;

/// How an opening message [text] reaches [descriptor]'s agent in a terminal:
/// on the command line where it arrives intact, typed into the composer once
/// the agent is ready where the server holds its screen ([typeable]) and
/// typing is lossless for it, else as a file it is pointed at.
HandoffRoute openingRoute(
  String text, {
  required AgentDescriptor? descriptor,
  required bool throughPowerShell,
  required bool typeable,
}) {
  final takesArgument = descriptor?.launch.acceptsPromptArgument ?? true;
  if (takesArgument &&
      argvCarries(text, throughPowerShell: throughPowerShell)) {
    return HandoffRoute.argv;
  }
  if (typeable && (descriptor?.terminal.typedTextArrivesWhole ?? false)) {
    return HandoffRoute.typed;
  }
  return HandoffRoute.file;
}

/// How a packet [text] reaches an agent as its system prompt — inline or as a
/// file — or null when it takes none and the packet is its opening message.
HandoffRoute? systemPromptRoute(
  String text, {
  required AgentSystemPromptFileSupport support,
  required bool throughPowerShell,
}) {
  if (support.takesText &&
      argvCarries(text, throughPowerShell: throughPowerShell)) {
    return HandoffRoute.argv;
  }
  return support.isSupported ? HandoffRoute.file : null;
}
