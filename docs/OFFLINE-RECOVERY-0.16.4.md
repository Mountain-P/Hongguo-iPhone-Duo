# 0.16.4／build 54：下載來源恢復

日期：2026-11-16（Asia/Taipei）。本版只修正註冊錯誤分類與離線下載佇列；來源簽章、手機登入、帳號同步及影片驗證規則不變。

## 使用方式與狀態

- 註冊逾時、斷線、明確零 ID 或適用的 500／502／503／504，會讓同一 `scope` 的當前與待下載集數一起等待 10、20、40 秒。其他來源的工作可以繼續。
- 等待期間總覽顯示倒數，劇集清單顯示等待集數。個別項目可取消，整部劇仍可刪除；新增同來源項目沿用等待，手動重試也不能跳過正在進行的等待。
- 最多進行初次下載與三次延遲重試。持續失敗後保留待下載項目並顯示「已暫停」，不逐集重複消耗同一失敗來源。總覽「全部重試」涵蓋失敗與暫停集數；劇內按鈕只處理該劇。
- 重試放入佇列尾端，不重抓已完成影片、不重啟手動取消項目。單集重試只恢復該集；未選取的暫停項目保持暫停。
- 等待時間、重試次數及暫停狀態會存入索引。重開 App 不會清空剩餘重試次數；已耗盡的等待必須手動重試。關閉 App 時仍在實際傳輸的項目沿用原有「已中斷」規則。
- 真正完成 provider 傳輸後才清除同來源待處理項目的重試次數。播放已下載檔、匯入 MP4 或其他來源下載成功，均不算該來源恢復。
- 明確 401／403／429、業務拒絕、安全阻擋、不相容格式與取消不進入這套自動等待。一般空模型及媒體傳輸仍沿用既有有限次恢復，未擴大成無限重試。

JS 邊界新增 `REGISTRATION_TIMEOUT`、`REGISTRATION_NETWORK_ERROR`、`REGISTRATION_HTTP_500/502/503/504`，保留 `REGISTRATION_UNAVAILABLE`。此前前三類常被攤平成 `DEVICE_REGISTRATION_FAILED`。`NativeCatalogService` 原本每集隱藏的 10／20／40 秒等待移至 `OfflineDownloads`，避免重複等待與下一集立即撞上同一故障。線上 `PlaybackRecovery` 的自動重試規則維持不變。

## 實際來源與參考固定版本

這份增補記錄當前實際採用的 pins；較早 `NativeRuntime/UPSTREAM.md` 的備援 profile 描述應以本節與程式為準。本次保留該檔原有未提交修改，沒有把整包上游替換進來。

| 用途 | 固定來源 |
| --- | --- |
| 原生 JS 基底 | [jackotom `2bab5cf`](https://github.com/jackotom/hongguo-drama/commit/2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0)，另有本地受限轉接 |
| 主 GET、簽章 | [jackotom v7.0 `3f5927d`](https://github.com/jackotom/hongguo-drama/commit/3f5927d0d605ff7742fde8cbd1bb92ffe951b080) |
| 0.16.1 起已採用的備援 POST 參考 | [jackotom `3b31058`](https://github.com/jackotom/hongguo-drama/commit/3b31058575f5c9aef0d1e2b4c98656ac95dc153c)：7.4.3.32、gzip，簽署實際壓縮位元組 |
| 本次核對及共用等待設計參考 | [jackotom v7.4 `f1f6939`](https://github.com/jackotom/hongguo-drama/commit/f1f6939a7d245fd7b0075eac831ecf5084ad9647)；未移植其對部分明確拒絕的重試 |
| 協定／固定向量參考 | [aston v0.2.150 `3650824`](https://github.com/aston314/hongguo-tv/commit/36508246eeca2cf5ef1f29f7f17f8e985d50ae2e)；不是 Go 執行期相依 |
| 原生手機登入參考 | [HGTV `b97e8cc`](https://github.com/charlie901208/HGTV/commit/b97e8cc69473db9400aa991898e392e3227d1c21)、[tsukiyo `70edaff`](https://github.com/tsukiyo-zero/hongguoTV/commit/70edafffc635d691d667ac1e6936c3ba827da9cf)，本版不變 |
| 選用 Node bridge | [N3urda `eea73e6`](https://github.com/N3urda/hongguoTV/commit/eea73e6a45569a2cbbb9440f7cd5290c459b0b70) 加 jackotom `2bab5cf` adapter；與 App 原生播放分開，未更新 |

`playback-signature.js`、`sm3.js`、`download-quality.js` 與已核對的 jackotom v7.4 逐位元組一致。此版只改 `runtime.js` 錯誤橋接，並更新 `source-sha256.json` 對應雜湊；不加入第三取源協定。所有 13 份 JS 在來源及最終 App bundle 都要比對。

## 驗證

- `swift test`：629 個 Core 測試／63 suites、112 個 AppSupport 測試／7 suites 通過。包含原有未提交資源完整性測試；它未納入本次 commit。
- 正式 JavaScriptCore runtime → Swift 的 17 種錯誤組合：註冊暫時錯誤、直接 HTTP 拒絕、業務拒絕、安全阻擋、取消與衝突時優先順序。
- 受控 provider／時鐘測試：同來源共用等待、10／20／40 秒上限、耗盡後不掃過後續集數、不同來源繼續、成功重設預算、等待時取消／刪除、遲到回呼、重開保留等待與暫停、手動與整批重試、完成檔與續播進度保留。
- Node bridge：22 項合成測試通過。
- iOS 27.2 Duo 模擬器：隔離測試 App 使用正式下載 model／view／queue 及合成 provider，實際觀察收合與展開排版、10／20／40 秒等待、取消第 2 集、耗盡後暫停、總覽「全部重試」完成第 1 集；原先完成的第 9 集與已取消的第 2 集保持原狀。這是 UI／佇列測試，6-byte fixture 不代表影片下載或播放實測。舊測試機及新機首次啟動曾回報 migration failure，新機其後進入桌面並完成本次 UI 測試；測試後皆已關機。
- 本地證據位於忽略目錄 `build/download-recovery-0.16.4/`。合成測試不代表所有真實片源或實機下載已驗證。

此次交付為本地 main 提交與從該提交建置的 iPhone 產物，不 push、不發布，也不安裝手機。
