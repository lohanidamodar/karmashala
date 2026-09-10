import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import '../data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';

/// Writes what [origin] says the checkout at [path] is onto the rows naming
/// that directory. Folded onto a reading already paid for; a null is written too.
void recordRepositoryIdentity(
  RepositoryDao dao,
  EnvironmentPath path,
  RepositoryOrigin origin,
) {
  final identity = canonicalRepositoryId(origin.url);
  for (final row in dao.getByLocation(path)) {
    if (row.canonicalId == identity) continue;
    dao.updateCanonicalId(row.id, identity);
  }
}
