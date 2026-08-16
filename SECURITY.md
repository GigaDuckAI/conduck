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

One vocabulary note before the boundaries, because it moves them: Conduck uses
*gateway* to mean a machine the user runs an agent on, **not** a routing proxy
in front of model providers (LiteLLM, Portkey, Cloudflare AI Gateway). The
[glossary](README.md#the-words-this-project-uses) settles that word and the
rest, and it is worth two minutes before deciding whether something is ours.

In scope:

- **This repository** — the Conduck app for iPhone, iPad, Mac, Apple Watch, and
  CarPlay — and the App Store builds made from it
- The **conduck.com** website
- **conduck-connect** (the pairing and setup tool) — it lives in its own
  repository, but reports for it are welcome at the same address

Out of scope (not operated by us — report to the respective project or vendor):

- The AI you point Conduck at — a gateway you run (OpenClaw, Hermes), any
  custom OpenAI-compatible endpoint you configure, and whatever machine or
  service stands behind it
- Hosted AI and speech providers you bring your own key for (such as OpenRouter)
- Apple and Google platform infrastructure

A flaw in **how Conduck integrates** with any of those services is very much in
scope — when in doubt, send it in and it will be routed.

## A note on setup codes

A Conduck setup code (`conduck-setup:v1:…`) is a **bearer credential**. It carries
the key for the AI it names and, when file transfer is configured, the file
server's password — so anyone holding the code gets every capability those
grant, until you rotate them.

Because the entire payload is chosen by whoever produced the code, nothing inside
it can prove where it came from. Conduck therefore treats importing one as a
consent step rather than a verification: before anything is contacted or stored,
the app shows the exact destination it is about to save and what accepting
grants, and it settles the certificate question against the live server. The
payload carries no certificate field at all, and one hand-crafted into a code is
ignored. Reports about that boundary are very much in scope — a fact the review
screen states wrongly, a way to reach the network or storage before the user
consents, or anything inside a code that changes the certificate outcome.

That settlement can only go one way. Conduck runs under App Transport Security —
Apple's platform rule for app network traffic — with no exemptions, so a
certificate the device does not trust is refused outright, and no surface in the
app offers to trust a server anyway. The optional certificate fingerprint a user
can pin only narrows a chain the system has already accepted; it can never admit
one.

## Safe harbor

Security research conducted in good faith and in line with the policy at
<https://conduck.com/security> is considered **authorized**: no legal action or
law-enforcement complaints will be initiated against you for your research or
your report. The full safe-harbor terms, including what it can and cannot cover,
are on that page.
