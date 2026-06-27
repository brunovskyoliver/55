# MVP Mac component is a menu bar app

The MVP ships as a macOS menu bar app with an embedded background agent rather than a headless daemon plus separate UI. This simplifies installation, pairing, inspection, quitting, and notarization during early development while keeping the core agent service separable enough to become a LaunchAgent later.
