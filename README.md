# PalSkillDPSAnalyzer v0.5.16-native-filter-callback-probe

Palworld 1.0 單機用 UE4SS 傷害驗證 Mod。它不是玩家排行榜，而是專門測量帕魯對 Boss 造成的技能傷害：預設接受競技場／高塔／地城／石板等封閉戰鬥 Boss，以及大世界有 Boss／Alpha 標記的頭目；普通野怪與基地混戰不納入預設正式統計。輸出包含總傷害、整場 DPS、占比、命中、每次施放傷害、完整動作時間、單次施放 DPS、實際施放間隔與 AI／再用空窗。

人物傷害預設關閉。需要測試武器時，可在另一場戰鬥中開啟人物來源；能辨識武器／投射物就分桶，不能辨識時保留為未知人物武器，不猜名稱。

## 獨立技能 DPS 面板

第一次有效命中後，畫面左側安全區會開啟縮小至 85% 的透明置頂 HUD；聊天輸出預設關閉。戰鬥儀表只顯示前五個技能的官方本地化名稱，並把總傷害放在每列與整體摘要的主要位置；整場 DPS、占比與施放次數作為次要效率資訊，避免時間增加造成 DPS 波動時遮蔽真正累積輸出。

預設是「手動 Boss 測試區間」：按 `F2` 可安全歸零並重新待命，直到第一下對可辨識 Boss 的有效命中才開始計時；之後即使其中一隻 Boss 死亡，測試仍會持續，直到再次按 F2。競技場內 Boss 與大世界 Boss 標記目標都會接受；普通野生帕魯預設排除。

實機已確認目前 Palworld／UE4SS 會在 Lua 動態 UMG 與 `PrintString` 路徑造成 GameThread 存取違規。顯示層因此隔離成隨附的 Windows WPF 程序：Lua 只寫入本機 UTF-8 結構化狀態檔，不再從傷害回呼呼叫 Unreal UI。面板只在 Palworld 位於前景時顯示，遊戲關閉後約 10 秒自行退出。

目前 `v0.5.16` 延續原生逐擊來源配對，並針對仍未涵蓋的技能本體主命中加入 `PalAttackFilter` 原生回呼與有限 final-source 診斷。只有 Filter 回呼與最終傷害位於同一引擎呼叫鏈、攻擊者／Boss 目標一致且 Waza 完整時才可正式歸因；其餘維持「未辨識傷害」。診斷不使用目前動作、最近施放、時間、`BasePower`＋元素或面板倍率猜測。上一版受控 Boss 場的 128 次命中全部守恆，98 次已有精確／一致來源，剩餘 30 次屬於第二條主命中路徑；本版用來確認其可靠來源。灼燒與中毒維持獨立狀態傷害方向，不會假裝屬於某個技能。F1 外部互動設定維持暫停；使用 `F2` 隨時開始新測試（傷害歸零），其他選項修改 `Scripts/config.lua` 後完整重開遊戲：

- 顯示語言（跟隨遊戲／17 種指定語言）
- 技能 DPS 面板開關
- 人物／武器傷害（預設關閉）
- 手動測試區間／每個目標自動分場
- Boss 與頭目（預設）／所有野生帕魯（僅額外診斷）
- 完整／精簡資料密度（預設精簡長條）
- 內部英文技能代碼（預設不顯示）
- 左／右安全區、左上／右上位置與 75%／85%／100%／115% 縮放
- 自動分場的戰後結果顯示時間
- 聊天輸出關閉／摘要／完整
- `F2` 開始新測試（歸零並在第一下命中開始計時）

手動設定保存在 `Scripts/config.lua`。完整逐次施放證據仍會寫入 `UE4SS.log`：

```text
[PalSkillDPSAnalyzer] diagnostic-source boss=... source_kind=pal source=... damage=... dps=... hits=... candidates=...
[PalSkillDPSAnalyzer] diagnostic-candidate boss=... candidate=... localized=... damage=... encounter_dps=... casts=... panel_cd=... actual_interval=... action_duration=... action_dps=... reuse_gap=... lifecycle_coverage=...
[PalSkillDPSAnalyzer] diagnostic-cast boss=... candidate=... cast=... damage=... hits=... action_duration=... cast_dps=... hit_window=... lifecycle=...
```

