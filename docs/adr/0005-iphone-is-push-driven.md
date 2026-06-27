# iPhone is push-driven

The iPhone app is push-driven by default instead of maintaining a long-running connection to the Mac or relay. The Mac agent emits attention events through APNs and the iPhone opens short-lived connections while foregrounded, which preserves battery life while the Mac remains responsible for continuous session monitoring.
