# Security model

ClipMesh encrypts clipboard events with a shared random 32-byte group key and AES-256-GCM, with a fresh nonce and group-bound associated data. QUIC endpoint identity and group-authenticated handshakes protect mesh membership. Server TLS certificate verification remains enabled.

## Secrets and membership

An invitation or QR contains the group key. Anyone who obtains it can read and inject that group's clipboard data. Share it privately, and do not include it in screenshots, issues or logs. To remove a compromised member, create a new group and re-pair the remaining devices. There is no per-device key revocation or application-level forward secrecy.

One active group is a shared latest-value register. Joining or reconnecting may replace the local clipboard with the winning remote value. Password-manager clipboard concealment flags are respected by the Mac client, but users should not assume every platform/app marks sensitive clips. Disable synchronization before copying data you do not want shared with group members.

## Discovery and relay privacy

The default mesh uses public iroh N0 discovery/relay services. Public endpoint IDs, network addresses, timing and sizes may be visible to infrastructure operators. The group key and clipboard plaintext are not published to the lookup service. Direct paths are preferred, and encrypted relay paths are used as needed. Internet access and availability of this infrastructure are still required; operating without a Mac is not the same as operating without infrastructure.

## Local data

The desktop config contains group keys and uses owner-only Unix permissions or the Windows profile ACL. Mobile stores follow platform-specific protections; runtime transport configs are private to their device/app. Android keeps protocol state encrypted with its Keystore and bounded plaintext PNG cache files privately for content-URI pasting. The rootless iPhone uses private preference/state files. A rooted/jailbroken attacker or a compromised OS account can defeat these local protections.

The iOS package includes a narrowly entitled clipboard helper restricted to SpringBoard as its caller. It has background/unchecked pasteboard access for synchronization, and the network transport is separately signed without those pasteboard privileges. Android's system hook observes ClipboardService and uses a restricted Binder bridge; it is intended for the physical user's clipboard, not arbitrary work profiles.

## Release properties

Mac packages are ad-hoc signed and not notarized, Windows setup is unsigned, and the current Android APK uses a development certificate. These are disclosed distribution properties, not an assertion of OS vendor review. The current repository does not claim a completed external security audit.

Do not report group keys, clipboard content or device identifiers in public issues. For sensitive reports, use the repository's private vulnerability-reporting feature if enabled; otherwise open a minimal issue requesting a private contact without disclosing the vulnerability or secrets.
