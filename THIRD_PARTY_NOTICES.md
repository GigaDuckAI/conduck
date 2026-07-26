# Third-Party Notices

Conduck's own source code and the neutral placeholder artwork in this repository
are licensed under the Apache License 2.0 — see the LICENSE file at the root of
this repository. This file lists the third-party components that are part of a
Conduck build, in three categories:

1. **A vendored model artifact** — one compiled machine-learning model checked
   into this repository.
2. **Swift Package Manager dependencies** — the packages recorded in
   `Conduck/Conduck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
   which holds their exact pinned versions and revisions. They are not vendored
   in this tree; they are fetched at build time and compiled into the
   distributed app binaries. The list covers direct and transitive packages.
3. **Components embedded via those dependencies** — third-party code and assets
   that are not SPM packages in their own right but travel inside the packages
   above and reach the distributed app binaries. Their notice-preservation terms
   attach to the binary, so they are reproduced here even though this
   repository does not itself redistribute them.

License identities below were verified against the upstream repositories.

---

## Vendored model artifact

### Silero VAD (Core ML conversion) — model weights, MIT

- **Artifact:** `Conduck/Conduck/Resources/silero-vad-unified-256ms-v6.0.0.mlmodelc`
  (compiled Core ML model, model version 6.0.0)
- **Original model:** Silero VAD by the Silero Team —
  <https://github.com/snakers4/silero-vad>
- **Core ML conversion:** FluidInference (authors of the FluidAudio package
  listed below), per the artifact's embedded metadata; Conduck runs the model
  through FluidAudio
- **License:** MIT — applies to the model weights themselves, separately from
  the Apache-2.0 license that covers the FluidAudio code

```text
MIT License

Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Swift Package Manager dependencies

### MIT-licensed packages

Each package's license, including its copyright notice, is reproduced in full
below.

#### EventSource

- **Upstream:** <https://github.com/mattt/EventSource>
- **License:** MIT

```text
Copyright 2025 Mattt (https://mat.tt)

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

#### KeyboardShortcuts

- **Upstream:** <https://github.com/sindresorhus/KeyboardShortcuts>
- **License:** MIT

```text
MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

#### swift-concurrency-extras

- **Upstream:** <https://github.com/pointfreeco/swift-concurrency-extras>
- **License:** MIT

```text
MIT License

Copyright (c) 2023 Point-Free

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

#### swiftui-math

- **Upstream:** <https://github.com/gonzalezreal/swiftui-math>
- **License:** MIT

```text
MIT License

Copyright (c) 2026 Guille Gonzalez
Copyright (c) 2023 Computer Inspirations (SwiftMath)
Copyright (c) 2013 MathChat (iosMath)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

#### Textual

- **Upstream project:** Textual by Guille Gonzalez —
  <https://github.com/gonzalezreal/textual>
- **Pinned as:** a fork at <https://github.com/GigaDuckAI/textual>, which
  carries the upstream MIT license unchanged; modifications in the fork are
  likewise MIT
- **License:** MIT

```text
MIT License

Copyright (c) 2024 Guille Gonzalez

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

#### yyjson

- **Upstream:** <https://github.com/ibireme/yyjson>
- **License:** MIT

```text
MIT License

Copyright (c) 2020 YaoYuan <ibireme@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Apache-2.0-licensed packages

The following packages are licensed under the Apache License 2.0. The full
license text is identical to this repository's root LICENSE file.
Three of these projects (SwiftASN1, Swift Crypto, SwiftNIO) publish a NOTICE
file, reproduced verbatim below; the remaining projects publish the unmodified
Apache-2.0 text without a project-specific copyright notice.

| Package | Upstream |
|---|---|
| FluidAudio | <https://github.com/FluidInference/FluidAudio> |
| SwiftASN1 | <https://github.com/apple/swift-asn1> |
| Swift Atomics | <https://github.com/apple/swift-atomics> |
| Swift Collections | <https://github.com/apple/swift-collections> |
| Swift Crypto | <https://github.com/apple/swift-crypto> |
| swift-huggingface | <https://github.com/huggingface/swift-huggingface> |
| swift-jinja | <https://github.com/huggingface/swift-jinja> |
| SwiftNIO | <https://github.com/apple/swift-nio> |
| Swift System | <https://github.com/apple/swift-system> |
| swift-transformers | <https://github.com/huggingface/swift-transformers> |

`swift-transformers` and `swift-huggingface` are listed because they reach the
binary transitively, as dependencies of FluidAudio's `Tokenizers` target: no
Conduck source file imports either package, and no Conduck code path calls their
Hugging Face Hub networking. That linked-but-uncalled download code is why the
literals `huggingface.co` and `router.huggingface.co` appear in a string dump of
the shipped binary — they are endpoints inside those libraries, not hosts Conduck
connects to.

#### SwiftASN1 — NOTICE

```text

                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:

  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

The SwiftASN1 Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

---

This product contains derivations of various scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio

---

This product contains derivations of various scripts from Swift OpenAPI Generator.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-openapi-generator
```

#### Swift Crypto — NOTICE

```text
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:

  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

The SwiftCrypto Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product contains test vectors from Google's wycheproof project.

  * LICENSE (Apache License 2.0):
    * https://github.com/C2SP/wycheproof/blob/31387e2cd596587c859c611027b6a44d2e2b65ff/LICENSE
  * HOMEPAGE:
    * https://github.com/google/wycheproof

---

This product contains a derivation of various files from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
```

#### SwiftNIO — NOTICE

