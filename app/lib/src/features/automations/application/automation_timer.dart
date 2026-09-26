import 'package:karmashala_automations/scheduler.dart';
import 'package:riverpod/riverpod.dart';

export 'package:karmashala_automations/scheduler.dart'
    show AutomationTimer, ManualAutomationTimer, WallClockAutomationTimer;

final automationTimerProvider = Provider<AutomationTimer>((ref) {
  final timer = WallClockAutomationTimer();
  ref.onDispose(timer.cancel);
  return timer;
});
