# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's private vulnerability reporting instead: on this repository's **Security** tab, choose **Report a vulnerability**.

## Scope

MeetingCard runs locally and reads your calendar through the `gws` CLI. Issues of particular interest:

- Anything that makes the app log, store, or send event content (titles, descriptions, attendees) anywhere. Known: the local log records meeting links, including any Zoom passcode in the link; redaction is tracked as an issue.
- Anything that makes gws run with a stripped environment, or that could cause gws to lose or expose its credentials.
- Join links that could open something other than the meeting link actually present in the invite (for example a host-matching bypass in link detection).

Vulnerabilities in gws itself should go to the [gws project](https://github.com/googleworkspace/cli).

## Supported versions

Only the latest commit on `main` is supported.
