# Mosh adapter

The Mosh data plane is [TraversioMosh](../../../docs/THIRD_PARTY.md) 1.0.0,
exposed to the app through `TerminalTransport`. Citadel performs SSH
authentication and starts the remote `mosh-server`; `TraversioMoshAdapter`
parses the `MOSH CONNECT` line with `TraversioMoshBootstrap` and mounts a
`TraversioMoshCore.MoshSession` for the UDP session.

`MoshPTYChannel` bridges Traversio's renderer-ready surface to SwiftTerm:
after each render operation it paints a complete replacement frame rendered
from `screenSnapshot`, so a roam, a re-based diff, or a dropped render
operation cannot accumulate duplicated glyphs. Path changes need no app-level
rebind — Traversio rebuilds the UDP link under the same `MoshSession`.

`mosh-server` bootstrap errors are classified by
`TransportSelectionCoordinator`; a bounded first-contact wait in the adapter
lets Auto mode keep the SSH bootstrap when the UDP path is blocked.

Blink's `libmoshios` remains a fallback if the pure Swift implementation does
not pass interoperability and roaming tests. See `docs/THIRD_PARTY.md` before
adding or linking GPL-licensed source code.
