import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show kMaxUploadBytes;
import 'package:karmashala_ui/picking.dart';

import '../../../core/util/failure_words.dart';
import 'files_client.dart';

/// The server [files] reaches, as the two-source picker (spec decision 11)
/// wants it: a device file goes up through [FilesClient.upload], the path
/// terminal drag-drop already uses.
///
/// [onThisMachine] is the caller's to give — the capabilities' `sameMachine`
/// once they exist (plan step 12), not a guess made here.
PickServer pickServerOf(
  FilesClient files, {
  required String name,
  required bool onThisMachine,
}) => PickServer(
  name: name,
  onThisMachine: onThisMachine,
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
