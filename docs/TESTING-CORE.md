# 內容核心驗證

`HongguoCore` 是不依賴 SwiftUI／AVFoundation 的核心模組；同一本機 Swift Package 中的 `HongguoPlayback` 提供 App 與 macOS 工具共用的 `NativeMediaAssetLoader`。0.5.0 加入內部 `HongguoAppSupport` target，直接編譯 App 的帳號 Controller、會話保存與片庫保存原始碼，供整合測試使用，避免只測試 DTO／純狀態。測試使用 Swift Testing，最低工具版本為 Swift 6／Xcode 16。

當前程式版本為 0.8.0／build 19。最終完整回歸為 **Core 317 項／40 個 suites，316 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 59 項／5 個 suites，全部通過**。合計登錄 376 項，375 通過、1 略過，記錄於 `build/core-0.8.0-validated-tests.log`。AppSupport 直接編譯正式 Controller、保存流程、目錄／片庫 model、海報管線與續播 launcher，使用合成資料、隔離 defaults 及注入傳輸，不操作真人帳號或真實 Keychain。簽署建置、安裝與當版 UI／硬體結果另記於 [TESTING.md](TESTING.md)。

0.8.0 新增本機推薦 16 項，驗證收藏與足夠保存位置的弱訊號、真實共同題材與簡繁正規化、泛型題材排除、穩定排序、探索／交錯、重複與上限、跨片庫拒用。試看位置政策新增 6 項，正式 launcher 新增 7 項，涵蓋最新詳情、位置選擇、紀錄改變／刪除、取消與舊選項、場景／帳號及原 scope handler。另增 queue 1 項與 CatalogModel 2 項，確認只排序新頁、目前卡片及游標不動、搜尋維持來源順序，以及網路回覆前片庫完成還原時會使用新快照。UI 點按行為由模擬器檢查，不以靜態字串測試取代操作。

歷史 0.7.0／build 18 為 Core 294 項／38 個 suites（293 通過、1 略過）與 AppSupport 50 項／5 個 suites 全通過，合計登錄 344 項、343 通過、1 略過，記錄為 `build/core-0.7.0-validated-tests.log`。

歷史 0.6.1／build 17 為 Core 286 項／37 個 suites（285 通過、1 略過）及 AppSupport 27 項／3 個 suites 全部通過，合計 313 項、312 通過、1 略過，記錄於 `build/core-0.6.1-tests.log`。

0.7.0 增加 `NativePlaybackQualityTests` 7 項，以及既有 progressive suite 的 1 項畫質偏好首段隔離：驗證持久偏好、無效值預設、真正 bundled JS 入口／真實來源尺寸排序／單版本 fallback、取源與首段快取隔離及取消。簽章向量與 12 份 bundled JS hash 仍參與回歸；這些不是實網影片解碼或手機播放證據。

`PosterImagePipelineTests` 14 項直接執行 ImageIO、正式 actor 與 URLSession delegate，涵蓋 EXIF 方向、縮圖與像素上限、LRU 位元組／項數上限、URL 及不同尺寸工作共用、取消單個／全部消費者、佇列名額回收、失敗後再試、HTTP 拒絕／長度與串流上限、憑據 header 清除，以及大圖解碼量測。`ContinuePlaybackModelTests` 在 0.7.0 新增的 9 項執行正式 launcher，涵蓋按鈕前不請求、最新進度、完成集跳過未開放集／末集重播、過期分集 ID、準備期間刪紀錄、取消及晚回覆、帳號／來源／前景／分頁有效性、錯誤與原 scope 進度 handler。UI 與真機結果分開驗收。

```sh
swift test --disable-sandbox --disable-xctest --filter NativePlaybackQualityTests
swift test --disable-sandbox --disable-xctest --filter 'PosterImagePipelineTests|ContinuePlaybackModelTests'
swift run NativePlaybackCheck --quality dataSaver --startup SERIES_ID EPISODE_NUMBER
```

歷史 0.6.0／build 16 為 Core 279 項／35 個 suites（278 通過、1 略過）及 AppSupport 12 項／1 個 suite 全部通過，合計 291 項、290 通過、1 略過，記錄於 `build/core-0.6.0-validated-tests.log`。

