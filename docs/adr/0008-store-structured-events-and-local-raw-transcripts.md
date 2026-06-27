# Store structured events and local raw transcripts

The Mac agent stores structured session events for the app UI and audit trail, while also retaining raw transcript chunks locally for search, debugging, and replay. The iPhone requests transcript slices on demand instead of syncing full raw output, which limits battery, bandwidth, and unnecessary exposure of sensitive session details.
