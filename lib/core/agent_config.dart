class AgentConfig {
  // Default LAN address of the agent. Goes through the nginx reverse proxy
  // that ships with docker-compose, which is the only thing exposed on the
  // host (port 80). If you're running the agent directly (`task run` with no
  // compose), switch this to `:8080` in Settings — the Go server listens
  // there and nginx is out of the picture.
  //
  // Overridden at runtime via the settings screen — no persistence in v1, so
  // edits live only for the session.
  static const String defaultBaseUrl = 'http://192.168.1.202';
}
