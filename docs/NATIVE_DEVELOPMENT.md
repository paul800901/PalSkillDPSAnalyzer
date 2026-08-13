# 原生 Mod 的 Git 與建置邊界

## 什麼會進 Git

GitHub 儲存的是可維護、可審查且能重建的內容：

- Lua／C++ 原始碼與測試。
- `tools/native-toolchain.lock.json` 的精確版本與 commit。
- 工具鏈安裝、依賴下載、建置、打包及驗證腳本。
- 技能來源鏈的實機事件格式、測試 fixture 與相容性報告。
- Workshop 描述、圖示來源、變更紀錄與授權文件。

每個可驗證階段使用獨立 commit。環境固化、診斷探針、正式歸因、UI
與 Workshop 發佈不混成同一個提交，方便回退及比對遊戲版本。

## 什麼不會進 Git

下列內容位於專案目錄，但由 `.gitignore` 排除：

- `.toolchain/`：數 GB 的 Visual Studio Build Tools。
- `external/`：可依鎖定檔重新下載的 UE4SS、fmt、Zydis 與 Zycore 原始依賴。
- `native/build*/`、`dist/`、`workshop/dist/`：可重建的物件檔、DLL 與 ZIP。
- 實機 log、crash dump 與個人遊戲安裝路徑。

這可避免 GitHub 倉庫膨脹，也不會誤提交 Epic 授權限制的 UEPseudo 標頭。

## 第一次建立環境

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install_native_toolchain.ps1
powershell -ExecutionPolicy Bypass -File .\tools\bootstrap_native_dependencies.ps1
powershell -ExecutionPolicy Bypass -File .\tools\verify_native_environment.ps1 -RequireDependencies
```

UE4SS 的 `UEPseudo` 子模組受 Epic Games 授權限制。執行依賴還原前，Git 使用的
GitHub 帳號必須已與 Epic Games 帳號連結；這是 UE4SS 官方建置要求，不會把該
標頭或任何憑證提交到本專案。只想先取得公開依賴時，可加
`-SkipRestrictedUEHeaders`，但此狀態不能編譯原生 DLL。

目前鎖定的本機環境為 Visual Studio Build Tools 17.14.37、MSVC
14.44.35207、Windows SDK 10.0.26100.0 與 RE-UE4SS
`c838a8acaade1a0f860bdf249f039e58f4e10088`。實際遊戲使用的 `UE4SS.dll`
另以 SHA-256 驗證 ABI 對象。

## GitHub 與 Steam Workshop

GitHub 是開發母專案，保留原始碼、issue、版本 tag 與可重現建置資訊。Steam
Workshop 是玩家發佈管道，只包含執行所需的 Lua、設定、原生 `main.dll`、圖示與
說明。發佈前必須從乾淨 Git commit 建置，記錄 commit、Palworld 版本、UE4SS
hash 與成品 hash；Workshop 不包含 Visual Studio、UE4SS 原始碼或開發 log。

目前只進行本機 Git 固化，不會自動 push GitHub，也不會發佈 Workshop。
