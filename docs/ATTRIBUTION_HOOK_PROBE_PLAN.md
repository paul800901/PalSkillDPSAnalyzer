# 帕魯技能來源鏈：UE4SS 最小診斷探針計畫

## 0.5.12 實作狀態

本文件原先是探針計畫；`v0.5.12` 已完成第一階段 Lua 實作：

- Action begin 建立每次施放的獨立 cast_id。
- `PalSkillEffectBase:OnInitialize` 與 `PalAttackFilter:BindPrimitiveComponent` 捕捉效果實例及 Filter Waza。
- 對已載入效果類別列舉 OnAttack Blueprint handler，使用 `RegisterCustomEvent` 接收 Context、Defencer、DamageInfo 與 hitCount。
- OnAttack 與巢狀 final OnDamage 以一次性 pending token 串接；事件順序錯開時只按 actor＋Waza＋捕捉時間回補 cast。
- BasePower、元素、目前／最近動作及裝備簽名均已降為診斷欄位，不得進正式技能桶。

離線回歸已完成，Palworld 實機尚須讀回 `effect-init`、`effect-attack`、`effect-hit-match`。因此目前狀態是「已安裝前候選、待 live 驗證」，不是正式完成。

## 結論

下一步不應直接改分桶規則，而應先做一個預設關閉、只寫事件日誌的診斷探針，確認帕魯輸出實際走過的：

```text
本次施放（cast）
  -> 技能效果實例（PalSkillEffectBase）
  -> PalAttackFilter / OnAttack damageInfo
  -> 最終 PalCharacterParameterComponent:OnDamage
```

本機證據已足以把第一輪探針縮到四條主要 hook：

1. 既有 `PalActionBase:OnBeginAction / OnEndAction`，建立每次施放身分。
2. `PalSkillEffectBase:OnInitialize`，取得每個效果實例、Owner 與其 `AttackFilter`。
3. `PalAttackFilter:BindPrimitiveComponent`，在傷害碰撞元件綁定時讀出 Filter 的 Waza 與所屬效果。
4. 技能 Blueprint 的 `OnAttackDelegate` 綁定函式，取得命中當下的 `Defencer + FPalDamageInfo + hitCount + AttackerComponent`，再與既有最終 `OnDamage` 對時、對欄位。

`MakeDamageInfoByWazaType` 保留作比較探針，但不能再當作帕魯輸出的唯一來源；目前實機已證明它只抓到 Boss 對帕魯的路徑。

下列內容保留原始診斷實驗與驗收契約，供實機失敗時定位缺少的來源節點。

## 證據邊界

### 目前機器上的實際狀態

- UE4SS 安裝根：`E:\Program Files (x86)\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS`。
- UE4SS 內含 `Pal-5.1.1-0+++UE5+Release-5.1-c838a8ac.usmap`，映射檔可見下列反射名稱：
  - `PalSkillEffectBase`
  - `PalAttackFilter`
  - `PalDamageInfo`
  - `PalCalculatedDamageInfo`
  - `OnProcessedActualDamageDelegate`
  - `OnInflictDamageDelegate`
  - `OnAttackDelegate`
  - `ActualDamage`
- 已安裝的 `AlwaysWinFishing` Lua 實際使用 `NotifyOnNewObject(...)`，證明這份 UE4SS build 提供物件建立通知 API。
- 目前 Workshop manifest 與遊戲 `Mods` 目錄中**沒有** PerfProbe（`3767336617`）或 SimpleDPS（`3769396301`）檔案；因此本輪不能把它們的傷害 hook 當作已即時驗證的證據。專案既有報告只留下先前對其 UMG/CommonUI 架構的靜態結論，沒有可重用的技能來源 hook 證據。

### 現有實機日誌已確認的失敗

`UE4SS.log` 在 2026-08-13 01:58–02:08 共留下 40 筆 `waza-marker`：

- 全部 attacker 都是世界樹之龍 Boss。
- 夜幕魔蝠作為 outgoing attacker 的 marker 是 0 筆。
- 夜幕魔蝠的最終輸出仍可在 `PalCharacterParameterComponent:OnDamage` 取得 attacker、defender、ActualDamage、BasePower、element。
- 這些輸出的 `DamageCauser=none`，也沒有可與 `MakeDamageInfoByWazaType` ReturnValue identity 配對的帕魯 Waza marker。

