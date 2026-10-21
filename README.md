# Quibase — the QuiccPOS counter tablet app

(This folder / repo is still called `mobile-agent` and the Dart package
`mobile_agent`; the app itself is **Quibase**, Android id `com.quiccpos.quibase`.)
Tested on the staging tablet (`192.168.1.217`) against the staging Pi.

Flutter app for the restaurant's counter tablet (Android, landscape, always
on). It talks **only** to the restaurant **agent** on the LAN (the Go binary on
the Pi) — never to `main/` or `online/`. The agent's API is specified in
`../contract/agent.md` §2; the order JSON inside it in `../contract/main.md` §10.1.

## What it does

| Tab | What staff do there |
|---|---|
| **Kitchen** (start screen) | Compact tickets in masonry columns, **most urgent first** (earliest promised ready time): kitchen #, type, time since the order arrived, the customer's name, **every item** (small font), **Reprint receipt** (the customer receipt only), **Resend to kitchen** (1.3.5: every kitchen ticket again, `POST /api/orders/{id}/kitchen`, always asks "Send to the kitchen again?" first; an older Pi says it needs an update) and **Ready**. The order details screen has the same two buttons (Resend once the order has a kitchen number). Each ticket is tinted by lateness: **green** until *green till* minutes after it arrived (agent web UI setting, default 20), then amber, **fully red at twice that**. New orders don't have a tab — they ring full-screen (below) and are accepted there. |
| **Deliveries** | Ready delivery orders (multi-select), each with its total and **CASH $x** to collect or **PAID** → pick a driver → **Send out**. The picker offers only **clocked-in, available** drivers in queue order (first = preselected); with nobody clocked in it says so and points to the Drivers tab. Below: drivers out with their orders and a live run timer, and **I have returned** per driver. |
| **Drivers** | Driver roster in queue order: add, rename, remove, drag to reorder. Each driver shows **off** (clocked out) / **available** (in the queue) / **out** (on a run), the clock-in time and runs this batch. **Clock in** puts a driver at the back of the queue; **Clock out** works while they're available (out on a run → "tap I have returned first"). Shows the daily auto clock-out time ("Everyone is clocked out daily at 10:00 AM" — set in the agent web UI). **Shifts** lists the last 7 days of clock-in/out records (for reports, not wages). |
| **History** | Current batch (live) or any kept closed batch; tap an order for full detail (items with size / modifiers / notes, customer, address, kitchen #, timeline, what was paid and the **CASH DUE**). |
| **Batch** | The open batch and **Close batch**. If orders are unfinished the agent lists them; confirm to close anyway (they're auto-finished). CLOSE ANYWAY asks the agent again first: an order that came in while the list was open shows the list again (marked NEW) instead of being cancelled unseen. Kitchen numbers restart at 1100. Closing prints **one driver report per driver** on the receipt printer. Below: **Driver reports** for the open or any kept batch (deliveries, cash owed, tips after tip tax, owed to store) and **Print driver reports** to reprint. |
| **Printers** | Read-only printer reachability. Printers are configured in the Quicc web app (main), not here. |
| **Settings** | Big-button cards, each with an (i) explaining it in plain words: **Continue setup** (while the setup wizard is unfinished); **The Pi** — its address, checked live as you type ("Found the Pi ✓ — *store*" / "Nothing there ✗"; a bare IP gets `:8080`), SAVE keeps the pairing, plus live / last sync / sync backlog; **This tablet** — its name with **Rename** (saved on the Pi too), **Pair another tablet** (a 6-digit code from the Pi, shown big with an expiry countdown and the steps for the new tablet: open Quibase → pick this Pi → I have a code → type it), **Unpair**; **Order chime** (sound + preview); **Receipts** — kitchen-ticket item / number size, the customer receipt's footer (store default, own text or none) and its size, copies (1 / 2), store name + address, customer phone, extra paper before the cut; SAVE, **PRINT SAMPLE** on a chosen printer (default the receipt printer; unsaved changes are saved first) and RESET TO DEFAULTS (`/api/settings/receipt`, `/api/printers/sample`; an older Pi shows "This Pi needs an update for receipt settings"); **Checks & tests** (tablet checks, test ring, test print); **Light / Dark / System** (remembered across restarts; the `q` logo still toggles light ↔ dark); **About & diagnostics**. |

**New-order alarm.** A new order opens a full-screen alert and loops the chosen
sound on the Android *alarm* stream. Tapping does **not** silence it — it stops
only when every arrived order has been accepted. **Hide** takes the alert off
the screen (a banner stays at the top, still ringing). If an order waits more
than 2 minutes the agent sends `order.escalated`: the alert comes back, louder,
and the sound is restarted. If the player fails to start (logged) or stops
by itself, it is retried on the next escalation / refresh. The chime asks for
no audio focus, so another app playing sound can't pause it. The manifest
holds `WAKE_LOCK`, which the alarm stream's `stayAwake` needs.

**Errors in plain words.** Anything that goes wrong is shown as a short
sentence plus what to do ("Can't reach the Pi — check the tablet is on the
store Wi-Fi and the Pi is on"), never the raw agent text: that sits behind a
small **Details** link and is written to the on-tablet log that rides along
with diagnostics. When a troubleshooting guide fits, the error offers
**FIX IT**. The Drivers and Batch tabs have (i) icons explaining clock in/out,
the queue, removing a driver, closing a batch and how the driver report adds
up; the driver button has one too (not the Kitchen screen).

**Driver button** (bottom-right on every tab but Settings — the old app's
queue button). Collapsed: a truck with a badge = drivers out on a run. Tap it:
a pill per driver who is **out**; tap a pill when they walk in = **I have
returned** (their run is delivered, they go to the back of the queue). The big
button shows who is **NEXT**. **Hold it 2 s** to undo the last return (the
agent allows it for 10 minutes; the driver is out again, their orders stay
delivered). Tap outside to close.

**Updates (forced).** The console's **Release Quibase** uploads a signed APK
to main; the agent caches it and the tablet (checking on start, resume,
reconnect and every 10 min) locks behind **Updating Quibase**, downloads it
from the agent, checks its sha256 and opens Android's installer — one tap on
**Install**. The first time, Android asks to allow installs from Quibase
(**Allow installs** → switch on → back). Releases are pushed after close.
The new-order alert stays **above** the lock, so an order can always be
accepted. A release withdrawn on the agent (or no longer newer than what's
installed) unlocks the tablet at the next check. After 2 failed attempts
(download, damaged file, installer cancelled / failed) **LATER** hides the lock
for an hour, so a broken APK can't take the counter down. Older APKs in the
cache are deleted when a new one is downloaded. After the install Quibase
comes back by itself (`RestartReceiver`, below) — nobody needs to open it.

**Driver name flash.** When a driver is sent out (from this tablet or anywhere
else — SSE `drivers.dispatched`) the driver's name fills the screen with the
kitchen numbers of their run, over every screen, so the driver at the counter
knows it's theirs. It closes after 8 s or on a tap. The new-order alert stays
on top of it if both are up.

**Live data.** The app holds an SSE connection to `GET /api/events` (auto
reconnect with 1 s → 30 s backoff, dropped after 70 s of silence) and refetches
`/api/floor`, `/api/orders?batch=current`, `/api/orders/arrived` and
`/api/drivers` on every (re)connect, plus every 20 s as a fallback (the batch is
paged 200 at a time, up to 2000 orders). If the agent closes the stream (e.g.
the tablet fell behind) the app reconnects and refetches. A late or repeated
`order.arrived` for an order already taken never flips it back. The dot under
the logo is green (live), amber (connecting) or red (retrying).

The screen is kept on with `wakelock_plus`. There is no auto-accept in the app.

## First-time setup (the wizard)

A fresh install (or a tablet that lost its pairing) opens a step-by-step setup
for the **store manager** — big buttons, plain words, an (i) on every step:

1. **Welcome**.
2. **Find the Pi** — lists the Pis on the Wi-Fi (UDP broadcast to the agent's
   discovery port 48080, plus the saved address and the `quiccpos-pi`
   hostname; a /24 sweep of `:8080/api/version` if nothing answers). "My Pi
   isn't listed" takes a typed address (a bare IP is enough — `:8080` is added).
3. **Sign in** — a **new Pi** is set up with the store manager login (the Pi
   links to the store, restores the open batch and pairs this tablet in one
   call; no internet yet → it retries every 15 s); an already set-up Pi is
   joined with a **6-digit code** from another tablet (Settings → Pair another
   tablet) or the agent web UI.
4. **Tablet checks** — notifications, full-screen alerts, battery saving off,
   app updates allowed, alarm volume; each opens the right Android screen and
   re-checks on return.
5. **Pi ready** — what was restored, then the Pi's internet / connection to
   Quicc / memory card / power and each printer as it comes online.
6. **Test ring** ("Did you hear it?", plus a screen-off test) and
7. **Test print** (a TEST slip per printer, no failover; FIX IT → printer guide).

   Both 5 and 7 (when no printers are set up) show **Found on the network**
   (1.3.4): printers the Pi found on TCP 9100 that the store doesn't have yet
   (`GET /api/printers/found`, SCAN AGAIN = `?refresh=1`), each with ADD →
   name it (chips Online / Pizza / Desi / Sub / Wings / Kitchen) →
   `POST /api/printers/add` (the Pi asks main; the first printer becomes the
   receipt printer). A Pi without these routes hides the section.
8. **Drivers** ("Who drives tonight?") and the **order chime**.
9. **All set** → START TAKING ORDERS (sends a setup report to the owner).

Progress is saved on every step (`setup_progress_v1`, never the password);
after pairing, **Finish later** lets the counter work and Settings offers
CONTINUE. Orders ring during the wizard too. Code: `lib/features/setup/`.

A tablet upgraded from 1.2.0 skips the wizard and gets a one-time "Quick tablet
check" prompt.

If the tablet is revoked in the web UI, its next request gets
`401 device_required`; the app wipes the key and returns to "Find the Pi".
**Settings → Unpair** revokes the key on the agent (`POST /api/device/unpair`).

## Ringing with the screen off ("ring anywhere")

`QuibaseApp.kt` keeps one Flutter engine for the whole process and
`RingService.kt` (a `specialUse` foreground service, "Listening for new
orders") keeps that process alive, so the SSE connection and the alarm keep
running when the app is in the background, swiped away or the screen is off.
The alarm is driven at the ProviderContainer level (`core/ring_bridge.dart`),
not by a widget. A new order nobody sees posts a full-screen notification:
over the lock screen it opens Quibase and turns the screen on; over another app
it's a heads-up, like a call. The chime plays on the alarm stream.

`RestartReceiver.kt` brings it all back after a **tablet reboot**
(`BOOT_COMPLETED`) and after a **self-update** (`MY_PACKAGE_REPLACED` — the
installer kills the process): the broadcast starts the process (so
`QuibaseApp` starts the engine and Dart connects to the Pi) and the receiver
starts `RingService` at once, inside Android's short window for starting a
foreground service from these broadcasts. On an unpaired tablet the Dart side
stops the service again. Quibase isn't direct-boot aware, so it starts after
the first unlock (no `LOCKED_BOOT_COMPLETED`); a tablet with no screen lock
unlocks by itself. A ring notification left over from before a restart is
taken down when nothing is waiting.

## Help and troubleshooting

The **Help** tab has four step-by-step guides with drawings — *Can't reach the
Pi*, *Printer problem*, *No orders coming in*, *Swap the Pi card / pair a
tablet* — that run automatic checks, ask only what can't be sensed, and re-test
after each step (TEST AGAIN). FIX IT buttons on the red Pi banner, the warning
bars (printer down, no orders while open, alarm quiet, tablet checks) and error
messages open the right guide. Every conclusion and **Send diagnostics to the
owner** sends a report: via the Pi, else straight to main with a report-only
key, else an outbox retried later. Code: `lib/features/diagnose/`,
`lib/features/illustrations/`.

**Cash vs prepaid.** One rule, the same as the agent's receipt: cash to
collect = the sum of the payments whose method is `cash` (main sends cash
owing as an explicit cash payment; part-paid = card + cash); an older order
with **no payments at all** is cash for the whole total; `other` (third party /
invoice) is prepaid. Prepaid = nothing to collect (`OrderSnapshot.cashDueCents`
/ `isPrepaid`).

## Build / run

Flutter (stable, Dart ≥ 3.11).

```bash
flutter pub get
flutter analyze
flutter test                      # unit tests + screen smoke tests (offline)
flutter run -d <android-device>   # debug on a connected tablet
flutter build apk --release --target-platform android-arm64   # signed with ~/.quibase
```

**Release signing.** The release key is `~/.quibase/quibase-release.jks` +
`~/.quibase/key.properties` (outside the repo; override with
`QUIBASE_KEY_PROPERTIES`). **Back up `~/.quibase`** — a tablet only accepts
updates signed with the key it was installed with; losing it means
uninstalling + re-pairing every tablet. Without it Gradle falls back to the
debug key (CI, tests). Releases go through the console (`Q` — Release
Quibase); version code = Unix seconds, version name = pubspec's x.y.z.

Cleartext HTTP to the LAN agent is allowed (`usesCleartextTraffic` in the
Android manifest).

## Layout

```
lib/
  main.dart, app.dart        bootstrap (prefs, ring bridge, wakelock), setup gate, alarm host
  core/
    api_client.dart          AgentClient — every /api call, error mapping
    sse.dart                 SSE line parser + self-reconnecting stream
    models.dart              StoredOrder / Snapshot / Status / Driver / Shift /
                             DriverDispatch / Batch / Floor
    printer_models.dart      PrinterStatus
    floor_state.dart         FloorState + pure SSE reducer (applySseEvent)
    alarm.dart               pure alarm rule (ring while anything is arrived)
    storage.dart             shared_preferences: pairing, sound, theme, …
    friendly_error.dart      any error → title / what to do / details / guide
    local_log.dart           on-tablet log (last 300 lines) for diagnostics
    providers.dart           Riverpod wiring (pairing, client, floor, alarm, …)
    ring_bridge.dart         alarm → chime + full-screen notification + service
    ring_platform.dart       quibase/ring channel (RingService.kt)
    device_platform.dart     quibase/device channel (tablet checks)
    discovery.dart           find Pis on the LAN
    diag_models.dart         /api/diag, printer test, pairing code, report token
    receipt_models.dart      ReceiptPrefs (receipt settings) + the GET/PUT answer
    alert_player.dart        looping alarm sound (audioplayers)
    format.dart, json.dart   formatting + defensive JSON readers
  features/<screen>/          kitchen, deliveries, drivers (+ the dispatch
                              name flash + the driver button), history, batch
                              (+ driver reports), printers, settings, setup,
                              diagnose (Help + guides), illustrations,
                              order_detail, alert (+ accept controls), update
                              (forced self-update gate), home (nav rail),
                              common (shared widgets)
  theme/                     QuiccColors / QuiccPalette / QuiccTheme
test/                        model parsing, SSE parsing + reducer (incl.
                             drivers.dispatched), driver filter, alarm rule,
                             API client (MockClient), screen smoke tests
```
