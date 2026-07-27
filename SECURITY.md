# Security policy

Denial is a compositor and therefore sits on security-sensitive boundaries:
it handles input, application surfaces, clipboard data, screen capture,
session state, and signed software distribution.

## Supported versions

| Version | Security support |
| --- | --- |
| Latest tagged release | Supported |
| `main` | Fixes are developed here, but it is not a released package |
| Older tagged releases | Not supported |

During the public alpha, users should update to the latest tagged release to
receive security fixes.

## Reporting a vulnerability

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/denialwm/denial/security/advisories/new).
Do not publish vulnerability details in an issue, discussion, pull request, or
other public channel before a fix and disclosure are coordinated.

Please include as much of the following as possible:

- the affected Denial version, commit, and installation method;
- the operating system, kernel, GPU, driver, and relevant hardware;
- a description of the security impact and the boundary that was crossed;
- minimal steps or a proof of concept that reproduces the behavior;
- logs, traces, or screenshots with unrelated private information removed;
- whether the issue is known to be actively exploited; and
- any disclosure deadline or prior disclosure that the maintainer should know
  about.

Do not include credentials, signing material, personal data, or unrelated
secrets.

## What to report

Security reports may include:

- lock-screen, authentication, or session-boundary bypasses;
- unintended input observation or injection;
- unauthorized access to application surfaces, clipboard contents, screen
  capture, or other session data;
- memory-safety problems with a security impact;
- ways for an untrusted Wayland or Xwayland client to gain capabilities beyond
  the intended protocol boundary;
- arbitrary code execution or privilege escalation caused by Denial;
- package, update, repository, signing, or release-integrity failures; and
- denial-of-service behavior that can be triggered intentionally across a
  security boundary.

Ordinary crashes, visual defects, compatibility problems, and performance
regressions without a security impact should be reported through the normal
issue tracker.

## Security boundaries

- User-provided Flutter shell bundles are trusted local code. They are not
  currently sandboxed from the compositor or the user's session.
- Live UI development exposes an authenticated Dart VM service only on
  loopback and stores its discovery URI in a user-private runtime file. The
  packaged editor profile is non-pausing, but another process already running
  as the same user remains inside the trusted-user boundary and may use the VM
  service directly.
- A system already controlled by an administrator, root process, compromised
  kernel, or compromised user account is outside Denial's threat boundary.
- A vulnerability entirely within an upstream project, with no
  Denial-specific behavior or impact, should be reported to that upstream
  project. If it is exploitable through Denial, it may also be reported here
  so the project can coordinate mitigation and dependency updates.
- Unsupported hardware or configurations are not automatically security
  issues, but crossing a security boundary remains reportable regardless of
  support status.

## Response and disclosure

Doctor Logix will make a reasonable effort to:

1. acknowledge a complete private report within seven days;
2. reproduce and assess its impact;
3. coordinate a fix, release, and disclosure with the reporter; and
4. credit the reporter if they want public credit.

This is a volunteer-maintained project and the acknowledgement target is not a
contractual service-level guarantee. Complex fixes, upstream coordination, or
hardware-specific investigation may take longer.

Please allow a reasonable remediation period before disclosure. If the report
is accepted, coordination will continue through the private advisory until a
release is available or the parties agree that disclosure is appropriate.

## Safe research

Only test systems and data you own or are explicitly authorized to use. Avoid
privacy violations, data destruction, persistence, service disruption beyond
what is necessary to demonstrate the issue, and access to data unrelated to
the report.

Denial does not currently operate a bug bounty program and cannot promise
payment or other compensation for reports.
