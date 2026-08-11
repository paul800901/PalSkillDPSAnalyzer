# 帕魯技能 DPS 分析器

Palworld 1.0 單人世界傷害驗證 Mod。預設只計算帕魯，依技能 ID、投射物或傷害來源建立診斷候選；獨立 HUD 會即時列出逐技能傷害、施放次數、每次傷害、面板 CD、實際間隔、完整動作、單次施放 DPS 與再用空窗。聊天輸出預設關閉，不進行玩家排名。

## 使用方法

1. 訂閱並啟用本 Mod 與 `UE4SS Experimental (Palworld)`。
2. 進入單人世界後按 F1 開啟設定面板；方向鍵上下選擇，左右或 Enter 調整。
3. 使用一隻帕魯攻擊 Boss；右上專用面板會即時更新。
4. 擊殺、捕捉或停止造成傷害 60 秒後完成結算。
5. 保留 `Palworld\Mods\NativeMods\UE4SS\UE4SS.log`。

人物傷害預設關閉。要測試武器時，可直接在 F1 面板開啟，或修改：

```lua
config.IncludePlayerDamage = true
```

完整重開遊戲，並建議一場只使用一種武器。可辨識時依武器／投射物分桶；無法辨識時保留為未知人物武器。

設定檔位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

這是 v0.4.2 外部透明 HUD 版。F1 可選跟隨遊戲或 17 種指定語言，設定、DPS 欄位與技能名稱會同步切換；也可選擇顯示內部英文代碼。實機確認目前 UE4SS 的 Lua 動態 UMG 與 `PrintString` 都可能造成 GameThread 崩潰，因此本版只由 Lua 寫入本機狀態檔，再交給隨附的 Windows WPF 透明面板顯示，不再呼叫 Unreal UI，也不使用聊天框。同一技能不同次施放會合併，同時保留逐次動作計時。只需要 UE4SS Experimental；PalSchema 不是必要依賴。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

MIT License。核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。本專案是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