0.6.1 新增 Core `PlaybackInterruptionTests` 3 項及 `LibraryRetryRotationTests` 4 項；正式 AppSupport `CatalogModelTests` 7 項、`LibraryBrowserModelTests` 6 項，以及 Controller 的人工收藏／進度輪替 2 項。目錄使用真正連續請求驗證重複第二頁後的有效第三頁、錯誤重試同頁、錯頁拒絕、成功空頁返回、100 頁上限，以及已取消重設／舊來源回覆隔離。片庫使用可控制的 worker 驗證完成快取立即返回、pending 不命中、完整 context 失效、A→B→A 晚回覆與單一執行工作。Controller 以合成 Cloud 回應驗證首批永久失敗後，第二次人工重試可到後續項目，而自動同步不重送需人工處理的操作。

```sh
swift test --disable-sandbox --disable-xctest --filter 'PlaybackInterruptionTests|LibraryRetryRotationTests'
swift test --disable-sandbox --disable-xctest --filter 'CatalogModelTests|LibraryBrowserModelTests|AccountLibraryControllerTests'
```

歷史 0.5.0／build 15 最終結果為 Core 245 項／29 個 suites（244 通過、1 略過），以及 AppSupport 8 項／1 個 suite（8 通過）；合計登錄 253 項，252 通過、1 略過，記錄於 `build/core-0.5.0-validated-tests.log`。

歷史 0.4.4／build 14 完整核心回歸為 199 項、23 個 suites，198 通過、1 項可選快照略過，記錄於 `build/core-0.4.4-tests.log`。該版包含 UserLibrary 25、PlaybackSpeed 15、PlaybackContinuation 7、RecommendationPreviewQueue 9 與 RecommendationFeedActivation 7。

歷史 0.4.3／build 13 最終完整核心回歸為 190 項、22 個 suites，189 項通過、1 項可選快照略過，記錄於 `build/core-0.4.3-tests-final.log`。該版包含 UserLibrary 25、PlaybackSpeed 15、PlaybackContinuation 7 與當時 7 項 RecommendationPreviewQueue；同頁 feed 的新增資格與穩定 ID 測試屬後續 0.4.4。

歷史 0.4.2／build 12 完整核心回歸為 162 項、20 個 suites，161 項通過、1 項可選快照略過，記錄於 `build/core-0.4.2-tests.log`。該版 AccountSession 11、NativePhoneAuth 12、NativePhoneRuntime 4、UserLibrary 19、AccountLibrary 9 均通過；其真人登入、會話還原與片庫讀寫證據屬該次歷史實機紀錄，不能視為後續版本已重新驗證帳號網路或硬體。

歷史 0.3.0／build 9 完整核心驗證共 107 項、15 個 suites：**106 項通過、1 項可選 `currentWebsiteSnapshot` 略過**。已以 `swift test --disable-sandbox --disable-xctest` 執行，記錄：`build/core-0.3.0-tests.log`。該輪新增 Discovery 9 項、NewRelease 7 項、Artist 7 項，全部參與該次完整驗證。

Discovery 測試涵蓋公開分類與動態題材、四榜單 alias、inline／deferred SSR、HTML entity 與單／雙引號、route／genre／page 綁定、回應上限、取消與明確拒絕，並驗證共用 recommendations helper。新劇與藝人測試涵蓋來源回應解析、身分／路徑綁定與失敗分支。這些 0.3.0 的附加選劇 metadata 測試保持獨立於後續帳號功能。

歷史 0.2.0／build 3 的完整核心基準為 84 項、83 通過與 1 項略過，記錄仍保留於 `build/core-0.2.0-tests.log`。該版已包含內建目錄、原生簽章／HTTP、完整及串流 MP4／CENC、下載與來源快取、Range 取消隔離與倍速狀態測試。

首頁的劇場式 adaptive 直式海報網格、完整海報 fit、自然垂直捲動、明確「開始觀看」入口，以及透明原生工具列與全畫布切換，屬 UI 與裝置整合驗收。0.2.4 的兩列輕透明資訊框、iOS 26+ Liquid Glass／舊系統材質分支、Reduce Transparency 不透明背景，以及隨控制狀態隱藏而不改變影片尺寸，也需對應 UI 驗收。這些項目的版本結果另記於 [TESTING.md](TESTING.md)。

