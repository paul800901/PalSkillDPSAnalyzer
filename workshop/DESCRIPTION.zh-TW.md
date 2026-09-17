[h1]帕魯技能 DPS 分析器[/h1]
[b]適用於 Palworld 1.0 單人世界的 Boss 傷害驗證工具。[/b]

測量每個帕魯技能的實際傷害、DPS、占比、命中段數與施放次數；不是玩家排行榜。野外／副本 Boss 與石板 Boss 由使用者明確選擇；石板戰報只合併同種且完整三格配招相同的帕魯。

[h2]安裝與測試[/h2]
[olist]
[*]訂閱本模組與 [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url]，在 Palworld 模組管理器啟用兩者，再完整重啟遊戲。不需要 PalSchema。
[*]按 [b]F3[/b] 選擇「野外／副本 Boss」或「石板 Boss」，關閉設定後按 [b]F2[/b] 清除舊結果。第一筆有效 Boss 傷害才開始計時。
[*]讓帕魯攻擊對應 Boss。即時儀表顯示總傷害、DPS 與技能列；F3 提供「設定」、「分組百分比」及「本次測試詳情」。
[/olist]

[h2]技能歸屬與 v0.5.41[/h2]
[list]
[*]原生證據沿施法、效果、AttackFilter Waza、Blueprint OnAttack 連到最終傷害；精確與推定證據分開，證據不足時維持「未歸屬傷害」。
[*]v0.5.41 將念動引力的一段延遲傷害補接回同一次精確施法、同一隻帕魯與同一目標。BP700／暗屬性只作核對，不單獨建立所有權。重複尾段、不同目標、配招不完整、缺少施法 ID，或同時存在另一個精確 BP700／暗屬技能時仍維持未歸屬。
[*]既有冰技能尾段、雙槍一閃、閃雷衝鋒、突襲木乃伊與隕星子技能仍使用各自的受限規則。傷害數字、一般目前／最近動作或僅憑三格配招都不會決定技能。
[*]保留 v0.5.40 的原生來源橋接與隕石 Rock-to-Ring 物件身分連結；本次不修改 UE4SS 或 PalSchema。
[/list]

[h2]顯示與適用範圍[/h2]
[list]
[*]預設只計算帕魯；可在 F3 另行開啟人物／武器傷害。武器測試建議整場只使用一種武器。
[*]石板主 HUD 顯示傷害最高三個配招組；所有組別及每隻帕魯的傷害、DPS、有傷／無傷施放與命中段數仍保留在 F3。
[*]困難塔只計具有 GYM 身分的主要塔主。普通野生帕魯、PvP、多人與專用伺服器不在已驗證範圍。
[*][b]目前版本：[/b]v0.5.41。目標為 Windows 單人世界；需要 UE4SS Experimental。
[/list]

[url=https://github.com/paul800901/PalSkillDPSAnalyzer]原始碼與技術說明[/url]
[i]獨立維護的 MIT 衍生作品，源自 AsahiChan-Game/PalBossDPSBroadcast。非官方模組，與 Pocketpair、Steam 或 UE4SS 無隸屬關係。[/i]

[h2]問題回報[/h2]
[url=https://discord.gg/Swzj4UjejE]Discord「帕魯模組問題回報」[/url] · [url=https://github.com/paul800901/PalSkillDPSAnalyzer/issues]GitHub Issues[/url]
請附模組名稱、Palworld 版本、模組版本、單人／多人／專用伺服器環境、重現步驟，以及相關 UE4SS.log 片段。請勿公開密碼、帳號資料或完整私人路徑。
