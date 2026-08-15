# 帕魯技能 DPS 原生來源收集器

本目錄是 PalSkillDPSAnalyzer 的 C++ 收集層。舊版 collector 只能在最終傷害
回呼中依 attacker／defender 聚合，會在技能歸因以前丟失事件順序。現階段正改為
保存逐命中事件，沿 cast、SkillEffect、AttackFilter、DamageInfo 與 final damage
傳遞來源；灼燒、中毒等來源不可回復的持續傷害獨立列為「狀態傷害」。

## 相容邊界

目標是 Palworld 1.0 Windows 單機與目前 Workshop 安裝的 UE4SS Experimental。
精確版本、runtime hash 與第三方 commit 見
`tools/native-toolchain.lock.json`。遊戲或 UE4SS 更新後必須重做 ABI／hook 驗證；
載入或反射失敗時不得把弱時間推定冒充精確技能來源。

## 建置

先依 `docs/NATIVE_DEVELOPMENT.md` 安裝並驗證工具鏈，再從倉庫根目錄執行：

```powershell
.\native\build_native.ps1 `
  -UE4SSDll "E:\Program Files (x86)\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\UE4SS.dll"
```

腳本從遊戲實際的 `UE4SS.dll` 匯出表產生 import library，不覆寫 UE4SS。建置結果
位於 `native/build-native/main.dll`，並執行原生事件／守恆壓力測試。

## 安装结构

```text
Mods/NativeMods/UE4SS/Mods/
├─ BossDPSNativeCollector/
│  ├─ enabled.txt
│  └─ dlls/
│     └─ main.dll
└─ PalSkillDPSAnalyzerSP/
   ├─ enabled.txt
   └─ Scripts/
      ├─ main.lua
      ├─ config.lua
      └─ commentary.lua
```

安裝或覆寫 DLL 前必須完全關閉 Palworld。日誌需同時出現原生版本、鎖定 ABI、
各 hook 註冊結果與逐事件收集狀態，才表示原生路徑真的啟用。