播放核心既有測試確認只抓前綴即可準備、補足較大 moov 與外部 auxiliary 小範圍、按需分段結果與完整 CENC 解密相同、LRU 淘汰、檔長／ETag 變更拒絕、200 忽略 Range 時停止、403 保留、最多兩筆 URLSession 下載、取消一筆不影響另一筆，以及 120 秒／16 筆來源快取與 fresh、取消隔離。

PlaybackSpeed 共 15 項，涵蓋選定速度、暫時長按／放開、鎖定／解除、背景取消、手動選速、無效輸入、等待中的速率更新與等速回饋抑制，以及暫停／換集／錯誤重載的播放意圖。暫停時改速不應啟播，自動重載不能把先前的暫停改成播放。手勢命中、AVPlayer 的實際等待與 seek 時序仍由獨立 UI 驗收確認，結果見 [TESTING.md](TESTING.md)。

PlaybackContinuation 共 7 項，驗證續播目標與進度判斷。RecommendationPreviewQueue 現為 11 項（包含 0.8.0 的新頁排序／目前卡片保護），驗證推薦片單的分頁、去重、有界容量、取消／替換來源與可播放的第 1 集；0.4.4 新增穩定 ID 任意選卡、未知 ID 不移動游標，以及裁除舊頁後保留目前 ID、不把失效位置錯認成其他劇集。

0.5.0 額外驗證已取消的舊分頁 Task 不能佔用重設後片單；正常的新 Task 仍可要求第 1 頁。

RecommendationFeedActivation 共 7 項，驗證只有停穩、可見且分頁／場景有效的卡片取得唯一啟播 lease；重複 idle 不重啟，滑動／減速、離頁、背景與詳情會撤銷資格，A→B→A 舊回覆無法套用，來源重設與空選取不能保留舊工作，詳情返回可維持暫停直到明確繼續。這是純狀態政策測試，不證明 AVPlayer 音訊交接、拖曳保留影格、海報銜接、播放按鈕命中或同頁詳情導航已在 GUI 通過。

```sh
swift test --disable-sandbox --disable-xctest --filter PlaybackContinuationTests
swift test --disable-sandbox --disable-xctest --filter RecommendationPreviewQueueTests
swift test --disable-sandbox --disable-xctest --filter RecommendationFeedActivationTests
```

0.2.0 的實網基準以 `swift run NativePlaybackCheck 7701935931787316286 4` 驗證 progressive 路徑：完整解碼第 4 集全部 89.79 秒、2,244 影片影格、825 個音訊 buffer；首幀約 1.98 秒、全流程約 7.9 秒，記錄於 `build/native-progressive-full-decode.log`。獨立 startup 檢查為準備 2.82 秒、首幀 3.10 秒；直接 seek 至 70% 為準備 1.66 秒、首幀 2.09 秒。均未使用播放服務。這些是分次 macOS 核心／解碼量測；版本對應的 Duo、真機與最新點播入口驗收見 [TESTING.md](TESTING.md)。

在專案根目錄執行：

```sh
swift test --disable-sandbox --disable-xctest
```

同一條命令會分別執行 Core 與 AppSupport 的測試程式；結果應分別核對，不能只讀第一個測試程式的總數。

## 帳號與片庫測試

五組 focused 測試可分別執行，均使用合成會話與注入傳輸，不會代發簡訊、登入真人帳號或寫入官方片庫：

```sh
swift test --disable-sandbox --disable-xctest --filter AccountSessionTests
swift test --disable-sandbox --disable-xctest --filter NativePhoneAuthTests
swift test --disable-sandbox --disable-xctest --filter NativePhoneRuntimeTests
swift test --disable-sandbox --disable-xctest --filter UserLibraryTests
swift test --disable-sandbox --disable-xctest --filter AccountLibraryTests
```

`AccountSessionTests` 保留官網 info/v2 的確切 GET 契約、白名單 Secure Cookie 與使用網域、19 位 UID 精度及一致性、會話到期和還原後 UID 不可改變、錯誤不回顯憑證，以及真正 URLSession delegate 的 2 MiB 上限、403 狀態保留與取消隔離等安全測試；這不表示目前 App 仍以官網登入。官方回 HTTP 200 本身不足以證明登入成功。

