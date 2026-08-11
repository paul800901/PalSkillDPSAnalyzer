# PalSkillDPSAnalyzer v0.4.2-external-hud

Palworld 1.0 單機用 UE4SS Lua 傷害驗證 Mod。它不是玩家排行榜，目標是把一場 Boss 測試中的每隻帕魯視為獨立來源，依可讀到的技能、投射物或攻擊欄位分桶，輸出總傷害、整場 DPS、占比、命中、每次施放傷害、完整動作時間、單次施放 DPS、實際施放間隔與 AI／再用空窗。

人物傷害預設關閉。需要測試武器時，可在另一場戰鬥中開啟人物來源；能辨識武器／投射物就分桶，不能辨識時保留為未知人物武器，不猜名稱。

## 獨立技能 DPS 面板

第一次打中 Boss 後，畫面右上會開啟專用透明置頂 HUD；聊天輸出預設關閉。每個技能會顯示總傷害、整場 DPS、命中、施放次數、每次傷害、完整動作時間、單次施放 DPS、面板 CD、實際開始間隔及 AI／再用空窗。技能預設只顯示本地化名稱，內部英文代碼保留在紀錄並可由 F1 選擇顯示。

實機已確認目前 Palworld／UE4SS 會在 Lua 動態 UMG 與 `PrintString` 路徑造成 GameThread 存取違規。v0.4.2 因此把顯示層隔離成隨附的 Windows WPF 程序：Lua 只寫入本機 UTF-8 狀態檔，不再從傷害回呼呼叫 Unreal UI。面板只在 Palworld 位於前景時顯示，遊戲關閉後約 10 秒自行退出。

F1 可選擇「跟隨遊戲」或 Palworld 的 17 種支援語言。切換後設定頁、DPS 面板與技能名稱會立即同步更新；即使 MOD 選擇的語言不同於遊戲介面，技能名稱仍會使用內建對照表切換。未收錄的新技能會先回退英文，再回退遊戲執行中讀到的名稱或內部代碼。

按 `F1` 開啟設定面板，以方向鍵選擇、左右鍵或 Enter 調整：

- 顯示語言（跟隨遊戲／17 種指定語言）
- 技能 DPS 面板開關
- 人物／武器傷害（預設關閉）
- 完整／精簡資料密度
- 內部英文技能代碼（預設不顯示）
- 左上／右上位置與 80%／100%／120% 縮放
- 戰後是否保留結果
- 聊天輸出關閉／摘要／完整
- 清除本場測試

設定會寫入 `Scripts/user_settings.lua`，下次啟動沿用。若 F1 已被其他 UE4SS 模組占用，會自動改用 `Ctrl+F1`。完整逐次施放證據仍會寫入 `UE4SS.log`：

```text
[PalSkillDPSAnalyzer] diagnostic-source boss=... source_kind=pal source=... damage=... dps=... hits=... candidates=...
[PalSkillDPSAnalyzer] diagnostic-candidate boss=... candidate=... localized=... damage=... encounter_dps=... casts=... panel_cd=... actual_interval=... action_duration=... action_dps=... reuse_gap=... lifecycle_coverage=...
[PalSkillDPSAnalyzer] diagnostic-cast boss=... candidate=... cast=... damage=... hits=... action_duration=... cast_dps=... hit_window=... lifecycle=...
```

帕魯攻擊會優先讀取 Palworld 建立傷害資料時帶入的 `EPalWazaID`；實機沒有 Waza 訊號時，改用穩定化後的動作類別，例如 `BeamSlicer`、`FlareTornado`。每次施放產生的 UObject 編號不會再把同一技能拆成多列。泛用持續傷害只有在 `BasePower + AttackElementType` 能唯一對應到一招時才合併，否則保留未解析候選，不會硬猜名稱。

## 預設測試模式

