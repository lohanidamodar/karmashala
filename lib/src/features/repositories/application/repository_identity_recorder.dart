import 'package:agent_cli/process.dart';
import '../../git/domain/repository_origin.dart';
import '../data/repository_dao.dart';
import '../domain/repository_identity.dart';

/// Writes what [origin] says the checkout at [path] *is* onto the rows that
/// name that directory.
///
/// **Folded onto a reading the app already pays for, never a sweep of its
/// own.** `repositoryOriginProvider` is the one place a repository's `origin`
/// is learned — once per repository however many worktrees it has — and it is
/// already on the probe queue and already `autoDispose`. Recording the identity
/// there costs one small indexed read of a table with tens of rows in it, and a
/// write only when the answer actually moved. There is no timer, no rescan hook
/// and no new process: a workspace whose identities are already right does one
/// read and stops (§19's third rule, applied to a column instead of a probe).
///
/// **A null is written as readily as a value.** A remote that was removed, or
/// repointed at a local path, leaves the old identity wrong rather than merely
/// stale, and a key nobody can trust is worse than no key. The clock this runs
/// on is the user looking at the checkout, which is exactly when a wrong answer
/// would be read.
///
/// Plural rows on purpose: two rows recorded from two spellings of one
/// directory are one working tree, and both are that repository.
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
