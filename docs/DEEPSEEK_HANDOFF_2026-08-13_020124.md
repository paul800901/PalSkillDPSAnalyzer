# DeepSeek 交接：停止用倍率／時間窗回猜技能來源

## 結論（STOP-SHIP）

目前的逐技能傷害歸因架構不能再靠補 `SkillMetadataFallbacks`、延長時間窗或增加單招特例繼續修。`Apocalypse`（啟示錄）與 `BubbleShower`（本機日誌稱「毒雨」，本場 HUD 顯示「暴雨」）已證明：同一隻帕魯連續施放多段／延遲技能時，僅用「目前動作、最近動作、BasePower、屬性、命中時間」會同時產生兩種相反錯誤：

1. 前一招的延遲命中被後一招或更舊的綁定搶走。
2. 當下技能明確正在施放，它自己的多段傷害卻因「最近另一招」而被丟進未歸屬。

這不是啟示錄或毒雨的單招資料缺漏，而是來源關聯鍵錯誤。遊戲裡相同性質的落雨、地板、爆炸、追蹤彈、持續領域與狀態效果很多；不建立「每次施放 → 效果／DamageInfo → 最終傷害」的來源鏈，繼續補表只會讓不同技能彼此污染。

本文件只整理證據與實作契約；本輪沒有修改任何程式碼、設定、安裝檔或工作坊內容。

## 本場證據範圍

- 影片：`C:\Users\Paulus\Desktop\錄製內容 2026-08-13 020124.mp4`
- 影片規格：204.373313 秒、1920×1080、30 FPS、6,128 個視訊影格。
- 驗證：6,128／6,128 影格可完整解碼，無解碼錯誤；另以每 2 秒接觸表與下列關鍵命中區段逐段對時。
- UE4SS 日誌：`E:\Program Files (x86)\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\UE4SS.log`
- 本場 session：`2026-08-13 01:57:58.481` 開始。
- 夜幕魔蝠三格：`Apocalypse,BubbleShower,DarkLegion`。
- 影片與日誌的近似換算：影片 00:17.5 約等於日誌 01:57:58.5。

## 最終 HUD 原始結果

| HUD 顯示列 | 傷害 | 比例 | 命中 | 施放 |
|---|---:|---:|---:|---:|
| 暴雨 | 64,388 | 15.3% | 43 | 12 |
| 未歸屬傷害 | 253,871 | 60.4% | 192 | 0 |
| 黑暗之擁 | 54,519 | 13.0% | 28 | 4 |
| 普攻｜暗能彈 | 38,885 | 9.3% | 29 | 20 |
| 啟示錄 | 8,337 | 2.0% | 5 | 6 |
| **總計** | **420,000** | **100%** | **297** | — |

## 依影片、動作生命週期與最終傷害簽名還原的本場真值

這裡是本場回歸 fixture 的真值，不是建議把倍率硬編碼成正式歸因規則。

| 正確來源 | 正確傷害 | 正確命中 | 原始 HUD 錯誤 |
|---|---:|---:|---|
| `BubbleShower`（毒雨／暴雨） | **72,725** | **48** | 其中 8,337／5 hits 被誤標為啟示錄 |
| `Apocalypse`（啟示錄） | **253,871** | **192** | 本體全部落入未歸屬 |
| `DarkLegion`（黑暗之擁） | **54,519** | **28** | 此列本場一致 |
| `GravityShot`（普攻｜暗能彈） | **38,885** | **29** | 此列本場一致 |
| **總計** | **420,000** | **297** | 傷害守恆 |

還原依據：

- 日誌中的 160／闇共有 48 hits、72,725 damage：
  - `BubbleShower`：20 hits、25,803。
  - `UNRESOLVED ... BP_160 ...`：23 hits、38,585；HUD 快照階段已把這些併入暴雨。
  - 被錯標 `Apocalypse`、但仍是 160／闇：5 hits、8,337。
