docs/
# AI-Assisted Development

This document describes how AI tools were used during the development of
Gacha Alarm, and what the developer was responsible for at each stage.

The goal is transparency: AI assistance is a real part of modern solo
development, and this file clarifies the boundary between tool use and
engineering ownership.

---

## How AI Was Used

### Implementation
AI was used to generate boilerplate, scaffold service classes, and produce
first-draft implementations of features. Every piece of generated code was
reviewed, often restructured, and adapted to fit the existing architecture
before being committed.

Examples:
- Initial drafts of Hive model classes and TypeAdapters
- Boilerplate for `MethodChannel` setup (Wear OS bridge)
- UI scaffold for screens (layouts, widget trees)
- Translation file generation for non-primary languages (de, es, fr, ja, ko, zh)

### Debugging & Root-Cause Analysis
AI was used as a sounding board when debugging hard-to-reproduce issues —
particularly around Android alarm reliability, Hive state corruption on
cold boot, and Supabase RPC error handling.

The developer identified the symptom and narrowed down the failure domain;
AI helped explore possible causes and propose hypotheses to test.

### Code Exploration
AI was used to explain unfamiliar APIs (e.g. `AlarmManager` exact alarm
flags, Wear OS Data Layer transport semantics, RevenueCat entitlement model)
and to surface relevant platform constraints before implementation began.

### Iteration
AI was used during refinement cycles — for example, tightening the boot
sequence logic, improving error recovery paths, and refining the offline
sync queue behavior — by proposing alternatives and explaining trade-offs.

---

## What the Developer Was Responsible For

| Area | Developer's role |
|:---|:---|
| **Product concept & scope** | Defined the entire product idea, feature set, and game design |
| **Architecture decisions** | All structural decisions (dual-boot, snapshot pattern, offline-first, command executor, MethodChannel bridge) were reasoned through and chosen by the developer — see [`docs/technical-decisions.md`](./technical-decisions.md) |
| **Evaluating AI output** | Every AI-generated suggestion was reviewed. Many were rejected, modified, or used only as a reference |
| **Debugging** | Root-cause analysis was led by the developer. AI provided hypotheses; the developer validated them against actual runtime behavior |
| **Code quality & correctness** | The developer caught and fixed multiple incorrect or incomplete AI suggestions, including logic errors in shard resolution, boot state handling, and sync timing |
| **Security posture** | Decisions about what to expose publicly, what to validate server-side, and how to structure anti-abuse mechanisms were made by the developer |

---

## What This Means for Code Reviewers

AI-assisted development does not mean AI-authored code. The architecture,
the key abstractions, and the engineering judgment throughout this codebase
reflect deliberate decisions made by the developer — decisions that AI tools
cannot make: choosing what to build, how to structure it, what trade-offs to
accept, and why.

The developer's ownership is most visible in the files listed in
[`README.md § Code Highlights for Reviewers`](../README.md#-code-highlights-for-reviewers):
these represent the hardest problems in the codebase, where generated code
alone would not have produced a working result.

---

## Tools Used

- ChatGPT (OpenAI)
- Gemini (Google)
- Claude (Anthropic)
- DeepSeek
