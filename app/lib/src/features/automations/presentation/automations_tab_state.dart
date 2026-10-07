import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Automations tab's three lists.
enum AutomationsSection {
  automations('Automations'),
  runs('Runs'),
  resumes('Resumes');

  const AutomationsSection(this.label);

  final String label;
}

/// Which list the Automations tab shows; kept outside it so a link can open
/// the tab on the one it means.
class AutomationsSectionNotifier extends Notifier<AutomationsSection> {
  @override
  AutomationsSection build() => AutomationsSection.automations;

  void show(AutomationsSection section) => state = section;
}

final automationsSectionProvider =
    NotifierProvider<AutomationsSectionNotifier, AutomationsSection>(
      AutomationsSectionNotifier.new,
    );
