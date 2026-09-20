# Codex App Server Method Adoption

This page is generated from
`Vendor/CodexAppServerProtocolSchema/method-adoption.json`. The manifest
is the source of truth for typed wrappers, the raw-method deny policy,
and this inventory.

Pinned schema: `rust-v0.154.0`. Inventory SHA-256:
`7f5aa61a8f2dbd8ae3c99380aef92c617a33bbba33851ff32d56715ef900b1e4`.

## Stable (96)

- `account/login/cancel`
- `account/login/start`
- `account/logout`
- `account/rateLimitResetCredit/consume`
- `account/rateLimits/read`
- `account/read`
- `account/sendAddCreditsNudgeEmail`
- `account/usage/read`
- `account/workspaceMessages/read`
- `app/installed`
- `app/list`
- `app/read`
- `command/exec`
- `command/exec/resize`
- `command/exec/terminate`
- `command/exec/write`
- `config/batchWrite`
- `config/mcpServer/reload`
- `config/read`
- `config/value/write`
- `configRequirements/read`
- `experimentalFeature/enablement/set`
- `experimentalFeature/list`
- `externalAgentConfig/detect`
- `externalAgentConfig/import`
- `externalAgentConfig/import/readHistories`
- `externalAgentConfig/import/recordHistory`
- `feedback/upload`
- `fs/copy`
- `fs/createDirectory`
- `fs/getMetadata`
- `fs/readDirectory`
- `fs/readFile`
- `fs/remove`
- `fs/unwatch`
- `fs/watch`
- `fs/writeFile`
- `hooks/list`
- `marketplace/add`
- `marketplace/remove`
- `marketplace/upgrade`
- `mcpServer/oauth/login`
- `mcpServer/resource/read`
- `mcpServer/tool/call`
- `mcpServerStatus/list`
- `model/list`
- `modelProvider/capabilities/read`
- `permissionProfile/list`
- `plugin/install`
- `plugin/installed`
- `plugin/list`
- `plugin/read`
- `plugin/share/checkout`
- `plugin/share/delete`
- `plugin/share/list`
- `plugin/share/save`
- `plugin/share/updateTargets`
- `plugin/skill/read`
- `plugin/uninstall`
- `review/start`
- `skills/config/write`
- `skills/extraRoots/set`
- `skills/list`
- `thread/approveGuardianDeniedAction`
- `thread/archive`
- `thread/compact/start`
- `thread/delete`
- `thread/fork`
- `thread/goal/clear`
- `thread/goal/get`
- `thread/goal/set`
- `thread/inject_items`
- `thread/items/list`
- `thread/list`
- `thread/loaded/list`
- `thread/metadata/update`
- `thread/name/set`
- `thread/read`
- `thread/resume`
- `thread/revert`
- `thread/rollback`
- `thread/section/move`
- `thread/shellCommand`
- `thread/start`
- `thread/turns/list`
- `thread/unarchive`
- `thread/unsubscribe`
- `threadSection/create`
- `threadSection/delete`
- `threadSection/list`
- `threadSection/update`
- `turn/interrupt`
- `turn/start`
- `turn/steer`
- `windowsSandbox/readiness`
- `windowsSandbox/setupStart`

## Experimental-only (51)

- `collaborationMode/list`
- `environment/add`
- `environment/info`
- `environment/status`
- `mcpServer/event/stream/start`
- `mcpServer/event/stream/stop`
- `memory/reset`
- `mock/experimentalMethod`
- `plugin/search`
- `process/kill`
- `process/resizePty`
- `process/spawn`
- `process/writeStdin`
- `project/create`
- `project/delete`
- `project/import`
- `project/list`
- `project/move`
- `project/read`
- `project/update`
- `remoteControl/client/list`
- `remoteControl/client/revoke`
- `remoteControl/disable`
- `remoteControl/enable`
- `remoteControl/pairing/start`
- `remoteControl/pairing/status`
- `remoteControl/status/read`
- `server/diagnostics`
- `thread/backgroundTerminals/clean`
- `thread/backgroundTerminals/list`
- `thread/backgroundTerminals/terminate`
- `thread/decrement_elicitation`
- `thread/increment_elicitation`
- `thread/memoryMode/set`
- `thread/queue/add`
- `thread/queue/delete`
- `thread/queue/list`
- `thread/queue/reorder`
- `thread/queue/start`
- `thread/queue/update`
- `thread/realtime/appendAudio`
- `thread/realtime/appendSpeech`
- `thread/realtime/appendText`
- `thread/realtime/listVoices`
- `thread/realtime/start`
- `thread/realtime/stop`
- `thread/search`
- `thread/searchOccurrences`
- `thread/settings/update`
- `thread/timeline/list`
- `turn/settings/update`

## Excluded (17)

- `FuzzyFileSearch` — legacy method is not adopted
- `GetAuthStatus` — legacy method is not adopted
- `GetConversationSummary` — legacy method is not adopted
- `GitDiffToRemote` — legacy method is not adopted
- `account/bedrock/discover` — Bedrock account onboarding is not adopted
- `account/bedrock/setup` — Bedrock account onboarding is not adopted
- `fuzzyFileSearch` — deprecated upstream method is not adopted
- `fuzzyFileSearch/sessionStart` — experimental fuzzy session is not adopted
- `fuzzyFileSearch/sessionStop` — experimental fuzzy session is not adopted
- `fuzzyFileSearch/sessionUpdate` — experimental fuzzy session is not adopted
- `initialize` — connection lifecycle owns the handshake
- `initialized` — connection lifecycle owns the handshake
- `plugin/reconcile` — plugin reconciliation is not adopted
- `userVerification/delete` — user verification administration is not adopted
- `userVerification/enroll` — user verification administration is not adopted
- `userVerification/status` — user verification administration is not adopted
- `userVerification/verify` — user verification administration is not adopted

## Last Schema Refresh API Diff

Added: 21. Removed: 2.

### Added

- `experimental` `mcpServer/event/stream/start`
- `experimental` `mcpServer/event/stream/stop`
- `experimental` `project/create`
- `experimental` `project/delete`
- `experimental` `project/import`
- `experimental` `project/list`
- `experimental` `project/move`
- `experimental` `project/read`
- `experimental` `project/update`
- `experimental` `server/diagnostics`
- `experimental` `thread/queue/add`
- `experimental` `thread/queue/delete`
- `experimental` `thread/queue/list`
- `experimental` `thread/queue/reorder`
- `experimental` `thread/queue/start`
- `experimental` `thread/queue/update`
- `experimental` `thread/timeline/list`
- `experimental` `turn/settings/update`
- `stable` `thread/items/list`
- `stable` `thread/revert`
- `stable` `thread/turns/list`

### Removed

- `experimental` `thread/items/list`
- `experimental` `thread/turns/list`