因此問題不是 post-hook 參數順序仍錯，而是帕魯技能根本沒有走目前掛到的 `MakeDamageInfoByWazaType` 路徑。

### FModel 已確認的技能效果結構

本機 FModel 匯出位於：

`D:\CodexScratch\jobs\20260812-023855_PalSkillDPSAnalyzer_5568b66b\work\FModel\Output\Exports`

晶鑽之雨提供一條可驗證的完整樣本：

- `BP_ActionDiamondFall`：`WazaID = EPalWazaID::DiamondFall`，建立 `BP_SkillEffect_DiamondFall_Marker`。
- `BP_SkillEffect_DiamondFall_Marker_C:OnInitialize` 確實覆寫 `/Script/Pal.PalSkillEffectBase:OnInitialize`。
- Marker 以 `GameplayStatics:BeginDeferredActorSpawnFromClass` 建立 `BP_SkillEffect_DiamondFall_Fall`，並將 `GetOwner()` 結果傳入子效果的 Owner 鏈。
- `BP_SkillEffect_DiamondFall_Fall` 再用 `GetOwner()` 建立 `BP_SkillEffect_DiamondFall_Explode`。
- Fall 與 Explode 的 `PalAttackFilter_0` 都直接宣告：

```text
Waza = EPalWazaID::DiamondFall
WazaPowerRate = 0.05
```

- Fall 的 Blueprint 先呼叫 Filter 的 `BindPrimitiveComponent(Capsule)`。
- Fall 綁定的 OnAttack 函式具有精確參數：

```text
Defencer          AActor*
damageInfo        FPalDamageInfo（320 bytes in this cooked asset）
hitCount          int32
AttackerComponent UPrimitiveComponent*
```

這代表 Waza 在效果 Filter 層仍存在，且 `damageInfo` 在最終 `OnDamage` 之前已經過一個可觀察的命中節點。這比 BasePower／元素／時間窗可靠得多。

### 現有原生 collector 的限制

`native/src/BossDPSNativeCollector.cpp` 目前只 hook 最終傷害，然後立刻依：

```text
defender + attacker + damage_causer + override_network_owner + info_attacker
```

聚合。`CollectorCore` 沒有 sequence、game time、Waza、cast、effect、AttackFilter 或逐筆 DamageInfo fingerprint。它會在完成來源關聯以前丟掉事件順序，因此第一版探針不可沿用這個聚合輸出；必須先保存逐事件 ring buffer。

## 第一階段：先做反射清冊，不開始分桶

在遊戲執行緒上用 `StaticFindObject` 檢查候選 UFunction；對找到的函式列出 `CPF_Parm`、`CPF_ReturnParm`、型別、offset 與 FunctionFlags。只有清冊確認存在、參數順序正確後才註冊 hook。

必查候選：

| 優先級 | 候選物件／函式 | 目的 | 當前證據 |
|---|---|---|---|
| P0 | `/Script/Pal.PalActionBase:OnBeginAction` | 建立 cast_id | 現有 Lua 已實機成功，能讀 action GUID、actor、WazaID |
| P0 | `/Script/Pal.PalActionBase:OnEndAction` | 關閉施法動作但保留延遲效果 | 現有 Lua 已實機成功 |
| P0 | `/Script/Pal.PalSkillEffectBase:OnInitialize` | 捕捉 effect instance 與 Owner/Filter | FModel Marker override 明確呼叫此父函式 |
| P0 | `/Script/Pal.PalAttackFilter:BindPrimitiveComponent` | 捕捉 Filter、效果 Actor、碰撞元件與 Waza | Fall/Explode bytecode 均直接呼叫；參數為 PrimitiveComponent |
| P0 | `/Script/Pal.PalCharacterParameterComponent:OnDamage` | 最終傷害與守恆 | 現有 Lua／native 均已實機成功 |
| P1 | DiamondFall Fall 的 Blueprint `...OnAttackDelegate__DelegateSignature` 綁定函式 | 直接觀察 Filter 命中前的 `FPalDamageInfo` | FModel 已確認四個參數 |
| P1 | `/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass` | 若 OnInitialize Owner 鏈不足，取得 child effect ReturnValue -> Owner | Marker/Fall bytecode已確認使用 |
| P1 | `/Script/Engine.GameplayStatics:FinishSpawningActor` | 確認 deferred child 完成建立 | 同上 |
| P2 | `/Script/Pal.PalUtility:MakeDamageInfoByWazaType` | 與 Boss 成功路徑比對，不作帕魯主鏈 | 現有 hook 只捕到 Boss outgoing |
| P2 | `OnProcessedActualDamageDelegate` 的 SignatureFunction | 尋找最終處理後但尚未聚合的事件 | usmap 只確認 delegate 名稱，尚未確認 owner/signature |
| P2 | `OnInflictDamageDelegate` 的 SignatureFunction | 尋找 attacker-side 最終命中事件 | usmap 只確認 delegate 名稱，尚未確認 owner/signature |
| 備援 | `/Script/Pal.PalDamageReactionComponent:MulticastDamageReact` | `OnDamage` 不存在時才使用 | 現有程式已列為 compatibility fallback |

