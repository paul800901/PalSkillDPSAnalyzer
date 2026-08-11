[h1]帕魯技能 DPS 分析器[/h1]
[b]適用於 Palworld 1.0 單人世界的傷害驗證工具。[/b]

這不是玩家排名 Mod。每隻帕魯都是獨立測試來源，依 Palworld 傷害事件與動作生命週期建立候選，輸出總傷害、整場 DPS、占比、命中、施放次數、每次傷害、完整動作、單次施放 DPS、實際間隔與再用空窗。

[h2]診斷版功能[/h2]
[list]
[*]預設只計算帕魯；人物與武器傷害預設關閉
[*]可選擇以一場一種武器的方式驗證人物傷害
[*]只使用可回讀證據建立候選；未知傷害不會被猜成某個技能
[*]技能優先顯示遊戲官方本地化名稱，並保留內部英文代碼
[*]對照遊戲面板 CD 與實際施放開始間隔，顯示受 AI、移動與選招影響的差值
[*]結算時列出每次傷害、完整動作、單次施放 DPS、再用空窗與計時覆蓋率
[*]在 UE4SS.log 寫入有界逐擊樣本、逐次施放與技能歸屬證據
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
[*][b]目前狀態：[/b]v0.2.0 診斷版，具官方中英名稱、面板／實測 CD 對照與完整動作 DPS
[*][b]不做：[/b]比較不同玩家或建立競技 DPS 排名
[/list]

原始碼與問題追蹤：[url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]獨立 MIT Mod，核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。與 Pocketpair、Steam 或 UE4SS 無隸屬關係。[/i]
