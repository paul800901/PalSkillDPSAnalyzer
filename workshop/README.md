# Steam 創意工坊發行

`content/` 是獨立套件 `PalSkillDPSAnalyzerSP` 的 Palworld 1.0 Workshop 內容目錄。

## 建包

```powershell
powershell -ExecutionPolicy Bypass -File .\workshop\build_workshop.ps1
```

建包會同步共享 Lua 核心、驗證 `Info.json`、相依項目、診斷預設值、UTF-8 與 Lua 語法，輸出：

```text
workshop/dist/PalSkillDPSAnalyzerSP-Workshop-v0.4.0.zip
```

## 獨立發布邊界

- PackageName：`PalSkillDPSAnalyzerSP`
- 目前版本：`0.4.0`
- UE4SS Workshop 相依：`3625223587`
- `.workshop.json` 的 Published File ID 預設保持空白。
- 第一次 SteamCMD 成功建立項目後，才由上傳腳本寫回新 ID。
- 不得填入或沿用 `PalBossDPSBroadcast` 的 Published File ID。

## 上傳

上傳屬於獨立 live 動作，只有在明確授權後執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\workshop\upload_workshop.ps1 `
  -SteamCmdPath "C:\steamcmd\steamcmd.exe"
```

腳本互動式詢問 Steam 帳號、密碼與 Steam Guard，不把秘密寫入專案或命令列。首次建立後仍需在 Workshop 頁面接受協議並設定 UE4SS 為 Required Item。

目前只維護英文與正體中文 Workshop 頁面；遊戲內沿用核心的 17 種語言名稱與 Boss 訊息能力。
