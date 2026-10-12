
## 🧪 **Episode Contamination Prevention Testing**

### **How to Test:**

1. **Launch the App in Simulator:**
   - Open Xcode
   - Select 'StreamRadios' scheme
   - Choose iPhone 15 Pro simulator (or any iOS device)
   - Press Cmd+R to run
   - OR use: Product -> Run from Xcode menu

2. **Open Console for Monitoring:**
   - In Xcode: View -> Debug Area -> Activate Console (Cmd+Shift+C)
   - Filter by typing 'StreamRadios' in the console search box
   - Look for our contamination prevention messages

### **Quick Test Scenarios:**

#### **Test 1: Basic Feed Switching**
1. Open app -> Go to Podcast tab
2. Tap on any podcast feed (e.g., 'NPR News Now')
3. Wait for episodes to load
4. Quickly tap on another feed (e.g., 'Accidental Tech Podcast')
5. Repeat switching between 3-4 feeds rapidly

**✅ Expected Result:** Clean episode display with no contamination

#### **Test 2: Console Monitoring**
Watch for these messages in console:
- ✅ '🛡️ SETTER PROTECTION: Set X validated episodes'
- ✅ '🛡️ EMERGENCY SYNC: Forced immediate UI update'
- ❌ Should NOT see: '🚨 UI CONTAMINATION DETECTED'

#### **Test 3: Stress Test**
1. Switch feeds as fast as possible (tap rapidly)
2. Try to catch the app during transitions
3. Background/foreground the app during feed loading

### **Advanced Testing Commands:**

```bash
# Run in simulator with console output
xcrun simctl launch booted com.radio.streamradios

# Monitor system logs for our app
log stream --predicate 'processImagePath contains "StreamRadios"' --level debug
```

### **What Success Looks Like:**
- Episodes always match the selected feed
- No cross-contamination between feeds
- Smooth transitions with brief empty states (expected)
- Console shows protection messages working

## Watch Playback and Bidirectional Sync

Build and run both the iPhone and Watch apps manually in Xcode. Both must contain
the versioned sync implementation. Do not use mixed app versions to validate the
new protocol. The assistant must not build, install, or launch either app.

### Implemented Policy

- Playback activates the audio session, waits for item readiness, and completes
   the saved-position seek before starting. A 30-second stalled-start/seek deadline
   exposes a retryable error. Player-status logs are not proof of audible output.
- Manual seeks have a separate 20-second deadline, including while paused.
   Repeated skip taps replace the pending seek and accumulate from its target.
   Playback errors appear as alerts rather than remaining hidden in player state.
- The Watch target uses `StreamRadiosWatch/Info.plist` for an explicit
   `UIBackgroundModes` array containing `audio`. On launch, verify the console
   prints `[WatchPlayback] background audio enabled=true` for the installed app.
- Episode progress is checkpointed every 15 seconds and on pause, seek completion,
   episode change, interruption, and leaving the active scene. Checkpoints carry
   absolute seconds and duration as well as fractional progress.
- Each progress, episode-favorite, and station-favorite field has an independent
   persisted revision. Newer revisions win, including rewinds and favorite removals;
   equal counters use a stable device-ID tie-break. Acknowledgement means the
   receiving journal was saved, not that CloudKit has finished syncing.
   - Phone launch replays only incoming changes explicitly awaiting application,
     never historical or locally recorded journal checkpoints. Duplicate deliveries
     do not reapply completed changes. Existing journals retain their sync history
     and outbox but are not treated as pending state-restoration instructions.
- Immediate messages and queued background transfers share the same revision.
   Duplicate and reordered messages are safe; superseded queued values coalesce.
   Pending changes retry on connectivity activation, reconnection, and Watch foreground.
- Small library messages have a 55,000-byte payload threshold. Oversized snapshots
   drop embedded artwork or use file transfer. Bootstrap files group state and
   episode payloads around a 240,000-byte target plus library metadata. This is not
   a strict per-file byte ceiling. Episode seeds are capped at 400 and prioritize
   favorites and unfinished episodes before additional recent episodes.
- Episode downloads have a 256 MiB cache budget and per-file limit. The current
   episode is protected from eviction; oldest saved files are removed first.
   Completed files are excluded from backup. Downloads avoid cellular, expensive,
   and constrained connections and stop when playback starts.
- Optional charging prefetch downloads up to three recent episodes from the
   opened feed. It runs while the app can execute; downloads are not durable
   background URLSession jobs and interrupted transfers restart rather than resume.
