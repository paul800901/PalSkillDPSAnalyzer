[h1]帕魯技能 DPS 分析器[/h1]
[b]適用於 Palworld 1.0 單人世界的傷害驗證工具。[/b]

這不是玩家排名 Mod。每隻帕魯都是獨立測試來源，依 Palworld 傷害事件可讀到的技能 ID、投射物或傷害來源建立候選，輸出總傷害、整場 DPS、占比、命中數與平均每擊傷害。

[h2]診斷版功能[/h2]
[list]
[*]預設只計算帕魯；人物與武器傷害預設關閉
[*]可選擇以一場一種武器的方式驗證人物傷害
[*]只使用可回讀證據建立候選；未知傷害不會被猜成某個技能
[*]結算時直接在遊戲聊天欄列出每個技能的傷害、占比、整場 DPS、命中與平均每擊
[*]在 UE4SS.log 寫入有界逐擊樣本與技能歸屬證據
[*]支援 Boss 擊殺、捕捉與無傷害逾時結算
[/list]

[h2]安裝[/h2]
[olist]
[*]訂閱本 Mod。
[*]訂閱並啟用 [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url]。
[*]在 Palworld Mod 管理器啟用兩個 Mod。
[*]讓一隻技能配置已知的帕魯攻擊 Boss，結束後保留 UE4SS.log。
[/olist]

[h2]人物武器測試[/h2]
將 [code]config.IncludePlayerDamage = true[/code]，完整重開 Palworld，並在整場戰鬥中只使用一種武器。能可靠辨識武器或投射物就建立獨立候選；不能辨識時保留為未知人物武器。

[h2]適用範圍[/h2]
[list]
[*][b]目標：[/b]Windows 單人世界
[*][b]目前狀態：[/b]v0.1.2 診斷版，同一技能的不同施放會合併成一列
[*][b]不做：[/b]比較不同玩家或建立競技 DPS 排名
[/list]

原始碼與問題追蹤：[url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]獨立 MIT Mod，核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。與 Pocketpair、Steam 或 UE4SS 無隸屬關係。[/i]
