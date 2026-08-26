<p align="center">
  <img src="https://conduck.com/conduck-icon-128.png" width="96" height="96" alt="Conduck app icon" />
</p>

<h1 align="center">Conduck</h1>

<p align="center"><strong>Your AI. Every Apple device. No middleman.</strong></p>

<p align="center">
  The native Apple client for your self-hosted or BYO-key AI.<br />
  Talk, type, share, and carry the same conversation across iPhone, iPad, Mac, Apple Watch, and CarPlay.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6773045286">
    <img src="https://conduck.com/download-on-app-store.svg" height="40" alt="Download Conduck on the App Store" />
  </a>
</p>

<p align="center">
  <a href="https://conduck.com/#film">Watch the 40-second film</a>
  ·
  <a href="#build-from-source">Build Conduck Community</a>
  ·
  <a href="https://conduck.com/setup/">Setup guide</a>
  ·
  <a href="https://conduck.com/discord/">Discord</a>
</p>

[![Conduck on Mac, iPad, iPhone, Apple Watch, and CarPlay. Watch the 40-second product demo.](https://conduck.com/media/conduck-film-poster-v1.jpg)](https://conduck.com/#film)

Conduck is the interface, not the AI service. There is no model inside the app and no Conduck account to create. You connect the AI you choose, then make it available wherever you already are: at your desk, on your wrist, in the car, or inside another app.

The official app is free for individual use. Conduck-authored application code is open source under Apache-2.0.

## Why Conduck

- **Ask from anywhere.** Use the Action Button, Control Center, or Shortcuts on iPhone and iPad, or ask from the Mac menu bar, a global hotkey, Apple Watch, or CarPlay.
- **One conversation across your devices.** Start on Mac, continue on iPhone, and check the reply from your Watch. Your threads sync through your own private iCloud.
- **Talk, type, or share what is in front of you.** Dictate with on-device speech, attach a photo or text file, share from another app, or use Screenshot & Ask on Mac.
- **Bring the AI that fits you.** Connect a self-hosted agent, an OpenAI-compatible model endpoint, or a hosted model through OpenRouter.
- **See what you actually use.** A Usage screen on iPhone, iPad, and Mac counts your turns, tokens, response times, and reliability, broken down by gateway, device, and model — measured on your device, visible only to you.
- **Keep Conduck out of the middle.** No Conduck-operated intermediary server, no account, and no analytics, ads, tracking, or telemetry. Your device talks directly to the AI and providers you chose, under your own keys.

## One client. Five surfaces.

| Surface | What Conduck adds |
|---|---|
| **iPhone** | Native chat and voice, attachments, Action Button, Control Center, Shortcuts, and the share sheet |
| **iPad** | Native chat and voice, attachments, Control Center, Shortcuts, and the share sheet |
| **Mac** | Full desktop app, menu-bar companion, global hotkeys, Screenshot & Ask, and the share extension |
| **Apple Watch** | Quick voice or text capture, conversations, and replies from your wrist |
| **CarPlay** | Hands-free, multi-turn voice conversations on the road |

Conversation history follows you through your private iCloud. CarPlay runs through the iPhone app. Conduck requires iOS, iPadOS, macOS, and watchOS 26.5 or later; the Mac app requires Apple silicon (M1 or later).

## How it works

**Three steps. One is setup.**

1. **Connect your AI.** Paste a URL and key, scan a setup code from [conduck-connect](https://github.com/gigaduckai/conduck-connect), or add an OpenRouter key if you do not run a server yet.
2. **Talk, type, or share.** Use the full app or whichever system shortcut is closest at hand.
3. **Continue anywhere.** Replies join the same conversation on your other devices through your own iCloud.

[Walk through the setup guide](https://conduck.com/setup/).

## Connect your way

| Path | Examples | What you get |
|---|---|---|
| **Self-hosted agent gateway** | OpenClaw, Hermes, or an agent behind the [Conduck adapter](https://conduck.com/setup/adapter/v1/) | Server-side agent tools, memory, long-running work, and optional full file exchange |
| **OpenAI-compatible model endpoint** | Ollama, LM Studio, vLLM, LiteLLM, a routing proxy, or another compatible service | Chat, vision, and declared capabilities; Conduck does not run an agent loop or execute returned tool calls |
| **Hosted model** | OpenRouter | Multi-turn chat and inline image or text/code attachments in about a minute, with your own API key and no server to run |

Images and text/code attachments can ride inline on every compatible lane. Full arbitrary-file exchange, including files created by an agent, requires a self-hosted agent plus an optional WebDAV folder reachable by both sides. The hosted-model lane covers chat, not an agent loop or full file exchange.

## Private by architecture, not by promise

```text
your device   -> your AI (direct HTTPS)
your device   -> your cloud voice provider (optional, direct HTTPS)
your devices <-> your private iCloud
your device  <-> your WebDAV file server (optional) <-> your agent
```

No Conduck-operated server sits on any of these paths.

- Conversations live on your device and mirror to your own private iCloud database. Apple encrypts that data, and it is not available to us.
- API keys and access tokens live in the Apple Keychain.
- Voice stays on-device by default through Apple's speech and read-aloud engines.
- If you choose cloud speech, audio goes directly to that provider under your own key.
- Conduck contains no analytics, ads, tracking, or telemetry.

The AI and optional providers you connect still receive the information you choose to send them. Their handling of it is governed by their own configuration and terms.

[See exactly how your data moves](https://conduck.com/trust/) · [Read the privacy policy](https://conduck.com/privacy/) · [Inspect the architecture](docs/ai-context/spec.md)

## Get it

Two builds share this codebase:

| | Official app | Personal source build |
|---|---|---|
| **Distribution** | [App Store](https://apps.apple.com/app/id6773045286) | Build from source |
| **Terms** | Free for individuals; [commercial use licensed separately](https://conduck.com/terms/) | Apache-2.0, including commercial source use |
| **Identity** | Conduck name and artwork | “Conduck Community” with neutral placeholder art |
| **CarPlay** | Included | Not included because it requires an Apple per-team entitlement |

The terms for the official app cover its distribution and the Conduck brand. They place no restriction on the source in this repository, which is licensed under Apache-2.0.

The official build is made from this public application source with private branding, signing, and Apple's CarPlay entitlement added for distribution. No functional code is withheld.

Personal builds may display the **Conduck Community** identity. If you redistribute a build, choose your own product name, icons, and identity as required by [TRADEMARKS.md](TRADEMARKS.md).

## Build from source

Conduck requires Xcode 26.5 or later.

1. Clone this repository.
2. Open `Conduck/Conduck.xcodeproj`.
3. Build and run. Simulator builds need no configuration.

An unsigned simulator build cannot write to the Keychain, so a gateway added there will not persist. To exercise the app against a real gateway, build with a signing identity or use the launch arguments described in [QA mode](docs/qa/qa-mode.md). To run on your own devices, see [Building from source](CONTRIBUTING.md#building-from-source).

The result is **Conduck Community**: the same application functionality, minus the CarPlay entitlement, under a neutral identity with placeholder art. Official Conduck brand artwork is not part of this repository and is not covered by the code license; see [TRADEMARKS.md](TRADEMARKS.md).

Before changing the application, read the [architecture document](docs/ai-context/spec.md). It records the decisions and deliberately rejected alternatives — the part the code alone cannot tell you.

## The words this project uses

Several of these words carry a narrower meaning here than they do elsewhere in the industry, and *gateway* carries nearly the opposite one. Read this glossary before working on the code or architecture.

<details>
<summary><strong>Open the contributor glossary</strong></summary>

### Gateway

In Conduck, a gateway is a machine you own that stays on and runs an agent for you: a VPS, home server, or always-on Mac mini. It holds the agent's tools, file system, and long-running jobs. Conduck is the thin client that talks to it over HTTPS and keeps the conversation on your device.

This differs from the common industry meaning of “AI gateway.” LiteLLM, Portkey, Kong AI Gateway, Cloudflare AI Gateway, and similar products are routing proxies: they sit in front of model providers and handle keys, failover, caching, rate limits, or spend. They do not themselves provide an agent loop, tools, or a working file system.

If you use an AI gateway in that industry sense, it normally sits farther downstream:

```text
Conduck -> your agent runtime -> your AI gateway -> model provider
```

OpenRouter is an AI gateway in the industry sense. Conduck treats it as a hosted-model lane: you operate no server, and that lane provides chat rather than agent tools or full file exchange.

### Agent runtime, or harness

The scaffolding that turns a model into an agent: the loop that lets it call tools, read and write files, and continue across multiple steps. Claude Code, Codex CLI, OpenClaw, and Hermes are examples.

Conduck does not contain an agent runtime. It talks to yours.

### Hosted model

A model reached through somebody else's API under your own key, with no server of your own in the path. Conduck's hosted lane is deliberately limited to chat.

Images and text/code attachments can still be sent to the model. Agent tools, an agent loop, and full file exchange require a self-hosted agent gateway.

### Model endpoint

Any URL that answers OpenAI-compatible chat-completion requests. The term says nothing about what is behind the URL: it may be a hosted service, Ollama, vLLM, a routing proxy, or a custom agent.

That is why Conduck asks you to declare the capabilities of a custom endpoint instead of guessing them.

### Adapter

The [published adapter contract](https://conduck.com/setup/adapter/v1/) defines the request and reply shapes a server implements to work with Conduck. Anything that speaks that contract can connect, regardless of what it is written in.

The [adapter build brief](https://conduck.com/setup/adapter/build/) explains how to place one in front of an AI you wrote yourself. [`conduck-connect`](https://github.com/gigaduckai/conduck-connect) checks software written for Conduck with `--check-adapter`. A stock server that was not written specifically for Conduck — such as Ollama, vLLM, or LiteLLM — is checked against the more forgiving app compatibility surface with `--check-server`.

### File server

A WebDAV server that both your devices and agent can reach, used to move complete files in either direction. It is separate from the gateway and belongs to you.

Conduck ships no file-server binary and is only a client of one you already run. The hosted-model lane has no file server, so it does not offer full file exchange.

### Backend

This word appears in two different senses.

In public privacy claims, “backend” means a server operated by Conduck. There is none.

In the source, `Conversation.backend` and `RemoteAgentBackend` are frozen persistence identifiers that record which kind of AI a conversation uses. Renaming them would orphan data already stored on users' devices. Public prose therefore says “gateway kind” or names the lane instead.

</details>

## Connecting to your gateway

<details>
<summary><strong>HTTPS and certificate requirements for self-hosted gateways</strong></summary>

This applies only to self-hosted lanes. A hosted model needs an API key but no certificate setup of your own.

Your gateway needs an `https://` address with a certificate your Apple devices already trust. Conduck refuses a self-signed certificate or one issued by a private certificate authority the device does not trust.

Conduck cannot offer an “ignore certificate errors” switch. App Transport Security — the platform rule Apple applies to app network traffic — allows an app to make certificate checks stricter, not looser.

On a managed fleet, a root certificate already trusted by the devices works, whether pushed by MDM or installed and enabled in Certificate Trust Settings. Otherwise, fix trust on the server side. The [setup guide](https://conduck.com/setup/) covers Tailscale Serve, Let's Encrypt, and reverse-proxy options such as Caddy.

</details>

## Documentation

Two documents cover the project. They are written for both people and AI coding agents. Individual files document themselves through mandatory header comments, while the test suite records detailed behavior.

- [`docs/ai-context/spec.md`](docs/ai-context/spec.md) explains the architecture, its boundaries, the decisions behind them, and the alternatives deliberately rejected.
- [`docs/ai-context/project-structure.md`](docs/ai-context/project-structure.md) maps the folders and build targets and explains where to begin for each kind of change.

## Community and contributing

- Chat, questions, and setup help: [Discord](https://conduck.com/discord/).
- Bugs and feature requests: GitHub issues.
- Contributions are welcome under the Developer Certificate of Origin (`git commit -s`, no CLA). See [CONTRIBUTING.md](CONTRIBUTING.md).
- Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not through a public issue.

## License and trademarks

Conduck-authored code and neutral placeholder art are licensed under [Apache-2.0](LICENSE). Bundled third-party code remains under its own licenses; see [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The Conduck™ name and official duck-character artwork are excluded from that license. Their use is governed by [TRADEMARKS.md](TRADEMARKS.md).

Apple, the Apple logo, Apple Watch, App Store, CarPlay, iCloud, iPad, iPhone, Mac, macOS, watchOS, and Xcode are trademarks of Apple Inc., registered in the U.S. and other countries and regions.