`NativePhoneAuthTests` 與 `NativePhoneRuntimeTests` 檢查手機與國碼正規化、驗證碼及 challenge 綁定、同一註冊身分、重發限制、送達不確定但不自動重發、明確拒絕、人工上行簡訊 MFA、取消、UID／憑證驗證，以及會話序列化與網域隔離。Runtime 使用合成 transport 核對實際表單、路徑、簽章模式及轉址／拒絕停止；沒有向電信業者發送簡訊。

`UserLibraryTests` 共 25 項，檢查舊版遷移、按來源／帳號隔離、各集觀看進度與完成狀態、較新時間的合併、明確匯入訪客副本、收藏及進度待同步操作、特定回覆確認與刪除記號。0.4.2 的 3 項 metadata 測試保留，確認補資料不改進度、時間、收藏狀態、操作 UUID 或其他作品；未知 ID／無效標題原子拒絕。空或不完整遠端資料不能直接抹去本機片庫。

0.4.3 新增 6 項持久重試測試：寫入前將 `retryRequired` 標記保存的快照經 JSON roundtrip 後仍禁止自動重送；舊檔缺欄位預設 false；已被擋住的前 25 筆不占自動批次名額，新的獨立操作仍可提交；舊 ACK 不清除較新 UUID；metadata 與遠端合併不默默解除限制；本機刪除意圖不會變成官方寫入。Controller 在等待寫入前先保存標記，只有明確手動重試才重設服務的失敗快取；自動同步跳過已標記操作，不因首筆失敗阻擋後續，也不為只有手動重試項目的佇列持續排程。保存／畫面整合仍依 App 驗收確認。

`AccountLibraryTests` 檢查分頁覆蓋、欄位／大整數與毫秒單位、精確路由及 Cookie 範圍、待同步操作的重複與失敗處理、兩段進度寫入的部分成功，以及帳號切換／取消。它們確認程式按契約處理合成回應，不能證明真人 App 會話已獲官方收藏／進度寫入授權。

原生 API 實際手機發碼／登入、來源挑戰、Keychain 真機保存／還原、真人帳號讀寫與跨裝置續播，另依 [ACCOUNT.md](ACCOUNT.md) 及 [TESTING.md](TESTING.md) 記錄；本輪未以真實 Cookie 或驗證碼執行上述 focused 測試。

## 保存與 Controller 整合測試

0.5.0 的下列三組原有 22 項；0.6.0 增加 4 項批次整理，0.6.1 再增加 2 項人工重試輪替，現合計 28 項，均已參與最終完整測試，可分別重現：

```sh
swift test --disable-sandbox --disable-xctest --filter MetadataHydrationTests
swift test --disable-sandbox --disable-xctest --filter LibrarySnapshotStoreTests
swift test --disable-sandbox --disable-xctest --filter AccountLibraryControllerTests
```

`MetadataHydrationTests` 6 項驗證前 50 筆持續失敗不擋住其後未試項目、失敗退避、每輪上限與去重、舊 batch lease／換 scope 失效，以及詳情快取的 TTL、LRU、部數與總集數上限。實際流程仍維持每輪最多 50 部、4 筆並行與 45 秒期限。

`LibrarySnapshotStoreTests` 8 項使用可控的磁碟屏障與臨時目錄，驗證 20 個版本合併為 2 次寫入、舊版本不可覆寫新快照、重試標記落盤前不能繼續雲端寫入、儲存失敗阻擋請求、scope 隔離與同版本衝突、損壞主檔只回復有效且同 scope 的備份、備份寫入失敗／超限／損壞遷移不覆空，以及 1,500 部作品的保存與重新開啟。編碼、讀備份及原子 IO 在串行背景執行；測試沒有證明所有真機大型片庫均不掉幀。

