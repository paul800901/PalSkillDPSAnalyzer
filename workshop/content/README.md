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

這是 v0.5.11 暗系長戰歸因熱修版。它保留固定 HUD 與三格裝備唯一 BasePower＋屬性簽名，並新增暗黑雷射、黑暗之擁、劇毒射擊的闇屬性簽名；40／闇仍獨立顯示為普攻「暗能彈」。預設採手動測試區間並接受所有野生帕魯；按 F2 可隨時歸零。灼燒與中毒狀態傷害尚未宣稱支援。即時儀表是固定尺寸、不可點擊的純顯示層；舊 F1 外部設定窗仍停用，等待遊戲內原生 CommonUI。只需要 UE4SS Experimental；PalSchema 不是必要依賴。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

MIT License。核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。本專案是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
