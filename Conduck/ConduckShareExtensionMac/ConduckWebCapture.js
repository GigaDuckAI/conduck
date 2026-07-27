// SPDX-License-Identifier: Apache-2.0

// Conduck — Safari page-text capture (NSExtensionJavaScriptPreprocessingFile).
//
// Safari executes this file INSIDE the shared page at share time; the object
// assigned to `ExtensionPreprocessingJS` gets `run(args)` called, and whatever
// is passed to `args.completionFunction` arrives in the appex as the
// `NSExtensionJavaScriptPreprocessingResultsKey` dictionary of a
// `com.apple.property-list` NSItemProvider. The Swift contract for this
// payload is `WebPageCapture.parse` — the appex treats everything here as
// UNTRUSTED input (a page script can replace any of it) and re-validates.
//
// BYTE-IDENTICAL PAIR: this file exists once per appex dir
// (`ConduckShareExtension/` + `ConduckShareExtensionMac/`) and the two copies
// must stay identical — drift guard: `ConduckTests/WebPageCaptureTests`.
//
// MAX_BYTES pairs with `WebPageCapture.maxCaptureBytes` and
// `Constants.webPageCaptureMaxBytes` (128 KiB) — JS cannot read Swift, so the
// literal is duplicated and pinned by the same guard test. Change all together.
//
// Scope rule: a non-empty (non-whitespace) selection is captured INSTEAD of
// the page — a selection is the stronger intent signal and avoids shipping a
// whole page the user only wanted one passage of. `finalize` is deliberately
// absent (the appex never returns items to Safari).

var MAX_BYTES = 131072;

var ConduckWebCapture = function () {};

ConduckWebCapture.prototype = {
    // The parameter must NOT be named `arguments` — inside a function that
    // identifier is the implicit arguments object, so Apple's sample naming
    // silently shadows and breaks. Named `args` on purpose.
    run: function (args) {
        var payload = {
            title: "",
            url: "",
            selection: "",
            pageText: "",
            originalByteCount: 0,
            truncated: false,
            scope: "page"
        };
        try {
            // Per-field try/catch (mirroring the getSelection inner-try below): a
            // hostile page can install a throwing getter on document.title or
            // location.href, so isolate each read — a throw costs only that one
            // field, not the whole capture.
            try {
                payload.title = String(document.title || "");
            } catch (titleErr) {
                payload.title = "";
            }
            try {
                payload.url = String(location.href || "");
            } catch (urlErr) {
                payload.url = "";
            }

            var selection = "";
            try {
                var sel = window.getSelection();
                selection = sel ? String(sel.toString()) : "";
            } catch (selErr) {
                selection = "";
            }

            var text;
            if (selection.replace(/\s+/g, "").length > 0) {
                payload.scope = "selection";
                text = selection;
            } else {
                payload.scope = "page";
                // innerText (not textContent): rendered text with layout-aware
                // line breaks, skipping display:none/script/style noise. Nil-safe:
                // a body-less document yields "" -> Swift parse returns nil ->
                // graceful absence (the share proceeds as a plain URL share).
                text = document.body ? String(document.body.innerText || "") : "";
            }

            var bytes = new TextEncoder().encode(text);
            payload.originalByteCount = bytes.length;
            if (bytes.length > MAX_BYTES) {
                text = utf8Truncate(bytes, MAX_BYTES);
                payload.truncated = true;
            }
            if (payload.scope === "selection") {
                payload.selection = text;
            } else {
                payload.pageText = text;
            }
        } catch (err) {
            // Swallow everything: a hostile/broken page must degrade to the
            // empty payload (Swift parse -> nil -> plain URL share), never to
            // a hung share sheet. No logging - page content/URLs are private.
        }
        args.completionFunction(payload);
    }
};

// Cut the encoded bytes to at most maxBytes WITHOUT splitting a UTF-8 code
// point: back off any continuation bytes (0b10xxxxxx) at the cut, so the
// decode below never manufactures U+FFFD replacement characters. Worst case
// clips one grapheme cluster mid-sequence (e.g. half a ZWJ emoji family) -
// accepted here: the Swift side re-clamps only text OVER its own cap, so a cut
// that lands exactly at the cap may retain a split grapheme (cosmetic).
function utf8Truncate(bytes, maxBytes) {
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) === 0x80) {
        end--;
    }
    return new TextDecoder("utf-8").decode(bytes.subarray(0, end));
}

var ExtensionPreprocessingJS = new ConduckWebCapture();
