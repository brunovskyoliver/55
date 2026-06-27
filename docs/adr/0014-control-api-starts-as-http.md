# Control API starts as HTTP

The MVP Control API uses authenticated HTTP request/response with foreground polling rather than WebSockets. This is simpler to secure, test, debug, and adapt to a future relay while avoiding premature optimization for live raw transcript streaming.
