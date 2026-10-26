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
| **Kitchen** (start screen) | Tickets in masonry columns, **most urgent first** (1.6.0: fewer, larger tickets — three columns on the 1280×800 tablet, about six on screen; the kitchen # and the timer in JetBrains Mono, items a step above body size; a **›** at the end of the card bar shows that tapping a ticket opens the order details) (earliest promised ready time). Each ticket (1.5.0) is a white "paper" body under a **card bar** in the lateness colour: the bar holds the big number (kitchen #, or the POS check # with a **POS** tag for a POS order; an online order the hub put into the POS also shows *POS #n*), **PAID** when settled, and the order type. The body: time since the order arrived, minutes left and the promised ready time (**LATE n min** past it), the customer's name, an order **flag** if any (e.g. "Settle manually: …", in the severity colour), **every item** (small font), the notes, then two icon buttons — **Reprint receipt** (the customer receipt only) and **Resend to kitchen** (1.3.5: every kitchen ticket again, `POST /api/orders/{id}/kitchen`, always asks "Send to the kitchen again?" first; an older Pi says it needs an update) — and **READY**. The order details screen has the same two buttons (Resend once the order has a kitchen number). Lateness: **green** until *green till* minutes after it arrived (agent web UI setting, default 20; a POS order counts from when the cashier pressed Send), then amber, **fully red at twice that**. A paid ticket that isn't ready (paid pickup, POS counter order) gets a slow soft green **paid wave** (feature switch). POS counter checks with nothing for the kitchen stay off the board (`board_hidden`). Scheduled **future orders** wait greyed in the **Later · N** strip at the end (due time, when it rings again, lead; tap = change the lead time). New orders don't have a tab — they ring full-screen (below) and are accepted there. |
| **Deliveries** | (1.4.0) Two columns. **Left — Unassigned · N**: delivery orders that are cooking (greyed, "ready in ~4 min") or ready and in nobody's pool, oldest placed first: kitchen #, customer, address, **2.3 mi · 7 min** (amber *approx* / red *outside area* tags; *locating…* / *no location* while main hasn't found it), tip, **CASH $x** / **PAID** and minutes since placed (amber 10 min before the delivery target, red past it). **Right**: one box per **available** driver in queue order (**NEXT** on top; no reordering here), each holding that driver's **pool** — chips with kitchen #, street, tip, mi · min, tags and ✕ (back to the left) — and **SEND OUT** (asks "#1104 isn't marked ready — send anyway?" when something is cooking; yes marks it ready; the name flash follows). Fill pools by **long-press drag** (left → driver, driver → driver, driver → left) or **SELECT** (tap deliveries, then tap a driver box — or the left column to unassign; a bar shows "N selected · CANCEL"). Tapping a driver's name opens the **run map**. Below: **Out** — each driver out with a run timer, their kitchen numbers (tap = the order) and **I HAVE RETURNED**. A single tap on any delivery opens it. **AUTO** asks the Pi for fair, route-aware runs for every available driver: the suggestions slide into the boxes with a **yellow glow** and nothing is saved until **CONFIRM** — an edited preview confirms only the stops still showing (`order_ids`) — (**CLEAR** drops them; *estimated (offline)* when the Pi had to guess drive times). Send Out on a driver with yellow stops sends those too. The preview drops itself (with a toast) if the floor changes under it. Pools live on the Pi (`/api/deliveries/pool`, `/api/drivers/{id}/send-out`, `/api/deliveries/auto-plan[/{id}/confirm]`). |
| **Drivers** | Driver roster in queue order: add, edit (name + **Driver #** — optional, 1.5.0; the in-app help says "their SoftTouch login number", but at Lombardi's it is the driver's SoftTouch **Employee Number** — the hub matches `EMPLOYEENUMBER`, CUTOVER §3a — and the hub writes it onto the POS check when the driver goes out), remove, drag to reorder. Each driver shows **off** (clocked out) / **available** (in the queue) / **out** (on a run), the clock-in time and runs this batch. **Clock in** puts a driver at the back of the queue; **Clock out** works while they're available (out on a run → "tap I have returned first"). Shows the daily auto clock-out time ("Everyone is clocked out daily at 10:00 AM" — set in the agent web UI). **Shifts** lists the last 7 days of clock-in/out records (for reports, not wages). |
| **History** | Current batch (live) or any kept closed batch; tap an order for full detail (items with size / modifiers / notes, customer, address, kitchen #, timeline, what was paid and the **CASH DUE**). |
| **Batch** | The open batch and **Close batch**. If orders are unfinished the agent lists them; confirm to close anyway (they're auto-finished). CLOSE ANYWAY asks the agent again first: an order that came in while the list was open shows the list again (marked NEW) instead of being cancelled unseen. Kitchen numbers restart at 1100. Closing prints **one driver report per driver** on the receipt printer. Below: **Driver reports** for the open or any kept batch (deliveries, cash owed, tips after tip tax, owed to store) and **Print driver reports** to reprint. |
| **Printers** | Read-only printer reachability. Printers are configured in the Quicc web app (main), not here. |
| **Settings** | Big-button cards, each with an (i) explaining it in plain words: **Continue setup** (while the setup wizard is unfinished); **The Pi** — its address, checked live as you type ("Found the Pi ✓ — *store*" / "Nothing there ✗"; a bare IP gets `:8080`), SAVE keeps the pairing, plus live / last sync / sync backlog; **This tablet** — its name with **Rename** (saved on the Pi too), **Pair another tablet** (a 6-digit code from the Pi, shown big with an expiry countdown and the steps for the new tablet: open Quibase → pick this Pi → I have a code → type it), **Unpair**; **Order chime** (sound + preview); **Receipts** — kitchen-ticket item / number size, the customer receipt's footer (store default, own text or none) and its size, copies (1 / 2), store name + address, customer phone, extra paper before the cut; SAVE, **PRINT SAMPLE** on a chosen printer (default the receipt printer; unsaved changes are saved first) and RESET TO DEFAULTS (`/api/settings/receipt`, `/api/printers/sample`; an older Pi shows "This Pi needs an update for receipt settings"); **Deliveries** — AUTO's delivery target (15–120 min, default 45) and "soon ready" minutes (0–30, default 5), − / + and SAVE (`PUT /api/settings/deliveries`); **Default times** (1.5.0) — X for pickup / dine-in (default 15) and Y for delivery (default 35), 1–240 min, where the accept time picker starts (`PUT /api/settings/times`); **Features** — six switches saved one by one on the Pi (`/api/settings/features`): *POS orders pull-in*, *Online order insert*, *Driver write-back*, *Address heal*, *Future orders*, *Paid wave*; **Kitchen tickets** — which orders print station tickets by themselves (`/api/settings/tickets`): POS delivery / takeout / counter (usually off — SoftTouch prints those), online cash pickup, online cash delivery, online card (an older Pi shows "This Pi needs an update for these switches"); **Checks & tests** (tablet checks, test ring, test print); **Light / Dark / System** (remembered across restarts; the `q` logo still toggles light ↔ dark); **About & diagnostics**. |

**Accepting (1.5.0).** The full-screen alert and the order details use one
**time picker**: three buttons **X / X+5 / X+10** (X = the store's default
time for the order type, preselected, so one CONFIRM tap is enough) with
− / + beside X+10 (never below X+10, up to 240). A **future order** (the Pi
marks it `future`: promised later than now + its default time) uses the same picker
on its first ring to set the **lead time** (`POST /api/orders/{id}/schedule`
— nothing prints; it goes to the Later strip); when it rings again
(`rerung`) one CONFIRM prints it with the lead picked before. A timed-out
accept is read back from the Pi before the tablet says it failed.

**Accepting a delivery (1.6.0).** A delivery's normal ring has no X / X+5 /
X+10: one big **ACCEPT · Y MIN** (Y = the store's default delivery time) with
small **−5 / +5** nudges beside it (5 … 240 min). Pickups and the future-order
cases are unchanged. On the full-screen alert a **read-only map** sits right
under the waiting timer (fixed height, nothing to tap: no gestures, buttons,
tooltips or pin mode — the alert lives above the Navigator, with no Overlay):
store, door, route line, **2.3 mi · 7 min** and the *approx* / *outside area*
tags. While main is still locating the address, or it wasn't found, or the Pi
has no map file yet, the map is one slim line instead.

**Version header (1.6.0).** Every request to the Pi, and the `/api/events`
stream, carries `X-Quibase-Version: <versionName>+<versionCode>` (read once
from the Android side; left off until it is known, e.g. in a process started
headless before the Activity). The Pi ignores it until 2.2.0.

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

## POS orders and hub alerts (1.5.0)

With **quicc-hub** (the store's bridge to the old SoftTouch POS, Pi 2.1.0)
checks the cashier sent arrive as SSE `order.added`: already accepted, they
**never ring** — a new POS delivery plays a gentle **soft chime** once on the
notification stream (`core/soft_chime.dart`). They show the POS check # with
a POS tag, **PAID** when settled at the terminal, and the cash the hub read
off the check (`cash_due_cents`); they are `local_only` (never synced to
main). POS deliveries join the Deliveries columns and pools like any other.
With *POS orders pull-in* off the tablet hides them (the Pi keeps them). An
order the hub couldn't map carries a **flag**; the order details also show
"POS says #12 (not clocked in)" when the POS's driver disagrees.

The hub's problems come through the Pi: **info / warn** as a toast in the
top-right corner (once per problem, fades by itself; SSE `integration.toast`
too), **serious** ones ("POS link down", "Quicc batch not open in SoftTouch")
as a full-width banner under the warning bars until the hub clears them.
Code: `lib/features/integration/`.

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
8. **Drivers** ("Who drives tonight?", each with an optional Driver #),
   **Default times** ("How long do orders usually take?" — X / Y for the
   time picker; an older Pi offers SKIP) and the **order chime**.
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

## Maps (1.4.0)

Every delivery's detail has a **map** above the address: the store, the
customer's door and the driving route (from main, OSRM), "2.3 mi · 7 min",
amber *approximate location* / red *outside delivery area* tags, pan + zoom,
a recenter button; light or dark with the app. *Locating…* while main is
still looking (geo `pending`). **Not found** → "Not found on the map — tap to
place pin"; never located (geo `unavailable`) → "No map location — tap to
place pin":
tap where the door is, **SAVE PIN** (`POST /api/orders/{id}/pin`; main
remembers it for the address and the route arrives as an order update). A
located order can be re-pinned too (pin button). **Check address** (1.5.0):
when main found more than one place for the address (geo `check`), an amber
CHECK ADDRESS tag / button offers up to 3 candidates
(`POST /api/orders/{id}/geo/choose`) or a full-screen pin. Without a map file on the Pi
yet: a plain card with the distance and "Map not downloaded yet". The **run
map** (driver name on the Deliveries screen) numbers the pool's stops in the
fastest driving order (`GET /api/drivers/{id}/pool/trip`), with the route
and total miles and minutes — or straight dashed lines marked *approximate*
when main can't be reached.

The streets come **only from the Pi** (`GET /api/map.pmtiles`, a small
offline Protomaps v4 file with Range requests) — no internet map service, no
glyph or sprite downloads: `flutter_map` 7 + `vector_map_tiles` 8 +
`vector_map_tiles_pmtiles` 1.5.0, drawn in **vector** layer mode (raster mode
draws nothing on Android with Impeller). The upstream Protomaps v4 style
labels with `format` expressions vector_tile_renderer 5 can't evaluate, so
`map_layers.dart` rewrites every label to the tile's English / local name in
the tablet's font and drops icons (`offlineProtomapsLayers`). Tests stub the
tile layer (`mapBaseLayerProvider`); `test/map_file_integration_test.dart`
checks a real file when `QUIBASE_MAP_URL` points at one. Code:
`lib/features/maps/`.

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

**Cash vs prepaid.** A POS order: the hub's `cash_due_cents` (0 once
**PAID**). An online order — one rule, the same as the agent's receipt: cash to
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
    soft_chime.dart          one-shot soft chime for a new POS delivery
    format.dart, json.dart   formatting + defensive JSON readers
    delivery_models.dart     AUTO plan / confirm / pool trip / delivery settings
    auto_preview.dart        the AUTO yellow preview (tablet memory only)
    polyline.dart            Google encoded polyline decoder (routes)
  features/<screen>/          kitchen, deliveries, drivers (+ the dispatch
                              name flash + the driver button), history, batch
                              (+ driver reports), printers, settings, setup,
                              diagnose (Help + guides), illustrations,
                              order_detail, maps (delivery map, run map,
                              offline tiles, check address), alert, arrived
                              (accept controls + time picker), integration
                              (hub toasts + banner), update
                              (forced self-update gate), home (nav rail),
                              common (shared widgets)
  theme/                     QuiccColors / QuiccPalette / QuiccTheme
test/                        model parsing, SSE parsing + reducer (incl.
                             drivers.dispatched), driver filter, alarm rule,
                             API client (MockClient), screen smoke tests,
                             POS / future-order models + widgets (release_150_*)
```
