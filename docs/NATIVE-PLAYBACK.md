# 內建漸進播放（0.4.2／build 12）

App 首次啟動採用「內建播放」。首頁、劇場搜尋與劇集詳情直接連到來源平台；瀏覽海報不會準備影片，按播放後才發出取源與索引請求。不需要使用者填播放服務網址，也不需要 Mac 持續開機。影片索引準備好即可開始，剩餘資料依播放與拖曳位置取得。「我的」集中觀看歷史、收藏與設定。

0.3.0 新增公開分類／題材、官方榜單、匿名近期上新，以及劇集評分、發布資訊、藝人與相關作品等選劇 metadata。這些讀取不需連結官方帳號，與影片取源分開；按「開始觀看」後仍沿用下面的分集身分綁定、匿名取源與 progressive 播放體系。來源探針、完整核心結果及裝置驗收界線見 [TESTING.md](TESTING.md)。

0.4.1 將選用帳號登入改為原生手機／簡訊介面與官方 App 登入 API，取代 0.4.0 的 WKWebView 官網流程，並沿用本機／帳號分開的收藏、各集進度與待同步片庫。發碼需使用者自行閱讀條款、勾選同意並按下按鈕；需要上行簡訊 MFA 時，由使用者核對官方回傳的號碼與內容後手動發送。手機號與簡訊碼不落檔，成功會話與同一個 `AccountAppDevice` 存於 Keychain，供 Cloud 請求重用。帳號同步不改變匿名影片取源，也不將登入 Cookie 交給播放器或 CDN。使用方式與尚待真人驗證的同步契約見 [ACCOUNT.md](ACCOUNT.md)。

0.4.2 將帳號片庫先行顯示，海報與劇集 metadata 再於背景補齊，避免大量逐部詳情請求阻擋整份清單。`LibraryState.enrichSeries` 只更新既存 ID 的資料，保留觀看位置、時間、收藏狀態及待同步操作編號；它不新增收藏或進度操作。

## 流程

1. `NativeCatalogService` 讀取官方目錄與劇集 `vid_list`，確認分集屬於目前劇集；網頁預覽的 `accessible_episode_cnt` 不作為內建來源的選集上限。
2. `NativeSourceResolver` 在本機 JavaScriptCore 執行隨 App 附帶的固定版本簽章程式。原生 URLSession 處理網路，CommonCrypto／CryptoKit 處理密碼演算法，zlib 處理註冊資料壓縮。這個簽章 runtime 只執行隨包程式。
3. 依目前取源契約先嘗試獨立匿名 GET；沒有可用模型才進入有次數與時間上限的 POST 復原。不同流程的匿名身分與 Cookie 分開；來源明確拒絕立即停止。成功片源以分集／content type 為鍵快取 120 秒、最多 16 筆；fresh 會重新取源，取消或失敗不寫入快取。這個影片取源流程不使用帳號會話或固定裝置憑證。
4. `NativeProgressiveMedia` 先抓取前 256 KiB，檢查前置 ftyp／moov，需要時只補索引至 moov 結尾加 16 bytes（最多 8 MiB），以及缺少的 CENC auxiliary 小範圍（最多三輪、8 MiB）。`NativeMP4.prepareStream` 建立可按任意 offset 處理的串流解密計畫，完成後立即返回，不等待整集下載。
5. App 與 macOS 工具共用 `HongguoPlayback.NativeMediaAssetLoader`，以公開 AVAssetResourceLoader API 將 `hongguo-native` asset 的讀取請求交給 `NativeMediaStream`。串流按需取得 512 KiB 區塊，處理 CENC／sample entry，使用 8 MiB 記憶體 LRU；每個串流重用 URLSession，最多兩筆 Range 同時下載，取消一筆不會取消另一筆。
6. 系統 AVPlayer／AVPlayerLayer 播放按需提供的資料，自適應畫布支援完整畫面與填滿螢幕。播放器的 NavigationStack 提供原生工具列，倍速、快轉、選集及續播由原生狀態管理。

Range 必須回傳精確的 206、Content-Range 與資料長度，檔長及來源提供的 ETag／Last-Modified 在串流中保持一致。只接受核准的 HTTPS CDN，轉址逐跳驗證；401／403 立即停止。來源以 200 忽略 Range 時會明確回報不支援，不會默默改成整集下載。索引／aux 準備總期限為 30 秒。

`NativeMediaStore` 的完整單集準備保留作明確對照與測試，並非預設播放或自動 fallback。漸進流程的區塊快取位於記憶體，不提供離線片庫。取源、索引與解碼錯誤分別保留，不以「連線成功」當成「可播放」。

## 觀看與倍速操作

首頁沿用劇場規格的 adaptive 直式海報網格，欄數依可用寬度自動調整，採自然垂直捲動；海報以 fit 完整顯示。點海報進入詳情，按「開始觀看」才準備並以 fullScreenCover 開啟獨立播放器，主 Tab 與首頁網格不透出。在播放器換劇會先返回海報，由使用者再次點播；同一劇集內的「自動下一集」仍可獨立設定。

播放器從 0.2.1 起使用 `playerFillsScreen.v2` 偏好，新偏好首次預設等比裁切填滿，可切回完整比例並保存選擇。點畫面切換真實原生工具列的隱藏／顯示；工具列顯示時也是透明覆蓋，影片保持全畫布，不為控制列縮小。完整比例模式的留白由影片長寬比自然產生。原生控制列的位置由系統依 Duo 姿態決定。

