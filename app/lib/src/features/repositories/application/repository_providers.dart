/// What a project with no checkout row is told. Only a project recorded before
/// a plain folder was enough can be in this state: a rescan writes its own
/// folder as somewhere to run, clone or not.
const String kNowhereToRunIn =
    'This project has nowhere recorded to run in yet. Rescan it — a folder is '
    'enough, it does not have to be a Git repository.';
