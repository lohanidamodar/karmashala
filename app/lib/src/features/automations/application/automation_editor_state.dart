import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';

import 'automation_draft.dart';
import 'automation_providers.dart';

/// The automation open in the Automations tab's editor, or null for the list.
/// [generation] tells a reopened draft from the one already on screen.
class AutomationEditing {
  const AutomationEditing(this.draft, this.generation);

  final AutomationDraft draft;
  final int generation;
}

class AutomationEditorNotifier extends Notifier<AutomationEditing?> {
  var _generation = 0;

  @override
  AutomationEditing? build() => null;

  void open(AutomationDraft draft) =>
      state = AutomationEditing(draft, ++_generation);

  /// Opens [automation], its check step given its checkout's project checks
  /// when it names no command of its own — what it ran before it carried one.
  void edit(Automation automation) {
    final carried = carryProjectChecks(
      automation.steps,
      ref.read(projectChecksProvider(automation.repositoryId)),
    );
    open(
      AutomationDraft.from(
        carried == null ? automation : automation.copyWith(steps: carried),
      ),
    );
  }

  void close() => state = null;
}

final automationEditorProvider =
    NotifierProvider<AutomationEditorNotifier, AutomationEditing?>(
      AutomationEditorNotifier.new,
    );
