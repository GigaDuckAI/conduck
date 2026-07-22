# Security Policy

The canonical vulnerability disclosure policy — including the full scope rules and
safe-harbor terms — is published at **<https://conduck.com/security>**. A
machine-readable summary lives at
[`/.well-known/security.txt`](https://conduck.com/.well-known/security.txt).
This file is the short version for people arriving via GitHub.

## Reporting a vulnerability

Email **security@gigaduck.ai**.

**Please do not open a public GitHub issue for security vulnerabilities** — a
public issue discloses the problem before a fix exists. Use email.

A helpful report includes:

- A description of the issue and where it lives (which app, platform, and
  version — or which page of the website)
- Steps to reproduce — a proof of concept, screenshots, or a screen recording
  all work
- Your assessment of the impact
- How you'd like to be credited, if at all

There is currently no published PGP key. If your report contains details you're
not comfortable sending in plain email, say so in a first email without the
sensitive parts and a secure channel will be arranged. If you prefer to stay
anonymous, you can report indirectly through CERT-EE, Estonia's national CSIRT
(cert@cert.ee), and ask them to pass it on without your identity.

## What to expect

- **Acknowledgment within 3 business days** of your report.
- **An initial assessment within 10 business days**, with updates as the fix
  progresses.
- Confirmed vulnerabilities are addressed without delay. For critical issues,
  90 days is the outer bound, not the plan — most fixes ship much faster.
- Coordinated disclosure: please hold public disclosure until a fix has shipped
  or 90 days have passed since your report, whichever comes first.
- Once a fix is available, an advisory is published; with your permission you
  are credited for the discovery. There is no monetary bug bounty at this time.

## Scope

In scope:

- **This repository** — the Conduck app for iPhone, iPad, Mac, Apple Watch, and
  CarPlay — and the App Store builds made from it
- The **conduck.com** website
- **conduck-connect** (the pairing and setup tool) — it lives in its own
  repository, but reports for it are welcome at the same address

Out of scope (not operated by us — report to the respective project or vendor):

- Your own AI gateway or server (OpenClaw, Hermes, a custom endpoint) and any
  machine you run it on
- Hosted AI and speech providers you bring your own key for (such as OpenRouter)
- Apple and Google platform infrastructure

A flaw in **how Conduck integrates** with any of those services is very much in
scope — when in doubt, send it in and it will be routed.

## Safe harbor

Security research conducted in good faith and in line with the policy at
<https://conduck.com/security> is considered **authorized**: no legal action or
law-enforcement complaints will be initiated against you for your research or
your report. The full safe-harbor terms, including what it can and cannot cover,
are on that page.
