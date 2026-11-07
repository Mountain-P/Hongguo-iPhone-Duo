# 驗證紀錄

更新：2026-11-07，當前版本 0.4.4／build 14。本輪將推薦試看改為同頁連續影片卡片。預設內建取源與 progressive Range 播放不使用帳號憑據。

## 0.4.4 同頁連續試看

完整核心回歸：199 項、23 個 suites，198 項通過，1 項可選 `currentWebsiteSnapshot` 略過；`build/core-0.4.4-tests.log`。包含 RecommendationFeedActivation 7 項及 RecommendationPreviewQueue 9 項，驗證停穩／可見／前景資格、取消、A→B→A 舊回覆隔離與穩定 ID 選卡。Core 不直接驗證 SwiftUI 手勢或 AVPlayer 的音訊交接。

試看改用垂直 ScrollView，依完整卡片邊界逐頁停靠，每部劇佔一個可用畫面，在卡片內重用 AVPlayerLayer；不再透過 PlayerScreen 或 fullScreenCover 逐部開關播放器。只有停穩且對齊的卡片可準備第一集，拖曳時暫停；離屏、離開分頁、背景與進入詳情會停止工作。以單一 owner 順序停止舊播放器後啟動新卡，media 快取最多三部。試看 progress callback 為空操作，不寫入原續播位置；本輪未以真人帳號作額外片庫寫入測試。

模擬器檢查曾發現滑動開始時撤掉觸控層、以及長按與分頁競爭的風險。新卡保留固定觸控層，改用可與父層 pan 同時辨識的 UIKit 點按／長按，互動資格在 handler 檢查；長按只暫時加速，分頁不提供上下滑鎖速。一般全螢幕播放器的既有鎖速操作維持獨立。首集播完後再次播放會先回到零秒。

當次 Duo 模擬器以匿名片源觀察到：試看直接顯示動態影片，實際向上拖曳可連續進入第二、第三部的第一集；點影片顯示中央播放鈕並暫停。第三部按「看整部」進入相符的 81 集詳情，返回仍在同一張卡並顯示「繼續試看」；沒有先繼續播放，再按一次「看整部」仍可進入正確詳情。展開與旋轉後仍顯示影片及系統分頁控制，沒有另開播放器。這些是短程畫面與互動觀察，不代表真機手感、音訊交接、所有折疊角度或長時間效能已驗收。

最終修正版的本機 Duo 模擬器 Debug 建置與安裝記錄為 `build/ios-0.4.4-build14-simulator-final-ui.log`；使用 Xcode 本機 ad hoc 簽署。暫時的分頁診斷文字已移除，不包含於交付程式。

收尾的無障礙換頁測試另外抓到確定的頁高差異：系統容器 paging 曾停在 661 pt，但卡片實際高度為 644 pt，導致下一部仍是海報、沒有啟播資格。已改為零垂直內容邊距與 view-aligned 停點，iOS 18+ 使用實際 scroll geometry 作可見頁判斷；診斷版確認第二、第三部停在 644、1288 pt，對齊與啟播資格均有效，第二部第一集進度持續增加。程式化換頁以 pending target 隔離舊卡，系統省略 idle 回呼時由無手指拖動、幾何穩定且對齊的延遲判斷補足。

移除診斷文字後已重新建置、安裝及啟動最終模擬器版本。透過原生無障礙「下一部試看」切到第二部，第一集進度實際增加；「暫停」後出現中央播放按鈕，進度停在 22%。按「看整部」進入相符的 96 集詳情，返回保留同一部與 22% 位置並顯示「繼續試看」；沒有先繼續播放，再按「看整部」仍能再次進入相符詳情。本項驗證的是實際 App 播放與導航，不把無障礙換頁等同於手指／滑鼠拖曳手感。

