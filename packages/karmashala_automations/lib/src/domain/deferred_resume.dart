import 'missed_fires.dart';
import 'scheduled_resume.dart';

/// What a resume due while the app was closed says while it waits for it.
/// Resuming a conversation needs the app's launcher, status reading and usage
/// check, so the session host holds it rather than guessing.
const String kResumeWaitingForApp =
    'Waiting for the Karmashala app: resuming a conversation needs the app\'s '
    'launcher and its reading of the session, and the app is not running. It '
    'goes ahead when the app opens, if that is still in time.';

/// Why a resume that waited for the app is now too late to go ahead, or null
/// when it may: the same catch-up grace as a missed fire, unless its owner
/// said to resume however late.
String? lateForDeferredResume(ScheduledResume resume, DateTime now) {
  if (resume.latePolicy == ResumeLatePolicy.resume) return null;
  final late = now.difference(resume.fireAt);
  if (late <= kMissedFireGrace) return null;
  final minutes = late.inMinutes;
  final ago = minutes < 60
      ? '$minutes minute${minutes == 1 ? '' : 's'}'
      : '${late.inHours} hour${late.inHours == 1 ? '' : 's'}';
  return 'The Karmashala app was not running when this was due, $ago ago, and '
      'resuming a conversation needs it. Only a resume within '
      '${kMissedFireGrace.inMinutes} minutes goes ahead unasked — resume it '
      'now if you still want it.';
}
