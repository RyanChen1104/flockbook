# Security policy

## Report a vulnerability

Do not open a public issue for a security problem.

Report it privately with GitHub's private vulnerability reporting: go to the [Security tab](https://github.com/minchenlee/flockbook/security) and click **Report a vulnerability** ([direct link](https://github.com/minchenlee/flockbook/security/advisories/new)).

Tell us:

- The Flockbook version and the macOS version.
- What an attacker can do, and what they need first (for example: on the same network, or paired with the Mac).
- The steps to reproduce it.

We reply as soon as we can. We fix the problem in a new release, and we credit you in the release notes if you want.

## Scope

These parts handle data from outside the Mac or from other programs. They are the most important to report:

- **Remote access:** the built-in server that the phone page connects to, over Tailscale or the local network, and its TLS.
- **Pairing:** how a phone gets access to the Mac, and how access is removed.
- **Push notifications:** the subscriptions and the messages sent through the phone's push service.
- **Hooks:** the optional Claude Code hook for question cards (Flockbook adds it only when you turn it on in Settings), and the data it saves.

Flockbook also reads local agent session logs and talks to Herdr through its local socket. Problems in Herdr itself go to the Herdr project, not here.

## Supported versions

Only the latest release gets security fixes. Update to the latest release before you report a problem.
