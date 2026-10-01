import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import '../data/flutter_data.dart';

/// A project's run configurations as the server keeps them. Asked for when a
/// surface shows them and invalidated after an edit here; an agent's edit
/// shows on the next look.
final flutterRunConfigsProvider = FutureProvider.autoDispose
    .family<List<FlutterRunConfiguration>, String>(
      (ref, projectId) => ref.watch(flutterDataProvider).runConfigs(projectId),
    );
