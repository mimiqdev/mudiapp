# Mosh adapter

The first implementation target is `swift-mosh`, exposed to the app through
`TerminalTransport`. Citadel performs SSH authentication and starts the remote
`mosh-server`; `MoshCore` owns the UDP session after bootstrap.

Blink's `libmoshios` remains a fallback if the pure Swift implementation does
not pass interoperability and roaming tests. See `docs/THIRD_PARTY.md` before
adding or linking GPL-licensed source code.
