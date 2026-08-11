# PalSkillDPSAnalyzer v0.1.0-diagnostic

Palworld 1.0 單機用 UE4SS Lua 傷害驗證 Mod。它不是玩家排行榜，目標是把一場 Boss 測試中的每隻帕魯視為獨立來源，依可讀到的技能、投射物或攻擊欄位分桶，輸出總傷害、整場 DPS、占比、命中數與平均每擊傷害。

人物傷害預設關閉。需要測試武器時，可在另一場戰鬥中開啟人物來源；能辨識武器／投射物就分桶，不能辨識時保留為未知人物武器，不猜名稱。

## 診斷版輸出

第一次打中 Boss 後，聊天欄會顯示開始提示。擊殺、捕捉或 60 秒無傷害後，聊天欄只顯示一行完成提示；完整證據寫入 `UE4SS.log`：

```text
[PalSkillDPSAnalyzer] diagnostic-source boss=... source_kind=pal source=... damage=... dps=... hits=... candidates=...
[PalSkillDPSAnalyzer] diagnostic-candidate boss=... candidate=... damage=... share=... dps=... hits=... avg_hit=... causer=... fields=...
```

`candidate` 是診斷候選，不一定已是正式技能名稱。只要 Palworld 提供可靠的 `SkillID`、技能投射物或其他攻擊欄位，後續版本就能建立穩定映射；無法確認的資料保持 `UNKNOWN_*`。

## 預設測試模式

```lua
config.EnableSkillDiagnostics = true
config.SkillDiagnosticsOnly = true
config.IncludePlayerDamage = false
config.DumpDamageSchema = true
```

要另外測試人物武器，將 `IncludePlayerDamage` 設為 `true`，完整重開遊戲，再以一場只使用一種武器的 Boss 戰進行測試。

## Steam 創意工坊單機安裝

診斷包需要 `UE4SS Experimental (Palworld)`。Palworld Mod 管理器會把 Lua 腳本安裝到：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\
```

開發中的本機建包：

```powershell
powershell -ExecutionPolicy Bypass -File .\workshop\build_workshop.ps1
```

輸出位於 `workshop/dist/PalSkillDPSAnalyzerSP-Workshop-v0.1.0.zip`。專案已保留獨立的 `Info.json`、PackageName 與空白 Workshop Published File ID，不會覆蓋上游 Mod。

## 驗證流程

1. 啟用本 Mod 與 UE4SS Experimental。
2. 預設先只帶一隻帕魯，使用已知的 2–3 個技能攻擊 Boss。
3. 結束戰鬥後保留 `UE4SS.log`。
4. 以 `damage-schema`、`damage-sample` 和 `diagnostic-candidate` 行確認技能欄位與候選映射。
5. 如需測武器，另開一場、開啟 `IncludePlayerDamage`，全程只使用同一武器。

## 適用邊界

- 正式目標：Palworld 1.0 Windows 單人世界。
- Boss 房間、塔主、野外 Boss 與召喚 Boss 可用；PvP 不是目前目標。
- 持續傷害、燃燒、中毒、同一泛用投射物承載多種技能等情況，可能先進入未知或合併候選。
- 診斷版強制使用 Lua 傷害事件，避免原生聚合器先丟失技能候選欄位。
- 修改設定後必須完整重開 Palworld。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run_all.ps1
```

離線測試不連線、不啟動或修改 Palworld。實機反射欄位仍需一次受控 Boss 戰驗證。

## 授權與來源

MIT License。Boss 遭遇辨識、帕魯歸屬與安全訊息核心衍生自 [AsahiChan-Game/PalBossDPSBroadcast](https://github.com/AsahiChan-Game/PalBossDPSBroadcast)，詳細見 [NOTICE.md](NOTICE.md)。本專案為獨立 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
