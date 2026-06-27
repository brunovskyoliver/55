# Use SQLite for the session store

The Mac Agent stores the Session Event Log and queryable session metadata in SQLite. SQLite supports durable append-heavy writes, indexed queries, retention, and migrations without coupling the event log to Core Data or spreading session history across plain files.
