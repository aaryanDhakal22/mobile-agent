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
| **Kitchen** (start screen) | Compact tickets in masonry columns, **most urgent first** (earliest promised ready time): kitchen #, type, time since the order arrived, the customer's name, **every item** (small font), **Ready** and **Reprint**. Each ticket is tinted by lateness: **green** until *green till* minutes after it arrived (agent web UI setting, default 20), then amber, **fully red at twice that**. New orders don't have a tab — they ring full-screen (below) and are accepted there. |
| **Deliveries** | Ready delivery orders (multi-select) → pick a driver → **Send out**. The picker offers only **clocked-in, available** drivers in queue order (first = preselected); with nobody clocked in it says so and points to the Drivers tab. Below: drivers out with their orders and a live run timer, and **I have returned** per driver. |
| **Drivers** | Driver roster in queue order: add, rename, remove, drag to reorder. Each driver shows **off** (clocked out) / **available** (in the queue) / **out** (on a run), the clock-in time and runs this batch. **Clock in** puts a driver at the back of the queue; **Clock out** works while they're available (out on a run → "tap I have returned first"). Shows the daily auto clock-out time ("Everyone is clocked out daily at 10:00 AM" — set in the agent web UI). **Shifts** lists the last 7 days of clock-in/out records (for reports, not wages). |
| **History** | Current batch (live) or any kept closed batch; tap an order for full detail (items with size / modifiers / notes, customer, address, kitchen #, timeline). |
| **Batch** | The open batch and **Close batch**. If orders are unfinished the agent lists them; confirm to close anyway (they're auto-finished). Kitchen numbers restart at 1100. Closing prints **one driver report per driver** on the receipt printer. Below: **Driver reports** for the open or any kept batch (deliveries, cash owed, tips after tip tax, owed to store) and **Print driver reports** to reprint. |
| **Printers** | Read-only printer reachability. Printers are configured in the Quicc web app (main), not here. |
| **Settings** | Agent address, this tablet's name, **Unpair**, alarm sound, connection + sync backlog. |

**New-order alarm.** A new order opens a full-screen alert and loops the chosen
sound on the Android *alarm* stream. Tapping does **not** silence it — it stops
only when every arrived order has been accepted. **Hide** takes the alert off
the screen (a banner stays at the top, still ringing). If an order waits more
than 2 minutes the agent sends `order.escalated`: the alert comes back, louder,
and the sound is restarted. If the player fails to start (logged), it is
retried on the next escalation / refresh. The manifest holds `WAKE_LOCK`, which
the alarm stream's `stayAwake` needs.

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

## Pairing a tablet

1. On a computer, open the agent's web UI (`http://<pi-ip>:8080`), log in, and
   go to **Settings → Pair tablet**. It shows a **6-digit code** valid for 5
   minutes.
2. On the tablet, enter the agent address (`host:port`, e.g.
   `192.168.1.219:8080`), the code, and a name for the tablet → **Pair**.
3. The tablet stores the address + device key (`shared_preferences`) and sends
   the key as `X-Agent-Device-Key` on every request.

If the tablet is revoked in the web UI, its next request gets
`401 device_required`; the app wipes the key and returns to the pairing screen.
**Settings → Unpair** revokes the key on the agent (`POST /api/device/unpair`)
and forgets it locally; if the agent is unreachable, revoke it in the agent web
UI (Settings → Counter tablets).

If the Pi's IP changes, update the address in Settings (the key is kept).

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
  main.dart, app.dart        bootstrap (prefs, wakelock), pairing gate, alarm host
  core/
    api_client.dart          AgentClient — every /api call, error mapping
    sse.dart                 SSE line parser + self-reconnecting stream
    models.dart              StoredOrder / Snapshot / Status / Driver / Shift /
                             DriverDispatch / Batch / Floor
    printer_models.dart      PrinterStatus
    floor_state.dart         FloorState + pure SSE reducer (applySseEvent)
    alarm.dart               pure alarm rule (ring while anything is arrived)
    storage.dart             shared_preferences: pairing + sound
    providers.dart           Riverpod wiring (pairing, client, floor, alarm, …)
    alert_player.dart        looping alarm sound (audioplayers)
    format.dart, json.dart   formatting + defensive JSON readers
  features/<screen>/          kitchen, deliveries, drivers (+ the dispatch
                              name flash + the driver button), history, batch
                              (+ driver reports), printers, settings, pairing,
                              order_detail, alert (+ accept controls), update
                              (forced self-update gate), home (nav rail),
                              common (shared widgets)
  theme/                     QuiccColors / QuiccPalette / QuiccTheme
test/                        model parsing, SSE parsing + reducer (incl.
                             drivers.dispatched), driver filter, alarm rule,
                             API client (MockClient), screen smoke tests
```
