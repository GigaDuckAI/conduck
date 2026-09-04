# Fixnote — second CloudKit container for the payload store

**Crash fixed.** First signed macOS launch threw `NSException` "Cannot assign the same iCloud
Container Identifier to multiple stores" while `ConversationStore.init()` assigned
`container.persistentStoreDescriptions`. Both descriptions carried
`NSPersistentCloudKitContainerOptions(containerIdentifier: Constants.iCloudCloudKitContainerID)`.
`NSPersistentCloudKitContainer` forbids two stores mirroring one container. The pre-decided
contingency (`docs/qa/desk-cloudkit/spike-fixnote.md:128`, the WWDC19-202 shape) is a second
container for `Blobs`; that is what shipped here.

Branch `feature/agent-workboard`, worktree
`/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`. No commits made.

## Values (all new, all set-once Apple identities from here on)

| Layer | Symbol | Official | Community |
|---|---|---|---|
| Build setting | `CONDUCK_ICLOUD_BLOBS_CONTAINER_ID` | `iCloud.ai.gigaduck.agentrelay.blobs` | `iCloud.com.example.conduck.blobs` |
| Info.plist key | `ConduckCloudKitBlobsContainerID` | `$(CONDUCK_ICLOUD_BLOBS_CONTAINER_ID)` | same |
| Swift | `Constants.iCloudCloudKitBlobsContainerID` | read from the plist key, fallback `"iCloud.\(identityNamespace).blobs"` | same |

## Files and symbols changed

1. `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Configs/Identity.xcconfig`
   — `CONDUCK_ICLOUD_BLOBS_CONTAINER_ID = iCloud.com.example.conduck.blobs` beside the existing
   container line.

2. `/Users/peterkruck/repos/GigaDuck/Conduck-Private/Configs/Identity-Override.xcconfig` (the ONE
   edit outside the worktree, written to the real file, never through the gitignored symlink)
   — `CONDUCK_ICLOUD_BLOBS_CONTAINER_ID = iCloud.ai.gigaduck.agentrelay.blobs`. Nothing else in that
   file touched.

3. `.../Conduck/Conduck/Info.plist` — `ConduckCloudKitBlobsContainerID` = `$(CONDUCK_ICLOUD_BLOBS_CONTAINER_ID)`,
   directly above `ConduckCloudKitContainerID`. Same build-setting-substitution mechanism as every
   other `Conduck*` identity key; `plutil -lint` OK. The Watch's own `Info.plist` is NOT given the
   key — the wrist mounts no payload store.

4. `.../Conduck/Conduck/Utilities/Constants.swift`
   - NEW `nonisolated static let iCloudCloudKitBlobsContainerID`. Doc comment states the reason
     (Core Data refuses two stores mirroring one container, with the exception text quoted), that
     both containers are the user's own private iCloud with no backend and "Data Not Collected"
     intact, and that the Watch never lists it because it never mounts `Blobs` — that omission IS
     the payload exclusion.
   - NEW `nonisolated private static func carriesICloudContainerEntitlement(_:) -> Bool` (macOS
     only) — the existing probe body, now parameterised by container, so both containers are judged
     by one reading.
   - `hasICloudContainerEntitlement` is now that helper applied to the conversations container
     (same fail-open contract, unchanged semantics: only a SUCCESSFUL read of a list that omits the
     container returns false).
   - NEW `hasICloudBlobsContainerEntitlement` — same helper, blobs container, same fail-open rule;
     constant `true` on every non-macOS platform, as before.

5. `.../Conduck/Conduck/Services/ConversationStore.swift`
   - `configureSyncOptions(on:cloudKit:)` → `configureSyncOptions(on:cloudKit:containerIdentifier:)`.
   - `storeDescriptions(core:blobStoreURL:cloudKit:)` →
     `storeDescriptions(core:blobStoreURL:cloudKit:blobsEntitled:)`, the new parameter defaulting to
     `Constants.hasICloudBlobsContainerEntitlement` so production reads the probe and a test can
     inject. `Core` keeps `Constants.iCloudCloudKitContainerID`; `Blobs` takes
     `Constants.iCloudCloudKitBlobsContainerID` and mirrors only when `cloudKit && blobsEntitled`.
   - When `cloudKit && !blobsEntitled`, `Blobs` mounts LOCAL-ONLY and the existing NSLog style logs
     `[ConversationStore] Blobs container entitlement missing — payloads stay on this device; cards
     on other devices read as waiting`. The app never crashes on a missing second container.
   - Doc comments on `storeDescriptions`, `configureSyncOptions`, and the file-header CloudKit
     posture paragraph rewritten present-tense with the reason paired.
   - NEW `#if CONDUCK_TESTING` seam `_storeDescriptionsForTesting(core:blobStoreURL:cloudKit:blobsEntitled:)`
     — the ONLY way to observe `cloudKitContainerOptions`, which exist only before the stores load
     and are never attached on a host a suite can run on. Not widened beyond the existing seam
     pattern.

