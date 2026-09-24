/// Starts [command] on a remote machine out of this SSH channel's process
/// group, its output appended to [log], so closing the channel neither kills
/// it nor waits on it. [command] and [log] are already quoted for `sh`.
///
/// `setsid` is util-linux's; macOS has none, but ships perl with POSIX, whose
/// `setsid` does the same once `sh` has put the job in the background — a
/// background job is not a group leader, which is all `setsid(2)` asks.
String detachedStart(String command, String log) =>
    'if command -v setsid >/dev/null 2>&1; then '
    'setsid nohup $command >> $log 2>&1 < /dev/null & '
    'else '
    "nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' "
    '$command >> $log 2>&1 < /dev/null & '
    'fi';

/// A shell test that is true when [detachedStart] has a way to detach here.
const String kCanDetachTest =
    '{ command -v setsid >/dev/null 2>&1 || command -v perl >/dev/null 2>&1; }';
