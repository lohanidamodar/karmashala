import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';

import '../../environments/application/environments_controller.dart';
import 'automation_providers.dart';

/// Where an automation runs, in words: its checkout's name or its folder,
/// and the machine either is on.
typedef AutomationPlace = ({String place, String machine});

/// [automation]'s place, read from the workspace as it is now.
AutomationPlace automationPlaceOf(WidgetRef ref, Automation automation) {
  final folder = automation.folder;
  final repository = ref
      .read(automationCheckoutsProvider)
      .where((r) => r.id == automation.repositoryId)
      .firstOrNull;
  final environmentId = folder?.environmentId ?? repository?.path.environmentId;
  return (
    place: folder?.path ?? repository?.name ?? 'its checkout',
    machine: environmentId == null
        ? 'its machine'
        : ref.read(environmentLabelForIdProvider(environmentId)),
  );
}
