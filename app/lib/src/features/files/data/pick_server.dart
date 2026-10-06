import 'package:agent_cli/process.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show kMaxUploadBytes;
import 'package:karmashala_remote/client.dart' show CompanionPairing;
import 'package:karmashala_ui/picking.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/failure_words.dart';
import '../../remote/application/machines_providers.dart';
import 'files_client.dart';

/// The server [files] reaches, as the two-source picker (spec decision 11)
/// wants it: a device file goes up through [FilesClient.upload], the path
/// terminal drag-drop already uses.
///
/// [onThisMachine] is the caller's to give — the capabilities'
/// `readsServerDisk` — not a guess made here. [environmentId] is where a
/// server pick is browsed: the project's own, for a WSL or SSH one.
PickServer pickServerOf(
  FilesClient files, {
  required String name,
  required bool onThisMachine,
  String environmentId = localHostEnvironmentId,
}) => PickServer(
  name: name,
  onThisMachine: onThisMachine,
  environmentId: environmentId,
  maxUploadBytes: kMaxUploadBytes,
  describeError: describeFailure,
  upload: (fileName, size, content, {directory}) => files.upload(
    fileName,
    size,
    content,
    // The server places an upload in the environment it names, so it must be
    // the folder's own.
    environmentId: directory?.environmentId ?? localHostEnvironmentId,
    directory: directory,
  ),
);

/// How the server this window uses is named on screen: the paired machine's
/// name, or "This computer" for the server run here.
String serverDisplayName(CompanionPairing? machine) {
  if (machine == null) return 'This computer';
  final name = machine.displayName.trim();
  return name.isEmpty ? 'The server' : name;
}

/// The server this window uses, as a picker for [environmentId] wants it.
final pickServerProvider = Provider.family<PickServer, String>(
  (ref, environmentId) => pickServerOf(
    ref.watch(filesClientProvider),
    name: serverDisplayName(ref.watch(machineInUseProvider)),
    onThisMachine: ref.watch(capabilitiesProvider).readsServerDisk,
    environmentId: environmentId,
  ),
);

/// A file **the server** will use — an SSH key, an agent, a Flutter SDK — so
/// picked from the server's files only, in [environmentId] (owner, answer 3).
/// On the server's own machine this is today's picker, untouched, and the path
/// is this machine's.
Future<EnvironmentPath?> pickServerFile(
  BuildContext context,
  WidgetRef ref, {
  required String what,
  String environmentId = localHostEnvironmentId,
  String? startNear,
  List<XTypeGroup> acceptedTypeGroups = const [],
}) async {
  final server = ref.read(pickServerProvider(environmentId));
  if (server.onThisMachine) {
    final file = await pickOneFile(
      context: context,
      what: what,
      startNear: startNear,
      acceptedTypeGroups: acceptedTypeGroups,
    );
    return file == null
        ? null
        : EnvironmentPath(
            environmentId: localHostEnvironmentId,
            path: file.path,
          );
  }
  final pick = await pickFileFrom(
    context,
    what: what,
    sources: FileSources.server,
    server: server,
    startNear: startNear,
    acceptedTypeGroups: acceptedTypeGroups,
  );
  return switch (pick) {
    ServerPick(:final path) => path,
    _ => null,
  };
}
