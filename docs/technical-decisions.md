# Gacha Alarm — Technical Decisions

A record of the key architectural decisions made during development,
and the reasoning behind each one.

---

## 1. Native Android Alarm Execution

**Problem**
An alarm clock must fire reliably even when the phone has been sitting idle
for hours, the screen is off, and Android has aggressively killed background
processes to save battery. A pure Dart/Flutter timer does not survive this.

**Options**
- `Timer` / `Future.delayed` in Dart → killed when process dies
- `WorkManager` → not time-exact, can be deferred by OS
- `AlarmManager` (native Android) → exact, survives process death

**Decision**
Use `android_alarm_manager_plus` (wraps `AlarmManager.setExactAndAllowWhileIdle`)
combined with `flutter_foreground_task` to keep the process alive once the
alarm fires.

**Reason**
`AlarmManager` is the only Android API that guarantees exact execution at a
specific time regardless of Doze mode or process state.

**Result**
Alarms fire reliably on all tested Android versions (API 21–34), including
on OEMs with aggressive battery management (Xiaomi HyperOS, Samsung OneUI).

---

## 2. Alarm Execution Decoupled from UI

**Problem**
The alarm must be dismissable or snoozable from multiple surfaces: the
in-app `RingingScreen`, a lock-screen notification, and a Wear OS watch.
Duplicating the dismiss/snooze logic in each surface creates inconsistency
and bugs.

**Options**
- Handle actions inline in each UI component
- Extract a shared `AlarmCommandExecutor` that all surfaces call

**Decision**
All alarm actions (dismiss, snooze, auto-snooze) are routed through a single
`AlarmCommandExecutor.execute(AlarmCommandType)` static method.

**Reason**
One execution path means one place to fix bugs, one place to update business
rules (e.g. snooze cap), and trivial support for new surfaces (Wear OS was
added without touching existing screen code).

**Result**
`RingingScreen`, lock-screen notification callbacks, and the Wear OS bridge
all call the same executor. Behavior is identical across surfaces.

---

## 3. Fast Boot / Normal Boot Dual Branch

**Problem**
A full app initialization (Hive open, Supabase connect, service setup) takes
several seconds. If the alarm fires while the phone is locked, the user sees
a blank screen during that time — directly undermining the core product promise.

**Options**
- Load everything on every boot → slow ringing UX
- Lazy-load services after showing the screen → race conditions and crashes
- Detect intent at startup and take a different code path → adds complexity but solves the problem cleanly

**Decision**
`main()` reads a single `isRinging` flag from `SharedPreferences` (available
in < 5 ms) before any other initialization. If true, it enters the Fast Boot
branch; otherwise Normal Boot.

**Reason**
`SharedPreferences` is the only storage layer available before Hive is open.
Branching at the very first line of `main()` guarantees the ringing screen
gets all resources first with zero contention from other services.

**Result**
`RingingScreen` renders within ~200–400 ms of process start. Normal boot
retains full initialization with no regressions.

---

## 4. Alarm Snapshot

**Problem**
The Fast Boot branch must display the correct character image, name, and
dialogue line the instant `RingingScreen` renders — but Hive and the network
are not yet available at that point.

**Decision**
A pre-computed snapshot is prepared and stored before each alarm fires.
`RingingScreen` reads only from this snapshot during Fast Boot.

**Reason**
The snapshot decouples the ringing UI from all slow I/O. The data it needs
is always ready, regardless of Hive open time or network state.

**Result**
The ringing screen displays the correct character and dialogue with no
loading states, even on a cold process start.

> Implementation details are intentionally not documented here.

---

## 5. Offline-First with Write Queue

**Problem**
Users may dismiss alarms, earn rewards, or change settings while offline
(airplane mode, poor signal). Discarding these writes degrades trust in
the product.

**Options**
- Discard writes when offline → data loss
- Block UI until network is available → poor UX
- Queue writes locally, flush when reconnected → resilient

**Decision**
`OfflineSyncService` maintains a local queue of pending sync operations.
On reconnect, the queue is flushed in order. Hive acts as the source of
truth for local state at all times.

**Reason**
The app's core loop (wake up → earn reward → see it reflected) must work
end-to-end even without a connection. Cloud sync is eventual, not required.

**Result**
Rewards and profile changes are never lost. The cloud catches up
automatically when connectivity is restored.

---

## 6. Supabase as Backend

**Problem**
The app needs user authentication, a shared database for leaderboards and
mail, real-time data updates, and server-side validation logic — all without
a dedicated backend team.

**Options**
- Firebase → good ecosystem, but vendor lock-in and row-based pricing
- Custom REST API → full control, but requires server infrastructure and maintenance
- Supabase → PostgreSQL-native, open source, supports RPC, Realtime, and Auth

**Decision**
Supabase for all backend needs: Auth (Google Sign-In), PostgreSQL (user data,
leaderboard, mail), Realtime (live leaderboard), and RPC (server-side
validation functions).

**Reason**
Supabase provides every required capability without a separate server.
PostgreSQL RPC functions allow server-side validation logic to run close to
the data with full transactional guarantees — something Firebase cannot do
without Cloud Functions.

**Result**
Zero backend infrastructure to maintain. RPC calls enforce data integrity
server-side. Realtime subscriptions power the live leaderboard with no
polling.

---

## 7. Wear OS via MethodChannel

**Problem**
Flutter has no first-party Wear OS SDK. The Wear OS companion app is a
separate native Android module that needs to exchange alarm data and receive
dismiss/snooze commands from the phone.

**Options**
- HTTP between phone and watch → requires network, fragile
- `flutter_blue_plus` BLE → too low-level, not suitable for this use case
- Android `MethodChannel` → direct Dart ↔ native bridge, no network required

**Decision**
All phone ↔ Wear OS communication goes through a named `MethodChannel`
(`gacha_alarm/wear_os`). The Flutter side calls methods to push alarm config
and dialogue; the native side receives Wear OS actions (dismiss, snooze) and
routes them back through the same channel.

**Reason**
`MethodChannel` is the standard Flutter mechanism for calling native Android
code. The Wear OS Data Layer API (used on the native side) is the official
Google-recommended transport for phone ↔ watch messaging — reliable,
low-latency, and works without internet.

**Result**
Users can dismiss or snooze alarms from the watch with sub-second response.
The native layer handles all Wear OS lifecycle concerns; Flutter code stays
platform-agnostic.