測試期間 Device Hub 曾回傳失效 AX、`noWindowsAvailable` 與無法擷取畫面，重新連線後可繼續原生按鈕及無障礙操作；座標拖曳無法在收尾時穩定重現，因此不將早期短程拖曳結果宣稱為最終版完整手勢驗收。iOS 17 相容分支、長按持續時間與取消手感、所有姿態與真機長時間播放仍未在本輪完整驗證。

本輪較早的 0.4.4 Debug 曾使用既有開發團隊簽署並通過嚴格驗證，經已配對 iPhone 的 `localNetwork` 連線安裝、啟動及讀回 0.4.4／build 14（`build/ios-wireless-0.4.4-build14-install.json`、`launch.json`、`app.json`，後兩者沿用同一檔名前綴）。後續手勢修正版雖再次安裝成功，啟動時無線連線逾時；使用者當時指示先以模擬器驗證，因此該次無線結果不能僅憑相同版號證明手機已有最終分頁修正。

之後使用者以 USB 連接並解鎖 iPhone，裝置確認為有線且已連線。最終 Debug 重新建置自 `19530ec`，嚴格簽署驗證通過；預覽來源與 App 程式碼 SHA256 再次核對，與 `build/ios-wireless-0.4.4-build14-delivery-validation.json` 記錄一致。USB 安裝、啟動及 App 清單查詢均回報 `info.outcome=success`，讀回版本為 0.4.4／build 14。證據：`build/ios-real-device-0.4.4-build14-delivery-build.log`、`build/ios-usb-0.4.4-build14-delivery-install.json`、`build/ios-usb-0.4.4-build14-delivery-launch.json`、`build/ios-usb-0.4.4-build14-delivery-app.json`。無線連線後續可用性尚未另外重驗。這證明最終程式已透過 USB 安裝並啟動，不作為本版真機手勢、帳號或長時間播放驗收。裝置與簽署識別、帳號、片單及私人產物不放入公開倉庫；本輪未另產生未簽署 Release IPA。

## 0.4.3 播放狀態與推薦試看

完整核心回歸：190 項、22 個 suites，189 項通過，1 項可選快照略過；`build/core-0.4.3-tests-final.log`。本輪含 PlaybackSpeed 15、UserLibrary 25、PlaybackContinuation 7、RecommendationPreviewQueue 7。Duo 模擬器 Debug 建置成功：`build/ios-0.4.3-build13-simulator-final.log`。

- 播放速度由單一狀態管理。KVO 不再回寫速率；等待資料時改速仍更新播放器，暫停時改速不會自行播放。手動選速能解除臨時加速／鎖定，舊長按拖曳不能把新選速度改回兩倍。
- 影片單點、中央玻璃播放圖示、原生按鈕共用播放／暫停入口。播放意圖在 waiting／playing 過渡保持穩定；換集 ready／seek 有 generation 與 current-item 檢查，避免同集重複準備。自動重試沿用原播放意圖，背景暫停後晚到的 ready 不會自行開播。
- 觀看完最後一集後重新觀看從零開始；續播政策依集數排序，略過未開放集，不借用其他作品的進度。搜尋返回保留既有頁面，分頁失敗重試該頁，換查詢或來源會取消舊回覆。
- 收藏／進度在寫入前持久保存重試門檻，重啟不自動重送結果未明的操作。被擋操作不佔自動同步批次，也不阻塞其他新變更；此項以合成狀態測試驗證，沒有重做真人帳號寫入。

當次 Duo 模擬器實際觀察：進入「試看」後第一部顯示第 1 集並有動態影片；在影片實際上拖後切到另一部、第 1 集與 0:00，接著開始播放。點影片暫停，中央與原生按鈕均顯示播放；暫停時選 2×，已播放時間保持不變。按「看整部」進到相符作品的 96 集詳情，仍顯示「開始觀看」；返回顯示「繼續試看」且不自動重播。這些操作使用匿名片源，沒有輸入手機號碼或登入帳號。