- Cached episode rows remain visible during refresh. Feed refresh uses a 15-minute
   freshness interval and conditional HTTP validators; forced refresh bypasses both.
   Watch feed lists and metadata caches retain at most the 20 newest episodes per
   feed, including phone seeds and offline cache loads. Oversized existing caches
   are trimmed when read. The list footer directs users to the iPhone app for more
   episodes. Trimming metadata does not delete saved progress, favorites, or audio
   downloads; older episodes are no longer listed on Watch. Chapter results persist for 30 days,
   empty results for one day, with at most 200 chapter-cache files.
- Downloaded audio is preferred for playback and embedded chapters. Uncached
   audio remains network-dependent; immediate audible startup is not guaranteed.
- When no local chapters or downloaded audio are available, a reachable iPhone
   is asked for the episode's chapters. The phone uses its saved chapter metadata
   or existing ID3 reader. The Watch waits at most 20 seconds for that reply, caches
   successful results, and falls back to its own network path if unavailable.
   Both apps must be updated for this request. Errors identify the failing Watch
   source and host; Retry is available directly on the Chapters screen.
- Remote embedded chapters use bounded HTTP data chunks: a 64 KiB prefix followed,
   when necessary, by the exact ID3 tag (maximum 4,000,000 bytes plus its header).
   Range-ignoring responses are capped and cancelled; they cannot download the
   entire episode. Chapter JSON has a 20-second request and 30-second resource
   timeout, with embedded-chapter fallback on failure. Local audio is checked first.

### Device Acceptance Checks

1. Start a new episode, then one saved midway. Compare remote and downloaded
    startup using audible sound, not just the advancing timeline. Check
    `[WatchPlayback]` request IDs and elapsed session-ready/item-ready/playing logs.
2. Play for several minutes, lower the wrist, reopen Now Playing, pause, change
    episodes, and restart the app. Verify position survives and resume occurs once.
   On iPhone, also play past the previously synced position, pause, note the time,
   force-close, and reopen. Verify resume from the new position with Watch both
   disconnected and reconnected. Repeat after a deliberate Watch rewind, then
   further phone playback, to check that the old rewind is not reapplied on launch.
3. Seek backward, including to zero and from an episode marked played. Reconnect
    the phone and verify the lower position and cleared played state on both apps.
4. Toggle episode and station favorites in both directions. Repeat while the phone
    is unavailable, including add-then-remove before reconnecting. Restart both
    apps and verify removals do not reappear. Repeat with different edits on each.
5. Switch episodes rapidly during startup, retry a failed stream, disconnect and
    reconnect Bluetooth, and test interruptions. Old callbacks must not start the
    previous episode or clear the current request's state. A dead stream must not
    spin indefinitely. Check sound for at least two minutes after each resume.
6. Open chapters, leave the screen, and return. Test embedded ID3, chapter JSON,
    genuinely absent chapters, retry after network failure, and downloaded audio
    with connectivity disabled. Failure must not be presented as "no chapters".
7. Download, cancel, remove, and reopen an episode offline. Fill the cache enough
    to trigger eviction. Confirm the current file remains, failed downloads do not
    show a downloaded badge, and turning off charging prefetch stops its work.
8. Reopen a cached feed after 15 minutes and pull to refresh. Existing rows should
    stay visible while new episodes appear. Test a large initial library transfer.
   For a feed with more than 20 episodes, verify only the newest 20 appear after
   refresh, phone sync, and offline relaunch. Scroll to the iPhone footer. Check
   that shorter feeds keep all their episodes and trimming one feed does not
   change another feed or clear any saved episode progress/favorites.
9. Tap forward twice quickly, then back once: expect approximately +45 seconds.
   Repeat while paused and while streaming. Inspect `seek requested`, `seekable
   ranges`, and `seek completed` logs if the audible position does not change.
10. With the capability log confirmed true, play an episode and press the Digital
    Crown to leave the app for at least two minutes. Repeat with the wrist lowered,
    and with downloaded audio to separate network stalls from background audio.