- 上述 5 hits 全都緊接 `BubbleShower` 結束後落地：
  - 01:58:45.902、01:58:46.191（BubbleShower 於 01:58:45.570 結束）。
  - 02:00:05.131、02:00:05.154（BubbleShower 於 02:00:04.770 結束）。
  - 02:00:44.080（BubbleShower 於 02:00:44.070 結束，下一招 DarkLegion 到 02:00:44.094 才開始）。
- 400／闇樣本全部以 `UNRESOLVED_PAL_ATTACK_BP_400_ELEMENT_8` 記錄；逐候選 64 筆日誌上限已滿，留下 64 hits、85,082 damage。完整 HUD 未歸屬桶則為 192 hits、253,871 damage；本場沒有第二種仍留在 HUD 未歸屬的簽名。
- 影片約 00:20–00:24、00:40–00:42、00:58–01:02、02:14–02:18、02:56–02:58 可見反覆成排出現的紅黑旋渦／領域命中，與 Apocalypse action 及 400／闇連續傷害段對時。
- 影片約 01:02–01:06、02:24–02:26、03:02–03:04 可見 BubbleShower 的紫色彈雨／殘留命中；其中殘留傷害跨過 action end，正是 160／闇被舊綁定錯抓的區段。

## 可重現的第一段交錯時序

| 日誌時間 | 影片約略時間 | 事件 | 應有歸因 |
|---|---|---|---|
| 01:57:55.839 | 00:14.8 | `BubbleShower` action begin | 建立 Bubble cast A |
| 01:57:58.507 | 00:17.5 | `BubbleShower` action end | cast A 結束施法，但效果可繼續命中 |
| 01:57:58.556 | 00:17.6 | `Apocalypse` action begin | 建立 Apocalypse cast B |
| 01:58:01.018 起 | 00:20.0 起 | 400／闇連續命中，日誌同時顯示 `Action_Apocalypse` | Apocalypse cast B；現版卻全部 unresolved |

## 可重現的延遲命中誤標時序

| 日誌時間 | 事件 | 現版結果 | 正確結果 |
|---|---|---|---|
| 01:58:42.928 | `BubbleShower` action begin | — | 建立 Bubble cast C |
| 01:58:45.218、45.335 | 160／闇命中 | concurrent conflict／未辨識 | Bubble cast C |
| 01:58:45.570 | `BubbleShower` action end | — | cast C 的場上效果仍可命中 |
| 01:58:45.584 | `GravityShot` action begin | — | 建立普攻 cast D，不得搶 Bubble 殘留 |
| 01:58:45.902、46.191 | 160／闇命中 | `Apocalypse` | Bubble cast C |

這組序列已同時涵蓋「技能 A 延遲命中、技能 B 已開始、普攻又插入」；任何只看 current/recent action 的演算法都不足以解題。

## 已確認根因

### 1. 延遲效果綁定鍵沒有 cast 身分

`Scripts/main.lua:1594-1642` 的 `recent_action_evidence` 使用：

```text
binding_key = source_actor_key .. "|" .. attack_signature
```

也就是只有「帕魯＋BasePower／元素簽名」，沒有 action instance、cast ID、effect instance、DamageInfo identity 或 defender。`SkillEffectMaxLifetimeSeconds=45`，且每次命中都會更新 `last_hit_at`；只要命中間隔未超過 3 秒，舊綁定可以持續續命。不同 cast、甚至不同技能共用／碰撞同一簽名時，後續傷害會被舊 record 接管。

### 2. current/recent 衝突分支會把明確的當下技能刪掉

`Scripts/main.lua:1874-1899`：只要最近完成技能與目前裝備技能不同，就把 `attribution.Source` 改成 `concurrent_action_conflict`，並清除 action class。Apocalypse 正在施放且 400／闇爆發與影片特效完全同時，仍因更舊 action 存在而全數變成 unresolved。

### 3. 精確 Waza／DamageInfo 主鏈沒有捕捉到本帕魯的輸出

本場時間範圍內共有 16 筆 `skill-trace waza-marker`，但：