另外在同一 Duo 模擬器，使用本機產生的四秒 H.264 合成片段及三集 fixture，經 App 設定連接 localhost 服務。實際觀察第 1 集開始播放、未操作下一集即到第 3 集播完；模擬器片庫三集各保存 4／4 秒，確認完成兩次自動銜接。這是正常本機 Range 回覆的短程測試，不代表所有實網緩衝／換源時序均已驗收。測後已還原模擬器內建播放並停止 fixture。

初次模擬器測試發現停用 Xcode 簽署只留下 linker ad hoc，沒有 simulated app identity，造成服務口令的 Keychain 操作失敗。建置腳本已改用本機 ad hoc 簽署（不需個人團隊）；重新建置後，Xcode 產生 Simulated.xcent，實際服務驗證與設定儲存成功。證據 `build/ios-0.4.3-build13-simulator-signed.log`。

本版實機 Debug 已以既有開發團隊簽署並通過嚴格驗證，透過已配對 iPhone 的區域網路連線完成安裝與啟動。`devicectl` 讀回 0.4.3／build 13；安裝後連線仍為 `localNetwork`。證據為 `build/ios-real-device-0.4.3-build13-build.log`、`build/ios-wireless-0.4.3-build13-install.json`、`build/ios-wireless-0.4.3-build13-launch.json`、`build/ios-wireless-0.4.3-build13-app.json`。本輪開發與互動檢查使用模擬器；無線部署成功不當作新版本真機手勢、帳號或長時間播放的驗收。

試看只傳第 1 集給播放器、關閉自動下一集且 onProgress 為空操作；不改續播位置。手勢長按的真機手感、各種網路緩衝時序與長時間播放仍需實機回饋，不把 Core 測試或模擬器當作完整硬體驗收。

## 0.4.2 片庫載入與實機帳號驗證

完整執行 `swift test --disable-sandbox --disable-xctest`：162 項、20 個 suites，161 項通過，1 項可選 `currentWebsiteSnapshot` 略過。證據：`build/core-0.4.2-tests.log`。UserLibrary 共 19 項，新增 metadata enrichment 不改收藏、進度、時間與 mutation UUID 的檢查。

修正首次帳號同步在逐筆補抓詳情前不顯示清單的問題：觀看紀錄及收藏分階段提交，作品資訊改為最多四筆並行、每輪 50 部／45 秒的背景補齊。實機觀察到大型雲端片庫與海報開始顯示，清單不再等待所有詳情完成。

實體 iPhone 的 Debug 與未簽署 Release 均編譯成功；Debug 嚴格簽署檢查、安裝、啟動成功，`devicectl` 讀回 0.4.2／build 12。證據：`build/ios-real-device-0.4.2-build12-build.log`、`build/ios-0.4.2-build12-release.log`、`build/ios-real-device-0.4.2-build12-install.json`、`build/ios-real-device-0.4.2-build12-launch.json`、`build/ios-real-device-0.4.2-build12-app.json`。更新後沿用 Keychain 會話，沒有要求重新取得驗證碼。

Device Hub 對同一實體裝置觀察到：

- 帳號片庫顯示雲端觀看歷史與收藏，最後為「片庫已同步」。不在公開文件保存個人帳號、電話、劇集片單或畫面。
- 原未收藏的測試作品，按「加入收藏」變為「已收藏」，片庫數量增加一筆且同步完成；再取消後恢復原數量、按鈕與同步完成狀態。測試沒有保留新增收藏。
- 明確按「開始觀看」後看到實際影片。返回「我的」顯示該集新的進度，後續狀態為「片庫已同步」，沒有待同步或錯誤提示。此狀態只會在收藏回覆及兩段進度寫入都確認成功、隊列清空後顯示。

當時使用者也在操作裝置、切換作品及折疊姿態，因此這是正常使用期間的端到端狀態觀察，不當作獨立、可重現的播放器手勢測試。未另以另一部裝置的官方 App 核對觀看位置，未驗收全部地區號碼、上行簡訊 MFA、會話過期、斷網重試或長時間同步。

