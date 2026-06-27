# Build LAN first with a relay-ready protocol

The first MVP uses local network connectivity between the iPhone and Mac agent, but the protocol keeps device identity, encryption, and per-action authorization explicit so a cloud relay can be added later. This validates the core workflow quickly without baking local-only trust assumptions into the system.
