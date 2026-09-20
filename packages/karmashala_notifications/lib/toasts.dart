/// What is handed to the operating system, and who hands it over: the event
/// waiting to be delivered, the title, body and payload it becomes, and the
/// presenter port — whose default is silence, so a platform we do not deliver
/// on degrades rather than throws.
library;

export 'src/notification_presenter.dart';
export 'src/notification_request.dart';