未簽署 IPA 已核對 iphoneos／arm64、版本、ZIP 完整性、12 份 bundled JS 的 SHA256 與 GPL／MIT／BSD 授權檔，且不含簽章、描述檔或 macOS metadata；證據 `build/package-0.4.2-validation.json`。本機 `build/`、實機紀錄、帳號資料與簽署產物不隨 Git 倉庫發布。

## 0.4.1 帳號與片庫核心

完整執行 `swift test --disable-sandbox --disable-xctest`：159 項、20 個 suites，158 項通過，1 項可選 `currentWebsiteSnapshot` 略過。證據：`build/core-0.4.1-tests.log`。新增帳號相關測試包括 Session 11、NativePhoneAuth 12、NativePhoneRuntime 4、AccountLibrary 9、UserLibrary 16；均參與這次完整執行。

涵蓋發碼／登入／MFA 請求、+86 full 與國際 mode 4 精確簽章向量、同一 AppDevice 綁定、取消不得繼續發碼、無自動重發、19 位 ID 精度、Cookie／Token 範圍與轉址拒絕、403／429／二階段進度寫入、失敗須明確重試、切換帳號／來源、舊資料 Codable、訪客明確匯入、完整／部分收藏及 tombstone、舊 ACK 不移除新操作、各集完成證據與不截斷 200 筆。測試使用合成資料，不發真實簡訊。

以正式 `NativePhoneAuthService.prepareRegistration()` 和 bundled runtime 執行只註冊、不帶電話／驗證碼／帳號憑據的實網探針：

```sh
swift run --disable-sandbox NativeAccountCheck --prepare-registration
```

當次結果 `registration=ready`，`phoneSubmitted=false`、`smsSent=false`、`credentialsStored=false`；證據 `build/native-account-registration-0.4.1.log`。此結果僅證明 macOS 上相同 Core 正式註冊路徑可用，不當作 iPhone 發碼、真人登入或收藏同步的驗收。

0.4.0／build 10 中間版曾完成 143 項（142 通過、1 可選略過）與實機安裝。Device Hub 觀察到舊有 8 筆觀看紀錄成功遷移並顯示分集與百分比；官網登入頁實際顯示導流下載介面，使用者要求改用原生 API。0.4.1 已移除該 WK 登入畫面，不將此中間版視為可用登入流程。

實體 iPhone 0.4.1／build 11 的 Debug 與 Release 均編譯成功，Debug 嚴格簽署檢查、安裝、啟動成功；`devicectl` 讀回相同版本。證據：`build/ios-real-device-0.4.1-build11-build.log`、`build/ios-0.4.1-build11-release.log`、`build/ios-real-device-0.4.1-build11-install.json`、`build/ios-real-device-0.4.1-build11-launch.json`、`build/ios-real-device-0.4.1-build11-app.json`。

使用者在手機自行輸入號碼／驗證碼，回覆「已登入成功」。Device Hub 隨後實際顯示已登入的官方帳號頭像、名稱與遮罩手機，以及帳號片庫同步狀態。未代使用者輸入條款同意、電話或驗證碼；不在紀錄中保存這些資料。此結果證明當次原生手機驗證碼登入成功，不推論全部地區、上行 MFA 或其他帳號均能登入。

原生 API、資料保存與仍需真人驗證的界線見 [ACCOUNT.md](ACCOUNT.md)。

## 0.3.0 選劇驗證

完整核心測試：107 項、15 個 suite，106 項通過，1 項可選 `currentWebsiteSnapshot` 略過。新增分類／榜單 9 項、近期新劇 7 項、藝人／詳情 metadata 7 項均在完整執行中通過。命令為 `swift test --disable-sandbox --disable-xctest`，證據：`build/core-0.3.0-tests.log`。

下列實網檢查經正式 Swift Service 與 `CatalogDiscoveryCheck` 執行，未取影片來源或下載劇集媒體：

