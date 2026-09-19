# 帕魯技能傷害計量器

Palworld 1.0 單人世界傷害驗證 Mod。預設只計算帕魯；野外／副本 Boss 與石板 Boss 分開測試。石板戰報只合併同種且三格配招完全相同的基地帕魯，配招不同就分成 A、B 等組。模組不向遊戲聊天室輸出任何資料，也不進行玩家排名。

## 使用方法

1. 訂閱並啟用本 Mod 與 `UE4SS Experimental (Palworld)`。
2. 按 F3，在「測試類型」選擇「野外／副本 Boss」或「石板 Boss」，再關閉設定。
3. 按 F2 開始新測試（傷害歸零）；第一筆有效傷害才會開始計時。
4. 石板模式主 HUD 以配招組顯示三個技能的累計傷害與占比；F3「本次測試詳情」保留每隻帕魯的實際傷害與 Hit／施放資料。

人物傷害預設關閉。要測試武器時，修改：

```lua
config.IncludePlayerDamage = true
```

完整重開遊戲，並建議一場只使用一種武器。可辨識時依武器／投射物分桶；無法辨識時保留為未知人物武器。

設定檔位於：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\config.lua
```

v0.5.45 在 F3「分組百分比」頁的每個技能旁同時顯示實際累計傷害與占比，並將公開及遊戲內名稱改為「帕魯技能傷害計量器」。既有 Workshop 訂閱與內部套件身分不變。請只沿用原訂閱，不要另裝測試檔；完整退出遊戲，等 Steam 更新後重開。

專案：https://github.com/paul800901/PalSkillDPSAnalyzer

本專案是獨立維護的 MIT 衍生作品。Boss 遭遇辨識、帕魯歸屬與安全訊息核心源自 AsahiChan-Game/PalBossDPSBroadcast；技能逐擊歸因、DPS HUD、原生 F3 CommonUI 與施放／命中統計由本專案後續開發。這是非官方社群 Mod，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。