6. Entitlements — `$(CONDUCK_ICLOUD_BLOBS_CONTAINER_ID)` added to the
   `com.apple.developer.icloud-container-identifiers` array in BOTH
   `.../Conduck/Conduck/Conduck-Official.entitlements` and `.../Conduck-Community.entitlements`.
   NOT `ConduckWatch.entitlements` (never mounts `Blobs`). NOT the two share extensions — verified:
   neither carries an iCloud entitlement today and neither constructs `ConversationStore` (the only
   `ConversationStore` occurrences in `ConduckShareExtension*/SharedInboxManifest.swift` are doc
   comments), so they attach no CloudKit options.

7. `.../Conduck/ConduckTests/WorkboardTwoStoreLoadTests.swift` — new section 7 (four tests) plus a
   `mirroredDescriptions(blobsEntitled:)` helper:
   - `testTheTwoMirroredStoresCarryDifferentCloudKitContainers` — with CloudKit on, both
     descriptions have non-nil options and DIFFERENT identifiers.
   - `testEachStoreMirrorsThroughTheContainerNamedForIt` — `Core` == `Constants.iCloudCloudKitContainerID`,
     `Blobs` == `Constants.iCloudCloudKitBlobsContainerID`.
   - `testAnUnentitledPayloadContainerLeavesTheConversationMirrorOn` — `blobsEntitled: false` leaves
     `Blobs.cloudKitContainerOptions` nil while `Core` still mirrors.
   - `testThePayloadStoreStaysMountedAndHistoryTrackedWithoutItsContainer` — still 2 descriptions,
     right file, `NSPersistentHistoryTrackingKey` still on, so it starts exporting the moment the
     container exists.

