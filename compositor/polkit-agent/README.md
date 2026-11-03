# Denial Polkit agent

A dedicated unprivileged Rust process registers an authentication agent for the
current logind/elogind session. It opens a separate native Wayland/Flutter dialog
only when Polkit requests authentication. The dialog lives in `polkit_app`;
its presentation can change without moving authentication into the compositor
or a shell plugin. The same bundle draws `denial-portal`'s Access requests when
started with `DENIAL_ACCESS_SOCKET` instead of `DENIAL_POLKIT_SOCKET`.

The dialog is a centered, undecorated layer-shell overlay (`--overlay`) with
exclusive keyboard focus, not a window. It paints its card inside a
transparent canvas, in the user's live Denial appearance read through the
control socket. The reference shell frosts the desktop beneath `dev.denial.*`
overlays wherever their alpha exceeds the configured backdrop-blur opacity
threshold, so the card is glass while its shadow stays below that threshold.
The reply field and actions use the floating toolbar material of application
search fields and actions, which blurs the card's accent aurora at the user's
app panel opacity. Appearance
is presentation only: without the control socket the dialog uses the defaults.

Build from the repository root, outside the sandbox:

```sh
tools/denial-pc polkit-agent
```

Native dependencies include Polkit's agent development library and GLib/GObject.
The dialog uses `native_app`, EGL, GLES and Wayland; it does not use GTK.

For manual testing, run the agent from a terminal in a Denial session:

```sh
tools/denial-pc polkit-agent-run
```

It remains invisible until a program asks Polkit for interactive authorization.
The user owns visual validation and authentication triggers. Building and the
headless ABI checks do not register an agent or launch a window.

## Running alongside another agent

The agent is on by default. If PolicyKit already has an agent registered for
the session, it logs a warning and exits successfully, leaving the other agent
in charge; the service does not restart it. A user whose own agent starts a few
seconds after Denial would lose that race, so the agent can be disabled:

- `deniald --no-polkit-agent` publishes `DENIAL_POLKIT_AGENT=0` to the session
  environment and skips the non-systemd fallback launch. The agent service then
  exits at once.
- `DENIAL_POLKIT_AGENT=0` in `/etc/denial/session.conf` makes `denial-session`
  pass that flag; `denial-polkit-agent` also honors the variable directly.
- On NixOS, set `programs.denial.polkitAgent.enable = false`.

## Authentication and lifecycle

- Only the unique system-bus owner of the Polkit authority can initiate or cancel
  requests. The authority owner is pinned for each registration.
- Registration uses the current Unix session. User-manager services outside
  session cgroups resolve the compositor's session through Wayland socket peer
  credentials. Another agent already registered for the session takes precedence;
  Denial exits successfully instead of displacing it.
- `PolkitAgentSession` owns the authentication conversation and invokes Polkit's
  existing privileged helper. Rust does not implement PAM or report a successful
  authentication itself. UI replies cannot grant authorization.
- Requests are serialized, with up to eight queued requests, three failed
  attempts per request, and a five-minute active-dialog timeout. Identities are
  selected from Polkit's supplied Unix users. Stale dialog/prompt replies are
  ignored. Cancellation also works if it arrives before the begin task.
- Locking or deactivating the session cancels active and queued requests. The
  backend watches logind properties at 250 ms intervals. A disconnected UI,
  closed window or expired deadline cancels the request.
- Polkit disconnection cancels requests before re-registration. Registration is
  retried a bounded number of times; the systemd unit restarts a failed backend.
- Passwords travel through a private socket, never argv, environment, persistent
  files or application logs. Owned Rust response buffers are cleared after use.
  Dart and library-managed temporary allocations are not guaranteed to be erased.

The default systemd session target starts `denial-polkit-agent.service`.
Non-systemd Denial sessions launch the backend through the compositor's existing
startup launcher. Installation/builds do not start it in the current session.

To use an external agent, mask `denial-polkit-agent.service` in your user manager
and start the replacement. On non-systemd sessions, set `DENIAL_POLKIT_AGENT=0`
before launching Denial. NixOS exposes `programs.denial.polkitAgent.enable` and
`programs.denial.polkitAgent.command`. Agents registered later cannot replace an
existing session registration automatically.

## Dialog IPC contract, schema 1

The backend starts the native runner with `DENIAL_POLKIT_SOCKET` and a random
`DENIAL_POLKIT_TOKEN`. The socket lives inside a random directory with mode 0700;
the socket itself has mode 0600. All messages are UTF-8 JSON followed by a newline.
Incoming messages are bounded to 16 KiB. The UI must connect and send its handshake
within 30 seconds. The cookie never crosses into the UI.

| Direction | Type | Fields |
| --- | --- | --- |
| UI → backend | `hello` | `token` |
| Backend → UI | `request` | `schema`, `action`, `message`, `icon`, `identities: [{uid, name}]` |
| UI → backend | `select` | `uid` from the supplied identities; select once before authentication |
| Backend → UI | `prompt` | `prompt` (monotonic ID), `text`, `echo` |
| UI → backend | `response` | matching `prompt`, `text` |
| Backend → UI | `info` / `error` | `text` |
| UI → backend | `cancel` | no other fields |

Set `echo: false` inputs to password mode. Disable correction, suggestions and
clipboard actions; clear the text field after each submission. A fresh prompt
may follow a retry or another PAM conversation step. The backend closes the
dialog process on completion/cancellation; socket EOF also ends the UI.

This process boundary provides fault isolation, not a sandbox against other
programs running as the same user. Denial plugins retain their documented trust
model.
