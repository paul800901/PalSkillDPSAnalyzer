# 帕魯技能 DPS 分析器

Palworld 1.0 單人世界傷害驗證 Mod。預設只計算帕魯，依實際帕魯個體與技能分組；坐騎、隊伍／跟隨帕魯與基地多隻帕魯不會被合併。聊天輸出預設關閉，不進行玩家排名。

## 使用方法

1. 訂閱並啟用本 Mod 與 `UE4SS Experimental (Palworld)`。
2. 進入單人世界後按 F2 開始新測試（傷害歸零）；第一筆有效傷害才會開始計時。
4. 可同時測試一般野生帕魯、野外／石板 Boss 與基地多帕魯群戰。
5. 從即時儀表查看帕魯與技能，並保留 `Palworld\Mods\NativeMods\UE4SS\UE4SS.log`。

人物傷害預設關閉。要測試武器時，修改：

```lua
config.IncludePlayerDamage = true
```

完整重開遊戲，並建議一場只使用一種武器。可辨識時依武器／投射物分桶；無法辨識時保留為未知人物武器。

設定檔位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

這是 v0.5.12 精確來源鏈診斷版。它不再用 BasePower＋元素、目前動作或最近施放替未知命中猜技能；每次施放會沿技能效果、AttackFilter.Waza、Blueprint OnAttack 與最終 OnDamage 傳遞來源。沒有強證據時保留「未辨識傷害」。預設採手動測試區間並接受所有野生帕魯；按 F2 可隨時歸零。灼燒與中毒若沒有施加來源仍不會冒充某個技能。即時儀表是固定尺寸、不可點擊的純顯示層；舊 F1 外部設定窗仍停用。只需要 UE4SS Experimental；PalSchema 不是必要依賴。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

MIT License。核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。本專案是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