注意：`OnProcessedActualDamageDelegate`、`OnInflictDamageDelegate`、`OnAttackDelegate` 是 delegate property 名稱，不一定本身就是可 `RegisterHook` 的 UFunction。不得只拼路徑硬掛；必須先由 owner property 反射取得 `SignatureFunction`。若需要綁定 delegate 才能收到事件，該方案會改變遊戲物件狀態，第一輪先不採用。

## 最小探針候選與回呼資料

### Probe A：Action lifecycle（既有、保留）

Hook：

```text
/Script/Pal.PalActionBase:OnBeginAction
/Script/Pal.PalActionBase:OnEndAction
```

每次 begin 產生新的 `cast_id`，不可把「帕魯＋Waza」當 cast_id。保存：

```text
event_seq
event_type = cast_begin / cast_end
game_time
qpc_time
thread_id
cast_id
action_object_id + UObject serial/generation（native 可得時）
action_guid
attacker_object_id
waza_id / canonical_code
```

`cast_end` 只代表動作結束；不得刪除已由該 cast 建立的 effect 關聯。

### Probe B：PalSkillEffectBase initialization

首選 hook：

```text
/Script/Pal.PalSkillEffectBase:OnInitialize
```

只讀 Context（effect object），不要修改屬性、不要呼叫初始化。擷取：

```text
effect_object_id + serial/generation
effect_full_name / class_full_name
owner_object_id / owner_class
instigator_object_id（若可讀）
attack_filter_object_id
attack_filter.Waza
attack_filter.WazaPowerRate
最近且仍 active 的同 owner cast_id（僅暫列 correlation，不算正式歸因）
```

若基底 `OnInitialize` 沒涵蓋所有子類，再用 `NotifyOnNewObject` 對**明確的測試技能效果類別**補觀察。不要對所有 Actor 使用全域 `NotifyOnNewObject`。

### Probe C：PalAttackFilter binding

候選 hook：

```text
/Script/Pal.PalAttackFilter:BindPrimitiveComponent
```

預期回呼形狀需以第一階段反射清冊為準；FModel bytecode顯示至少含一個 `PrimitiveComponent` 參數。擷取：

```text
attack_filter_object_id
filter outer / owner effect_object_id
filter.Waza
filter.WazaPowerRate
primitive_component_id
primitive_component owner actor
```

成功時可直接建立：

```text
attack_filter_id -> effect_id -> cast_id
```

這條鏈不依賴最終傷害倍率，也不因施放下一招而被覆蓋。

### Probe D：已知技能 Blueprint OnAttack

第一個定點 probe 使用晶鑽之雨 Fall。FModel 的 cooked object path 為：

```text
Pal/Content/Pal/Blueprint/Skill/DiamondFall/
BP_SkillEffect_DiamondFall_Fall.
BP_SkillEffect_DiamondFall_Fall_C:
BndEvt__BP_EnergyShotBullet_AttackFilter_
K2Node_ComponentBoundEvent_1_OnAttackDelegate__DelegateSignature
```

實際 UE4SS path 必須先用 `StaticFindObject` 從 `/Game/Pal/Blueprint/Skill/DiamondFall/...` 與 cooked full name 驗證，不得假設 FModel package path 可原字串直接註冊。

已確認參數順序：

