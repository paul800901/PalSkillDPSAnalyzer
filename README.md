# PalSkillDPSAnalyzer v0.5.28-mummy-rush-four-hit

Palworld 1.0 單機用 UE4SS 傷害驗證 Mod。它不是玩家排行榜，而是專門測量帕魯對 Boss 造成的技能傷害。F3 明確分成「野外／副本 Boss」與「石板 Boss」兩種測試，不由模組自動混判；普通野怪與未選用石板模式的基地混戰不納入正式統計。

人物傷害預設關閉。需要測試武器時，可在另一場戰鬥中開啟人物來源；能辨識武器／投射物就分桶，不能辨識時保留為未知人物武器，不猜名稱。

## 獨立技能 DPS 面板

第一次有效命中後，畫面左側安全區會開啟縮小至 85% 的透明置頂 HUD；模組完全不向遊戲聊天室送出任何資料，也沒有聊天輸出設定。野外／副本模式維持技能名稱、累計傷害、DPS、占比與測試時間。石板模式則改成簡化戰報：依「種類＋三技能配招」分組，同種同配招顯示 `×N`，同種不同配招分成 A／B 組；每組只顯示三技能占比數字與長條。主 HUD 固定只保留傷害最高的三組，其餘以提示導向 `F3`。F3 有三個同層分頁：「設定」、「分組百分比」完整列出所有配招組；第三頁「本次測試詳情」保留原有每隻帕魯的實際傷害、DPS、施放與 Hit 詳情。

預設是「手動測試區間＋野外／副本 Boss」：按 `F2` 可安全歸零並重新待命，直到第一下有效 Boss 傷害才開始計時；基地派駐帕魯在此模式會被排除。要測召喚石板戰，先在 F3 把「測試類型」切到「石板 Boss」，再按 `F2` 開始新測試。困難塔主只統計具有 `GYM` 角色身分、實際擁有塔主血條的主體；塔內小怪即使也帶 Boss／TowerBoss 資料旗標仍會排除。世界倍率產生的多隻真正 Boss 仍會持續累計，直到下一次 `F2` 才清空。

實機已確認目前 Palworld／UE4SS 會在 Lua 動態 UMG 與 `PrintString` 路徑造成 GameThread 存取違規。顯示層因此隔離成隨附的 Windows WPF 程序：Lua 只寫入本機 UTF-8 結構化狀態檔，不再從傷害回呼呼叫 Unreal UI。面板只在 Palworld 位於前景時顯示，遊戲關閉後約 10 秒自行退出。

目前 `v0.5.28` 保留嚴格的技能來源規則：引擎可直接對接的 Waza、效果或來源鏈列為精確歸屬；若同一隻帕魯對同一 Boss 僅有 2–4 筆最終傷害先到、隨後只有一個引擎 `OnAttack` Waza 來源，則進入該技能桶但明確標成「推定」。極寒雙星與鑽石星辰另允許同目標已連結 Hit 承接約 1.2 秒後的最後爆炸；完全缺少來源時，也只接受最近唯一、無鄰近衝突的這兩種已完成配裝動作。雙槍一閃若已在同一攻擊者／目標建立施放綁定，可承接 1 秒內且原生傷害序號緊接上一段的最後 Hit；中間插入任何其他原生傷害事件就不補接。閃雷衝鋒只在同一帕魯／目標的精確 Action 仍進行中、開始後 1.5–3.3 秒內接收第一筆無來源 Hit；每次施放最多一筆且不接受尾段。隕星雨則把每個 `Commet` 子技能標記一對一歸入已裝備的 `CommetRain` 父技能，只接受約 1 秒後的同目標命中且每個標記僅能使用一次。突襲木乃伊只在精確 Action 開始至少 2 秒後建立四段綁定，後續原生序號須嚴格遞增；全域序號可被其他已辨識事件推進，中間揮空也不限制相鄰命中間隔，Action 尾段最多保留 0.35 秒且每次最多四 Hit。其他較大批次、來源衝突、逾時或物件世代不符仍維持「未辨識傷害」。石板模式中的基地派駐帕魯必須同時具有非空基地 ID，且目前群組必須等於本機玩家公會。全程不按傷害大小、倍率＋元素或三格技能反推。

- 顯示語言（跟隨遊戲／17 種指定語言）
- 技能 DPS 面板開關
- 人物／武器傷害（預設關閉）
- 手動測試區間／每個目標自動分場
- 野外／副本 Boss（預設）／石板 Boss
- 完整／精簡資料密度（預設精簡長條）
- 內部英文技能代碼（預設不顯示）
- 左／右安全區、左上／右上位置與 75%／85%／100%／115% 縮放
- 自動分場的戰後結果顯示時間
- `F2` 開始新測試（歸零並在第一下命中開始計時）

手動設定保存在 `Scripts/config.lua`。完整逐次施放證據仍會寫入 `UE4SS.log`：

```text
[PalSkillDPSAnalyzer] diagnostic-source boss=... source_kind=pal source=... damage=... dps=... hits=... candidates=...
[PalSkillDPSAnalyzer] diagnostic-candidate boss=... candidate=... localized=... damage=... encounter_dps=... casts=... panel_cd=... actual_interval=... action_duration=... action_dps=... reuse_gap=... lifecycle_coverage=...
[PalSkillDPSAnalyzer] diagnostic-cast boss=... candidate=... cast=... damage=... hits=... action_duration=... cast_dps=... hit_window=... lifecycle=...
```

