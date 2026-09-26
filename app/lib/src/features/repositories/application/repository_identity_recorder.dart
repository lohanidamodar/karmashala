import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import '../../workspaces/data/workspace_data.dart';

/// Records what [origin] says the checkout at [path] is on the rows naming
/// that directory. Folded onto a reading already paid for; a null is written
/// too. Sent only when the copy says some row would change.
void recordRepositoryIdentity(
  WorkspaceData workspace,
  EnvironmentPath path,
  RepositoryOrigin origin,
) {
  final identity = canonicalRepositoryId(origin.url);
  final stale = workspace
      .repositoriesAt(path)
      .any((row) => row.canonicalId != identity);
  if (!stale) return;
  unawaited(
    workspace
        .write(CheckoutsIdentify(path: path, canonicalId: identity))
        .then<void>((_) {}, onError: (Object _) {}),
  );
}
