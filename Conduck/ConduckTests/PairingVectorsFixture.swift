// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingVectorsFixture.swift
//
// VENDORED SNAPSHOT of the pairing-code conformance vectors owned by
// `conduck-connect`. The app is the RECEIVER of every code the wizard mints,
// so the app must prove it agrees with the fixture's `import` column — but the
// two repositories never build against each other, so the vectors are copied
// here rather than read across a repo boundary.
//
//   Canonical file : github.com/GigaDuckAI/conduck-connect
//                    tests/fixtures/pairing-vectors.json
//   Vendored       : revision 1, copied 2026-09-09
//   Consumed by    : `PairingVectorsConformanceTests`
//
// UPDATE PROCEDURE (and nothing else): replace everything between the `#"""`
// and `"""#` delimiters below with the canonical file's contents, verbatim,
// then set `vendoredRevision` to the `revision` the pasted file carries and
// update the "copied" date above. Do not reformat, re-key or hand-edit a
// vector — the file is the contract.
//
// What the `vendoredRevision` assertion does and does not catch: it is a LOCAL
// consistency check — a paste that forgot the pin, or a pin bumped without a
// paste — and NOT a staleness check. Both values live in this one file, so a
// canonical file that moves to revision 2 while nobody re-pastes leaves this
// copy at 1 == 1 and green; the two repositories never build against each
// other, and nothing here can see the canonical file. Re-vendoring is a step
// of the conduck-connect release that changes the fixture, and that is where
// staleness is caught.
// (This copy was produced by a scripted paste of the canonical file; a manual
// paste is equivalent.)
//
// The literal is a RAW multi-line string so the JSON's own escapes
// (`\u001b`, `\n`, `\\u00e9`) reach `JSONSerialization` untouched. Every
// token and credential in it is a placeholder (`not-a-real-…`); every host is
// an example, `.local`, or private/loopback literal — nothing here is a secret
// and nothing here is a real endpoint.

import Foundation

enum PairingVectorsFixture {

    /// The `revision` this copy was taken from — set by hand at every re-paste
    /// to the value the pasted file carries, and asserted against it.
    static let vendoredRevision = 1

