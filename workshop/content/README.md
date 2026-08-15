# 帕魯技能 DPS 分析器

Palworld 1.0 單人世界傷害驗證 Mod。預設只計算帕魯，依實際帕魯個體與技能分組；坐騎、隊伍／跟隨帕魯與基地多隻帕魯不會被合併。聊天輸出預設關閉，不進行玩家排名。

## 使用方法

1. 訂閱並啟用本 Mod 與 `UE4SS Experimental (Palworld)`。
2. 進入單人世界後按 F2 開始新測試（傷害歸零）；第一筆有效傷害才會開始計時。
3. 攻擊競技場／塔／石板 Boss，或有 Boss／Alpha 標記的大世界頭目；普通野怪不納入預設正式統計。
4. 從即時儀表查看帕魯與技能，並保留 `Palworld\Mods\NativeMods\UE4SS\UE4SS.log`。

人物傷害預設關閉。要測試武器時，修改：

```lua
config.IncludePlayerDamage = true
```

完整重開遊戲，並建議一場只使用一種武器。可辨識時依武器／投射物分桶；無法辨識時保留為未知人物武器。

設定檔位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

這是 v0.5.19 五項核心 HUD 版。首頁只顯示技能名稱、累計傷害、DPS、占比與測試時間；F2 可隨時歸零，F3 開啟／關閉遊戲內原生設定面板。用滑鼠切換設定與本次測試分頁；施放次數、有傷施放／無傷施放、總命中段數、每次施放命中段數、每次施放命中段數最低／平均／最高（含無傷施放）、本次遊戲最高單次施放段數與理論最高命中段數只放在第二頁。手動 Boss 測試會在 Boss 最終死亡或捕捉時鎖定完整結果，主 HUD 保持原值到下一次 F2，延遲尾傷不會另開新場覆蓋。技能歸因只接受可靠來源；多筆候選、衝突或逾時仍顯示「未辨識傷害」，不使用傷害大小、目前動作、最近施放、倍率＋元素或三格技能猜測。灼燒與中毒若沒有施加來源也不會冒充某個技能。只需要 UE4SS Experimental；PalSchema 不是必要依賴。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

本專案是獨立維護的 MIT 衍生作品。Boss 遭遇辨識、帕魯歸屬與安全訊息核心源自 AsahiChan-Game/PalBossDPSBroadcast；技能逐擊歸因、DPS HUD、原生 F3 CommonUI、施放／命中統計與 Boss 結算快照由本專案後續開發。這是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
