# CarPlay Simulator rig — voice QA

How to test Conduck's CarPlay voice surface on a desk rig, and how to read its
one recurring failure. The rig is Apple's **CarPlay Simulator** app (from the
"Additional Tools for Xcode" download, `Hardware/` folder) on a Mac, with a
physical iPhone attached by cable. The app runs on the real phone, so this
exercises the true audio stack — but the *car side* is simulated, and Apple
recommends real CarPlay hardware for final validation. Treat the rig as
authoritative for UI, navigation, and session lifecycle; treat real-car runs as
authoritative for voice timing and HFP route behavior.

## Pre-flight, in order

1. **If a previous run ever showed `engine.start failed … 1852797029`
   ('nope'): reboot the iPhone before concluding anything.** That refusal is a
   wedged `mediaserverd`/RemoteIO state on the phone; it persists across app
   relaunches and CarPlay reconnects until the device reboots. Testing on a
   wedged phone reproduces the failure forever and proves nothing about the
   build.
2. **Verify Siri (or keyboard dictation) hears you on the phone** before
   testing Conduck. If the system's own microphone path is dead, the problem
   is below the app.
3. **Mac side:** System Settings → Privacy & Security → Microphone must allow
   the CarPlay Simulator app, and the Mac's selected input device must work.

## The failure signature

One cascade accounts for the rig's "CarPlay just crashed" reports. In the
app's log (subsystem = the app's identity namespace, category
`CarPlayCapture`/`CarPlayScene`):

```
CarPlay engine.start failed (attempt 0): … code=1852797029 …   ← FourCC 'nope'
Connection interrupted            (XPC)
sceneWillResignActive …
Connection invalidated            (mediaserverd)
```

…then the whole CarPlay connection drops to reconnect. The app process
survives — this is not an app crash. `CarPlayRecordingService`'s header and
`startCaptureEngineWithRetry` document the mechanism and the recovery ladder;
every start-path exit now logs exactly one line, so the log always says which
guard ended the attempt.

## Reading a failure

| Observation | Read it as |
|---|---|
| 'nope' at attempt 0 on a rig that worked before, phone not rebooted since an iOS update or a prior wedge | OS-level wedge — reboot first; not a build regression |
| 'nope' only after a prior Conduck session, log shows `listen abort: session ended during engine start` or a stale-service teardown line | The stale-commit/observer guards fired — capture the log and file it; the guards exist precisely so this cannot wedge the phone |
| Scene resigns with **no** preceding `ROUTE CHANGE` / `INTERRUPTION` line | CarPlay-host (Simulator) limitation, not an audio-driven bug — the open question `CarPlaySceneDelegate.sceneWillResignActive`'s comment tracks |
| `ROUTE CHANGE … state=nil` lines | A leaked service instance survived a disconnect. Should no longer occur; if seen, file it with the log |
| Picker shows the one-shot "Mic couldn't start" row | The session ended on an activation/engine-start failure with the scene alive — the deliberate visible form of a silent end |

## Capturing logs

`log` is zsh-shadowed in this repo's shells — use the absolute path:

```
sudo /usr/bin/log show --last 10m \
  --predicate 'subsystem == "<identity namespace>" AND category IN {"CarPlayCapture","CarPlayVAD","CarPlayScene"}'
```

`CarPlayVAD` prints the first raw speech probabilities per listen — sane
nonzero values mean "the driver was quiet"; all-zero/NaN means "the VAD never
saw audio". `CarPlayCapture` distinguishes a dead mic from a converter failure
from an engine refusal.