```text

                            The SwiftNIO Project
                            ====================

Please visit the SwiftNIO web site for more information:

  * https://github.com/apple/swift-nio

Copyright 2017, 2018 The SwiftNIO Project

The SwiftNIO Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product is heavily influenced by Netty.

  * LICENSE (Apache License 2.0):
    * https://github.com/netty/netty/blob/4.1/LICENSE.txt
  * HOMEPAGE:
    * https://netty.io

---

This product contains NodeJS's llhttp.

  * LICENSE (MIT):
    * https://github.com/nodejs/llhttp/blob/1e1c5b43326494e97cf8244ff57475eb72a1b62c/LICENSE-MIT
  * HOMEPAGE:
    * https://github.com/nodejs/llhttp

---

This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's uSHET

  * LICENSE (MIT):
    * https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/lib/cpp_magic.h
  * HOMEPAGE:
    * https://github.com/18sg/uSHET

---

This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project)

  * LICENSE (BSD-3):
    * https://opensource.org/licenses/BSD-3-Clause
  * HOMEPAGE:
    * https://github.com/freebsd/freebsd-src

---

This product contains a derivation of Fabian Fett's 'Base64.swift'.

  * LICENSE (Apache License 2.0):
    * https://github.com/swift-extras/swift-extras-base64/blob/b8af49699d59ad065b801715a5009619100245ca/LICENSE
  * HOMEPAGE:
    * https://github.com/fabianfett/swift-base64-kit

---

This product contains a derivation of "XCTest+AsyncAwait.swift" & "StructuredConcurrencyHelpers" from AsyncHTTPClient.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swift-server/async-http-client

---

This product contains a derivation of "_TinyArray.swift" from SwiftCertificates.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-certificates

---

This product contains a derivation of the mocking infrastructure from Swift System.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-system

---

This product contains a derivation of "TokenBucket.swift" from Swift Package Manager.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swiftlang/swift-package-manager
```

---

## Components embedded via dependencies

Each component below is compiled or copied into the distributed app binaries
through one of the Swift packages listed above. None of them is an SPM package
of its own, so none appears in `Package.resolved`.

### Prism.js v1.29.0 — MIT

- **Embedded in:** Textual, as
  `Sources/Textual/Internal/Highlighter/Prism/prism-bundle.js` — a single file
  built from the upstream minified core plus language definitions. Textual
  declares the enclosing directory as an SPM resource, so the bundle is copied
  into `textual_Textual.bundle` inside every Conduck build and loaded by
  Textual's code-block syntax highlighter.
- **Upstream:** <https://github.com/PrismJS/prism>
- **License:** MIT

```text
MIT LICENSE

Copyright (c) 2012 Lea Verou

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### fastcluster — BSD 2-Clause

- **Embedded in:** FluidAudio, as its `FastClusterWrapper` C++ target
  (`Sources/FastClusterWrapper/fastcluster_internal.hpp` and its wrapper). The
  `FluidAudio` library target depends on that target, so the C++ is compiled and
  linked into the app.
- **Upstream:** <https://danifold.net/fastcluster.html>
- **License:** BSD 2-Clause. Its binary-form condition requires reproducing the
  copyright notice, the list of conditions, and the disclaimer in materials
  distributed with the binary — which is what this entry does.

```text
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### VBx speaker-clustering algorithm — Apache-2.0

- **Embedded in:** FluidAudio, as
  `Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift` — a Swift
  implementation of the VBx variational-Bayes clustering algorithm from BUT
  Speech@FIT. It sits in the `FluidAudio` library target, so it compiles into
  the app.
- **Upstream:** <https://github.com/BUTSpeechFIT/VBx>
- **License:** Apache License 2.0, `Copyright 2021-2024 BUT Speech@FIT`. The
  full license text is identical to this repository's root LICENSE file.

### swiftui-math math fonts — SIL OFL-1.1 and the GUST Font License

- **Embedded in:** swiftui-math, as `Sources/SwiftUIMath/mathFonts.bundle`.
  swiftui-math declares it with `.copy`, so the directory is embedded verbatim —
  fonts and license files alike — in `swiftui-math_SwiftUIMath.bundle` inside
  every Conduck build.
- **License texts ship with the fonts.** Because the bundle is copied verbatim,
  its own license files are present in the installed app alongside the fonts,
  which is what OFL-1.1 and the GUST Font License require of a distribution:
  `OFL.txt` (the STIX Font License, which reproduces SIL OFL-1.1 in full),
  `GUST-FONT-LICENSE.txt` (the GUST Font License, distributed under the LaTeX
  Project Public License 1.3c or later), and `LICENSE` (MIT, Copyright (c) 2013
  MathChat — the iosMath heritage that swiftui-math's own entry above already
  reproduces). Those shipped files are authoritative; this entry records the
  fonts so the list of components is complete.

The twelve fonts, with the license each declares in its own `name` table:

| Font | License |
|---|---|
| Asana-Math | SIL OFL-1.1 |
| Euler-Math | SIL OFL-1.1 |
| FiraMath-Regular | SIL OFL-1.1 |
| Garamond-Math | SIL OFL-1.1 |
| KpMath-Light | SIL OFL-1.1 |
| KpMath-Sans | SIL OFL-1.1 |
| LeteSansMath | SIL OFL-1.1 |
| LibertinusMath-Regular | SIL OFL-1.1 |
| NotoSansMath-Regular | SIL OFL-1.1 |
| xits-math | SIL OFL-1.1 |
| latinmodern-math | GUST Font License |
| texgyretermes-math | GUST Font License |