11. For phone-assisted chapters, open the updated iPhone app, then retry chapters
   on Watch. Look for `[WatchChapters] iPhone chapters: loaded` in the Watch log.
   Reopen the chapter screen without the phone to verify the cached result.
   Also test an uncached episode with the phone unreachable. Record the podcast,
   episode title, and source-specific error if that standalone request fails.
   12. With both updated apps installed, open the iPhone app and sync the Watch.
      Check artwork on favorite/recent stations, podcast feeds, episode rows, and
      Now Playing, including items near the end of a large library. Keep an episode
      list and Now Playing open while artwork arrives; both should update without
      reopening. Matching stations in All should use the synced iTunes thumbnail.
      Look for `[PhoneWatchArtwork] queued` and `[WatchArtwork] received` counts.
      Relaunch the Watch offline to verify received thumbnails remain available.
      Artwork uses separate file transfers (up to 20 thumbnails per file, each at
      most 8 KiB), independent of the compact snapshot's artwork budget. Delivery
      timing is controlled by WatchConnectivity; URL-only artwork still needs a
      network connection.
   13. Play a music station on Watch while the phone is not playing. With usable
       artist/title stream metadata, verify live iTunes art in Now Playing, the mini
       player, and the current station row. Switch stations while a lookup is pending
       and verify that no previous station's result appears. Check a song change,
       repeated metadata, a catalog miss, and a station without track metadata.
       Logs include `radio artwork matched=` or `radio artwork lookup failed:`.
       Watch lookup uses the public iTunes API independently of the phone, with no
       Shazam fallback; missing/ambiguous metadata keeps the station artwork.
   14. For podcast failures, test a saved-position startup, network interruption,
       and an unusable downloaded file. Playback gets one fresh-player remote retry
       with the intended resume position, then a visible error if that also fails.
       Tapping Play after failure/timeout creates a fresh player. Check that pausing
       or selecting another episode prevents an old callback from restarting audio.
       If playback still fails, capture the episode and `[WatchPlayback]` failure,
       error-log, and retry lines, including the error domain/code.

### Automated Verification Scope

Watch chapter requests now opt into an immediate iPhone acknowledgement followed
by a separate chapter delivery. Requests are also queued with `transferUserInfo`
before attempting live messaging, including when the phone is unreachable.
Repeated requests for the same feed/audio URL reuse the pending transfer. A live
acknowledgement releases the Watch HTTP fallback immediately; a silent live link
delays it by at most three seconds. The phone coalesces concurrent requests and
caches up to 100 successful chapter results in memory. The phone sends live and queued copies so a
WatchConnectivity reply timeout does not discard a later successful fetch.
The Watch caches delivery by audio URL and updates only the matching feed/audio
request. The phone reads its downloaded episode file first when available.
Both apps must be updated for this protocol; legacy direct replies remain supported.
Test a slow chapter fetch, navigate to another episode before delivery, and reopen
the original episode offline. A late success should clear the error for the
original episode without replacing the newly selected episode's chapters.
The simulated-timeout loader/cache harness passed these cases. Network failures
on both devices still require Retry or a working connection; queued delivery timing
is controlled by WatchConnectivity.

For `WCErrorCodeTransferTimedOut` / IDS error 35, verify `[WatchChapters] queued
iPhone request` on Watch and `[PhoneWatchChapters] received queued request` on
iPhone. If the second never appears, chapter requests have not reached the phone;
the parser cannot fix the device link. If it appears, use the subsequent fetching
and result-count logs to distinguish phone HTTP failure from return delivery.
The request harness passed simulated live timeout, unreachable phone, queue
deduplication, immediate acknowledgement fallback, shared concurrent fetches,
and reuse of successful cached results. These do not prove device connectivity.

`SRSyncJournalTests` covers reordered/duplicate changes, rewinds, independent
favorite fields, stale acknowledgements, persisted restart, episode identity
aliases, precise positions, synchronous local staging, and case-sensitive URLs.
Its nine test bodies were executed against the shared source with standalone Swift
assertions because the package's UIKit targets prevent a macOS `swift test` run.
Restart regressions cover stale local checkpoints, legacy-journal upgrades,
duplicate incoming changes, and replay of an unapplied incoming rewind only.

The artwork batch regression in `SRLibraryModelsTests` was also executed with
standalone Swift assertions: 27 station and 24 feed thumbnails at the 8 KiB
maximum round-trip through three files below 240 KB, retaining every thumbnail
and its batch timestamp. Empty artwork produces no file batches.

Two radio lookup regression bodies cover standard/ICY/tilde metadata, station
label rejection, reversed artist/title, match ranking, and karaoke/nonmatch
rejection. A live macOS lookup returned a matching 300x300 image that decoded
successfully. Podcast recovery passed watchOS static type checking; interrupted
network playback and audio-session behavior still require Watch device testing.

The shared core passed Swift 6 type checking and all Watch source passed watchOS
SDK type checking. Phone changes passed syntax parsing and editor diagnostics,
not a full iPhone target build. Source-level chapter checks covered ID3 v2.3/v2.4,
truncation, local files, disk-cache round trips, loader retry/cancellation, and an
ATP sample with 22 chapters. These Mac checks do not establish Watch audibility,
energy use, background execution, or physical-device synchronization latency.

