import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/dashboard_glance.dart';
import '../../stores/presentation/stores_glance.dart';
import '../presentation/glances/running_glance.dart';
import '../presentation/glances/todos_glance.dart';
import '../presentation/glances/usage_glance.dart';

/// **Every glance the dashboard can show**, in their first order. A page
/// offering one adds its import and its entry here; this device's order,
/// hiding and folding are kept by id ([DashboardGlance.id]).
final dashboardGlancesProvider = Provider<List<DashboardGlance>>(
  (ref) => const [todosGlance, runningGlance, storesGlance, usageGlance],
);