```lua
config.EnableSkillDiagnostics = true
config.SkillDiagnosticsOnly = true
config.IncludePlayerDamage = false
config.SkillDiagnosticChatMode = "off"
config.EnableSkillDPSHUD = true
config.EnableExternalHUD = true
config.ExternalHUDAutoLaunch = true
config.DumpDamageSchema = false
config.SkillDiagnosticLogCasts = true
```

要另外測試人物武器，將 `IncludePlayerDamage` 設為 `true`，完整重開遊戲，再以一場只使用一種武器的 Boss 戰進行測試。

## Steam 創意工坊單機安裝

診斷包只需要 `UE4SS Experimental (Palworld)`。PalSchema 是許多資料型 Mod 的常見前置，但本 Mod 不修改資料表，因此不是必要依賴。Palworld Mod 管理器會把 Lua 腳本安裝到：

```text
Palworld\Mods\NativeMods\UE4SS\Mods\PalSkillDPSAnalyzerSP\Scripts\
```

開發中的本機建包：

```powershell
powershell -ExecutionPolicy Bypass -File .\workshop\build_workshop.ps1
```

輸出位於 `workshop/dist/PalSkillDPSAnalyzerSP-Workshop-v0.4.2.zip`。專案已保留獨立的 `Info.json`、PackageName 與空白 Workshop Published File ID，不會覆蓋上游 Mod。

## 驗證流程

1. 啟用本 Mod 與 UE4SS Experimental。
2. 進入世界後按 F1，確認專用面板與設定可開啟。
3. 預設先只帶一隻帕魯，使用已知的 2–3 個技能攻擊 Boss。
4. 結束戰鬥後保留 `UE4SS.log`。
5. 以 `HUD backend=external-file`、`Waza attribution hook`、`action_hooks=true/true`、`diagnostic-candidate` 和 `diagnostic-cast` 行確認顯示後端、技能代號、官方名稱與動作計時。
6. 如需測武器，在 F1 面板開啟人物傷害，另開一場全程只使用同一武器。

## 適用邊界

- 正式目標：Palworld 1.0 Windows 單人世界。
- Boss 房間、塔主、野外 Boss 與召喚 Boss 可用；PvP 不是目前目標。
- 持續傷害、燃燒、中毒、同一泛用投射物承載多種技能等情況，可能先進入未知或合併候選。
- 「面板 CD」來自遊戲技能資料庫；「實際開始間隔」是相鄰施放開始到開始，會包含 AI 選招、移動、距離與其他技能造成的等待，不等同純冷卻。
- 「完整動作」只統計成功捕捉開始與結束的施放。報表的 `完整計時 n/m` 是覆蓋率；未完整捕捉時只保留首末命中窗，不把它冒充動作時間。
- 診斷版強制使用 Lua 傷害事件，避免原生聚合器先丟失技能候選欄位。
- F1 的 HUD／語言／人物傷害等選項會即時保存；直接編輯 `config.lua` 時仍建議完整重開 Palworld。
- 外部 HUD 需要 Windows PowerShell 5.1 與 WPF（Windows 10／11 內建）；若安全軟體阻擋 PowerShell，統計核心與 `UE4SS.log` 仍可運作，但畫面面板不會出現。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run_all.ps1
```

離線測試不連線、不啟動或修改 Palworld。實機反射欄位仍需一次受控 Boss 戰驗證。

## 授權與來源

MIT License。Boss 遭遇辨識、帕魯歸屬與安全訊息核心衍生自 [AsahiChan-Game/PalBossDPSBroadcast](https://github.com/AsahiChan-Game/PalBossDPSBroadcast)，詳細見 [NOTICE.md](NOTICE.md)。17 語言技能名稱表由 `tools/update_skill_names.ps1` 從 [PalDB Active Skills](https://paldb.cc/en/Active_Skills) 的遊戲本地化資料產生。本專案為獨立 Mod，與 Pocketpair、PalDB、Steam 或 UE4SS 無隸屬關係。