| 檢查 | 當次結果 | 證據（位於 `build/catalog-research-0.3.0/`） |
| --- | --- | --- |
| 真人／漫劇／AI 公開分類 | 各 24 部，題材依內容類型動態回傳 | `category-real-live.log`、`category-comic-live.log`、`category-ai-live.log` |
| 愛情題材第二頁 | 24 部，page=2、hasMore=true | `category-romance-page2-live.log` |
| 總榜／真人／漫劇／AI 榜 | 各 20 部，保留官方名次、熱度、評分 | `rank-all-live.log`、`rank-real-live.log`、`rank-comic-live.log`、`rank-ai-live.log` |
| 總榜第二頁 | 20 部，樣本名次從 21 開始 | `rank-all-page2-live.log` |
| 近七天真人新劇 | 86 部去重作品，含「今日上新」標記 | `new-real-live.log` |
| 近七天 AI 新劇 | 82 部去重作品，含「新剧」標記 | `new-ai-live.log` |
| 劇集詳情 | 原 102 集保留；18 位演員、16 部官方相似推薦、評分 9.5、來源熱度、上架日 2026-10-31 | `detail-live.log` |
| 藝人李柯以 | 有公開簡介、54 部當次公開參演作品 | `artist-live.log` |

新劇每類使用單一匿名 metadata runtime 順序抓最多兩頁，總期限 8 秒、最多 100 部、記憶體快取 60 秒。沒有將舊網站排序重導後的熱門資料標成最新，也未把藝人公開片單宣稱為完整履歷。詳情附加資料沿用同一次 HTML，解析失敗不阻擋原分集。新增 DTO 的舊 Codable 相容、錯誤 route／身份綁定、來源拒絕、取消、超量、快取與游標隔離均包含於測試。

最終實機 Debug 0.3.0／build 9 已編譯、嚴格簽署檢查、安裝及啟動成功；`devicectl` 已讀回 `version=0.3.0`、`bundleVersion=9`。證據：`build/ios-real-device-0.3.0-build9-build.log`、`build/ios-real-device-0.3.0-build9-install.json`、`build/ios-real-device-0.3.0-build9-app.json`。Release 編譯成功：`build/ios-0.3.0-build9-release.log`。

Device Hub 選取實體 iPhone，build 8 已觀察到劇場四入口、總榜名次與來源熱度、新劇片單及「今日上新」標記、原生題材面板。選擇愛情並按「套用」後，分類按鈕變為愛情、海報改為對應作品；這些瀏覽過程沒有建立播放器。

build 8 實機檢查發現藝人作品的值導航可能重建原藝人頁；build 9 已將詳情內的作品網格改為明確推入新詳情頁，並在實機完成以下流程：

- 原 102 集作品詳情顯示來源評分、熱度、上架日及演員與角色。點李柯以進入公開人物頁，顯示 54 部當次作品；點第一部進入「乡下真千金竟是老祖宗」的 71 集詳情。返回立即保留藝人片單，再返回保留原劇集資料。
- 原詳情的相似推薦先顯示 6 張直式海報，附「查看全部 16 部相似作品」。點「王妈在顾家当保姆后全家只会搞笑了」進入對應 86 集詳情，載入後顯示作品資訊與演員；返回仍保留原相似片單及捲動位置。
- 上述藝人、作品及相似推薦導航未自動開始影片。這是當次實體裝置的短程 UI 檢查，不涵蓋全部作品、姿態與長時間操作。

build 9 只追加上述 SwiftUI 導航修正；Core 沿用本節已通過的完整 107 項測試版本，未將 UI 修正宣稱為另一次 Core 全量測試。

## 0.3.0 打包狀態

