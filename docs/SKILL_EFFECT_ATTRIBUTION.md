# 技能效果歸因證據

本表只收錄已從 Palworld 1.0 熟化資產直接確認的規則。`DamageCauser` 類別命中本表時，優先級高於「目前動作」與「最近一次施放」；沒有直接證據的效果仍保留未歸屬，不依畫面或時間猜技能。

## DiamondFall（晶鑽之雨）

動作資產 `BP_ActionDiamondFall` 明確使用 `EPalWazaID::DiamondFall`，並在動作開始 1.6 秒後建立 `BP_SkillEffect_DiamondFall_Marker`。

Marker 的熟化屬性與位元碼顯示：

- `FallInterval = 0.3`
- `AmbienceFallCount = 10`
- `PredictFallCount = 7`
- `DirectFallCount = 3`
- 逐次建立 `BP_SkillEffect_DiamondFall_Fall`

兩個實際傷害階段：

| DamageCauser 類別 | 階段 | 資產內 Waza | WazaPowerRate |
|---|---|---|---:|
| `BP_SkillEffect_DiamondFall_Fall_C` | 冰塊落下命中 | `EPalWazaID::DiamondFall` | 0.05 |
| `BP_SkillEffect_DiamondFall_Explode_C` | 落地範圍爆炸 | `EPalWazaID::DiamondFall` | 0.05 |

`Fall` 在碰撞後以 `GetOwner()` 作為 Owner 建立 `Explode`，所以兩段都應歸入同一隻帕魯的同一個 DiamondFall 技能列；不可拆成兩個技能，也不可因爆炸發生時帕魯已改放別招而被改歸到新技能。

## 收錄門檻

新增技能規則前至少要符合其一：

1. 傷害效果的 `PalAttackFilter` 直接宣告 `Waza`。
2. 專屬效果由已知技能效果建立，且 Owner／Instigator 的傳遞路徑可由資產確認。

僅有相同元素、相同 BasePower、相近命中時間或相似特效，不足以建立固定規則。

## 裝備技能唯一簽名（Palworld 1.0）

部分多段技能的最終傷害事件沒有 `WazaID` 與 `DamageCauser`，但遊戲技能資料仍提供固定的 `BasePower` 與屬性。此類簽名只在該技能確實位於該帕魯當下三格 `EquipWaza`，而且三格內只有一個技能符合時使用；換技能後會立即重建，不會跨配裝沿用。

2026-08-13 兩場火系實機紀錄確認：

| 技能 | BasePower | 屬性 | 面板 CD | 實機最終傷害事件 |
|---|---:|---:|---:|---|
| `FireBall`（烈焰球） | 600 | 2（火） | 30 | 直擊與延遲命中皆為 600／2 |
| `FlameFunnel`（流火） | 300 | 2（火） | 16 | 多枚火球皆為 300／2 |
| `FlareTornado`（烈焰風暴） | 200 | 2（火） | 12 | 雙龍捲持續命中皆為 200／2 |

`GravityShot`（暗能彈）的 40／8 是另一個固定簽名。當它是目前動作且最終傷害也是 40／8 時，必須保留為普攻，不得因前一個火系技能的延遲效果仍在場上而併入火系技能。

2026-08-13 世界樹之龍長戰的 282 筆可讀最終傷害事件另確認：

| 技能 | BasePower | 屬性 | 面板 CD | 實機最終傷害事件 |
|---|---:|---:|---:|---|
| `DarkLaser`（暗黑雷射） | 450 | 8（闇） | 30 | 64 筆無 Waza 命中在舊版全數進入未辨識 |
| `DarkLegion`（黑暗之擁） | 600 | 8（闇） | 30 | 59 筆已辨識、34 筆因同時動作衝突而未辨識 |
| `PoisonShot`（劇毒射擊） | 30 | 8（闇） | 2 | 64 筆已辨識、41 筆因同時動作衝突而未辨識 |

這三個簽名仍只在該帕魯當下三格裝備為 `DarkLaser / DarkLegion / PoisonShot` 時生效。舊版畫面的 189,323 未辨識傷害可由 450／8、600／8、30／8 三個桶完整解釋，不代表存在第四個主動技能。

灼燒是獨立狀態傷害，不等於上述火系技能的多段命中。若最終傷害路徑沒有保留施加者，現階段不得猜回某個技能；需另以狀態傷害事件與施加來源建立關聯。

中毒同樣是獨立狀態傷害，不等於 `PoisonShot` 的 30／8 本體命中。本次最終傷害日誌能修正的是三個主動技能本體；沒有攻擊者／施加來源的毒傷仍不得直接灌入劇毒射擊。
