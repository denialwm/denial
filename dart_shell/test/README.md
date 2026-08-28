# Flutter test policy

The Flutter suite is deliberately small. It protects failures that can break a
session, cross a privilege or process boundary, corrupt durable state, or make
the compositor and shell disagree about authoritative state.

Keep a test only when it covers at least one of these contracts:

- authentication, lock state, or destructive session actions;
- native protocol framing, validation, versioning, or state authority;
- settings persistence, migration, conflict handling, or fail-safe parsing;
- output geometry and scale invariants;
- cursor archive safety, animation timing, surface arbitration, or native
  cursor authority.

Do not add tests for wording, destination order, credits, visual styling,
minimum-size presentation, ordinary control choreography, or implementation
details already covered by a stronger contract test. Review those concerns in
the running shell instead of encoding the current UI composition as policy.