`AccountLibraryControllerTests` 現為 14 項，直接執行 `HongguoAppSupport` 中的正式 Controller／LibraryPersistence。原有 8 項涵蓋：延遲載入期間的收藏與進度先排隊；較早進度不能在稍後清除之後復活；切來源後舊載入／進度留在原 scope；載入失敗不以空片庫覆檔；flush 等待尚未完成寫入之後更新的最後進度；舊 metadata 任務的 defer 不能清除替代任務；換來源拒絕舊回覆；第二輪補資料能到達前 50 筆失敗之後的有效作品。0.6.0 的 4 項批次整理範圍見下一節；0.6.1 的 2 項人工輪替另以注入服務驗證 30 筆收藏與 15 筆進度在首批永久失敗後仍能到達後續項目。

整合測試以注入初始化避開正式 Keychain，使用隔離的 UserDefaults、合成片庫與 metadata 載入器；沒有真實手機號碼、驗證碼、Cookie 或官方片庫寫入。App 的暫停／離開／背景 flush 觸發與有限背景執行時間仍需對應 GUI／裝置驗收，不能把合成落盤屏障測試當作強制終止或斷電零遺失證據。

## 0.6.0 片庫、搜尋與播放政策測試

```sh
swift test --disable-sandbox --disable-xctest --filter LibraryBrowserTests
swift test --disable-sandbox --disable-xctest --filter SearchPolicyTests
swift test --disable-sandbox --disable-xctest --filter 'PlaybackPreferencesTests|PlaybackReplayTests|EpisodePrefetchTests|PlaybackPrefetchTests|PlaybackMeasurementTests'
```

`LibraryBrowserTests` 8 項驗證本機繁簡／全半形／大小寫搜尋、多詞同時比對、片名／題材／描述／分集名稱欄位、完成狀態篩選與明確排序、19 位 ID 的穩定順序，以及批次歷史移除與取消收藏。搜尋與排序不修改保存資料。批次操作先驗證全部 ID，再建立一次待提交狀態；未選項目的 UUID／重試限制保持原樣，舊 ACK 不能移除較新的取消收藏意圖，未知項目略過且不建立額外刪除記號。

Controller 新增 4 項驗證：載入未完成時批次取消收藏仍套用於 captured scope，切來源後不污染新片庫並只提交一次；批次移除歷史只作一次本機提交且保留收藏；無效／過期選取不造成部分變更或無意義寫檔；排隊批次移除之後的明確收藏動作保留較新的意圖。確認對話框的數量、片庫名稱、帳號同步提示與切 context 取消行為屬 SwiftUI 整合，需另外驗收，不以這 4 項測試宣稱畫面通過。

`SearchPolicyTests` 14 項使用合成來源，核對保留原查詢、僅完整空結果才允許一次順序繁簡替代、分頁沿用實際查詢、錯誤／取消不啟動替代，以及來源已載入題材的篩選與數量；不宣稱搜尋了來源尚未回傳的全部資料。

0.6.0 新增 `PlaybackPreferencesTests` 3 項、`PlaybackReplayTests` 1 項與 `EpisodePrefetchTests` 3 項，共 7 項，涵蓋明確偏好保存、試看不覆寫設定、無效速率拒絕、播完重播，以及近片尾只預取一次、依速度換算時間、當前緩衝優先與取消。既有 `PlaybackPrefetchTests` 4 項仍參與回歸，驗證預取 actor 的取消、所有權與預算傳遞。`PlaybackMeasurementTests` 5 項核對首幀等待與後續緩衝分開計時、恢復沿用原起播時鐘、亂序事件與使用者暫停處理；這是時間狀態測試，不是當版真機首幀速度或長播穩定性量測。

## 選劇 metadata 實網探針

`Tools/CatalogDiscoveryCheck` 是明確執行的來源探針，使用與 App 相同的 Core service；只讀分類、題材、榜單、新劇、劇集與藝人資料，不取影片模型或下載媒體，也不使用官方帳號。可在專案根目錄執行：

```sh
swift run CatalogDiscoveryCheck category real-drama
swift run CatalogDiscoveryCheck category comic-drama
swift run CatalogDiscoveryCheck category ai-drama
swift run CatalogDiscoveryCheck category real-drama 2 romance
swift run CatalogDiscoveryCheck rank all
swift run CatalogDiscoveryCheck rank real-drama
swift run CatalogDiscoveryCheck rank comic-drama
swift run CatalogDiscoveryCheck rank ai-drama
swift run CatalogDiscoveryCheck rank all 2
swift run CatalogDiscoveryCheck new real-drama
swift run CatalogDiscoveryCheck new ai-drama
swift run CatalogDiscoveryCheck detail 7701935931787316286
swift run CatalogDiscoveryCheck artist ARTIST_ID
```

