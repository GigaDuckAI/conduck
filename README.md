# Conduck

Conduck is a native Swift/SwiftUI chat and voice client for your own AI. It talks directly to a gateway you run yourself — or to hosted models under your own key — from iPhone, iPad, Mac, Apple Watch, and CarPlay. There is no backend, no account, and no telemetry: you bring your own keys, and nothing you say or send ever passes through our servers, because there are none.

[Get the official app](https://apps.apple.com/app/id6773045286) · [Build from source](#build-from-source) · [Architecture](docs/ai-context/spec.md) · [conduck.com](https://conduck.com) · [Join the Discord](https://conduck.com/discord/)

## How your data flows

```
your device → the voice provider you chose (optional) → the gateway or model provider you chose
```

That is the entire pipeline. Speech recognition and read-aloud default to Apple's on-device engines, conversation history lives on your device and syncs only through your own iCloud private database, and every network request goes to an endpoint you configured under a key you own. We are never in the path.

## What it works with

- **Self-hosted agent gateways** — OpenClaw and Hermes presets, plus any custom OpenAI-compatible endpoint. Guided setup via the companion [conduck-connect](https://github.com/gigaduckai/conduck-connect) pairing wizard; manual URL + token entry always works. Either way the gateway needs a certificate your devices already trust — see [Connecting to your gateway](#connecting-to-your-gateway).
- **Hosted models as an on-ramp** — OpenRouter, for multi-turn chat before you run a gateway. A hosted model endpoint is not your server: it covers chat, not agent tools or file exchange.
- **Voice both ways** — on-device Apple speech by default; optional cloud speech-to-text and text-to-speech providers, all BYO-key, including custom OpenAI-compatible speech endpoints.
- **Attachments and files** — images and text/code files in the conversation, and full file exchange with your agent (send arbitrary files, pull generated files back with previews) through your own WebDAV file server.
- **Every surface, natively** — action-button voice capture and a share-sheet extension on iPhone/iPad, a menu-bar + Dock app with global hotkeys and screenshot-and-ask on the Mac, quick voice capture on the Watch, hands-free multi-turn voice in CarPlay.

## Connecting to your gateway

Your gateway needs an `https://` address whose certificate your Apple devices already trust. A self-signed certificate — or one from a private certificate authority you run yourself — is refused, and Conduck cannot offer to ignore that: App Transport Security, the platform rule Apple applies to every app's network traffic, lets an app make certificate checks stricter, never looser. The fix is always on the server.

Three routes, all free, none needing a paid domain:

- **[Tailscale Serve](https://tailscale.com/kb/1312/serve)** — issues a trusted certificate automatically on your own private network, with nothing exposed publicly.
- **[Let's Encrypt](https://letsencrypt.org)** — free certificates, including for plain IP addresses, so no domain is required.
- **A domain in front of the gateway**, using [Caddy](https://caddyserver.com) or another reverse proxy that obtains and renews certificates for you.

Step-by-step instructions for each: [conduck.com/setup](https://conduck.com/setup/).

## Platforms

| Platform | Minimum OS |
|---|---|
| iOS / iPadOS | 26.5 |
| macOS | 26.5 |
| watchOS | 26.5 |
| CarPlay | via the iOS app (official build — see below) |

## Get it

Two builds share this codebase:

| | Official app | Conduck Community |
|---|---|---|
| Distribution | [App Store](https://apps.apple.com/app/id6773045286) | Build from source |
| Cost | Free for individuals; commercial use licensed separately | Source under Apache-2.0 |
| Branding | Conduck name and artwork | "Conduck Community", placeholder art |
| CarPlay | Included | Not included (restricted Apple entitlement) |

The official build is this public code plus private branding, signing, and Apple's per-team CarPlay entitlement — no functional code is withheld from this repository.

## Build from source

Requires Xcode 26.5 or later.

1. Clone this repository.
2. Open `Conduck/Conduck.xcodeproj`.
3. Build and run — no configuration needed. Simulator builds work as-is. Running on your own devices needs your development team plus your own identifiers (the community `com.example.*` app group, iCloud container, and push capabilities can't provision under an arbitrary team) — define them via a gitignored `Conduck/Configs/Identity-Override.xcconfig` as described in [CONTRIBUTING.md](CONTRIBUTING.md).

The result is **Conduck Community**: identical functionality (minus the CarPlay entitlement) under a neutral identity with placeholder art. The real Conduck brand artwork is not part of this repository and is not covered by the code license — see [TRADEMARKS.md](TRADEMARKS.md).

Before changing anything, read [the architecture document](docs/ai-context/spec.md) — it records the decisions and the deliberately rejected alternatives, which is the part the code cannot tell you.

## Documentation

Two short documents cover the whole project. Both are written for people and for
AI coding agents, and both are deliberately kept small — the code itself, through
per-file header comments and a large test suite, is the detailed documentation.

- [`docs/ai-context/spec.md`](docs/ai-context/spec.md) — the architecture: what
  the boundaries are, the decisions behind them, and the alternatives that were
  deliberately rejected. The things the code cannot tell you.
- [`docs/ai-context/project-structure.md`](docs/ai-context/project-structure.md)
  — a map of the folders and build targets, and where to start for a given kind
  of change.

## Community and contributing

- Chat, questions, and setup help: [Discord](https://conduck.com/discord/).
- Bugs and feature requests: GitHub issues.
- Contributions are welcome from day one under the Developer Certificate of Origin (`git commit -s`, no CLA) — see [CONTRIBUTING.md](CONTRIBUTING.md).
- Security vulnerabilities: please report privately as described in [SECURITY.md](SECURITY.md) — not via public issues.

## License and trademarks

The code is licensed under [Apache-2.0](LICENSE) (see also [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled third-party licenses). The Conduck™ name and the duck-character brand artwork are excluded: they are not licensed under Apache-2.0, and their use is governed by [TRADEMARKS.md](TRADEMARKS.md).