最終通用包為 `dist/Hongguo-iPhone-0.3.0-unsigned.ipa`（0.3.0／build 9，1,503,931 bytes）。已確認 iphoneos／arm64、ZIP 完整性、10 份 bundled JS 與來源 SHA256 manifest 相符，以及 GPL／MIT 授權檔完整；不含簽章或開發描述檔。IPA SHA256：`ea443596d0d3a97783df42f662c050dd08ee13fc7e18548b5924e47085c4c135`。驗證資料：`build/package-0.3.0-validation.json`。

原始碼包 `dist/Hongguo-iPhone-0.3.0-source.zip` 包含新選劇／藝人 Core、UI、測試、來源聲明與建置腳本。打包後檢查版本與必要檔案、ZIP 完整性，排除 build、暫存、node_modules、測試影片、簽署描述檔及口令檔。兩份交付檔的大小與 SHA256 列於 `dist/Hongguo-iPhone-0.3.0-checksums.json`。實際已安裝的 Debug 使用個人開發簽署，與此未簽署 IPA 分開。

## 核心與真實串流基線（0.2.0）

| 檢查 | 結果／證據 |
| --- | --- |
| 完整 Swift 核心 | 84 項，83 通過、1 項可選官網快照略過；`build/core-0.2.0-tests.log` |
| 內建取源 | 真正 JavaScriptCore／CommonCrypto／URLSession 取得 HEVC 1080p 片源，約 1.6 秒；`build/native-source-live.log` |
| Progressive startup | 官方 102 集劇集第 4 集，準備 2.82 秒、第一個解碼影格 3.10 秒；`build/native-progressive-startup.log` |
| 完整 progressive 影片／音訊 | 同一第 4 集全部 89.79 秒、2,244 影片影格、825 個音訊 buffer；首幀 1.98 秒、全流程 7.9 秒；`build/native-progressive-full-decode.log` |
| 直接 seek 至 70% | 準備 1.66 秒、目標位置第一個解碼影格 2.09 秒；`build/native-progressive-seek.log` |
| MP4／CENC | 完整及任意 offset 分段解密對照；8／16-byte IV、subsample、senc／外部 saiz／saio、AVC／HEVC、metadata 範圍與錯誤包含於核心測試 |
| Range／快取／取消 | 精確 206 與檔長、ETag 變更拒絕、忽略 Range 的 200 停止、403 保留、body 上限、最多兩筆並行、取消隔離、8 MiB LRU、來源 120 秒／16 筆快取均有測試 |
| 倍速狀態 | 7 項測試涵蓋長按 2x、恢復原選速度、鎖定／解除、背景取消、手動改速及無效輸入 |
| 選用 Node 橋接 | 22／22 測試通過，另做過真實 HEVC 前段解碼；預設 iPhone 流程不依賴它 |

以上三次 progressive 量測使用相同劇集與第 4 集，但為不同執行，數值反映各次網路與快取狀態。完整解碼、首幀與 seek 均經共享 `HongguoPlayback.NativeMediaAssetLoader` 和 AVFoundation 路徑，未使用播放服務。

明確執行真實來源檢查：

```sh
swift test --disable-sandbox --disable-xctest
swift run NativePlaybackCheck --startup 7701935931787316286 4
swift run NativePlaybackCheck 7701935931787316286 4
swift run NativePlaybackCheck --seek 7701935931787316286 4
```

工具不輸出影片簽名網址、內容金鑰或匿名身分。來源可用性只代表當次結果，不推論全部平台影片。

## 0.2.0 Duo 模擬器介面基線