帕魯攻擊使用每次施放、技能效果實例、父子效果、`AttackFilter.Waza`、Blueprint OnAttack 與最終 OnDamage 的精確來源鏈。原生 Event v2 中，沒有精確來源的命中直接顯示「未辨識傷害」；即時三格裝備、目前／最近動作、`BasePower` 與元素只保留為診斷資訊，不得決定正式技能桶。三格外的內建補招只有在引擎提供直接 Waza 證據時才標示為「普攻｜技能名稱」。解包證據與來源鏈計畫見 `docs/SKILL_EFFECT_ATTRIBUTION.md` 與 `docs/ATTRIBUTION_HOOK_PROBE_PLAN.md`。

## 預設測試模式

```lua
config.EnableSkillDiagnostics = true
config.SkillDiagnosticsOnly = true
config.MeasurementMode = "manual"
config.TargetScope = "boss"
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

輸出位於 `workshop/dist/PalSkillDPSAnalyzerSP-Workshop-v0.5.16.zip`。專案已保留獨立的 `Info.json`、PackageName 與空白 Workshop Published File ID，不會覆蓋上游 Mod。原生來源收集器目前隨專案本機建置；正式 Workshop 發布前仍需完成原生 DLL 的套件化與實機驗收。

## 驗證流程

1. 啟用本 Mod 與 UE4SS Experimental。
2. 進入世界後按 F2 歸零，再使用帕魯攻擊一隻競技場／石板 Boss 或有 Boss 標記的大世界頭目；計時從第一下可接受 Boss 傷害開始。
3. 確認左側即時儀表沒有左右跳動，且晶鑽之雨沒有再被歸到暗能彈。
4. 測試後保留 `UE4SS.log`，供技能建立、最終傷害與動作生命週期逐筆核對。
5. 以原生 capabilities 中的 `attack_matches`、`exact_hits`、`unresolved_hits`，以及 `diagnostic-candidate`／`diagnostic-cast` 行確認精確來源鏈與顯示結果；沒有 exact 證據的命中不得進入具名技能桶。
6. 如需測武器，先在 `config.lua` 開啟人物傷害，完整重開遊戲，另開一場全程只使用同一武器。

## 適用邊界

- 正式目標：Palworld 1.0 Windows 單人世界。
- Boss 房間、塔主、地城／競技場 Boss、召喚／石板 Boss 與有 Boss／Alpha 標記的大世界頭目是正式目標；普通野生帕魯、基地群戰與 PvP 不是預設正式統計範圍。
- 持續傷害、燃燒、中毒、同一泛用投射物承載多種技能等情況，可能先進入未知或合併候選。
- 「面板 CD」來自遊戲技能資料庫；「實際開始間隔」是相鄰施放開始到開始，會包含 AI 選招、移動、距離與其他技能造成的等待，不等同純冷卻。
- 「完整動作」只統計成功捕捉開始與結束的施放。報表的 `完整計時 n/m` 是覆蓋率；未完整捕捉時只保留首末命中窗，不把它冒充動作時間。
- 原生 Event v2 逐擊事件在歸因前不聚合；若原生收集器不可用，Lua 相容模式仍可統計總傷，但不保證重疊持續技能的精確歸因。
- v0.5.16 暫不提供 F1 互動設定；HUD／語言／人物傷害等選項需編輯 `config.lua` 並完整重開 Palworld。
- 外部 HUD 會以本機心跳自我檢查並在中止後重新啟動；例外記錄位於 `Scripts/skill_dps_hud_overlay.log`。
- 外部 HUD 需要 Windows PowerShell 5.1 與 WPF（Windows 10／11 內建）；若安全軟體阻擋 PowerShell，統計核心與 `UE4SS.log` 仍可運作，但畫面面板不會出現。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run_all.ps1
```

離線測試不連線、不啟動或修改 Palworld。實機反射欄位仍需一次受控 Boss 戰驗證。

原生 C++ 來源收集器的工具鏈、鎖定版本、Git 邊界與 Workshop 發佈分工，見
[`docs/NATIVE_DEVELOPMENT.md`](docs/NATIVE_DEVELOPMENT.md)。Visual Studio 與第三方
依賴可保留在專案目錄，但不會被提交到 Git；乾淨 checkout 可由鎖定檔重新建立。

## 授權與來源

MIT License。Boss 遭遇辨識、帕魯歸屬與安全訊息核心衍生自 [AsahiChan-Game/PalBossDPSBroadcast](https://github.com/AsahiChan-Game/PalBossDPSBroadcast)，詳細見 [NOTICE.md](NOTICE.md)。17 語言技能名稱表由 `tools/update_skill_names.ps1` 從 [PalDB Active Skills](https://paldb.cc/en/Active_Skills) 的遊戲本地化資料產生。本專案為獨立 Mod，與 Pocketpair、PalDB、Steam 或 UE4SS 無隸屬關係。
