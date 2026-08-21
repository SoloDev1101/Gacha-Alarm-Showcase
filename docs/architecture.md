# Gacha Alarm — Architecture

```
Gacha Alarm
│
├── Flutter
│   │
│   ├── UI / Product Logic
│   │     Screens, Widgets, Controllers
│   │     D3 dialogue rendering, Gacha animations,
│   │     Evolution flow, Leaderboard, Store
│   │
│   ├── Local Storage
│   │     Hive  → Characters, Alarms, UserProfile, Mail
│   │     SharedPreferences → Boot flags, Snooze state,
│   │                         Reward timestamps, Sync cursors
│   │
│   ├── Sync Layer
│   │     AlarmSyncService, CharacterSyncService,
│   │     ProfileSyncService, OfflineSyncService
│   │     (write queue → flush on reconnect)
│   │
│   └── Native Android Layer
│         │
│         └── Alarm / Wear OS
│               android_alarm_manager_plus  → Schedule & fire alarms
│               flutter_foreground_task     → Keep process alive while ringing
│               flutter_local_notifications → Wearable action buttons
│               MethodChannel               → Wear OS two-way bridge
│
└── Cloud (Supabase)
      │
      ├── Auth         Google Sign-In / Anonymous sessions
      ├── PostgreSQL   Users, Characters, Alarms, Mail, Leaderboard
      ├── Realtime     Live leaderboard updates
      └── RPC          Server-side reward validation
```

## Boot Flow

```
App launch
    │
    ├── isRinging == true ──► Fast Boot
    │                              Load snapshot from SharedPreferences
    │                              Render RingingScreen immediately
    │                              Init remaining services in background
    │
    └── isRinging == false ─► Normal Boot
                                   Full service initialization
                                   Navigate to RootBootScreen → HomeScreen
```

## Data Flow (Alarm Lifecycle)

```
User sets alarm (UI)
    └── AlarmService.schedule()
            └── android_alarm_manager_plus registers native callback
                    │
                    [alarm fires — possibly no UI process]
                    │
                    └── AlarmCommandExecutor.execute()
                            ├── Show notification (flutter_local_notifications)
                            ├── Start ForegroundTask (keep process alive)
                            └── Set isRinging = true → app launches Fast Boot
```
