# Conduck

Conduck is a native Swift/SwiftUI chat and voice client for your own AI. It talks directly to a gateway you run yourself — or to hosted models under your own key — from iPhone, iPad, Mac, Apple Watch, and CarPlay. There is no backend, no account, and no telemetry: you bring your own keys, and nothing you say or send ever passes through our servers, because there are none.

[Get the official app](https://apps.apple.com/app/id6773045286) · [Build from source](#build-from-source) · [Glossary](#the-words-this-project-uses) · [Architecture](docs/ai-context/spec.md) · [conduck.com](https://conduck.com) · [Join the Discord](https://conduck.com/discord/)

## How your data flows

```
your device → the voice provider you chose (optional) → the gateway or model provider you chose
your device → the WebDAV file server you run (optional) → your agent, and back for the files it produces
```

That is the request path for a turn. Speech recognition and read-aloud default to Apple's on-device engines, and conversation history lives on your device, mirrored into your own private iCloud database. Apple's own services are the one exception to "an endpoint you chose": the iCloud mirror, the key-value store, and the on-device speech model Apple downloads the first time you dictate in a language. Everything else goes to an endpoint you configured under a key you own — your speech provider, the AI you chose, and, where your gateway has one, its file server. We are never in the path.

The full privacy policy — the canonical version of these claims — is at [conduck.com/privacy](https://conduck.com/privacy/).

## What it works with

- **Self-hosted agent gateways** — OpenClaw and Hermes presets, for an agent running on a machine you keep online. Guided setup via the companion [conduck-connect](https://github.com/gigaduckai/conduck-connect) pairing wizard; manual URL + token entry always works. Either way the gateway needs a certificate your devices already trust — see [Connecting to your gateway](#connecting-to-your-gateway).
- **Hosted models as an on-ramp** — OpenRouter, for multi-turn chat before you run anything of your own. You operate no server on this lane, and it covers chat, not agent tools or file exchange. [Start here](https://conduck.com/setup/).
- **Any other OpenAI-compatible endpoint** — added by hand. Conduck assumes nothing about what is behind one: a local Ollama or vLLM, a routing proxy in front of your own providers, another agent runtime, or something you wrote yourself all connect the same way, and what the lane can do is what you configure.
- **Voice both ways** — on-device Apple speech by default; optional cloud speech-to-text and text-to-speech providers, all BYO-key, including custom OpenAI-compatible speech endpoints.
- **Attachments and files** — images and text/code files in the conversation, and full file exchange with your agent (send arbitrary files, pull generated files back with previews) through your own WebDAV file server.
- **Every surface, natively** — one-press voice capture on iPhone and iPad, bound to whatever trigger the device offers (Action Button, Back Tap, or Control Center), a share-sheet extension on iPhone, iPad and Mac, a menu-bar + Dock app with global hotkeys and screenshot-and-ask on the Mac, quick voice capture on the Watch, hands-free multi-turn voice in CarPlay.

## The words this project uses

Several of these words mean something else elsewhere in the industry, and one of them means almost the opposite. This section says which sense Conduck means, so you can tell which layer of your own stack the app is talking about.

**Gateway.** In Conduck, a gateway is *a machine you own that stays on, running an agent for you* — a VPS, a home server, an always-on Mac mini. It holds the agent's tools, its file system, and its long-running jobs. Conduck is a thin client that talks to it over HTTPS and keeps the conversation on your device.

That is not the industry's usual sense of the word, and the collision is worth stating plainly. An "AI gateway" or "LLM gateway" — LiteLLM, Portkey, Kong AI Gateway, Cloudflare AI Gateway — is a **routing proxy**: it sits in front of several model providers and does key management, failover, caching, rate limiting and spend accounting. It runs no agent, owns no file system, and holds no tools. Conduck's gateway is not one of those, and Conduck is not one either.

If you run an AI gateway in that sense, it sits *behind* whatever Conduck points at rather than in its place. `Conduck → your agent runtime → your AI gateway → the model provider` is an ordinary arrangement, and Conduck only ever sees the first hop — it neither knows nor needs to know what is downstream of it.

OpenRouter is genuinely an AI gateway in the industry sense. Conduck talks to it as a hosted-model lane, not as a gateway in the sense above: you operate no server for it, and it carries no agent tools and no file exchange.

**Agent runtime**, also called a **harness**. The scaffolding that turns a model into an agent — the loop that lets it call tools, read and write files, and keep working across several steps. Claude Code, Codex CLI, OpenClaw and Hermes are all agent runtimes. Conduck does not contain one and is not going to; it talks to yours.

**Hosted model.** A model you reach over somebody else's API under your own key, with no server of your own anywhere in the path. Conduck's hosted lane is deliberately limited to chat. Attachments still ride inline to the model; agent tools, the agent loop and file exchange need a gateway.

**Model endpoint.** Any URL that answers OpenAI-compatible chat-completion requests. It says nothing about what is behind it — a hosted service, a local Ollama or vLLM, a routing proxy, or somebody's hand-written agent are all model endpoints. That is exactly why a custom endpoint you add cannot be assumed to be any one of them, and why Conduck asks you to declare what it supports instead of guessing.

**Adapter.** The [published contract](https://conduck.com/setup/adapter/v1/) a server meets in order to answer Conduck: the request and reply shapes, and nothing else. Anything that speaks it works, whatever it is written in; there is a [build brief](https://conduck.com/setup/adapter/build/) for putting one in front of an AI you wrote yourself. [`conduck-connect`](https://github.com/gigaduckai/conduck-connect) grades software written for Conduck against it with `--check-adapter`; a server that was not written for Conduck — a stock Ollama, vLLM or LiteLLM — is graded against what the app itself accepts with `--check-server`, which is the more forgiving bar.

**File server.** A WebDAV server that both your devices and your agent can reach, for moving whole files in either direction. It is separate from the gateway and it is yours as well — Conduck ships no server binary for it, and is only ever a client for one you already run. The hosted lane has none, which is why file exchange is not offered there.

**Backend.** This word carries two senses and this repository keeps them apart. In the privacy claim at the top of this file — "there is no backend" — it means *a server operated by us*, and there is none. In the source it is also the frozen name of the field recording which kind of AI a conversation is bound to, which is why you will meet `Conversation.backend` and `RemoteAgentBackend` in the code; those identifiers cannot be renamed without orphaning data already on people's devices. In prose the project says "gateway kind", or names the lane.

## Connecting to your gateway

This section is about the self-hosted lanes. If you are on the hosted lane you configure a key and nothing else — there is no certificate for you to arrange.

Your gateway needs an `https://` address whose certificate your Apple devices already trust. A self-signed certificate, or one from a private certificate authority your devices do not already trust, is refused, and Conduck cannot offer to ignore that: App Transport Security, the platform rule Apple applies to every app's network traffic, lets an app make certificate checks stricter, never looser. On a fleet you manage, a root your devices already trust — pushed by MDM, or installed and then enabled in Certificate Trust Settings — works; otherwise the fix is on the server.

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
| Cost | Free for individuals; [commercial use licensed separately](https://conduck.com/terms/) | Source under Apache-2.0 |
| Branding | Conduck name and artwork | "Conduck Community", placeholder art |
| CarPlay | Included | Not included (restricted Apple entitlement) |

Those terms cover the official App Store build and the Conduck brand; they place no restriction on the source in this repository, which is Apache-2.0.

The official build is this public code plus private branding, signing, and Apple's per-team CarPlay entitlement — no functional code is withheld from this repository.

## Build from source

Requires Xcode 26.5 or later.

1. Clone this repository.
2. Open `Conduck/Conduck.xcodeproj`.
3. Build and run — no configuration needed. Simulator builds work as-is. An unsigned simulator build cannot write the Keychain, so a gateway you add there will not persist; to exercise the app against a real gateway, either build with a signing identity or use the launch arguments in [docs/qa/qa-mode.md](docs/qa/qa-mode.md). To run on your own devices, see [CONTRIBUTING.md](CONTRIBUTING.md#building-from-source).

The result is **Conduck Community**: identical functionality (minus the CarPlay entitlement) under a neutral identity with placeholder art. The real Conduck brand artwork is not part of this repository and is not covered by the code license — see [TRADEMARKS.md](TRADEMARKS.md).

Before changing anything, read [the architecture document](docs/ai-context/spec.md) — it records the decisions and the deliberately rejected alternatives, which is the part the code cannot tell you.

## Documentation

Two documents cover the whole project. Both are written for people and for AI
coding agents, and neither describes individual files, by decision — the code
itself, through per-file header comments and a large test suite, is the detailed
documentation.

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
