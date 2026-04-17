# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build
swift build

# Run tests
swift test

# Run specific test
swift test --filter UsageBarTests/testAuthRequiredSnapshotDefaults

# Release build
swift build -c release --artifact-path .derived-release
```

## Architecture

**App Type**: Native macOS menu bar app (SwiftUI + AppKit)

**Entry Point**: `UsageBarApp.swift` uses `MenuBarExtra` scene with `@NSApplicationDelegateAdaptor` for lifecycle management.

**Core Components**:

- **ProviderAdapter** (protocol): Each provider (Bailian, Z.ai Global, OpenAI Codex) implements this for fetching usage data
- **ProviderStore**: Central state management for provider snapshots, connection diagnostics, and credential handling
- **SettingsStore**: Persists app settings (language, launch at login, provider configs) to UserDefaults
- **CredentialStore**: Secure credential storage in Keychain (API keys, cookies, session tokens)
- **SnapshotCacheStore**: Persists provider snapshots to disk for app relaunch bootstrap

**Data Flow**:
```
ProviderAdapter → ProviderStore → DashboardView/MenuBarExtra
     ↓                              ↓
CredentialStore              SettingsStore (environment)
```

**Key Patterns**:
- `@MainActor` for all UI-related state (ProviderStore, SettingsStore)
- SwiftUI environment objects for cross-component state sharing
- Protocol-driven provider architecture allows adding new providers without modifying core logic
- Automatic refresh every 5 minutes via `RefreshPolicy.automaticInterval`

**Provider Architecture**:
- Each provider lives in `Sources/UsageBar/Providers/`
- Providers support two auth modes: `apiKey` or `webSession` (cookie/session capture via WKWebView)
- Provider metadata structures encode usage windows (5-hour, weekly, monthly buckets) for menu bar display

## gstack

**Use /browse skill for ALL web browsing tasks.** Never use `mcp__claude-in-chrome__*` tools directly.

**Available gstack skills**:

- `/office-hours` — YC Office Hours mode
- `/plan-ceo-review` — CEO/founder-mode plan review
- `/plan-eng-review` — Eng manager-mode plan review
- `/plan-design-review` — Designer's eye plan review
- `/design-consultation` — Design consultation
- `/design-shotgun` — Design shotgun (multiple variants)
- `/design-html` — Design finalization
- `/review` — Pre-landing PR review
- `/ship` — Ship workflow
- `/land-and-deploy` — Land and deploy workflow
- `/canary` — Post-deploy canary monitoring
- `/benchmark` — Performance regression detection
- `/browse` — Fast headless browser for QA testing
- `/connect-chrome` — Chrome DevTools MCP connection
- `/qa` — Systematic QA testing
- `/qa-only` — Report-only QA testing
- `/design-review` — Designer's eye QA
- `/setup-browser-cookies` — Import cookies from Chromium
- `/setup-deploy` — Configure deployment settings
- `/retro` — Weekly engineering retrospective
- `/investigate` — Systematic debugging with root cause
- `/document-release` — Post-ship documentation
- `/codex` — OpenAI Codex CLI wrapper
- `/cso` — Chief Security Officer mode
- `/autoplan` — Auto-review pipeline
- `/plan-devex-review` — Developer experience plan review
- `/devex-review` — Live developer experience audit
- `/careful` — Safety guardrails for destructive commands
- `/freeze` — Restrict file edits to specific directory
- `/guard` — Full safety mode
- `/unfreeze` — Clear freeze boundary
- `/gstack-upgrade` — Upgrade gstack to latest version
- `/learn` — Manage project learnings

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
