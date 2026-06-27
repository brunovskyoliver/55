# Store raw transcripts as files

Raw transcript chunks are stored as append-only local files on the Mac and referenced by SQLite metadata in the Session Store. This keeps the query database focused on structured events and indexes while allowing large transcript data to be retained, pruned, and sliced efficiently.
