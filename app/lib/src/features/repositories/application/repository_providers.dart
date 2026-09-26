import 'package:riverpod/riverpod.dart';

import 'package:karmashala_git/repositories.dart';
import '../../projects/application/wsl_path_existence.dart';
import '../../workspaces/data/workspace_data.dart';
import 'checkout_retirement_service.dart';
import 'host_checkout_presence_probe.dart';

/// What a project with no checkout row is told. Only a project recorded before
/// a plain folder was enough can be in this state: a rescan writes its own
/// folder as somewhere to run, clone or not.
const String kNowhereToRunIn =
    'This project has nowhere recorded to run in yet. Rescan it — a folder is '
    'enough, it does not have to be a Git repository.';

/// Whether a recorded checkout's directory is still on disk. Overridden in
/// tests with a stub, so a case like "the distro is stopped" can be stated
/// rather than staged.
final checkoutPresenceProbeProvider = Provider<CheckoutPresenceProbe>(
  (ref) => HostCheckoutPresenceProbe(wsl: ref.watch(wslPathExistenceProvider)),
);

/// Retires checkouts whose directories are provably gone — the rescan's other
/// half, since a rediscovery only ever adds.
final checkoutRetirementServiceProvider = Provider<CheckoutRetirementService>(
  (ref) => CheckoutRetirementService(
    workspace: ref.watch(workspaceDataProvider),
    probe: ref.watch(checkoutPresenceProbeProvider),
  ),
);