`ARTIST_ID` 是占位值，需使用來源藝人卡的實際 ID。0.3.0 曾檢查三大分類、題材第 2 頁、四榜與總榜第 2 頁、真人／AI 上新、劇集附加 metadata，以及藝人作品列表；當次數量、分頁排名與原始證據見 [TESTING.md](TESTING.md)。探針成功屬 Core／來源證據，App 畫面、實機安裝及 UI 操作另依該文件記錄。

## 初版歷史驗證指令

首次核心驗證時，這部 Mac 僅安裝 Command Line Tools，沒有完整 Xcode 與 XCTest。當時的 SwiftBuild 未自動載入已安裝的 TestingMacros，因此明確指定系統隨附的巨集函式庫，並將快取放在暫存目錄。之後已安裝 Xcode 27.2；完整 Xcode 環境可直接使用前述簡短命令，以下保留早期驗證指令：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/hongguo-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/hongguo-swift-modulecache \
swift test \
  --scratch-path /private/tmp/hongguo-swift-build \
  --cache-path /private/tmp/hongguo-spm-cache \
  --config-path /private/tmp/hongguo-spm-config \
  --security-path /private/tmp/hongguo-spm-security \
  --disable-sandbox --disable-xctest \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

初版在 Swift 6.4.2 下核心建置成功，13 項固定測試通過，涵蓋：

- 官網 JSON 擷取、分類、搜尋、分集身份與開放集數。
- 公開影片與目前劇集、分集的綁定，拒絕受保護的 SEO 預覽與不符的影片。
- 橋接 API 路徑、搜尋編碼、字串 ID、標籤與存取口令。
- 反向代理 `/bridge` 前綴保留，支援服務根目錄相對路徑、已含前綴路徑與明確同來源絕對網址。
- 阻擋跨來源影片網址攜帶橋接口令、錯誤訊息不回顯上游敏感資料。
- 服務網址、HTTP 區域網路限制、無效輸入不發出網路請求。

## 可選的真實頁面快照驗證

`Tests/HongguoCoreTests/LiveSnapshotTests.swift` 只在 `HONGGUO_LIVE_FIXTURES` 指向本機資料夾時啟用。資料夾需包含 `category.html`、`search.json`、`detail.html`、`player.html`。此檢查使用固定的驗證樣本劇集與分集 ID，重新選取其他劇集時應同步調整測試預期值。

初版曾以當時取得的官網頁面執行，總計 **14 項測試通過**。在上面的歷史指令最前面加入：

```sh
HONGGUO_LIVE_FIXTURES=/private/tmp/hongguo-live
```

這是同一條命令的環境變數，與 `CLANG_MODULE_CACHE_PATH` 等變數一起設定。快照含有會過期的封面或媒體簽名，未納入專案。

該歷史快照可解析 24 部分類內容、10 筆搜尋結果，以及一部 102 集短劇的完整分集列表。來源標記前 3 集可供網頁存取，但第一集同時有 `protectedPlayback=true`。公開網頁解析依此拒絕將 SEO 預覽當成完整影片播放；內建 App 取源則以當次播放回應判斷。

另以真正的 `URLSessionTransport` 連線至 `http://127.0.0.1:8788` 的合成測試服務，完成健康檢查、首頁、搜尋、3 集分集詳情及同來源 MP4 播放來源解析。此測試使用自製短片與測試資料，確認 Swift HTTP 整合，未驗證紅果平台影片或 AVPlayer 畫面。

以上歷史快照只證明當次解析及請求契約。0.2.0 已另完成前述核心／實網基準、真機簽署安裝與播放畫面，使用者已確認有聲音。0.2.1 的點播取消競態與已安裝的 0.2.2 中間版均有版本紀錄；0.2.4 的劇場式首頁與 0.3.0 附加選劇功能的裝置驗收另記於 [TESTING.md](TESTING.md)。真機長按手感、長時間播放及耗電仍未驗證。
