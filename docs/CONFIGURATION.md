# 設定說明

設定檔是 `Scripts/config.lua`。Steam 創意工坊單機版安裝後位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

v0.5.11 暫時停用不可靠的外部 F1 互動設定；請直接修改本檔並完整重開 Palworld。遊戲中按 `F2` 可隨時把本次測試歸零並重新待命。

## 診斷模式

| 設定 | 預設 | 用途 |
|---|---:|---|
| `EnableDPSRecording` | `true` | 傷害驗證總開關 |
| `EnableSkillDiagnostics` | `true` | 建立技能／武器候選與原始證據 |
| `SkillDiagnosticsOnly` | `true` | 只輸出驗證摘要，不輸出玩家排名 |
| `IncludePlayerDamage` | `false` | 是否加入人物／武器來源 |
| `DumpDamageSchema` | `false` | 選用：啟動後反射傷害事件欄位一次；目前 UE4SS 巢狀反射可能失敗 |
| `SkillDiagnosticMaxSamplesPerCandidate` | `64` | 每個候選最多保留幾筆逐擊樣本；診斷版保留足夠多段技能命中供核對 |
| `SkillDiagnosticMaxSchemaFields` | `128` | 反射欄位數上限 |
| `SkillDiagnosticChatMode` | `"off"` | `off` 不使用聊天框；`summary` 只顯示完成摘要；`full` 顯示完整舊式報表 |
| `SkillDiagnosticChatMaxRows` | `12` | `full` 模式的技能／武器明細上限 |
| `SkillMarkerTTLSeconds` | `30` | 延遲投射物可沿用 Waza 技能代號的時間 |
| `SkillMarkerMaxEntries` | `2048` | Waza 關聯快取的有界上限 |
| `EquipWazaRefreshSeconds` | `5` | 三格裝備技能清單的 TTL；每次動作開始也會失效重讀，換技後分類會在下次命中時更新 |
| `SkillActionPostHitSeconds` | `10` | 動作結束後，第一筆延遲命中可比對最近施放的秒數 |
| `SkillActionConflictSeconds` | `1.25` | 兩個不同施放結束時間過近時視為衝突，不強行歸屬 |
| `SkillEffectHitGapSeconds` | `3` | 已確認的同一延遲效果允許相鄰命中的最大間隔 |
| `SkillEffectMaxLifetimeSeconds` | `45` | 已確認延遲效果可持續累計的最長時間 |
| `PreferNativeCollector` | `true` | 優先使用具備逐命中與精確來源鏈能力的原生事件 API v2；未完成／不相容時自動退回 Lua |
| `AllowLegacyNativeAggregate` | `false` | 是否允許只保留總傷、會丟失技能來源的舊原生聚合器；技能分析不建議開啟 |
| `MeasurementMode` | `"manual"` | `manual` 由使用者控制測試區間；`target` 每個目標自動分場 |
| `TargetScope` | `"all"` | `all` 接受所有野生帕魯；`boss` 只接受 Boss／頭目 |

帕魯測試請保持 `IncludePlayerDamage = false`。測試人物武器時改為 `true`，並建議每場只使用一種武器。

## 技能 DPS 面板

| 設定 | 預設 | 用途 |
|---|---:|---|
| `EnableSkillDPSHUD` | `true` | 顯示獨立技能 DPS 面板 |
| `HUDRefreshMilliseconds` | `500` | 即時面板更新間隔 |
| `HUDSettingsVersion` | `3` | 使用者 HUD 設定格式；舊版第一次載入會遷移成安全區傷害實驗室配置 |
| `HUDDetailMode` | `"compact"` | `compact` 顯示比例長條；`full` 在每招下方展開所有計時 |
| `HUDShowInternalSkillCode` | `false` | 是否在官方本地化名稱後附加內部英文 Waza／動作代碼 |
| `HUDAnchor` | `"left-center"` | `left-center`、`right-center`、`top-left` 或 `top-right` |
| `HUDScale` | `0.85` | F1 可選 0.75、0.85、1.0、1.15 |
| `HUDMaxSkillRows` | `5` | 即時儀表最多顯示幾個技能；F1「本次測試」不受此限制 |
| `HUDFinalResultSeconds` | `15` | `target` 模式結算後保留秒數；0 立即隱藏，-1 永久保留 |
| `HUDKeepFinalResults` | `true` | 舊版相容設定；v3 以 `HUDFinalResultSeconds` 為準 |
| `EnableExternalHUD` | `true` | 啟用不碰 Unreal UI 的透明 Windows HUD |
| `EnableExternalHUDSettings` | `false` | 安全保護；原生 CommonUI 完成前禁止外部互動設定窗 |
| `ExternalHUDAutoLaunch` | `true` | MOD 載入時自動啟動隨附 WPF 顯示程序 |
| `HUDUseExperimentalUMG` | `false` | 相容保護；外部 HUD 不再呼叫此崩潰路徑 |
| `HUDUseScreenTextFallback` | `false` | 相容保護；外部 HUD 不再呼叫會崩潰的 `PrintString` |

外部 HUD 僅是不可點擊的顯示層，不再搶 Windows 焦點、不變更 Palworld 游標、不 DisableInput，也不解除游標裁切。F1 在原生 CommonUI 設定頁完成前會 fail closed；按 `F2` 可清空目前測試資料但不修改歷史 log，`manual` 模式會重新待命直到第一筆有效傷害。原生暫停／設定選單、標題畫面、讀取中或沒有可控制角色時，外部 DPS 會自動隱藏。

外部 HUD 的即時狀態檔是 `Scripts/skill_dps_hud_state.txt`；`skill_dps_hud_heartbeat.txt` 供 Lua 偵測顯示程序，WPF 例外寫入 `skill_dps_hud_overlay.log`。執行期只接受 `meter` 顯示文件，不接受舊版 `settings` 互動文件。面板不讀取或修改世界存檔；Palworld 不在前景時自動隱藏，遊戲程序結束後自動退出。

## 結算口徑

- 測試區間：`manual` 從歸零後第一筆有效傷害開始，跨多個目標持續累計；`target` 依單一目標的擊殺、捕捉或逾時結算。
- 來源：以實際攻擊者帕魯個體分組；坐騎、隊伍／跟隨帕魯及基地帕魯不因屬於同一玩家而合併。啟用人物後，人物角色另算一個來源。
- 候選：優先使用 `EPalWazaID`；缺少 Waza 時使用去除實例編號的當前動作、投射物、武器來源或未知桶。
- 泛用持續傷害：只有 `BasePower + AttackElementType` 在整場唯一對應到一個已知技能時才合併；有歧義時保持未解析。
- 整場 DPS：候選累計傷害除以目前測試區間總秒數。
- 平均每擊：候選累計傷害除以有效命中數。
- 占比：候選傷害除以該來源的累計傷害。
- 未知資料保留 `UNKNOWN_*`，不依傷害數字猜技能。

## 相容設定

專案保留上游 Boss 遭遇偵測需要的安全與快取設定。診斷版固定建議：

```lua
config.PreferNativeCollector = true
config.AllowLegacyNativeAggregate = false
config.EnableProgressReports = false
config.EnableDetailedAwards = false
config.EnablePalDamageBreakdown = false
config.EnableFunComments = false
```

只有原生事件 API 回報精確 cast／effect 來源鏈已就緒時才會啟用；舊聚合器不會被
技能分析器誤選。原生來源鏈未完成或 ABI 不符時，會保留總傷並以未歸屬呈現，
不使用時間、倍率或屬性冒充精確技能。
