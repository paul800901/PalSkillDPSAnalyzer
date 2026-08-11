# 帕魯技能 DPS 分析器

Palworld 1.0 單人世界傷害驗證 Mod。預設只計算帕魯，依技能 ID、投射物或傷害來源建立診斷候選，完整結果寫入 UE4SS.log；不進行玩家排名。

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

這是 v0.1.0 診斷版。`candidate` 代表有原始證據的候選，不保證已是正式技能名稱；未知傷害不會被硬套名稱。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

MIT License。核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。本專案是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
