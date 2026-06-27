# Pair Owner Device over a Paired TLS Channel

GitHub: https://github.com/brunovskyoliver/55/issues/3

## Parent

#1

## What to build

Add secure first-device pairing for the Owner Device. The Mac Agent should display a short-lived QR Pairing Invitation, the iPhone should scan it, Secret Material should be stored in Keychain, and future Control API requests should use the paired identity over a Paired TLS Channel. Unpaired devices must not be able to read state or submit Structured Actions.

## Acceptance criteria

- [ ] The Mac Agent can generate and display a short-lived Pairing Invitation.
- [ ] The iPhone can scan the invitation and complete pairing as the Owner Device.
- [ ] Pairing keys and related Secret Material are stored in Keychain, not in the Session Store.
- [ ] The Control API uses TLS and rejects unpaired or invalid device identities.
- [ ] Tests cover successful pairing, expired invitation, unpaired request rejection, and paired request acceptance.

## Blocked by

- #2
