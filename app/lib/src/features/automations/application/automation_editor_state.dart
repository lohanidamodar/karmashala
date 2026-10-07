import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';

import 'automation_draft.dart';

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

  void edit(Automation automation) => open(AutomationDraft.from(automation));

  void close() => state = null;
}

final automationEditorProvider =
    NotifierProvider<AutomationEditorNotifier, AutomationEditing?>(
      AutomationEditorNotifier.new,
    );