```text
Context = BP_SkillEffect_DiamondFall_Fall_C instance
Defencer
damageInfo (FPalDamageInfo)
hitCount
AttackerComponent
```

擷取：

```text
effect_id（Context）
attack_filter_id（Context.AttackFilter）
defender_id
attacker_component_id + owner
hit_count
damage_info_call_address（僅作同一 callback 診斷，不視為長期 identity）
damage_info primitive fingerprint
```

`FPalDamageInfo` fingerprint 至少複製以下存在的 primitive／UObject 欄位：

```text
Waza / WazaID / WazaType
BasePower
AttackElementType
Attacker / Defender
DamageCauser
OverrideNetworkOwner
WeaponType
hit location / foliage index（若有）
```

Lua 的 struct wrapper 或臨時記憶體位址可能重用；正式 join 不得只靠該位址。探針要比較「OnAttack 的 primitive fingerprint」是否原樣或可預測地出現在 final `OnDamage`。

### Probe E：Effect spawn chain（條件式）

只有 Probe B/C 無法取得 parent effect 時才短時間啟用：

```text
/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass
/Script/Engine.GameplayStatics:FinishSpawningActor
```

這是高頻全域函式。回呼第一行就依 SpawnClass 過濾 `PalSkillEffectBase` 子類；非測試帕魯或非 SkillEffect 不做名稱解析、不寫 log。

BeginDeferred 的 post callback 需記錄：

```text
spawn_class
owner_object_id
ReturnValue child_effect_id
spawn transform（只在需要辨識多個同類 child 時保留）
```

可建立 `child_effect_id -> owner/parent_effect_id -> cast_id`。晶鑽之雨資產已證明 Marker -> Fall -> Explode 使用這條 Owner 傳遞路徑。

## 統一事件格式

輸出採逐行 JSONL 或固定欄 TSV；不要寫聊天框、不要更新 HUD、不要先聚合。

所有事件共同欄位：

```text
schema_version
probe_run_id
event_seq（全域單調遞增）
event_type
wall_time_utc
game_time_seconds
qpc_ticks
thread_id
world_id / level_name
```

物件欄位使用：

```text
address
UObject index + serial/generation（native 可得時必須保存）
FName
full_name
class_full_name
valid_at_capture
```

事件型別最少包含：

```text
reflection_candidate
hook_registered / hook_unavailable
cast_begin / cast_end
effect_new / effect_initialize
attack_filter_bind
effect_spawn_begin / effect_spawn_finish
attack_delegate
make_damage_info
final_damage
probe_drop / probe_fault / probe_stop
```

## 低風險啟停與保護

1. 探針預設 `false`，只能在遊戲啟動前由獨立設定開啟；不要占用 F1/F2，也不要產生設定面板。
2. 探針為 diagnostics-only：不改正式分桶、不改簽名表、不改 UI、不向聊天框輸出。
3. 只觀察使用者目前測試的單一帕魯 attacker；其他 actor 第一層即丟棄。
4. 不綁定／移除遊戲 delegate，不寫 `PalAttackFilter`，不改 Owner、Instigator、Waza 或 DamageInfo。
5. 事件先寫入有界 ring buffer（建議 8,192 或 16,384 筆），由遊戲執行緒外批次落盤；hook 內不格式化大型 UObject tree。
6. 硬上限：單次 3 分鐘或 20,000 筆事件；任一達到即只記 `probe_stop` 並停止收集。
7. 連續反射錯誤、buffer overflow、無效 UObject 或世界切換時 fail closed，不自動切回時間推定。
8. 全域 spawn hook 只在 P0/P1 資料不足時啟用，且必須有 class/owner early filter。
9. 測試時只開 UE4SS 必要前置與本 Mod；其他傷害統計 Mod 保持停用，避免多重 hook 改變順序。
10. 結束後保留原始 probe log；解析器輸出是派生資料，不可覆蓋原始事件流。

## 分階段執行順序

### Stage 0：反射清冊

- 只找候選 UFunction／delegate owner/signature。
- 輸出每個參數與 ReturnValue 的真實順序。
- 不記傷害、不改分桶。

### Stage 1：基底效果鏈

啟用：Action lifecycle、PalSkillEffectBase OnInitialize、PalAttackFilter BindPrimitiveComponent、final OnDamage。