- 本機 Xcode 27.2、iOS SDK 27.2；Duo 專用 runtime 為 24B91016s，identifier：`com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`。一般 runtime 24B8117 不支援 Duo，不能只看 27.2 版本號。
- Progressive／Duo 建置成功：`build/ios-progressive-sidebar-build.log`。最新 NavigationStack 原生工具列建置成功：`build/ios-native-toolbar-build.log`。
- 根畫面使用「首頁／劇場／我的」原生 TabView；播放器透過 fullScreenCover 呈現自己的 NavigationStack／toolbar，讓 Duo 系統處理側欄配置。播放中不透出主 Tab 或首頁 pager。
- 當時播放器的原生工具列持續顯示並可點，「更多」內含選集、下一集及自動續播；三秒自動隱藏當時限於片名／進度時間資訊浮層。0.2.3 起工具列與資訊會一起顯隱，見後續實機紀錄。
- Device Hub 已實際顯示橫向原生側欄；收合後系統自動收納較少用的項目至原生 overflow，展開後恢復。原生暫停可用；變更姿態時仍保留第 39 集、1:07 的播放位置。截圖：`build/duo-native-system-toolbar.png`。
- 單擊影片後片名／進度從 accessibility tree 消失，再點一次會重新出現；主分頁、常駐選集與下一張海報沒有透出全螢幕播放器。
- 長按 0.35 秒暫時 2 倍速、上滑 60 pt 鎖定、再長按下滑 60 pt 解除均已實作。7 項 Core 行為測試通過，Duo 也以無障礙操作驗證鎖定提示與點選解除。工具未可靠取得長按中的瞬間畫面，因此不把這項操作宣稱為實體觸控／滑動手勢驗收；實機手感與 continuous hover 硬體驗證仍待完成。

原生列的實作參考 Apple [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/) 與 [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)。本節畫面檢查是在 Duo 模擬器完成；實機證據另列如下。Apple 原生列在外螢幕與內螢幕橫向使用側邊配置，內螢幕直向則回到上下配置；`toolbarVerticalEdge` 為唯讀環境值，不能用它強制側邊配置。

## 實體 iPhone 安裝與播放

2026-11-06 已在連接的實體 iPhone Duo（iPhone19,4／iOS 27.1）完成：

- 使用使用者的 Apple Personal Team 建立開發簽署，Debug 0.2.0／build 3 編譯成功：`build/ios-real-device-build.log`。`codesign --verify --deep --strict` 在正常可存取鑰匙圈的執行環境通過。
- `devicectl` 確認配對成功、Developer Mode Enabled；安裝成功：`build/ios-real-device-install.log` 與 `.json`。第一次啟動回報未信任簽署，之後重新啟動成功：`build/ios-real-device-launch-second.log`。
- Device Hub 選取的是上述實體裝置，實際看到動態影片影格及原生工具列，並看到外螢幕側欄、內螢幕直向上下列與內螢幕橫向側欄配置。使用者在手機旁確認「有聲音」。這屬短時間、當次網路的基本播放驗證。
- 開發描述檔包含這一台裝置，當次有效期限為 2026-11-13 23:37（Asia/Taipei）。未匯出私鑰；供通用下載的 unsigned IPA 仍不含此描述檔。

使用者在實機指出首頁滑動自動播放，以及控制列佔位造成黑邊；這些回饋於 0.2.1 至 0.2.4 迭代修正，最新結果如下。上述早期紀錄不作為新版全部操作驗收，也不宣稱長按滑動手感或長時間連播已通過。

## 0.2.3／0.2.4 實機 UI 更新

