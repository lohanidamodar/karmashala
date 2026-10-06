/// The relays PopupBits runs, and which of them a pairing should live on.
/// **The one place** that says which relay is the old default: everything
/// else asks [KnownRelays] rather than comparing against a literal.
library;

/// The relay official builds name in `KARMASHALA_RELAY_URL`. Pinned to every
/// build script and release workflow by test.
const String kPopupBitsRelayUrl = 'wss://kmrelay.popupbits.com';

/// Relays PopupBits ran before [kPopupBitsRelayUrl], still up for the phones
/// paired through them. A pairing on one of these is moved; nothing else is.
const List<String> kRetiredPopupBitsRelayUrls = ['wss://relay.popupbits.com'];