帕魯攻擊使用每次施放、技能效果實例、父子效果、`AttackFilter.Waza`、Blueprint OnAttack 與最終 OnDamage 的精確來源鏈。原生 Event v2 中，沒有精確來源的命中原則上顯示「未辨識傷害」；僅針對已實機確認具有長飛行／落地延遲的極寒雙星與鑽石星辰，允許同目標近期已連結 Hit 或唯一無衝突的已完成配裝動作補接，並明確標示為推定。即時三格裝備、一般目前／最近動作、`BasePower` 與元素不得單獨決定技能桶。三格外的內建補招只有在引擎提供直接 Waza 證據時才標示為「普攻｜技能名稱」。解包證據與來源鏈計畫見 `docs/SKILL_EFFECT_ATTRIBUTION.md` 與 `docs/ATTRIBUTION_HOOK_PROBE_PLAN.md`。

## 預設測試模式

```lua
config.EnableSkillDiagnostics = true
config.SkillDiagnosticsOnly = true
config.MeasurementMode = "manual"
config.TargetScope = "field"
config.IncludePlayerDamage = false
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

候選套件輸出位於 `workshop/dist/PalSkillDPSAnalyzerSP-Workshop-v0.5.28.zip`。專案保留獨立的 `Info.json`、PackageName 與 Workshop Published File ID，不會覆蓋上游 Mod；套件包含 Lua、遊戲內 CommonUI 主介面 PAK 與 LogicMods 啟動 PAK。Steam Workshop 公開版目前是 v0.5.28。

## 驗證流程

1. 啟用本 Mod 與 UE4SS Experimental。
2. 野外／副本測試保留預設類型後按 F2；石板測試先在 F3 選「石板 Boss」，再按 F2，讓基地帕魯攻擊召喚 Boss。
3. 確認左側即時儀表沒有左右跳動，且晶鑽之雨沒有再被歸到暗能彈。
4. 測試後保留 `UE4SS.log`，供技能建立、最終傷害與動作生命週期逐筆核對。
5. 以原生 capabilities 中的 `attack_matches`、`exact_hits`、`unresolved_hits`，以及 `diagnostic-candidate`／`diagnostic-cast` 行確認精確來源鏈與顯示結果；沒有 exact 證據的命中不得進入具名技能桶。
6. 如需測武器，先在 `config.lua` 開啟人物傷害，完整重開遊戲，另開一場全程只使用同一武器。

## 適用邊界

- 正式目標：Palworld 1.0 Windows 單人世界。
- Boss 房間、塔主、地城／競技場 Boss 與有 Boss／Alpha 標記的大世界頭目使用「野外／副本 Boss」；召喚／石板 Boss 使用「石板 Boss」。普通野生帕魯與 PvP 不納入。
- 持續傷害、燃燒、中毒、同一泛用投射物承載多種技能等情況，可能先進入未知或合併候選。
- 「面板 CD」來自遊戲技能資料庫；「實際開始間隔」是相鄰施放開始到開始，會包含 AI 選招、移動、距離與其他技能造成的等待，不等同純冷卻。
- 「完整動作」只統計成功捕捉開始與結束的施放。報表的 `完整計時 n/m` 是覆蓋率；未完整捕捉時只保留首末命中窗，不把它冒充動作時間。
- 原生 Event v2 逐擊事件在歸因前不聚合；若原生收集器不可用，Lua 相容模式仍可統計總傷，但不保證重疊持續技能的精確歸因。
- `F3` 開啟／關閉遊戲內原生面板；用滑鼠直接切換「設定」、「分組百分比」與「本次測試詳情」三個同層分頁。不註冊 `F1`，避免與其他常見 Mod 衝突。
- 外部 HUD 會以本機心跳自我檢查並在中止後重新啟動；例外記錄位於 `Scripts/skill_dps_hud_overlay.log`。
- 外部 HUD 需要 Windows PowerShell 5.1 與 WPF（Windows 10／11 內建）；若安全軟體阻擋 PowerShell，統計核心與 `UE4SS.log` 仍可運作，但畫面面板不會出現。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run_all.ps1
```

離線測試不連線、不啟動或修改 Palworld。涉及新版 Palworld／UE4SS 的改版仍需重新進行受控 Boss 實機驗證；v0.5.24 已完成困難塔主 GYM 篩選、延遲冰技能尾段與總傷守恆的本機實戰驗收。

原生 C++ 來源收集器的工具鏈、鎖定版本、Git 邊界與 Workshop 發佈分工，見
[`docs/NATIVE_DEVELOPMENT.md`](docs/NATIVE_DEVELOPMENT.md)。Visual Studio 與第三方
依賴可保留在專案目錄，但不會被提交到 Git；乾淨 checkout 可由鎖定檔重新建立。

## 授權與來源

MIT License。Boss 遭遇辨識、帕魯歸屬與安全訊息核心衍生自 [AsahiChan-Game/PalBossDPSBroadcast](https://github.com/AsahiChan-Game/PalBossDPSBroadcast)，詳細見 [NOTICE.md](NOTICE.md)。17 語言技能名稱表由 `tools/update_skill_names.ps1` 從 [PalDB Active Skills](https://paldb.cc/en/Active_Skills) 的遊戲本地化資料產生。本專案為獨立 Mod，與 Pocketpair、PalDB、Steam 或 UE4SS 無隸屬關係。