- 夜幕魔蝠（actor `1861576876064`）作為 attacker 的 outbound marker：**0**。
- 夜幕魔蝠作為 defender 的 marker：15。

也就是 `/Script/Pal.PalUtility:MakeDamageInfoByWazaType` 在現行 Lua hook 中只捕到 Boss 對帕魯的路徑，沒有捕到夜幕魔蝠這三招的輸出路徑。最終 damage event 又是 `DamageCauser=none`，因此真正可精確串接的證據根本沒有進入歸因器。

### 4. 現有原生 collector 也不足以逐技能歸因

`native/src/BossDPSNativeCollector.cpp:444-510` 只在 final damage 讀取 attacker、defender、ActualDamage、DamageCauser、OverrideNetworkOwner、info attacker，隨即以這些指標聚合。

`native/include/CollectorCore.hpp` 的 key 沒有 Waza、cast、action instance、effect instance、DamageInfo identity、BasePower／element 或事件時間；`native/src/BossDPSNativeCollector.cpp:534-562` 拉回 Lua 時也只有聚合後總傷／hits 與幾個 UObject。即使啟用這個 collector，它目前也已在關聯前丟掉命中順序與來源鏈，無法解決本問題。

### 5. 逐候選 sample cap 會遮蔽完整錯誤

BP400 unresolved 在 64 筆後停止逐筆記錄，但 HUD 繼續累積到 192 hits。因此離線測試若只讀 diagnostic samples，會錯以為資料只有 85,082；回歸 fixture 必須保存完整事件流或至少保存所有來源關聯鍵與最終分桶，不得用截斷樣本當真值。

## DeepSeek 必須實作的來源鏈

### A. 每次施放建立不可變 cast record

最少欄位：

```text
cast_id
attacker_object_id（需含 UObject serial/generation，不能只用可重用裸指標）
action_instance_id / action GUID
waza_id / canonical code
begin_game_time / end_game_time
```

`cast_id` 必須代表「這一次施放」，不能代表技能名稱，也不能只代表帕魯。

### B. 在效果／DamageInfo 建立時攜帶 cast_id

需要先用診斷 hook 找到夜幕魔蝠 outgoing damage 實際經過的建立路徑，不能假設目前的 `MakeDamageInfoByWazaType` 已涵蓋。對每個新建 projectile、ground field、marker、explosion、attack filter 或 DamageInfo，保存：

```text
effect_instance_id -> cast_id
damage_info_id -> cast_id
child_effect_instance_id -> parent_effect_instance_id -> cast_id
```

若 DamageInfo 在流程中被複製／包裝，必須在複製點傳遞同一 token，或找出可跨 copy 保留的穩定欄位。不能等到 final damage 才用當時正在播放的動作回猜。

### C. final damage 只按強證據連接

建議優先序：

1. exact DamageInfo identity／propagated token；
2. exact effect instance／owner chain；
3. final result 內直接 WazaID；
4. action instance 明確建立的 effect token；
5. 若以上全無，保留 unresolved 或另列「推測」，不得寫成確定技能。

`BasePower + element` 只能作診斷交叉檢查與 legacy fallback，不能作 production 主鍵；相同倍率、同屬性、同時命中與未來平衡改版都會破壞它。

### D. 狀態傷害獨立建模

中毒、灼燒等 DoT 需要在「狀態施加」當下建立：

```text
status_application_id
attacker / defender / status_type
source_cast_id（若遊戲有保留）
applied_at / expires_at
```

tick 以 status application identity 回接。若遊戲沒有保留施加來源，就顯示「中毒／灼燒（來源未知）」，不可把 tick 依時間灌給最近技能。

### E. 資料結構限制

- 用 bounded deque／ring buffer 保存逐事件來源鏈；不可只存每個 attacker 的 latest marker。
- identity key 必須防 UObject 位址重用。
- 每筆 final hit 必須保留 sequence 與高精度 game time，直到完成歸因後才可聚合。
- 聚合 key 至少要包含 `source actor + cast_id/waza + defender/session`；不能在歸因前先只按 attacker/defender 合併。
- 世界切換、角色銷毀、重設測試時清理弱引用與未完成來源鏈。

