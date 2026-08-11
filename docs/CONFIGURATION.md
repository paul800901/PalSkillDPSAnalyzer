# 設定說明

設定檔是 `Scripts/config.lua`。Steam 創意工坊單機版安裝後位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

修改後必須完整重開 Palworld。

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
| `SkillDiagnosticChatMaxRows` | `12` | 結算時在遊戲聊天欄顯示的技能／武器明細上限 |
| `SkillMarkerTTLSeconds` | `30` | 延遲投射物可沿用 Waza 技能代號的時間 |
| `SkillMarkerMaxEntries` | `2048` | Waza 關聯快取的有界上限 |

帕魯測試請保持 `IncludePlayerDamage = false`。測試人物武器時改為 `true`，並建議每場只使用一種武器。

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
