# 設定說明

設定檔是 `Scripts/config.lua`。Steam 創意工坊單機版安裝後位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

大部分顯示設定可直接在遊戲內按 F1 調整並自動保存；手動修改後需完整重開 Palworld。

## 診斷模式

| 設定 | 預設 | 用途 |
|---|---:|---|
| `EnableDPSRecording` | `true` | 傷害驗證總開關 |
| `EnableSkillDiagnostics` | `true` | 建立技能／武器候選與原始證據 |
| `SkillDiagnosticsOnly` | `true` | 只輸出驗證摘要，不輸出玩家排名 |
| `IncludePlayerDamage` | `false` | 是否加入人物／武器來源 |
| `DumpDamageSchema` | `false` | 選用：啟動後反射傷害事件欄位一次；目前 UE4SS 巢狀反射可能失敗 |
| `SkillDiagnosticMaxSamplesPerCandidate` | `3` | 每個候選最多保留幾筆逐擊樣本 |
| `SkillDiagnosticMaxSchemaFields` | `128` | 反射欄位數上限 |
| `SkillDiagnosticChatMode` | `"off"` | `off` 不使用聊天框；`summary` 只顯示完成摘要；`full` 顯示完整舊式報表 |
| `SkillDiagnosticChatMaxRows` | `12` | `full` 模式的技能／武器明細上限 |
| `SkillMarkerTTLSeconds` | `30` | 延遲投射物可沿用 Waza 技能代號的時間 |
| `SkillMarkerMaxEntries` | `2048` | Waza 關聯快取的有界上限 |

帕魯測試請保持 `IncludePlayerDamage = false`。測試人物武器時改為 `true`，並建議每場只使用一種武器。

## F1 技能 DPS 面板

| 設定 | 預設 | 用途 |
|---|---:|---|
| `EnableSkillDPSHUD` | `true` | 顯示獨立技能 DPS 面板 |
| `HUDRefreshMilliseconds` | `500` | 即時面板更新間隔 |
| `HUDDetailMode` | `"full"` | `full` 顯示所有計時；`compact` 每招一列 |
| `HUDShowInternalSkillCode` | `false` | 是否在官方本地化名稱後附加內部英文 Waza／動作代碼 |
| `HUDAnchor` | `"top-right"` | `top-right` 或 `top-left` |
| `HUDScale` | `1.0` | F1 可選 0.8、1.0、1.2 |
| `HUDMaxSkillRows` | `6` | 面板最多顯示幾個技能候選 |
| `HUDKeepFinalResults` | `true` | 戰鬥結束後保留面板，方便抄錄與比較 |
| `EnableExternalHUD` | `true` | 啟用不碰 Unreal UI 的透明 Windows HUD |
| `ExternalHUDAutoLaunch` | `true` | MOD 載入時自動啟動隨附 WPF 顯示程序 |
| `HUDUseExperimentalUMG` | `false` | 相容保護；v0.4.2 不再呼叫此崩潰路徑 |
| `HUDUseScreenTextFallback` | `false` | 相容保護；v0.4.2 不再呼叫會崩潰的 `PrintString` |

F1 已被其他 UE4SS 模組註冊時，本 Mod 會改用 `Ctrl+F1`。方向鍵上下選擇，左右鍵或 Enter 調整。使用者設定保存在 `Scripts/user_settings.lua`；「清除本場測試」不會修改歷史檔案，只會清空目前記憶中的遭遇。

外部 HUD 的即時狀態檔是 `Scripts/skill_dps_hud_state.txt`。面板只讀此檔，不讀取或修改世界存檔；Palworld 不在前景時自動隱藏，遊戲程序結束後自動退出。

## 結算口徑

- 來源：每隻帕魯；啟用人物後，人物角色另算一個來源。
- 候選：優先使用 `EPalWazaID`；缺少 Waza 時使用去除實例編號的當前動作、投射物、武器來源或未知桶。
- 泛用持續傷害：只有 `BasePower + AttackElementType` 在整場唯一對應到一個已知技能時才合併；有歧義時保持未解析。
- 整場 DPS：候選累計傷害除以 Boss 遭遇總秒數。
- 平均每擊：候選累計傷害除以有效命中數。
- 占比：候選傷害除以該來源的累計傷害。
- 未知資料保留 `UNKNOWN_*`，不依傷害數字猜技能。

## 相容設定

專案保留上游 Boss 遭遇偵測需要的安全與快取設定。診斷版固定建議：

```lua
config.PreferNativeCollector = false
config.EnableProgressReports = false
config.EnableDetailedAwards = false
config.EnablePalDamageBreakdown = false
config.EnableFunComments = false
```

原生聚合器會把多次事件先合併，可能丟失技能候選欄位，因此診斷版使用 Lua 回退路徑。
