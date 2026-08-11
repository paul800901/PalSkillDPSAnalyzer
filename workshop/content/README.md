# 帕魯技能 DPS 分析器

Palworld 1.0 單人世界傷害驗證 Mod。預設只計算帕魯，依技能 ID、投射物或傷害來源建立診斷候選；結算時會在遊戲聊天欄列出逐技能結果，完整原始證據另寫入 UE4SS.log。不進行玩家排名。

## 使用方法

1. 訂閱並啟用本 Mod 與 `UE4SS Experimental (Palworld)`。
2. 進入單人世界，使用一隻帕魯攻擊 Boss。
3. 擊殺、捕捉或停止造成傷害 60 秒後完成結算。
4. 保留 `Palworld\Mods\NativeMods\UE4SS\UE4SS.log`。

人物傷害預設關閉。要測試武器時，修改：

```lua
config.IncludePlayerDamage = true
```

完整重開遊戲，並建議一場只使用一種武器。可辨識時依武器／投射物分桶；無法辨識時保留為未知人物武器。

設定檔位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

這是 v0.1.2 診斷版。同一技能不同次施放會依穩定動作名稱合併；泛用持續傷害只有能唯一對應時才併回技能，無法證明則保留為未解析候選。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

MIT License。核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。本專案是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