根畫面保留「首頁／劇場／我的」原生 TabView；播放器自帶 NavigationStack 與有名稱、symbol 的 `.toolbar` 項目。Duo 外螢幕與內螢幕橫向可使用側欄，內螢幕直向的原生列則在上下方。「更多」中提供選集、下一集及自動續播。點按與 hover 分別處理。原生列的實作依據見 Apple [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/) 與 [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)。

0.2.4 的影片資訊採輕透明圓角框，片名／集數一列，slider／時間一列，最大寬度 560 pt，以玻璃材質呼應原生底部工具列。iOS 26+ 使用 `.glassEffect(.regular)` 與圓角矩形；較舊系統使用 ultraThinMaterial，啟用 Reduce Transparency 時改用不透明背景。資訊框隨 `controlsVisible` 同步隱藏，包含原有閒置自動隱藏；顯示與隱藏都只覆蓋影片，不重算影片尺寸。

- 長按影片至少 0.35 秒，暫時以 2 倍速播放；放開恢復選單選定的速度。
- 長按後上滑 60 pt，鎖定 2 倍速，放開仍維持。
- 鎖定後再長按並下滑 60 pt，即時解除鎖定並恢復選定速度。也可點「2 倍速已鎖定」提示解除。
- 從倍速選單選取速度會解除長按加速與鎖定。進入背景會取消暫時長按，已提交的鎖定保留。

`PlaybackSpeedState` 以獨立核心狀態保存正常速度、長按與鎖定；其行為測試與實際 Duo 手勢驗收分開記錄，最新畫面及手勢結果見 [TESTING.md](TESTING.md)。

## 自訂服務

「我的 → 設定 → 播放方式 → 自訂播放服務」為選用功能。網址與口令完成協定及目錄驗證後才儲存，並切換為服務播放。這個模式仍使用 Range／Bearer 的原生 ResourceLoader；與預設內建流程分開。切回「內建播放」即可恢復獨立執行。

## 帳號與觀看紀錄

在「我的」可以選擇本機或已登入帳號的片庫。登入不會自動上傳訪客紀錄；需明確選擇匯入，才把副本加入帳號待同步隊列。各來源與帳號分開儲存，播放器建立時綁定原片庫，切換帳號後的遲到回覆不能寫入另一個帳號。

觀看位置先保存於手機。帳號同步先以 `validateForLibrary` 檢查本地會話、帳號與有效期限，再用該會話及同一 `AccountAppDevice` 讀取官方紀錄、合併並提交待同步收藏與進度；這個本地檢查不是已證實的獨立線上驗證。會話是否仍有效，由實際 Cloud 請求判定，登入失效或來源拒絕會顯示錯誤。只成功一部分、來源拒絕或格式改變時保留待同步狀態。清除觀看紀錄是本機隱藏；取消收藏是明確的帳號操作。簡訊登入、MFA、收藏寫入與跨裝置同步各自依真人實測記錄判定，App 建置與合成測試不代表後續帳號操作均已獲接受。詳細契約見 [ACCOUNT.md](ACCOUNT.md)，當版結果見 [TESTING.md](TESTING.md)。

## 驗證

離線核心測試：`swift test --disable-xctest`。

0.4.2／build 12 完整 Core 回歸為 162 項、20 個 suites：161 項通過、1 項可選快照略過；其中 UserLibrary 19 項包含 metadata 補齊不改變進度、刪除狀態與待同步操作的驗證。原始結果及 focused 指令見 [TESTING-CORE.md](TESTING-CORE.md)。

明確執行真實來源與 macOS 影片解碼檢查（目前工具同樣使用 progressive 與共用 loader）：

```sh
swift run NativePlaybackCheck SERIES_ID EPISODE_NUMBER
swift run NativePlaybackCheck --startup SERIES_ID EPISODE_NUMBER
swift run NativePlaybackCheck --seek SERIES_ID EPISODE_NUMBER
```

不加旗標時，工具按需取得並完整解碼一集的影片與音訊；`--startup` 只驗證準備與第一幀，`--seek` 直接從影片 70% 位置取得第一幀。輸出影格數、音訊 buffer 數與時長，不印出片源簽名網址、內容金鑰或匿名身分。

0.2.0 的 progressive 基準使用同一部 102 集劇集的第 4 集分次實測：startup 準備 2.82 秒／首幀 3.10 秒；完整串流解碼全部 89.79 秒、2,244 影片影格及 825 音訊 buffer，首幀 1.98 秒／全流程 7.9 秒；70% seek 準備 1.66 秒／首幀 2.09 秒。均不使用播放服務，數值反映各次網路與快取狀態。原先整集準備路徑的 31.2 秒／745 個音訊 buffer 僅保留為歷史對照。

上述數據是 macOS 核心與 AVFoundation 解碼證據。另有 0.2.0／build 3 的真機簽署安裝與播放畫面，且使用者已確認有聲音。0.2.1／build 4 已安裝，但首頁點播入口曾遇 scrollPosition 取消競態；0.2.2／build 5 的固定格數首頁屬中間版。0.2.4／build 7 的劇場式首頁與輕透明資訊框、0.3.0 的附加選劇 metadata 均保留版本紀錄。0.4.2／build 12 已完成真機 Debug 與未簽署 Release 建置。各版 Release、簽署安裝及原生帳號登入／片庫的最新驗收狀態見 [TESTING.md](TESTING.md)。真機長按手感與長時間播放／耗電仍待驗證。

演算法、固定提交、GPL 與轉引來源見 [SOURCES.md](SOURCES.md) 及 Core 隨附的來源聲明；未複製無許可聲明的 Go 實作。