8. Docs (present tense, no changelog narration):
   - `.../docs/ai-context/spec.md`, the Work decision: the payload store mirrors through a CloudKit
     container of its own (the conversations container's identifier with `.blobs` appended) because
     one container cannot mirror two stores, and the Watch's entitlements name only the first; the
     model-16 deploy sentence now says each store's half goes to its own container.
   - `.../docs/qa/desk-cloudkit-handoff.md`: release gate 1 now deploys BOTH containers' schemas to
     Production; Gate 2 gains the "zone question is answered by construction" line collapsing
     `spike-fixnote.md` §(c) step 5 to a schema confirmation; founder QA script gained item 3
     (payload container missing) with 3–12 renumbered to 4–13 and the heading now "the thirteen";
     "Decisions taken by the orchestrator" gained item 9 with the container id.

## Numbers

| Check | Result |
|---|---|
| iOS `build-for-testing` (sim `2B6E0EAC…`) | `** TEST BUILD SUCCEEDED **`, 0 compile errors |
| Targeted: `ConversationsModelMigrationTests` | 20 executed, 0 failures |
| Targeted: `WorkboardBlobPublicationTests` | 22 executed, 0 failures |
| Targeted: `WorkboardBlobSeamPlatformGuardTests` | 1 executed, 0 failures |
| Targeted: `WorkboardModelMigrationTests` | 6 executed, 0 failures |
| Targeted: `WorkboardPersistenceTests` | 7 executed, 0 failures |
| Targeted: `WorkboardTwoStoreLoadTests` | 11 executed, 0 failures (was 7; +4 new) |
| Targeted total | 67 executed, 0 failures |
| FULL iOS suite (`test-without-building`) | **5150 executed, 1 skipped, 0 failures** — baseline 5146/1/0, delta +4 = exactly the four new tests, nothing else moved |
| Watch `build-for-testing` + suite (`28AC563B…`) | `TEST BUILD SUCCEEDED`; **232 executed, 0 failures** — the expected count; `Constants.swift` compiles into the wrist unchanged |
| macOS signed build (`platform=macOS`, no `CODE_SIGNING_ALLOWED` override) | `** BUILD SUCCEEDED **`, 0 errors |
| `scripts/check-storage-seam.sh` | exit 0 (817 Swift files, no new App Group query) |
| `scripts/check-spec-cites.sh` | exit 0 |
| `scripts/check-spec-size.sh` | exit 0 — 16649 words of 16900 (was 16607) |
| `scripts/check-folder-map.sh` | exit 0 |
| `git -C "$WT" diff --check` | clean |

Simulator TCC: no row of any kind for `ai.gigaduck.AgentRelay` in the iOS sim's `TCC.db`, so
nothing needed resetting.

## The provisioning result — better than expected, and what it means

The signed macOS build did NOT fail on provisioning. Xcode's automatic signing produced a
Development profile that already names both containers, so the second container exists in the
developer portal now. Verified on the built app at
`~/Library/Caches/gigaduck-builds/blobs-container/dd-mac/Build/Products/Debug/Conduck.app`:

```
Authority=Apple Development: Peter Krueck (Z4PNDLZK98)
TeamIdentifier=J2ANN674AF

com.apple.developer.icloud-container-identifiers   (signed binary)
  iCloud.ai.gigaduck.agentrelay
  iCloud.ai.gigaduck.agentrelay.blobs

com.apple.developer.icloud-container-identifiers   (embedded.provisionprofile)
  iCloud.ai.gigaduck.agentrelay.blobs
  iCloud.ai.gigaduck.agentrelay
```

So there was no provisioning failure to report and no `CODE_SIGNING_ALLOWED=NO` retry was needed.

## The exact portal step the founder must do

Xcode created the DEVELOPMENT provisioning. Two things it cannot do:

1. **Confirm the container in the CloudKit dashboard.** Open
   [CloudKit Console](https://icloud.developer.apple.com/dashboard/) and check that
   `iCloud.ai.gigaduck.agentrelay.blobs` is listed under team `J2ANN674AF`. After the first signed
   launch that syncs, its Development schema should show `CD_WorkMaterialBlob` — and the Core
   container `iCloud.ai.gigaduck.agentrelay` should NOT. That pair of observations is what
   `spike-fixnote.md` §(c) step 5 now reduces to.
2. **Deploy the Blobs container's schema to Production** before any release build carries byte
   sync — separately from the Core container's model-16 deploy. CloudKit Console →
   `iCloud.ai.gigaduck.agentrelay.blobs` → Deploy Schema Changes. A container whose Production
   schema is missing syncs in a debug build and silently not in TestFlight/App Store, which is the
   single most common shipping failure for this API.

Also regenerate/refresh any DISTRIBUTION (App Store / TestFlight) provisioning profile before the
next upload — an existing one predates this container and will not carry it.

## Founder QA

Run these on a signed build. The first item is the one this change exists for.

1. **Launch the signed macOS app.** It opens. No `NSException`, no "Cannot assign the same iCloud
   Container Identifier to multiple stores". This was a hard crash on every launch before.
2. **Two devices, small file.** Capture on the Mac, wait on the iPhone — the card opens with its
   bytes. Payload sync is now riding the second container, so this is the first real proof of it.
3. **Missing payload container** (the graceful-degradation path, item 3 of the handoff's QA
   script). Simplest way to see it: build with a provisioning profile that predates the container,
   or before the container exists. Expect the app to LAUNCH, `Console.app` to show
   `[ConversationStore] Blobs container entitlement missing — payloads stay on this device; cards
   on other devices read as waiting`, and cards on the other device to sit at "Waiting for
   iCloud…". Recreate the container, rebuild, and the same card opens. Fail: any launch crash that
   names an iCloud container identifier.
4. **Watch.** The wrist still shows no Work card and downloads no blob. Its entitlements name only
   the conversations container, and it mounts no payload store — two independent reasons now.
5. **CloudKit Console.** `iCloud.ai.gigaduck.agentrelay.blobs` Development schema shows
   `CD_WorkMaterialBlob`; `iCloud.ai.gigaduck.agentrelay` does not.

## Nobody undo

- The two mirrored descriptions must never name one container again — that is the crash, exactly.
- `iCloud.ai.gigaduck.agentrelay.blobs` is a set-once Apple identity now, frozen like the bundle
  IDs, the App Group and the conversations container. Renaming it strands every synced payload.
- `hasICloudBlobsContainerEntitlement` must keep failing OPEN. A signed build losing payload sync
  to a failed entitlement probe is far worse than the unsigned-build crash the probe prevents.
- Never add the blobs container to `ConduckWatch.entitlements`. The wrist's exclusion is the store
  it does not mount, and its entitlement list is the second lock on the same door.
