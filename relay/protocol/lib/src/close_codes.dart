/// Close codes the relay hangs a WebSocket up with. WebSocket only lets an
/// application send 1000 or 3000-4999, so every refusal is in the 4000s and
/// mirrors its HTTP cousin.
library;

/// The other end left.
const int kClosePeerLeft = 1000;

/// The other end's socket failed.
const int kClosePeerFailed = 4001;

/// Nobody arrived at the rendezvous in time — "nobody else was ever there",
/// a different thing to tell a user than "the network failed".
const int kCloseNoPeer = 4408;

/// The rendezvous already holds two sockets.
const int kCloseBusy = 4409;

/// A frame above the relay's size cap.
const int kCloseFrameTooLarge = 4413;

/// A lone socket sent more frames than the relay holds before pairing.
const int kCloseImpatient = 4429;
