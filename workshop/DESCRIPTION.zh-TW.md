[h1]帕魯技能 DPS 分析器[/h1]
[b]適用於 Palworld 1.0 單人世界的傷害驗證工具。[/b]

這不是玩家排名 Mod。可隨時開始新測試並歸零，從第一筆有效傷害開始計時；坐騎、隊伍／跟隨帕魯與基地帕魯都依實際個體分組，再依技能輸出傷害、DPS、占比、施放與動作計時。

[h2]獨立 HUD 與安全歸零[/h2]
[list]
[*]預設只計算帕魯；人物與武器傷害預設關閉
[*]可選擇以一場一種武器的方式驗證人物傷害
[*]原生逐擊來源鏈沿施放、效果、AttackFilter Waza、Blueprint OnAttack 連到最終傷害
[*]缺少精確來源時保留未辨識，不使用目前動作、最近施放或倍率＋元素猜測
[*]技能預設只顯示遊戲官方本地化名稱；內部英文代碼仍保留在紀錄
[*]對照遊戲面板 CD 與實際施放開始間隔，顯示受 AI、移動與選招影響的差值
[*]結算時列出每次傷害、完整動作、單次施放 DPS、再用空窗與計時覆蓋率
[*]左側安全區的精簡技能 DPS 儀表即時更新；總傷害為主要大數字，DPS 為次要效率資訊，不再使用聊天框
[*]崩潰隔離顯示：Lua 只寫入本機 UTF-8 狀態檔，由隨附透明 Windows 面板呈現，不呼叫 Unreal UMG 或 PrintString
[*]F2 可隨時開始新測試並歸零，不開外部視窗、不改遊戲游標或輸入
[*]外部 HUD 改為固定尺寸、不可點擊的純顯示層，避免焦點爭搶與左右跳動
[*]預設只顯示官方中文名稱；進階選項可在 config.lua 修改
[*]在 UE4SS.log 寫入有界逐擊樣本、逐次施放與技能歸屬證據
[*]預設支援所有野生帕魯、野外／石板 Boss、多目標與基地多帕魯戰鬥；也可切回只限 Boss
[/list]

[h2]安裝[/h2]
[olist]
[*]訂閱本 Mod。
[*]訂閱並啟用 [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url]。
[*]在 Palworld Mod 管理器啟用兩個 Mod。
[*]進入世界按 F2 歸零，再讓一隻或多隻帕魯攻擊任意野生帕魯／Boss。
[*]結束後保留 UE4SS.log。
[/olist]

[h2]人物武器測試[/h2]
可在 config.lua 開啟人物傷害，完整重開遊戲，並在整場戰鬥中只使用一種武器。能可靠辨識武器或投射物就建立獨立候選；不能辨識時保留為未知人物武器。

[h2]適用範圍[/h2]
[list]
[*][b]目標：[/b]Windows 單人世界
[*][b]目前狀態：[/b]v0.5.14 原生精確歸因診斷版；缺少精確來源一律保留未辨識，F1 舊外部設定暫停，F2 安全歸零；原生 DLL 正式套件化與實機驗收仍在進行中
[*][b]必要前置：[/b]UE4SS Experimental；PalSchema 不是必要依賴
[*][b]不做：[/b]比較不同玩家或建立競技 DPS 排名
[/list]

原始碼與問題追蹤：[url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]獨立 MIT Mod，核心衍生自 AsahiChan-Game/PalBossDPSBroadcast。與 Pocketpair、Steam 或 UE4SS 無隸屬關係。[/i]
