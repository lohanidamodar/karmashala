import 'package:riverpod/riverpod.dart';

import '../process/command_runner_providers.dart';
import 'installed_application.dart';
import 'installed_applications_service.dart';

final installedApplicationsServiceProvider =
    Provider<InstalledApplicationsService>(
      (ref) => InstalledApplicationsService(ref.watch(hostCommandRunnerProvider)),
    );

/// **What this desktop has installed**, read once and kept for the session.
///
/// Not `autoDispose`: the list costs a process and a directory walk, and it
/// moves only when somebody installs something. `ref.invalidate` is the
/// refresh, which is what the dialog's own button calls.
final installedApplicationsProvider = FutureProvider<List<InstalledApplication>>(
  (ref) => ref.watch(installedApplicationsServiceProvider).all(),
);