    /// The canonical file's bytes minus its final LF: a multi-line raw string
    /// ends at the line before the closing delimiter, so the newline that ends
    /// the file is not part of the value. A byte-diff against the canonical
    /// file is exact once that one trailing byte is allowed for.
    static let json = #"""
{
  "revision": 1,
  "canonical": "tests/fixtures/pairing-vectors.json",
  "spec": "PAYLOAD.md#minting-a-code-for-another-device",
  "about": "Frozen vectors for a gateway that mints conduck-setup:v1 codes natively, on three axes: `minter` (what --emit-code does with the inputs), `import` (the app's verdict) and `mint` (--check-code's). Conformance is semantic — for every accept vector whose mint is pass and whose inputs the minter supports, its decoded JSON must equal `expected` as a JSON object (key order and Unicode escaping are free; `transport` and minter-chosen display values are compared for presence only), and it never emits the shape of an accept vector whose mint is fail; only the `exact` entries pin bytes, and those are for orientation.",
  "contract": {
    "accept": "inputs -> expected. `minter` is `mints` (default: --emit-code with these inputs must decode to `expected`), `refuses` (--emit-code exits 2 naming `minterReason`; the validator grades a code encoded from `expected`), or `none` (no inputs; --emit-code cannot write this shape, the validator grades a code encoded from `expected`). `import` is the app's verdict; `mint` is --check-code's, with `mintReason` when it fails.",
    "exact": "The literal code --emit-code prints for `inputs`, and the minified JSON inside it. Orientation only: a native minter is conformant when it matches `expected` in the accept table, not these bytes.",
    "refuse": "One code per entry, with the decoded `payload` where the defect is in the JSON. The app refuses every one of these; `reason` is the category --check-code names first.",
    "reasons": "The fixed kebab-case vocabulary of --check-code (MANUAL.md, Validate a setup code). Tokens and credentials here are placeholders; hosts are example, .local, or private/loopback literals."
  },
  "accept": [
    {
      "id": "bearer-https-openclaw",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "openclaw"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "bearer-https-hermes-tailscale",
      "inputs": {
        "url": "https://hermes.example.com:8443",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "hermes",
        "transport": "tailscale"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "hermes",
          "url": "https://hermes.example.com:8443",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "tailscale"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "bearer-https-hermes-with-model",
      "inputs": {
        "url": "https://hermes.example.com:8443",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "hermes",
        "model": "qwen3:32b"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "hermes",
          "url": "https://hermes.example.com:8443",
          "auth": "bearer",
          "token": "not-a-real-token-0001",
          "model": "qwen3:32b"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass",
      "minter": "refuses",
      "minterReason": "--model applies to --kind custom only",
      "note": "The app imports this code and ignores the model: it pre-fills a model only for a custom gateway. --emit-code refuses to mint a hint the app will drop, so this vector reaches the validator through a code encoded from `expected`."
    },
    {
      "id": "bearer-https-custom-with-model",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "name": "Lab box",
        "model": "llama3.1:8b"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Lab box",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001",
          "model": "llama3.1:8b"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "custom-unicode-name",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "name": "Café · 研究"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Café · 研究",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "keyless-plain-http-private-ip",
      "inputs": {
        "url": "http://192.168.1.10:11434",
        "auth": "none",
        "kind": "custom",
        "name": "Ollama"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Ollama",
          "url": "http://192.168.1.10:11434",
          "auth": "none"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "keyless-plain-http-dot-local",
      "inputs": {
        "url": "http://gateway.local:18789",
        "auth": "none",
        "kind": "openclaw"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "http://gateway.local:18789",
          "auth": "none"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "bearer-plain-http-ipv6-ula",
      "inputs": {
        "url": "http://[fd00::10]:11434",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "name": "Rack"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Rack",
          "url": "http://[fd00::10]:11434",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "https-with-file-server",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "name": "Rig",
        "transport": "cloudflare",
        "fileServer": {
          "url": "https://files.example.com:8443",
          "credential": "not-a-real-credential-0002"
        }
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Rig",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "fileServer": {
          "url": "https://files.example.com:8443",
          "credential": "not-a-real-credential-0002"
        },
        "transport": "cloudflare"
      },
      "import": "accept",
      "mint": "pass"
    },
    {
      "id": "custom-without-name-takes-the-minter-default",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "transport": "funnel"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "My gateway",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "funnel"
      },
      "import": "accept",
      "mint": "pass",
      "note": "\"My gateway\" is --emit-code's default, not a rule of the format: a native minter names the gateway itself. The vector pins the default so the two do not drift."
    },
    {
      "id": "unknown-extra-top-level-key",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public",
        "x-vendor": {
          "note": "ignored by the app and by the validator"
        }
      },
      "import": "accept",
      "mint": "pass",
      "note": "Tolerant decode: an unknown top-level key is ignored. --emit-code never writes one, so the code is encoded from `expected`."
    },
    {
      "id": "unknown-nested-key",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001",
          "x-vendor-hint": "ignored"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "pass",
      "note": "Tolerant decode: an unknown key inside `gateway` is ignored."
    },
    {
      "id": "self-only-loopback-https",
      "inputs": {
        "url": "https://127.0.0.1:8480",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "openclaw"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://127.0.0.1:8480",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "address-only-reachable-from-the-gateway-itself",
      "note": "The app imports it (Conduck on the same Mac as its gateway); a code minted for a phone must not carry it."
    },
    {
      "id": "self-only-localhost-plain-http",
      "inputs": {
        "url": "http://localhost:11434",
        "auth": "none",
        "kind": "custom",
        "name": "Ollama"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Ollama",
          "url": "http://localhost:11434",
          "auth": "none"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "address-only-reachable-from-the-gateway-itself"
    },
    {
      "id": "self-only-ipv6-loopback-https",
      "inputs": {
        "url": "https://[::1]:8480",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "hermes"
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "hermes",
          "url": "https://[::1]:8480",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "address-only-reachable-from-the-gateway-itself"
    },
    {
      "id": "self-only-file-server-loopback",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "name": "Rig",
        "fileServer": {
          "url": "http://127.0.0.1:8081",
          "credential": "not-a-real-credential-0002"
        }
      },
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Rig",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "fileServer": {
          "url": "http://127.0.0.1:8081",
          "credential": "not-a-real-credential-0002"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "address-only-reachable-from-the-gateway-itself",
      "note": "The self-only tier keeps its own reason on the file-server address too; every other file-server defect folds into file-server-url-invalid."
    },
    {
      "id": "auth-omitted-stricter-than-app",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "missing-required-field",
      "note": "The app reads a missing auth as bearer; a native minter is held to writing it, because a code that relies on the default reads as keyless to anyone who inspects it."
    },
    {
      "id": "token-with-newline-stricter-than-app",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001\nstray-second-line"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "control-characters-in-text",
      "note": "The app imports any non-empty token; the validator refuses a control character in it, because no request carrying that header can succeed and the newline is always a copy accident."
    },
    {
      "id": "oversize-line-stricter-than-app",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public",
        "x-pad": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "payload-too-large",
      "note": "The app has no size bound and imports this if it is pasted; a QR cannot carry it at all, and the validator refuses a line over 8192 bytes before decoding anything."
    },
    {
      "id": "gateway-url-ends-in-v1-stricter-than-app",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "openclaw",
          "url": "https://ai.example.com/v1",
          "auth": "bearer",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "gateway-url-ends-in-v1",
      "note": "The app imports the address as written and then appends /v1/… to it, so every request goes to /v1/v1/…. --emit-code strips the tail before it mints (so no inputs reproduce this shape); a native minter refuses or strips it; the validator refuses it."
    },
    {
      "id": "keyless-code-carries-token-stricter-than-app",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Ollama",
          "url": "http://192.168.1.10:11434",
          "auth": "none",
          "token": "not-a-real-token-0001"
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "keyless-code-carries-token",
      "note": "The app imports it and drops the token; the validator refuses a code that carries a key it says it does not use. --emit-code refuses --keyless with CONDUCK_TOKEN set, so no inputs reproduce this shape."
    },
    {
      "id": "model-null-stricter-than-app",
      "minter": "none",
      "expected": {
        "v": 1,
        "gateway": {
          "kind": "custom",
          "name": "Rig",
          "url": "https://ai.example.com",
          "auth": "bearer",
          "token": "not-a-real-token-0001",
          "model": null
        },
        "transport": "public"
      },
      "import": "accept",
      "mint": "fail",
      "mintReason": "null-instead-of-omitted",
      "note": "The app reads a null model as absent and imports the code; the contract says a conditional field is omitted, never null, and the validator holds a native minter to it (the same rule covers transport and the three fileServer delivery fields)."
    }
  ],
  "exact": [
    {
      "id": "exact-bearer-https-openclaw",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "openclaw"
      },
      "json": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0="
    },
    {
      "id": "exact-keyless-plain-http-private-ip",
      "inputs": {
        "url": "http://192.168.1.10:11434",
        "auth": "none",
        "kind": "custom",
        "name": "Ollama"
      },
      "json": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"url\":\"http://192.168.1.10:11434\",\"auth\":\"none\",\"name\":\"Ollama\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwOi8vMTkyLjE2OC4xLjEwOjExNDM0IiwiYXV0aCI6Im5vbmUiLCJuYW1lIjoiT2xsYW1hIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9"
    },
    {
      "id": "exact-custom-unicode-name",
      "inputs": {
        "url": "https://ai.example.com",
        "auth": "bearer",
        "token": "not-a-real-token-0001",
        "kind": "custom",
        "name": "Café · 研究"
      },
      "json": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"name\":\"Caf\\u00e9 \\u00b7 \\u7814\\u7a76\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwczovL2FpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsIm5hbWUiOiJDYWZcdTAwZTkgXHUwMGI3IFx1NzgxNFx1N2E3NiIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9"
    }
  ],
  "refuse": [
    {
      "id": "wrong-prefix",
      "code": "conduck-pair:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "not-a-setup-code",
      "note": "The prefix is conduck-setup: and nothing else; a scanner ignores anything without it."
    },
    {
      "id": "unsupported-version-segment",
      "code": "conduck-setup:v2:eyJ2IjoyLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "unsupported-version",
      "note": "The segment after the prefix must be v1."
    },
    {
      "id": "bad-base64",
      "code": "conduck-setup:v1:!!!not-base64!!!",
      "import": "refuse",
      "reason": "malformed-base64"
    },
    {
      "id": "base64-empty",
      "code": "conduck-setup:v1:",
      "import": "refuse",
      "reason": "malformed-base64"
    },
    {
      "id": "json-not-an-object",
      "payload": "[1,2,3]",
      "code": "conduck-setup:v1:WzEsMiwzXQ==",
      "import": "refuse",
      "reason": "malformed-json"
    },
    {
      "id": "missing-v",
      "payload": "{\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "missing-required-field"
    },
    {
      "id": "non-integer-v",
      "payload": "{\"v\":\"1\",\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoiMSIsImdhdGV3YXkiOnsia2luZCI6Im9wZW5jbGF3IiwidXJsIjoiaHR0cHM6Ly9haS5leGFtcGxlLmNvbSIsImF1dGgiOiJiZWFyZXIiLCJ0b2tlbiI6Im5vdC1hLXJlYWwtdG9rZW4tMDAwMSJ9LCJ0cmFuc3BvcnQiOiJwdWJsaWMifQ==",
      "import": "refuse",
      "reason": "field-wrong-type"
    },
    {
      "id": "v-is-2",
      "payload": "{\"v\":2,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoyLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "unsupported-version"
    },
    {
      "id": "gateway-not-an-object",
      "payload": "{\"v\":1,\"gateway\":\"https://ai.example.com\",\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5IjoiaHR0cHM6Ly9haS5leGFtcGxlLmNvbSIsInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "field-wrong-type"
    },
    {
      "id": "unknown-kind",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"ollama\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvbGxhbWEiLCJ1cmwiOiJodHRwczovL2FpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "field-value-not-allowed"
    },
    {
      "id": "auth-unknown-without-token",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"basic\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmFzaWMifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "field-value-not-allowed",
      "note": "The app reads an unknown auth as bearer and then finds no token; the validator names the value first."
    },
    {
      "id": "bearer-without-token",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "bearer-token-missing"
    },
    {
      "id": "bearer-with-empty-token",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiIifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "bearer-token-missing"
    },
    {
      "id": "custom-without-name",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwczovL2FpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "custom-name-missing"
    },
    {
      "id": "custom-with-whitespace-name",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"   \",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiICAgIiwidXJsIjoiaHR0cHM6Ly9haS5leGFtcGxlLmNvbSIsImF1dGgiOiJiZWFyZXIiLCJ0b2tlbiI6Im5vdC1hLXJlYWwtdG9rZW4tMDAwMSJ9LCJ0cmFuc3BvcnQiOiJwdWJsaWMifQ==",
      "import": "refuse",
      "reason": "custom-name-missing",
      "note": "Trimmed with the app’s own whitespace set before it is judged empty."
    },
    {
      "id": "name-too-long",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "text-too-long",
      "note": "121 scalars; the cap is 120."
    },
    {
      "id": "control-character-in-name",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"Rig\\u001b[31m\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiUmlnXHUwMDFiWzMxbSIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "control-characters-in-text",
      "note": "An ESC in a display string; the app refuses the whole code over it."
    },
    {
      "id": "bidi-override-in-model",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"Rig\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\",\"model\":\"m-1\\u202eevil\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiUmlnIiwidXJsIjoiaHR0cHM6Ly9haS5leGFtcGxlLmNvbSIsImF1dGgiOiJiZWFyZXIiLCJ0b2tlbiI6Im5vdC1hLXJlYWwtdG9rZW4tMDAwMSIsIm1vZGVsIjoibS0xXHUyMDJlZXZpbCJ9LCJ0cmFuc3BvcnQiOiJwdWJsaWMifQ==",
      "import": "refuse",
      "reason": "control-characters-in-text",
      "note": "RIGHT-TO-LEFT OVERRIDE in a model id."
    },
    {
      "id": "userinfo-in-gateway-url",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://user:not-a-real-password@ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vdXNlcjpub3QtYS1yZWFsLXBhc3N3b3JkQGFpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "url-userinfo-present"
    },
    {
      "id": "url-scheme-not-allowed",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"ftp://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6ImZ0cDovL2FpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "url-scheme-not-allowed"
    },
    {
      "id": "url-without-host",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https:///v1\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vL3YxIiwiYXV0aCI6ImJlYXJlciIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "url-host-invalid"
    },
    {
      "id": "plain-http-dotted-domain",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"http://gateway.example.com:18789\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHA6Ly9nYXRld2F5LmV4YW1wbGUuY29tOjE4Nzg5IiwiYXV0aCI6ImJlYXJlciIsInRva2VuIjoibm90LWEtcmVhbC10b2tlbi0wMDAxIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "plain-http-host-not-local-only",
      "note": "Apple refuses a dotted name over plain http from the string, however private the machine behind it."
    },
    {
      "id": "plain-http-single-label",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"NAS\",\"url\":\"http://nas:11434\",\"auth\":\"none\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiTkFTIiwidXJsIjoiaHR0cDovL25hczoxMTQzNCIsImF1dGgiOiJub25lIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "plain-http-host-not-local-only",
      "note": "A one-label name can resolve at the public DNS root; its .local spelling or its IP literal is the working form."
    },
    {
      "id": "plain-http-cgnat",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"Tailnet\",\"url\":\"http://100.64.0.1:11434\",\"auth\":\"none\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiVGFpbG5ldCIsInVybCI6Imh0dHA6Ly8xMDAuNjQuMC4xOjExNDM0IiwiYXV0aCI6Im5vbmUifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "plain-http-host-not-local-only",
      "note": "Carrier-grade NAT, the range an overlay VPN hands out; measured refused."
    },
    {
      "id": "plain-http-unspecified",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"custom\",\"name\":\"Bind-all\",\"url\":\"http://0.0.0.0:11434\",\"auth\":\"none\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJuYW1lIjoiQmluZC1hbGwiLCJ1cmwiOiJodHRwOi8vMC4wLjAuMDoxMTQzNCIsImF1dGgiOiJub25lIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "address-only-reachable-from-the-gateway-itself",
      "note": "0.0.0.0 is refused by the app too, but the validator tests the self-only tier before the plain-http rule, so that is the reason it names."
    },
    {
      "id": "userinfo-in-file-server-url",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"fileServer\":{\"url\":\"https://conduck:not-a-real-password@files.example.com\",\"credential\":\"not-a-real-credential-0002\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwiZmlsZVNlcnZlciI6eyJ1cmwiOiJodHRwczovL2NvbmR1Y2s6bm90LWEtcmVhbC1wYXNzd29yZEBmaWxlcy5leGFtcGxlLmNvbSIsImNyZWRlbnRpYWwiOiJub3QtYS1yZWFsLWNyZWRlbnRpYWwtMDAwMiJ9LCJ0cmFuc3BvcnQiOiJwdWJsaWMifQ==",
      "import": "refuse",
      "reason": "file-server-url-invalid"
    },
    {
      "id": "file-server-plain-http-public-name",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"fileServer\":{\"url\":\"http://files.example.com\",\"credential\":\"not-a-real-credential-0002\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwiZmlsZVNlcnZlciI6eyJ1cmwiOiJodHRwOi8vZmlsZXMuZXhhbXBsZS5jb20iLCJjcmVkZW50aWFsIjoibm90LWEtcmVhbC1jcmVkZW50aWFsLTAwMDIifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "file-server-url-invalid"
    },
    {
      "id": "file-server-missing-credential",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"fileServer\":{\"url\":\"https://files.example.com:8443\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwiZmlsZVNlcnZlciI6eyJ1cmwiOiJodHRwczovL2ZpbGVzLmV4YW1wbGUuY29tOjg0NDMifSwidHJhbnNwb3J0IjoicHVibGljIn0=",
      "import": "refuse",
      "reason": "missing-required-field"
    },
    {
      "id": "file-server-empty-credential",
      "payload": "{\"v\":1,\"gateway\":{\"kind\":\"openclaw\",\"url\":\"https://ai.example.com\",\"auth\":\"bearer\",\"token\":\"not-a-real-token-0001\"},\"fileServer\":{\"url\":\"https://files.example.com:8443\",\"credential\":\"\"},\"transport\":\"public\"}",
      "code": "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vYWkuZXhhbXBsZS5jb20iLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJub3QtYS1yZWFsLXRva2VuLTAwMDEifSwiZmlsZVNlcnZlciI6eyJ1cmwiOiJodHRwczovL2ZpbGVzLmV4YW1wbGUuY29tOjg0NDMiLCJjcmVkZW50aWFsIjoiIn0sInRyYW5zcG9ydCI6InB1YmxpYyJ9",
      "import": "refuse",
      "reason": "missing-required-field"
    }
  ]
}
"""#
}
