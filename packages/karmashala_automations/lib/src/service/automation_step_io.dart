import '../domain/automation.dart';
import '../domain/automation_run.dart';

/// How a command step ended. [exitCode] is null when it was stopped at its
/// timeout.
class StepCommandResult {
  const StepCommandResult({
    required this.exitCode,
    required this.output,
    this.timedOut = false,
  });

  final int? exitCode;
  final String output;
  final bool timedOut;
}

/// Runs a command step's shell command where [run] worked. Throws
/// [StateError] with the reason when it could not start.
abstract interface class StepCommandRunner {
  Future<StepCommandResult> run(
    Automation automation,
    AutomationRun run, {
    required String command,
    required Map<String, String> environment,
    required Duration timeout,
  });
}

/// What a webhook step's URL answered.
class StepWebhookResult {
  const StepWebhookResult({required this.status, required this.body});

  final int status;
  final String body;
}

/// POSTs a webhook step's body. Throws [StateError] with the reason when the
/// address is refused or nothing answered in time.
abstract interface class StepWebhookPoster {
  Future<StepWebhookResult> post(
    Uri url, {
    required String body,
    required String idempotencyKey,
    required bool allowPrivate,
    required Duration timeout,
  });
}

/// The longest output a later step is handed from a command or a webhook.
const int kStepOutputCap = 8 * 1024;

/// The end of [output], cut to [kStepOutputCap].
String capStepOutput(String output) => output.length <= kStepOutputCap
    ? output
    : '…${output.substring(output.length - kStepOutputCap)}';
