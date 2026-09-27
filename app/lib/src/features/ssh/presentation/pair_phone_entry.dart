import 'package:agent_cli/process.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_environments/ssh.dart';

import '../application/ssh_hosts_controller.dart';
import 'pair_phone_dialog.dart';

/// What every "Pair a phone…" says, so the card, the switcher and the health
/// panel cannot drift into three names for one dialog.
const String kPairPhoneLabel = 'Pair a phone…';

/// The saved host behind an SSH environment, or null for every other machine —
/// only a box has an address of its own for a phone to pair with.
SshHost? sshHostOf(WidgetRef ref, ExecutionEnvironment? environment) {
  final id = environment?.sshHostId;
  if (environment?.kind != EnvironmentKind.ssh || id == null) return null;
  for (final host in ref.read(sshHostsControllerProvider)) {
    if (host.id == id) return host;
  }
  return null;
}

/// Opens the one pairing dialog for [environment]'s machine, from wherever that
/// machine is shown. Does nothing for a machine that is not an SSH host.
Future<void> pairPhoneWith(
  BuildContext context,
  WidgetRef ref,
  ExecutionEnvironment? environment,
) async {
  final host = sshHostOf(ref, environment);
  if (host == null) return;
  await PairPhoneDialog.show(context, host: host);
}
