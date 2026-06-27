# Include guarded stop in MVP

The MVP includes a guarded stop action for Wrapped Sessions. Stopping requires confirmation, records an audit event, and attempts a graceful interrupt before escalating to termination so the Owner Device can halt runaway or mistaken work while away from the Mac.