先測晶鑽之雨單招。若每個 Fall/Explode 都有 effect/filter/Waza，直接進 Stage 3；否則 Stage 2。

### Stage 2：定點 OnAttack／spawn probe

- 掛晶鑽之雨 Fall 的 Blueprint OnAttack 綁定函式。
- 必要時短暫加 BeginDeferred/FinishSpawning。
- 證明 `cast -> Marker -> Fall -> Explode -> OnAttack damageInfo -> final damage`。

### Stage 3：兩招重疊壓力測試

用 `BubbleShower -> Apocalypse -> GravityShot` 的既有回歸順序：

- Bubble 延遲命中必須仍帶 Bubble cast/effect/filter 鏈。
- Apocalypse 的 BP400 多段必須帶 Apocalypse cast/effect/filter 鏈。
- GravityShot 不得接走前兩招的延遲傷害。
- 正式驗證不准使用 BasePower、元素或最近動作作 join key。

### Stage 4：擴充未知技能與狀態傷害

- 對啟示錄、毒雨、火系多段技解包其 Action/SkillEffect/PalAttackFilter。
- 若所有技能都經過 Filter，就將 Probe C 做成通用原生來源鏈。
- 若中毒／灼燒不走同一 Filter，另找 status application identity；來源不存在時保留「狀態傷害（來源未知）」。

## 成功門檻

### 探針本身

- 所有候選都有 `hook_registered` 或帶明確原因的 `hook_unavailable`，不得靜默缺失。
- 一次晶鑽之雨施放至少看到一筆 cast、Marker、Fall、Explode／其 AttackFilter、OnAttack 與 final damage 時序。
- 每筆事件都有單調 sequence 與同一時間基準；不得只靠 `os.time()` 秒級時間。
- 事件丟失為 0；若丟失，該場不可用於歸因驗收。

### 歸因可行性

- 晶鑽之雨落下與爆炸兩段能以 effect/filter/owner chain 回到**同一 cast_id**。
- 在下一招已開始後，晶鑽之雨延遲落地仍回到舊 cast，而不是 current/recent action。
- BubbleShower 與 Apocalypse 同時在場時，兩者 final hit 仍有不同的 exact source token。
- 多隻同型帕魯同時攻擊同一目標時，token 必須包含 effect/cast/attacker identity，不得因 Waza 相同而合併。
- 每場 `sum(final_damage by exact source) + unresolved = raw final damage total`，傷害與命中數完全守恆。
- 來源鏈缺失時輸出具體 unresolved reason；不得退回「唯一倍率」並宣稱精確。

### 安全與效能

- 無崩潰、無遊戲輸入異常、無 UI／焦點副作用。
- 單一測試帕魯下 FPS 差異不超過 2%，沒有持續卡頓。
- hook 回呼 p95 低於 1 ms；高頻 final/Filter hook 不做磁碟同步寫入。
- 停止探針或換世界後，ring buffer、弱物件映射與 cast/effect 關聯都可清除，沒有跨世界位址誤用。

## 不可採用的捷徑

- 不要只把 `Apocalypse=400/8`、`BubbleShower=160/8` 寫進表。
- 不要把 effect 綁定鍵設為 `attacker + BasePower + element`。
- 不要延長 current/recent action 時間窗。
- 不要把 Blueprint 類別名稱本身當成 cast_id；同技能連放仍是不同 cast。
- 不要以 Lua temporary struct wrapper address 當永久 DamageInfo identity。
- 不要在來源鏈完成前使用現有 native collector 聚合。
- 不要因 PerfProbe／SimpleDPS 曾經能顯示總傷，就推論它們已解決逐技能來源；本機目前沒有可驗證的該模組檔案。

## 第一個最小交付物

第一個實作版本只需交付：

1. 候選函式反射清冊。
2. 一份晶鑽之雨單招的完整 JSONL 事件流。
3. 一份 BubbleShower／Apocalypse 重疊事件流。
4. 離線 join 報表，逐 hit 列出 `cast_id -> effect_id -> filter_id / damageInfo fingerprint -> final_damage_seq`。

在這四項證明來源鏈可跨延遲、跨下一招且守恆以前，不改正式 HUD 的技能分桶邏輯。
