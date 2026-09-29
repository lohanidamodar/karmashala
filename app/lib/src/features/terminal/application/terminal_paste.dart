import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:xterm2/xterm.dart';

import '../../agents/application/agent_providers.dart';

/// What `Ctrl+V` sends when there is nothing to paste: the key itself.
const String kPasteKeyToProgram = AgentImagePasteKey.ctrlV;

/// Pastes the clipboard into [terminal], or hands [keyToProgram] to the
/// program: xterm's own paste reads `text/plain`, so it ate the key on an
/// image. The program then reads the image off the clipboard itself.
Future<void> pasteIntoTerminal(
  Terminal terminal, {
  TerminalController? controller,
  String keyToProgram = kPasteKeyToProgram,
}) async {
  // On Windows `OpenClipboard` fails while another app holds it and Flutter
  // raises; unhandled, the chord did nothing at all, not even send `^V`.
  String? text;
  try {
    text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } on PlatformException {
    text = null;
  }
  if (text == null || text.isEmpty) {
    terminal.textInput(keyToProgram);
    return;
  }
  terminal.paste(text);
  controller?.clearSelection();
}

/// The key that makes [instance]'s program paste the clipboard's image: its
/// agent's own binding for where it runs, or `Ctrl+V` for a plain shell and an
/// agent nobody measured. Claude Code on Windows binds only `alt+v`, so the
/// `Ctrl+V` every pane used to send pasted nothing there (2026-09-29).
String imagePasteKeyFor(WidgetRef ref, TerminalInstance instance) {
  final launch = instance.agentLaunch;
  if (launch == null) return kPasteKeyToProgram;
  final descriptor = ref.read(agentRegistryProvider).byId(launch.agentId);
  if (descriptor == null) return kPasteKeyToProgram;
  final kind = launch.sshHostId != null
      ? EnvironmentKind.ssh
      : launch.wslDistribution != null
      ? EnvironmentKind.wsl
      : Platform.isWindows
      ? EnvironmentKind.windowsNative
      : EnvironmentKind.localPosix;
  return descriptor.imagePaste.keyFor(kind);
}
