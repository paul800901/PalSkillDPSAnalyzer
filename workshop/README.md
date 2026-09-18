# Steam 創意工坊發行

`content/` 是獨立套件 `PalSkillDPSAnalyzerSP` 的 Palworld 1.0 Workshop 內容目錄。

## 建包

```powershell
powershell -ExecutionPolicy Bypass -File .\workshop\build_workshop.ps1
```

若本版完全沒有修改 CommonUI／LogicMods 來源，可明確使用
`-ReuseExistingNativeUi` 沿用上一個已發布版本的兩個 PAK；腳本仍會確認兩檔存在。
此開關不得用於 UI 來源有變更的版本。

建包會同步共享 Lua 核心、驗證 `Info.json`、相依項目、診斷預設值、UTF-8 與 Lua 語法，輸出：

```text
workshop/dist/PalSkillDPSAnalyzerSP-Workshop-v0.5.44.zip
```

## 獨立發布邊界

- PackageName：`PalSkillDPSAnalyzerSP`
- 本機候選版本：`0.5.44`（大量帕魯戰後效能與純傷害介面）
- 工坊公開版本：`0.5.44`（上傳後須由公開 API 與頁面讀回確認）
- UE4SS Workshop 相依：`3625223587`
- 沿用本專案既有 Published File ID `3784125454`，只更新原訂閱，不建立第二個項目。
- 不得填入或沿用 `PalBossDPSBroadcast` 的 Published File ID。

## 上傳

上傳屬於獨立 live 動作，只有在明確授權後執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\workshop\upload_workshop.ps1 `
  -SteamCmdPath "C:\steamcmd\steamcmd.exe" `
  -ReuseExistingNativeUi
```

腳本互動式詢問 Steam 帳號、密碼與 Steam Guard，不把秘密寫入專案或命令列。首次建立後仍需在 Workshop 頁面接受協議並設定 UE4SS 為 Required Item。

目前只維護英文與正體中文 Workshop 頁面；遊戲內沿用核心的 17 種語言名稱與 Boss 訊息能力。
