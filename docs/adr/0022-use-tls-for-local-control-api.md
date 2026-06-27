# Use TLS for local control API

The Local Connection uses TLS for the Control API, with authentication tied to the paired Mac Agent and Owner Device identities. The system must not rely on plaintext or unauthenticated LAN HTTP, because the relay-ready protocol and structured action model require authenticated requests and responses from the start.