## 禁止以這些方式宣稱修好

1. 只新增 `Apocalypse=400/8`、`BubbleShower=160/8` 到 fallback 表。
2. 把 10／45 秒視窗再調長。
3. 繼續使用 `actor|signature` 作唯一 delayed binding key。
4. 看到 current action 就全部歸 current，或看到 recent action 就全部歸 recent。
5. 讓 snapshot 階段把 unresolved 依唯一倍率重新命名，卻沒有 cast/effect 證據。
6. 只通過 stub 單元測試，沒有重播交錯事件與實機 trace。

上述做法可能暫時讓本場 HUD 好看，但遇到另一個同倍率技能、同時場地效果、多帕魯或改版後仍會再錯。

## 必做回歸 fixture

### Fixture 1：本場 420,000 傷害守恆

重播本文件的 action/final-hit 時序後必須得到：

```text
BubbleShower = 72,725 / 48 hits
Apocalypse   = 253,871 / 192 hits
DarkLegion   = 54,519 / 28 hits
GravityShot  = 38,885 / 29 hits
Total        = 420,000 / 297 hits
Unresolved   = 0（fixture 已提供完整 source token 的前提）
```

### Fixture 2：A 延遲、B 當下、普攻插入

- Bubble cast A 結束。
- 50 ms 後 Apocalypse cast B 開始。
- A 的 160／闇殘留命中。
- B 的 400／闇領域同時命中。
- GravityShot 又開始並命中 40／闇。

三者必須各自回到 A、B、GravityShot；不能靠命中先後覆蓋。

### Fixture 3：同倍率同屬性

兩個不同技能故意使用相同 BasePower／element，同一隻帕魯重疊命中同一目標。只要 cast/effect token 不同，仍須分成兩列。

### Fixture 4：同技能多 cast／多目標

同一技能下一次施放開始時，上一次地板效果仍存在；兩個 cast 同時打多個目標。不得把舊 cast 續命成新 cast，或因 target 不同而丟失來源。

### Fixture 5：狀態效果

兩招都可造成同一種狀態時，狀態 tick 只能依 status application token 回接；沒有 token 時保持來源未知。

### Fixture 6：缺證據必須 fail closed

移除 effect／DamageInfo／Waza token，只保留 BasePower、element、current/recent action。正式確定值必須 unresolved；可另外輸出低信心推測供診斷，但不得污染正式技能總傷。

## 完成門檻

- 夜幕魔蝠 outgoing skill path 必須能產生 Waza/cast/effect token；不能再是 0 筆來源標記。
- 本場 fixture 精確通過上列四個分桶與 420,000 傷害守恆。
- 延遲技能與新技能重疊時，0 筆跨 cast 誤標。
- 同倍率同屬性測試仍可分辨。
- 未知來源不偽裝成技能。
- 實機診斷輸出要能列出每次 cast、effect/DamageInfo 關聯與 final hit sequence；不得再被 64 筆 sample cap 遮住關鍵段。
- 通過離線測試後仍需一次相同三技能的實機回讀；未做 live readback 前只能標「本機 fixture 驗證」，不能宣稱正式修好。

## DeepSeek 建議的實作順序

1. **先做純診斷版**：找出帕魯 outgoing damage 真正走的函式／效果建立點，記錄 action instance、effect instance、DamageInfo 與 final damage 的身分鏈；暫時不要再改分桶結果。
2. **建立 cast/effect graph**：讓來源 token 從施放一路傳到 final hit。
3. **延後聚合**：逐 hit 完成歸因後才加總。
4. **把 current/recent/signature 降為非正式推測**：移除它們覆蓋強證據的能力。
5. **加入上述六個 fixtures**，再做同配裝實機驗證。

這才是能覆蓋啟示錄、毒雨以及同類大量延遲技能的解法；單招補表不再接受為完成。
