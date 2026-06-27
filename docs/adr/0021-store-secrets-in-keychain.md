# Store secrets in Keychain

Secret material is stored in Keychain rather than the Session Store. SQLite may reference key identifiers or device identifiers, but pairing keys, local API credentials, and encryption keys stay outside the inspectable session database.
