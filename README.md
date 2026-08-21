<div align="center">

# ⏰ Gacha Alarm

**Wake up — not because you have to, but because your companion is waiting.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Supabase](https://img.shields.io/badge/Supabase-Backend-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com)
[![Hive](https://img.shields.io/badge/Hive-Local%20DB-FFD700)](https://pub.dev/packages/hive)
[![Version](https://img.shields.io/badge/Version-1.0.2%2B59-blueviolet)](./pubspec.yaml)
[![Platform](https://img.shields.io/badge/Platform-Android-brightgreen?logo=android)](https://android.com)
[![Google Play](https://img.shields.io/badge/Google%20Play-Download-414141?logo=google-play&logoColor=white)](https://play.google.com/store/apps/details?id=com.solodev.gacha_alarm)
[![License](https://img.shields.io/badge/License-Proprietary-red)](#-license)

</div>

---

## 📖 Overview

**Gacha Alarm** is a fully gamified alarm clock app built in the style of an Anime/Gacha RPG. Instead of mindlessly hitting snooze and falling back asleep, Gacha Alarm turns waking up into a **journey of collecting characters, building relationships, and uncovering a story**.

Every on-time wake-up is rewarded. Every character has a unique personality and voice. Every year of use tells a different story.

---

## ✨ Key Features

### ⏰ Smart Alarm & Wake-Up System
- **D3 — Dynamic Dialogue Delivery**: Your companion calls you awake with dialogue matching their personality (Tsundere, Friendly, Evil, Soft...). The dialogue escalates in intensity based on how many times you've snoozed.
- **Ultra-Fast Boot**: The ringing screen launches even when the phone is locked, prioritizing display speed above everything else.
- **Stale Alarm Recovery**: Automatically restores app state if an alarm gets "stuck" for more than 5 minutes.
- **Wake-up Rewards**: Dismiss on time → earn gacha tickets (up to 6/day). Affinity points are granted once per day with server-side validation.
- **Snooze Limit**: Snooze is capped at 2 times per alarm. After that, the alarm escalates to the "Ignored" event type, triggering a different character dialogue.

### 🎲 Gacha Summoning System
- **Single & Multi (x10) pulls** with animated card flip effects and special summon video cutscenes.
- **7 Rarity Tiers**: F → E → D → C → B → A → SR. The top tier **SR++** characters require collecting 3 Shards to unlock (see below).
- **SR++ Shard System**: Rolling an SR++ character you don't own adds 1 Shard to it. At 3 Shards, the character is unlocked. Rolling a duplicate non-SR++ character grants a +10% CP bonus instead.
- **36 characters** in total, each with their own lore connections in the World Tree.

### ⚡ Evolution & Affinity
- **3 Evolution Phases**: Base → Phase 2 → Phase 3 / Pixel / Transcendent.
- **Affinity System**: Unlocks over time by waking up on time each day. Affinity gains are validated server-side.
- Each evolution phase unlocks new **Skins**, unique **ringtones**, and exclusive **dialogue sets**.

### 🌳 World Tree
- A constellation-style map connecting all 36 characters, representing cause-and-effect relationships in the game's lore.
- Discover secret lore entries and character backstories as you collect and evolve characters.

### 🏆 Global Leaderboard
- Rankings based on **Wake-up Streak**, **Total CP**, and **characters collected**.
- Filterable by country. Powered by Supabase Realtime.

### 📬 In-Game Mailbox
- Receive items from the developer, event rewards, and achievement bonuses directly in-app.
- Claim all attachments (gacha tickets, diamonds) in one tap.

### 🛒 Store & In-App Purchases
- Purchase **Gacha Ticket Packs**, **Diamonds**, and **VIP Bundles** via RevenueCat (Google Play Billing).
- Watch **Rewarded Ads** (Google AdMob) to earn free daily tickets.

### ☁️ Cloud Sync & Offline Support
- Sign in with **Google Sign-In** or play as a **Guest** with no account required.
- Automatically syncs characters, alarms, and profiles to the cloud. Queues pending writes when offline and flushes them when reconnected.

### ⌚ Smartwatch Integration
- Two-way communication with **Wear OS** via MethodChannel.
- Dismiss or snooze alarms directly from your wrist without touching your phone.

### 🌍 Multilingual Support
- **8 languages**: Vietnamese 🇻🇳, English 🇬🇧, Japanese 🇯🇵, Korean 🇰🇷, Chinese 🇨🇳, French 🇫🇷, German 🇩🇪, Spanish 🇪🇸.
- Smart permission assistant for brands with strict battery management: **Xiaomi (HyperOS/MIUI)**, **Samsung (OneUI)**, **Oppo**, **Vivo**.

> **🚧 In Roadmap:** A daily water intake reminder widget is planned. The data models (`water_log`, `water_settings`) are already implemented but the UI is not yet connected.

---

## 🗂️ Project Structure

```
gacha_alarm/
├── lib/
│   ├── main.dart                   # Entry point — dual-branch boot logic
│   ├── controllers/                # Real-time ringing state management
│   ├── data/                       # Static data: character DB & World Tree layout
│   ├── models/                     # Data models & Hive TypeAdapters
│   ├── screens/                    # 16 user-facing screens
│   ├── services/                   # 33 services covering all business logic
│   ├── utils/                      # Logger, formatters, evolution codec
│   └── widgets/                    # Reusable UI components
├── assets/
│   ├── images/characters/          # Character artwork (base, phase2, phase3, pixel)
│   ├── sounds/                     # Per-character ringtones
│   ├── videos/                     # Summon cutscene videos
│   ├── borders/                    # Rarity frame overlays (F through SR++)
│   ├── dialogues/                  # D3 dialogue scripts
│   ├── lore/                       # Story content
│   └── translations/               # JSON locale files (8 languages)
└── android/                        # Android native config (Alarm Manager, Wear OS)
```

---

## 📊 Codebase Stats

| Metric | Value |
|:---|:---:|
| Total lines of Dart code | **~16,500** |
| Dart source files | **95** |
| Screens | **16** |
| Business logic services | **33** |
| Playable characters | **36** |
| Supported languages | **8** |
| Current version | **1.0.2+59** |

---

## 🛠️ Tech Stack

| Layer | Technology |
|:---|:---|
| **Framework** | [Flutter 3.x](https://flutter.dev) + Dart 3 |
| **Local Database** | [Hive](https://pub.dev/packages/hive) (embedded NoSQL) |
| **Backend & Auth** | [Supabase](https://supabase.com) (PostgreSQL + Realtime + RPC) |
| **Authentication** | [Google Sign-In](https://pub.dev/packages/google_sign_in) |
| **Alarm Scheduling** | [android_alarm_manager_plus](https://pub.dev/packages/android_alarm_manager_plus) + [flutter_foreground_task](https://pub.dev/packages/flutter_foreground_task) |
| **Audio** | [audioplayers](https://pub.dev/packages/audioplayers) |
| **Notifications** | [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications) |
| **In-App Purchases** | [RevenueCat](https://pub.dev/packages/purchases_flutter) |
| **Ads** | [Google Mobile Ads](https://pub.dev/packages/google_mobile_ads) |
| **Localization** | [easy_localization](https://pub.dev/packages/easy_localization) |
| **Video** | [video_player](https://pub.dev/packages/video_player) |
| **Permissions** | [permission_handler](https://pub.dev/packages/permission_handler) |

---

## 📲 Download

<a href="https://play.google.com/store/apps/details?id=com.solodev.gacha_alarm">
  <img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" alt="Get it on Google Play" height="60"/>
</a>

Gacha Alarm is publicly available on the Google Play Store.

---

## 🛠️ Build from Source

> For contributors and reviewers who want to run the project locally.

**Requirements:** Flutter SDK `>=3.1.0`, Android Studio or VS Code, Android API 21+

```bash
# 1. Clone
git clone https://github.com/SoloDev1101/Gacha-Alarm.git
cd gacha_alarm

# 2. Create .env in project root
SUPABASE_URL=your_supabase_project_url
SUPABASE_ANON_KEY=your_supabase_anon_key

# 3. Install & generate
flutter pub get
dart run build_runner build --delete-conflicting-outputs

# 4. Run
flutter run
```

---

## 🏗️ Architecture

The project follows a **Service-Oriented Architecture** with clear layer separation:

```
UI Layer (Screens & Widgets)
        │
        ▼
Service Layer (Business Logic)
    ├── AlarmService          — Scheduling & triggering alarms
    ├── GachaService          — Pull logic & shard/CP resolution
    ├── EvolutionService      — Character evolution handling
    ├── AuthService           — Login & session management
    ├── SyncService           — Sync orchestration
    ├── NotificationService   — System notifications
    ├── PurchaseService       — IAP via RevenueCat
    └── WearableSyncService   — Wear OS bridge
        │
        ▼
Data Layer (Hive Local DB + Supabase Cloud)
```

### Dual-Branch Boot — A Key Design Decision

`main.dart` detects whether an alarm is currently ringing on startup and takes one of two paths:

- **Ringing Branch** (`_bootRingingLuong`): Ultra-fast boot. Skips all non-essential initialization. Loads only what's needed (snapshot data, partner character) to render `RingingScreen` as fast as possible.
- **Normal Branch** (`_bootNormalLuong`): Full boot. Initializes all services and navigates to `RootBootScreen`.

---

## 🎮 User Flow

```
First launch
    └── OnboardingScreen (permissions & introduction)
            └── LoginScreen (Google / Guest)
                    └── HomeScreen
                          ├── Set alarm  → AlarmListScreen → D3SetupScreen
                          ├── Pull gacha → GachaScreen → [Result + Animation]
                          ├── Characters → CollectionScreen → EvolutionScreen
                          ├── Story      → WorldTreeScreen
                          ├── Rankings   → LeaderboardScreen
                          ├── Rewards    → MailboxScreen
                          ├── Shop       → StoreScreen
                          └── Options    → SettingsScreen

When an alarm fires (from background)
    └── RingingScreen (Ultra-Fast Boot)
              ├── Dismiss → Rewards granted → HomeScreen
              └── Snooze  → Escalated dialogue → [Rings again in 10 min, max 2×]
```

---

## 🔍 Code Highlights for Reviewers

If you're an engineer or recruiter reviewing this project, the table below points to the most technically interesting decisions in the codebase — each one represents a real production problem that had to be solved:

| File | What makes it interesting |
|:---|:---|
| [`lib/main.dart`](./lib/main.dart) | **Dual-branch cold-start boot** — detects at startup whether an alarm is ringing and takes a completely different initialization path to minimize time-to-UI |
| [`lib/services/alarm_snapshot_service.dart`](./lib/services/alarm_snapshot_service.dart) | **Snapshot pattern** — pre-bakes alarm + dialogue data into `SharedPreferences` so the ringing screen can render without waiting for Hive or network |
| [`lib/services/alarm_command_executor.dart`](./lib/services/alarm_command_executor.dart) | **Command pattern** for dismiss/snooze — decouples alarm actions from UI and makes them callable from both the app and Wear OS |
| [`lib/services/wearable_sync_service.dart`](./lib/services/wearable_sync_service.dart) | **Wear OS MethodChannel bridge** — two-way sync of alarms and D3 dialogue to a smartwatch companion app |
| [`lib/services/ringing_reward_service.dart`](./lib/services/ringing_reward_service.dart) | **Reward integrity** — orchestrates wake-up rewards with server-side validation to ensure consistency |
| [`lib/services/offline_sync_service.dart`](./lib/services/offline_sync_service.dart) | **Offline-first write queue** — queues failed sync operations and flushes them automatically when connectivity is restored |
| [`lib/services/gacha_rng_service.dart`](./lib/services/gacha_rng_service.dart) | **Weighted random engine** — implements rank-weighted pulls and the SR++ shard accumulation system (3 shards to unlock) |
| [`lib/services/permission_assistant.dart`](./lib/services/permission_assistant.dart) | **Per-OEM permission handling** — detects device manufacturer and deep-links into the correct battery optimization settings for Xiaomi, Samsung, Oppo, and Vivo |

---

## 🤖 AI-Assisted Development

AI was extensively used throughout the development process for implementation, debugging, code exploration, and iteration.

I remained responsible for:
- Product requirements and scope
- Architecture and technical decisions
- Evaluating and validating AI-generated solutions
- Debugging and root-cause analysis
- Final implementation decisions

→ See [`docs/ai-assisted-development.md`](./docs/ai-assisted-development.md) for a detailed breakdown.

---

## 🤝 Contributing

This project is under independent development. If you'd like to report a bug or suggest a feature, please open an **Issue** on GitHub.

---

## 📄 License

This project is proprietary. All rights reserved by the author. Copying, distribution, or commercial use without explicit written permission is prohibited.

---

<div align="center">

Made with ❤️ by **SoloDev1101**

*"Waking up isn't just opening your eyes — it's starting a new day with the one who's been waiting for you."*

</div>