- 0.2.3／build 6 改成與劇場一致的自適應海報網格，海報等比完整顯示。瀏覽、換分類和回到首頁不建立影片播放器；按「開始觀看」才載入。
- 修正首頁載入被 scroll position 變動取消，以及海報裁切後點擊區溢出、攔截其他按鈕的問題。0.2.3 在 Device Hub 對實機首頁第一個「開始觀看」觀察到該按鈕載入狀態；console 依序記錄 `prepare_started → detail_ready → presented`，證據為 `build/ios-real-device-0.2.3-console-final.log`。
- 原生 NavigationStack 工具列透明覆蓋影片，影片畫布獨立忽略容器 safe area。控制項顯隱只改前景，不縮放影片畫布；完整比例模式仍保留影片本身寬高比，因此可能自然留邊。
- 0.2.4／build 7 將片名／集數、進度／時間合成兩列 Liquid Glass 圓角浮層，移除大片黑色漸層。iOS 26+ 用系統 `glassEffect`；舊版回退材質，減少透明度設定採不透明背景。Slider 保留至少 44pt 操作範圍。
- 0.2.4 實機 Debug 編譯、嚴格簽署檢查、安裝與啟動成功；`devicectl` 讀回 `version=0.2.4`、`bundleVersion=7`。證據：`build/ios-real-device-0.2.4-build.log`、`build/ios-real-device-0.2.4-install.json`、`build/ios-real-device-0.2.4-app.json`。Release 編譯也成功：`build/ios-0.2.4-release.log`。
- Device Hub 選取實體裝置，實際觀察到第一部劇集影片與新玻璃浮層，底部原生控制列後方仍有影片，未見上下工具列黑色佔位區。當次 console 也有手動點播三個階段：`build/ios-real-device-0.2.4-console.log`。
- 使用者於 2026-11-07 表示「播放的狀況完全沒有問題」，並轉向選劇功能。遠端檢查期間使用者也在操作手機，因此沒有把後續混合操作當成可重現的單擊收起／進度拖曳驗收；本輪未重新量測實機首幀或全部長按手勢。

0.2.1～0.2.4 為 UI 與點播生命週期修正；核心串流測試結果仍屬上方 0.2.0 基線，沒有宣稱每個中間版本重跑全部核心測試。

## 歷史對照

較早版面曾在 Duo 驗證 Closed／Open 原生播放、自動續播至下一集，以及「我的」觀看進度。先前自製控制列與首頁內嵌播放器的畫面紀錄屬舊版；最新版本採上述原生工具列與獨立全螢幕呈現。

先前完整單集準備路徑曾解碼相同第 4 集：89.79 秒、2,244 影片影格、745 個音訊 buffer、全流程約 31.2 秒，記錄於 `build/native-audio-video-live.log`。該整集準備與磁碟快取保留作明確對照／測試，已非 App 或目前 NativePlaybackCheck 的預設路徑，不會在 Range 失敗時自動啟用。

## 0.2.0 歷史打包狀態

當時交付為 0.2.0／build 3。iPhone Release 建置成功（`build/ios-0.2.0-release.log`），並產生 `dist/Hongguo-iPhone-0.2.0-unsigned.ipa`（1,259,446 bytes）。確認平台 iphoneos、架構 arm64、ZIP 完整性、每份打包 JS 的 SHA256、GPL／MIT 授權檔；沒有簽章或描述檔殘留。IPA SHA256：`54902538f496a85c40b6cb04c554ed272cc659d63c8e835790ab90598bb758a1`。

原始碼包為 `dist/Hongguo-iPhone-0.2.0-source.zip`，包含 Core、共用 ResourceLoader、UI、來源聲明與建置腳本；排除 build、暫存、node_modules、測試取得的影片及口令檔。

本節 0.2.0 通用 IPA 未簽署，不含開發者私鑰或描述檔；實際安裝到手機的 Debug 是另行建立的個人開發簽署版本，驗證範圍見上節。

## 保留的驗收界線

- 真實音訊／影片完整解碼量測是在 macOS AVFoundation 執行；實體 iPhone 已有畫面與使用者確認聲音的基本驗證，但尚未量測實機首幀、效能或耗電。
- 預設先讀 256 KiB 前綴及必要索引，按需取得 512 KiB 區塊，以 8 MiB 記憶體 LRU 管理；網速仍會影響首幀與緩衝。來源必須支援精確 Range，不提供離線片庫。
- 支援非 fragmented MP4 的 CENC AES-CTR；ByteVC2、CBCS、key rotation 或不支援的結構會明確拒絕。
- 尚未完成全部機型、大字級／完整 VoiceOver 流程、全部折疊角度、背景中斷、行動網路、長時間連播與來源持續可用性驗收。本節的歷史驗證未包含遠端 CI 或正式後端部署；最新 CI 結果以倉庫 Actions 為準。
