# 驗證紀錄

更新：2026-11-08，當前版本 0.12.1／build 30。本輪加入左右雙點前後十秒，以及待完成定位目標的連續累加。測試、模擬器手勢與手機部署分開記錄。

## 0.12.1 左右雙點定位

完整本機 `swift test --disable-sandbox`：Core 註冊 482 項／52 suites，481 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 101 項／6 suites 全通過，合計 **582 通過、1 略過、無失敗**，見 `build/core-0.12.1-final-tests.log`。新增 10 項幾何與相對定位政策測試，範圍見 [TESTING-CORE.md](TESTING-CORE.md)。兩平台 Debug 建置與嚴格簽章檢查通過，記錄 `build/ios-0.12.1-build30-final.log`、`build/ios-real-device-0.12.1-build30-final.log`。

### Duo 模擬器手勢

正式播放器使用《一念沉沦，霍总心动了》第 2 集，先暫停於 1:54；實際左側雙點到 1:44，右側雙點回到 1:54，連續右側雙點兩組到 2:14，中央按鈕仍是「播放」。單點收起控制列後，左側雙點仍定位且不叫回完整控制列；固定事件記錄同時為 `controls=0`。長按約 900 ms 只有開始／結束倍速事件，沒有多出雙點定位。實際上滑切到第 3 集；再次暫停、以既有輔助動作鎖定 2 倍速後雙點，仍維持暫停且保留鎖速提示，最後已解除鎖定。沒有把輔助鎖速當成長按上下滑複合手勢的本輪驗收。

試看滿版使用《杀手归来，以后换我保护妈妈》第一集，暫停後左側雙點進度由 93% 降至 83%，右側回到 93%，畫面維持隱藏控制列；輔助樹讀到左右「後退／前進 10 秒」短暫提示。單點可叫回中央播放與其他控制，長按未額外定位，上滑可換到其他作品。快速模擬器拖曳可能跨多張卡，不將其當成每個拖曳恰好一頁的驗收。

展開內螢幕後，在《小镇是非多之同床异梦》第一集暫停的同一張卡，直向及橫向都實際左右雙點，進度各可在約 28% 與 19% 之間往返，旋轉後中央仍為「播放」。本輪 12 次有效雙點對應 12 次 `skip` 觸覺事件，正式／試看各 6 次；固定事件保存於 `build/playback-gesture-0.12.1.log`，不含內容識別、來源網址或憑據。模擬器無法驗收實體震感；雙指縮放的 recognizer 依賴保留並完成程式審查，本輪未操作真正雙指觸控或完整 VoiceOver 手勢。測後恢復 Closed／首頁、1 倍速，移除診斷參數正常重新啟動。

### CI 與手機部署

App 原碼 `9e5a1c16897a4d1eaf7b394d2129af03adf1ba8f` 的 [CI](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42399758081) 核心測試通過；遠端缺少相容 Duo SDK，App 建置步驟略過，兩平台建置以上述本機結果為準。118 份來源、成品版號與雜湊保存於本機 `build/ios-0.12.1-build30-validation.json`。

手機已覆蓋安裝，清單讀回 0.12.1／30，啟動命令成功，後續程序查詢確認同一啟動 PID 仍在執行；結果保存於該驗證 manifest 及本機 `build/ios-0.12.1-build30-device-*.json`。手機上的完整觸控與觸覺手感仍待使用者試用；以上畫面與定位操作來自 Duo 模擬器。

## 0.12.0 倍速緩衝與磁碟預讀

完整本機 `swift test --disable-sandbox`：Core 註冊 472 項／51 suites，471 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 101 項／6 suites 全通過，合計 **572 通過、1 略過、無失敗**，見 `build/core-0.12.0-final-tests.log`。本輪新增 37 項 Core 測例，詳細範圍見 [TESTING-CORE.md](TESTING-CORE.md)。兩平台 Debug 建置及嚴格簽章檢查成功，記錄 `build/ios-0.12.0-build29-final.log`、`build/ios-real-device-0.12.0-build29-final.log`。

舊版固定的 5 秒媒體緩衝偏好，在 2 倍速時只相當於約 2.5 秒播放時間；這是 AVPlayer 的偏好提示，不是實際緩衝的硬上限。新版改以播放時間及倍速設定目標，另在符合網路與電量條件時預讀目前集，下一集的準備先讓目前尾段保有餘裕。從手機既有診斷抽出的不含內容摘要，確有一筆約 7.96 秒等待，但未保存當時倍速；其餘不少是極短的狀態轉換，不能全部算成肉眼可見轉圈，也不能和下列模擬器樣本作前後效能比較。原始偏好副本抽取後已移除，摘要僅存本機 `build/playback-0.12.0-phone-baseline.json`。

### Duo 模擬器

以內建取源實際播放《一念沉沦，霍总心动了》。第一集在 1 倍速下持續前進；暫停後以後退十秒回到 1:01，維持暫停，再選 2 倍速。使用正式「下一集」入口從第 2 集零秒開始播放，看到影片前進至 1:10，之後暫停於 1:40／2:25；這段約 50 秒的 2 倍速播放，起播後未觀察到持續轉圈。未量測或宣稱手機、長時間播放及不同 CDN 的改善比例。

固定數值 DEBUG 記錄 `build/playback-buffer-0.12.0.log` 核對：正式 1 倍速目標由 30 提升至 45 媒體秒；選 2 倍速後為 90。新一集 2 倍速由 60 提升至 90；暫停時預讀資格為 0。試看另實際播放首集及長按，記錄 1 倍速 8→12、2 倍速 24 媒體秒，暫停後預讀資格為 0。這些值確認偏好接線，並非已下載相同秒數的保證；同一 item 的目標維持只增不減。

在「我的 → 設定」看到播放快取 7.5 MB，按清除後顯示 0 KB；同時核對專用分段目錄由 15 個檔案、7,502,821 bytes 變成 0 檔案、0 bytes。此入口不包含既有全檔 fallback 的獨立快取。測後恢復 1 倍速、Closed／首頁，並以無診斷參數正常重新啟動。未重做所有姿態、雙指手勢、帳號網路寫入與耗電量測。

### CI 與手機部署

App 原碼 `a3a1ef6d697749de28eeca4f9760fc4943dcd638` 的 [CI](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42397798142) 核心測試通過；遠端 App 建置因缺少相容 Duo SDK 略過，兩平台建置以上述本機結果為準。117 份來源與成品版號、雜湊保存於本機 `build/ios-0.12.0-build29-validation.json`。

手機已覆蓋安裝，清單讀回 0.12.0／29；啟動成功，後續程序查詢確認同一 PID 仍在執行，記錄為本機 `build/ios-0.12.0-build29-device-*.json`。沒有代替使用者操作手機長播；2 倍速、快取清除與畫面操作證據來自模擬器，手機的常看劇集及網路狀況仍需使用者試用確認。

## 0.11.1 快轉與倍速觸覺回饋

倍速回歸 15 項全部通過，記錄 `build/core-0.11.1-speed-tests.log`；本輪未改 Core／AppSupport 狀態規則，沒有把上一版完整本機 535 通過、1 略過當成此次重新執行。兩平台 Debug 建置及嚴格簽章檢查通過，見 `build/ios-0.11.1-build28-final.log`、`build/ios-real-device-0.11.1-build28-final.log`。

Duo 模擬器實際操作一般播放器及試看長按，並以 DEBUG 固定事件記錄核對一次性回饋：3 次開始、2 次正常結束、鎖定／解除各 1 次、前後十秒合計 2 次、選速 2 次，共 11 次，見 `build/playback-haptic-0.11.1.log`。第三次開始是已鎖定時再次長按；放開保留鎖速，因此沒有多一次結束提示。選擇相同的 2 倍速未增加事件，選回 1 倍速才增加一次。影片暫停在 0:37，前進到 0:47、後退至 0:37，倍速操作均未使其自行播放。離開播放器及試看後沒有額外清理事件；正常啟動已移除診斷參數。

鎖速與解除在本輪使用正式無障礙命令及提示按鈕核對，長按上下拖曳仍走相同命令接點；沒有宣稱工具完成這個複合手勢或感受到 Taptic Engine。觸覺只在有效使用者命令的實際狀態變更時發出，背景、換集、取消、捏合與交接的清理維持 silent；模擬器事件紀錄不是實體震感驗收，強弱及手感仍待手機使用者確認。

App 原碼 `ae0172be45e428c687d1a79b28042db02d11f8b3` 的 [CI](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42394401677) 核心測試通過；遠端 App 建置因缺少 Duo SDK 略過，兩平台建置以上述本機結果為準。手機已覆蓋安裝，讀回 0.11.1／28，正常啟動且後續查詢確認同一 PID 仍在執行；未透過聊天收集帳號或驗證碼。115 份來源、兩平台成品與部署核對保存在本機 `build/ios-0.11.1-build28-validation.json`，手機的實際震感仍待使用者試用。

## 0.11.0 播放連續性、推薦題材與滿版縮放

完整本機 `swift test --disable-sandbox`：Core 註冊 435 項／48 suites，434 通過、1 項可選實網快照略過；AppSupport 101 項／6 suites 全通過。合計 **535 通過、1 略過、無失敗**，記錄 `build/core-0.11.0-final-tests.log`，測例範圍見 [TESTING-CORE.md](TESTING-CORE.md)。

### Duo 模擬器

使用內建目錄與實際影片。在《一江春水》滿版試看中按「追這部」，DEBUG 出現 `PlaybackHandoff claimed samePlayer=1 sameItem=1`，其間沒有建立 `preview=0` 管線；正式 surface／seek 就緒後撤除轉場影格。暫停正式播放於第 1 集 2:36／2:47，再退出，回到同一張完整卡並顯示「繼續試看」；點選後建立新的 `preview=1` 管線，仍只播放第一集。回首頁正式紀錄保持 93%，未被後續試看覆寫。固定事件記錄在 `build/playback-session-0.11.0-final.log`，沒有寫劇集識別、網址或帳號憑據。這是本次符合條件的實際重用證據，不能推論所有來源都能無等待交接；拒用、過期、取消等條件另由核心測試覆蓋。

本輪一般播放器切至下一集時，準備期間仍可見上一集的解碼影格，新影片顯示後恢復實際畫面；返回上一集亦有 `EpisodeTransition captured=1` 與 `ready=1 released=1` 配對，見 `build/playback-session-0.11.0-transitions.log`。沒有用固定秒數提早撤圖，也未量測整體網路啟播加速幅度。

實際選擇「多推薦古装」與「少推薦逆袭翻身」後，目前卡片沒有跳走；重新安裝及啟動 App 後，推薦偏好頁仍列出這兩項。逐項恢復會移除該題材，全部恢復後顯示尚未設定；本次加入的兩項測試偏好已還原，既有正式紀錄及不感興趣設定未清除。跨頁尾部題材交錯與回應時最新 profile 的契約由正式 model 的可控回應測試核對，未把一次畫面排序當成推薦效果評估。

試看滿版已確認原生 Tab／狀態列及控制資訊隱藏，影片使用完整畫布；點影片空白處能收起／叫回控制，暫停狀態不變。選單放大到 125%、完整比例重設至 100%、縮小至 80%、一鍵還原 100% 均正常；完整比例保留影片原始比例，因此可能有自然留白。橫直旋轉仍保持同劇及播放意圖。雙指縮放的 UIKit 接線與取消恢復已實作，8 項純狀態測試通過；本輪工具沒有執行真正雙指觸控，該手勢手感仍待實機使用者驗收。

測試另發現 LazyVStack 會在尺寸改變後保留離屏卡片舊高度，造成重開／滿版／返回時兩張卡混在同頁及操作失效。已改用統一頁高的原生 ScrollView 頁框，只建立穩定目標附近的有限卡片，其餘為空頁框；保持當前播放器識別。首次恢復、正式 cover／偏好／背景返回都有有界重錨入口。最終來源 `9c5966d714662407b6b469abfa016e45cf56c3bc` 重新驗證重開還原、橫向滿版、直向滿版、正式播放返回與手動恢復；尺寸診斷確認實際 content 高度等於頁數乘以新頁高，見 `build/preview-layout-0.11.0-fixed-pitch.log`、`build/preview-layout-0.11.0-rotation.log`。完成後恢復模擬器 Closed／首頁，以不含診斷參數的正常命令重新啟動。

### 建置、CI 與實機

最終來源的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42392946238) 核心測試成功；遠端缺少相容 Duo SDK，App 建置步驟略過。兩平台 Debug 本機建置及嚴格簽章檢查成功，記錄 `build/ios-0.11.0-build27-final.log`、`build/ios-real-device-0.11.0-build27-final.log`。114 份來源與成品版號／雜湊保存於 `build/ios-0.11.0-build27-validation.json`。

已透過既有開發連線覆蓋安裝實機，讀回 0.11.0／27；啟動成功，隨後查詢確認同一啟動 PID 仍存在。安裝、版號與啟動的 JSON 證據保存在本機 `build/ios-0.11.0-build27-device-*.json`。手機上沒有重做完整播放、帳號同步與雙指手勢驗收；上述畫面操作來自 Duo 模擬器。

## 0.10.0 播放連續性與位置記憶

最終本機 `swift test --disable-sandbox`：Core 註冊 395 項／45 suites，394 通過、1 項可選實網快照略過；AppSupport 95 項／6 suites 全通過，合計 489 通過、1 略過，無失敗。記錄為 `build/core-0.10.0-final-tests.log`。初次 CI 曾因既有取消測試使用固定 80ms 等待而偶發失敗；該 fixture 已改為明確進入等待、取消與完成的 gate，保留嚴格取消斷言，最終完整測試再次通過，App／Core 播放原碼未因測試修正而改動。新增 14 項手勢政策、10 項 session／本機片單還原與 6 項實際 RecommendationPreviewModel 整合測試，包含拉回與取消不提交、單次 seek、靈敏度切換不跳、來源／片庫隔離、壞資料與大小上限、重新驗證第一集、遲到回呼與分頁失敗保留位置；不將這些單元測試當成實際手勢或觸感驗收。

### Duo 模擬器操作

使用內建取源實際播放《杀手归来，以后换我保护妈妈》。停在第二張卡片 14% 後離開並終止重開 App，再進試看仍回到同一部，播放後暫停為 23%；時間差包含重開後實際播放，並非精確啟播時間量測。正式歷史在按「追這部」前沒有新增該劇；完整的保存秒數及不改正式 history key 另由測試核對。

按「追這部」後，準備期間畫面保留原影片；DEBUG 記錄 `capture_success size=540x960`、`retained_preparing`，正式 surface ready 與初始 seek 都完成後才出現 `formal ready=1 seekComplete=1 released=1`，之後影片正常前進。紀錄位於本機 `build/playback-transition-0.10.0.log`，只有固定事件及尺寸，不含劇集識別、來源網址或帳號資料；這證明本次有效影格的交接，不代表每種來源都能擷取影格，也沒有量測網路加速。

展開橫向、暫停狀態下，進度條水平移動約 80 畫面像素由 1:06 調至 1:19；相同水平位移並往上移手指後，由 1:19 僅調至 1:21，放開後維持暫停且未換集。實際上滑切到第 2 集、下滑返回第 1 集，再下滑顯示「已經是第一集了」並保留影片；短滑沒有提交換集。拖動中的放大時間與目標提示由程式接線及核心狀態核對，本輪工具在放開後取圖，未聲稱捕捉到按住中的畫面或模擬器實體觸感。

鎖定 2 倍速時只有頂部獨立提示，完整控制列保持隱藏；解除後回到原試看卡，需手動「繼續試看」。展開橫向轉直向仍是同一張完整卡片；手動暫停後再轉橫向，保留同劇及 49% 暫停位置，中央顯示播放。未把旋轉動畫中的斜向截圖當成布局問題。

最終 App 來源另在模擬器確認內建目錄 session 的同劇恢復：《孝子归来报母恩》第二張卡 86% 離頁後終止重開，仍還原該劇並續播至結尾；未新增該劇正式 history。再從第三張《杀猪娘子娶进门，扶起一屋软骨头》按「追這部」，記錄 `capture_success`、準備期保留、正式 ready／seek 完成後撤圖，畫面正常繼續播放，見 `build/playback-transition-0.10.0-final.log`。完成後退出正式播放器，將模擬器恢復 Closed／首頁，並以無診斷參數重新啟動。

最終 App 來源 `ab405ea8aadc8bddb4df95f77cd03543e9cc231a` 的 [CI](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42385624368) 核心測試通過；遠端仍缺少相容 Duo SDK，App 建置步驟略過。兩平台 Debug 建置與嚴格簽章檢查通過，見 `build/ios-0.10.0-build26-final.log`、`build/ios-real-device-0.10.0-build26-final.log`。當版 110 份來源與成品版號、雜湊保存於 `build/ios-0.10.0-build26-validation.json`。實機以 USB 安裝成功，讀回版號為 0.10.0／26，啟動命令成功且後續程序查詢確認 App 仍在執行。手機上未重做完整手勢驗收；上述操作證據來自 Duo 模擬器。

## 0.9.3 上下集手勢與試看旋轉

新增 8 項相鄰分集邊界測試，正式 `EpisodeSelectionTests` 與 `PlaybackSpeedTests` 共 30 項／2 個 suites 全數通過，記錄為 `build/core-0.9.3-navigation-speed-tests.log`。沒有用單元測試冒充手勢或布局驗收，AppSupport 未改。兩平台 Debug build 25 均建置成功並通過嚴格簽章驗證；記錄為 `build/ios-0.9.3-build25-final.log`、`build/ios-real-device-0.9.3-build25-final.log`。106 份 App 來源雜湊與兩平台版號保存在本機 `build/ios-0.9.3-build25-validation.json`。

最終原碼 `63edf07c6aba47a63cb118f4121de061cb9c72dc` 的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42381599840) 核心測試成功；遠端缺少相容 Duo SDK，App 實際建置步驟略過，兩平台建置以上述本機結果為準。

### 換集操作

在 Duo 展開橫向的詳情入口，以《妈咪受辱，大小姐回国掀翻全场》第一集實際下滑，頂部顯示「已經是第一集了」且未換集；上滑顯示「第 2 集」並開始準備第二集，下滑顯示「第 1 集」返回。從原生選集選第 57 集後，再上滑顯示「已經是最後一集了」，沒有越界載入。邊界提示沒有喚出完整控制列。測試期間正常連播可能推進集數，不能把不同操作間的經過時間當成精確首幀量測。

首頁一般播放原本還傳入舊的上下換劇 callback；正式播放器現在優先使用上下集操作，只有試看維持換劇。未開放鄰集不跳過、單集、稀疏與不合法當前識別由上述核心測試核對。長按後上下滑仍沿既有鎖速手勢，未改閾值；本輪沒有用輔助操作冒充實際長按滑動的驗收。

最終 build 25 再從首頁「接著看」打開同劇第 57 集，影片的輔助選項已是「上一集／下一集」，實際下滑顯示「第 56 集」並準備該集，沒有改換另一部劇。

### 旋轉問題重現與修復

修補前在第二部試看來回旋轉，畫面停在兩張卡片之間：上方是保留的影片與 footer，下方是別部海報，中央按鈕與當前卡的輔助功能入口消失。頁高改變後沒有重新錨定，嚴格頁頂判定因而撤銷播放及互動資格。

修補後以穩定作品識別限次重錨。中間版本另量到原生側欄造成外層 viewport 863×669 pt、卡片 867×669 pt；雖然頁頂已為 0，寬度全等檢查仍使資格無法恢復。最終恢復條件只使用垂直分頁所需的頁頂與新頁高，保留 ±2 pt 判定；Card 過渡判定也使用同樣維度。量測為本機 `build/preview-0.9.3-resize-dimensions.log`。取消 resize 會撤銷其設定的暫時非 idle 狀態，舊 task 以 generation 及取消檢查拒絕晚回覆；不清片單、媒體識別或手動暫停意圖。

最終 build 25 在第二部《不婚女孩儿不是软柿子》重跑展開橫向 → 直向 → 橫向：同一部始終完整佔一頁，直向進度到約 42%、回橫向到約 64%，當前影片與中央控制的輔助入口也正常恢復。手動暫停在約 94% 後再來回旋轉，仍顯示「播放」且進度維持不動。最終幾何記錄 `build/preview-0.9.3-resize-final.log` 可見 669 pt 頁高、offset 669、頁頂 0、idle 1、pending 0、aligned 1；這是對齊／互動回歸，不是精確的旋轉耗時、全角度或真機手勢驗收。

測後關閉正式播放器，重新以無診斷旗標啟動並收合至首頁，內建來源保留，未啟動合成服務。本輪未重做真人帳號同步、聲音、VoiceOver 全流程、長播或耗電測試。

### 手機狀態

首次安裝遇到開發通道離線，CoreDevice 無法取得可信的遠端服務連線，沒有將它誤報為手機鎖定或要求重設開發者模式。使用者接回 USB 後，最終原碼的 build 25 已安裝成功，App 清單讀回 0.9.3／25；啟動成功，程序清單確認同一個 Hongguo 程序仍在執行。106 份 App 原碼雜湊與建置清單一致。這是安裝、版號與啟動證據；上述手勢與旋轉互動在模擬器核對。

本機記錄為 `build/ios-real-device-0.9.3-build25-details.json`、`…-install.json`、`…-install-retry.json`、`…-app.json`、`…-launch.json`、`…-processes.json`；裝置、簽署識別及原始部署資料不納入 Git。

## 0.9.2 獨立倍速提示

本次僅調整 App View 與私有手勢的顯示／結束回呼，未改 Core 或 AppSupport。`PlaybackSpeedTests` 15 項全部通過，記錄為 `build/core-0.9.2-speed-tests.log`；最近完整回歸仍為下列 0.9.1 的 452 項，不將舊結果冒充本版重跑。兩平台 Debug build 24 均建置成功並通過嚴格簽章驗證，記錄為 `build/ios-0.9.2-build24-final.log` 與 `build/ios-real-device-0.9.2-build24-final.log`；106 份來源與兩平台版號見本機 `build/ios-0.9.2-build24-validation.json`，對應原碼 `0b7e9ce`。

在 Duo 外螢幕橫向、內建影片的當版模擬器：

- 試看控制列隱藏時執行長按，放開後完整 HUD 沒有出現；播完的中央重播按鈕仍可顯示。工具觀察在放開後完成，未擷取按住瞬間的臨時提示；提示位於獨立 overlay 的接法由原碼及兩平台建置核對。
- 一般播放器以影片的輔助鎖速操作鎖定 2 倍速，畫面只出現頂部鎖速膠囊，沒有側邊工具列、資訊框或中央暫停鈕；點該提示解除後，畫面繼續播放且控制列仍隱藏。一般長按放開後亦維持隱藏。
- 明確喚回控制列後可以關閉播放，測後回到首頁。手動選單的速度行為及長按上下滑閾值未改；沒有將輔助鎖速操作當作實際長按上下滑手勢驗收。

同一份 build 24 已安裝到 iPhone，讀回 0.9.2／24，啟動成功且程序查詢確認同一個 Hongguo 程序仍在執行。本機記錄為 `build/ios-real-device-0.9.2-build24-install.json`、`…-app.json`、`…-launch.json`、`…-processes.json`。手機結果限安裝、版號與啟動；上述互動在模擬器核對，未重做所有姿態、真人帳號或長播／耗電測試。

## 0.9.1 換劇準備交接

完整回歸登錄 452 項：Core 363 項／43 個 suites（362 通過、1 項可選官網快照略過），AppSupport 89 項／6 個 suites 全數通過，記錄為 `build/core-0.9.1-validated-tests.log`。完整回歸後僅強化測試 fixture 的 producer 啟動 barrier，取源 14 項重新通過，正式原碼不變。Duo 模擬器與 iPhoneOS／arm64 Debug build 23 均建置成功且通過嚴格簽章驗證；記錄為 `build/ios-0.9.1-build23-final.log`、`build/ios-real-device-0.9.1-build23-final.log`。106 份 App 來源雜湊及兩平台 0.9.1／23 版號保存在本機 `build/ios-0.9.1-build23-validation.json`，公開工程團隊保持空白。

原碼 `067ffbc0b12f675cb3ae62660ffdd98b8f11702f` 的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42373979506) 核心測試成功。遠端缺少相容 Duo SDK，實際 App 建置步驟略過；兩平台建置證據來自本機。

### 同條件等待對照

使用舊版與新版正式 model／resolver 原碼，各做三次控制對照。這些時間是 metadata 或 source ready，沒有把它們當成首幀或手機網路時間。

| 情境 | 舊版 | 0.9.1 |
| --- | --- | --- |
| 詳情固定 600 ms；預取先跑 100 ms，再滑動 200 ms | B 詳情啟動 2 次、取消 1 次；停穩後 603.3–607.8 ms 準備好 | 啟動 1 次、無取消；停穩後 278.4–287.7 ms 準備好 |
| 取源固定 600 ms；前景在預取後約 300 ms 加入，50 ms 後撤預取讀者 | 底層啟動 2 次、取消 1 次；前景等待 635.7–639.9 ms | 底層啟動 1 次、無取消；前景等待 297.4–311.3 ms |

已完成預取的詳情對照為舊版 0.1 ms、新版 0.2 ms，沒有實質退化。只共用詳情及取源工作；progressive 索引／首段準備仍可能各自請求，不能由此推算下載量減半。

另以兩部相同作品的同一首集，核對舊／新版均取到同樣的 HEVC 1080p 版本及檔案大小，使用 Mac `AVAssetReader` 解出首幀，四次均成功。樣本一舊版 4.961 秒、新版 3.204 秒；樣本二反轉執行順序後，新版 2.661 秒、舊版 1.919 秒。方向不一致，DNS／TLS／CDN 與匿名身分準備未受控，不能宣稱普遍實網加速比例。這是來源及解碼驗證，不是 AVPlayerLayer 顯示首幀、iPhone 或耗電量測。

來源雜湊、編譯物 provenance、對照 JSON 與重現方式均存本機 `build/preview-switch-0.9.1/`；摘要為 `summary.json`。未使用含歷史版本的 App 診斷中位數當作比較基準。

### 模擬器操作

在正式 build 23 的 Duo 外螢幕橫向，使用內建目錄與真實影片：

- 從第一部實際上滑快速跳過多張卡，最後停在《人到中年：我的双眼可以看穿一切》，看到動態影片及第一集進度；其後按相鄰換頁進入《别欺负小福宝，她能洞悉万物》。快速拖曳可能跨多頁，沒有當作「一個拖曳恰好一頁」驗收。
- 連續換至《我成全嫡孙抗旨退婚，他却慌了》《先扯证，再谈心动》《温柔以待，终有回甘》，最後一部正常播放、進度到 25%，未看到舊作品覆蓋當前卡。
- 滑回《先扯证，再谈心动》後能播放，暫停在約 6%。切至 2 倍速再恢復 1 倍速，仍維持暫停及相同進度；按中央播放按鈕後進度繼續到 7%。未以短距離捲動沒有變化的結果，宣稱已驗收所有取消拖曳手勢。

測後已恢復 1 倍速並回到首頁，來源保持內建，沒有啟動合成服務。當前 owner、取消、快取重入及最後停穩的競態另由正式 model 測試核對。本輪未重做所有 Duo 姿態、VoiceOver、長播、聲音或真人帳號同步，也未量測 GUI 精確首幀。

### 手機部署

同一份 build 23 已覆蓋安裝，App 清單讀回 0.9.1／23。初次啟動由 iOS 明確以 Locked 拒絕；2026-11-07 使用者解鎖後重新啟動成功，程序清單確認同一個 Hongguo 程序仍在執行，App 清單再次讀回 0.9.1／23。這是安裝、版號、啟動與程序驗證，不當作真機換劇手勢或首幀速度驗收。

本機記錄為 `build/ios-real-device-0.9.1-build23-install.json`、`…-app.json`、`…-launch.json`；解鎖後為 `…-launch-unlocked.json`、`…-processes-unlocked.json` 與 `…-app-unlocked.json`。裝置及簽署識別只保留本機。

## 0.9.0 候選擴源與原地重試

完整回歸登錄 432 項：Core 351 項／43 個 suites（350 通過、1 項可選官網快照略過），AppSupport 81 項／6 個 suites 全數通過，記錄為 `build/core-0.9.0-validated-tests.log`。Duo 模擬器及 iPhoneOS／arm64 Debug build 22 均建置成功，嚴格簽章驗證通過；記錄為 `build/ios-0.9.0-build22-final.log`、`build/ios-real-device-0.9.0-build22-final.log`。106 份 App 來源雜湊及兩平台版號存於本機 `build/ios-0.9.0-build22-validation.json`，公開工程團隊保持空白。

原碼 `a8de819726521845a033f9217d5402b72c6ed921` 的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42370054003) 核心測試成功。遠端缺少相容 Duo SDK，App 建置步驟略過；兩平台實際建置證據以上述本機結果為準。

### 公開 metadata 探針

新增 `CatalogDiscoveryCheck preview <category> [pages]`，只讀 metadata，不取影片。2026-11-07 實測真人與 AI：第一頁各 24 部原目錄，第二／三頁各 24 部原目錄及 6 部近 7 天新劇。漫劇前三頁各 24 部原目錄；實作不呼叫不支援的漫劇新劇來源，也不保證每次都有不重複補充作品。獨立真人榜單回傳 20 筆、新劇 88 筆；這些是當時來源快照，不是推薦命中率或速度比較。

結果存於 `build/discovery-0.9.0-preview-real.json`、`…-preview-ai.json`、`…-preview-comic.json` 及 `…-rank-real.json`、`…-new-real.json`。探針會在第一頁後刻意等待背景準備窗口；正式 App 的第一頁不做這個等待。

### 模擬器操作

- 在外螢幕橫向，以 loopback 合成服務讓 QA 2 首次試看詳情成功，中央按鈕暫停在約 54%（24 秒片，約 13 秒）。下一次詳情刻意回傳 503；按「追這部」顯示原地「重試／關閉」，按重試後正式播放器從第 1 集約 13 秒接續，隨後可用中央按鈕暫停。合成服務核對同劇 `200 → 503 → 200`，見 `build/qa-0.9.0-fixture/ui-retry-state.json`。
- 再次讓同劇失敗後換到 QA 3，舊錯誤及重試入口消失。帳號／來源／背景變動、進度選擇期間紀錄更新、非暫時錯誤及取消舊 caller 的競態另由正式 model 測試核對。
- 恢復內建來源後，實際滑動及輔助換頁進入後續候選；看到《墨痕》的「真人近 7 天上新」文字、中央播放控制與動態影片。來源標示與片名、第一集提示分開，影片維持原畫布，不額外留下控制黑帶。這次沒有重做所有姿態、VoiceOver 或大型字級的布局驗收。

模擬器已恢復內建播放與首頁，合成服務停止。合成片無音軌，不代表聲音驗收；本輪沒有宣稱首幀、資料用量、推薦準確度或耗電改善，也未重新驗證真人帳號同步。

### 手機部署

build 22 已覆蓋安裝，App 清單讀回 0.9.0／22。首次查詢遇到短暫開發連線斷線，重新確認通道後讀回成功；初次啟動由 iOS 以 Locked 拒絕。2026-11-07 使用者解鎖後重新啟動成功，程序查詢確認同一個 Hongguo 程序持續執行，App 清單再次讀回 0.9.0／22。106 份 App 原碼雜湊均與兩平台建置驗證清單相符。這是版本、啟動與程序證據；推薦來源標示及原地重試的互動驗證仍以上述模擬器記錄為準，未追加真人帳號操作或真機長播測試。

本機記錄為 `build/ios-real-device-0.9.0-build22-install.json`、`…-app.json`、`…-details.json`、`…-app-recheck.json` 及 `…-launch.json`；解鎖後為 `…-launch-unlocked.json`、`…-processes-unlocked.json` 與 `…-app-unlocked.json`。裝置及簽署識別只保留本機。

## 0.8.2 推薦與播放細節

完整回歸登錄 408 項：Core 339 項／42 個 suites（338 通過、1 項可選官網快照略過），AppSupport 69 項／6 個 suites 全數通過，見 `build/core-0.8.2-validated-tests.log`。相同來源原始集、完成狀態與解析目標下的兩秒容差、有效觀看時間與排除的非同步競態均由正式 policy／model 測試核對。模擬器與 iPhoneOS／arm64 Debug build 21 建置成功，兩者嚴格簽章驗證通過；記錄為 `build/ios-0.8.2-build21-final.log`、`build/ios-real-device-0.8.2-build21-final.log`，105 份 App 來源雜湊與產品版號見本機 `build/ios-0.8.2-build21-validation.json`。公開工程團隊維持空白，未另外產生 Release IPA。

原碼 `bd3dfe16da7ffb3de0560d4059d4a95ccaa830be` 的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42367983817) 核心測試成功。遠端 runner 沒有可編譯 Duo API 的 SDK，模擬器建置步驟略過；實際兩平台建置結果來自上述本機記錄。

### 本輪模擬器操作

在 Duo 外螢幕橫向，以僅監聽 loopback 的合成服務測試兩頁共八部作品，各集為 24 秒無音軌測試片。它不使用官方內容或帳號，測試服務及素材只存於 ignored `build/qa-0.8.2-fixture/`。

- 對 QA 1 按「不感興趣」後，畫面直接換到 QA 2，接著可換至 QA 3／QA 4／QA 5；合成服務計數顯示沒有因單筆排除重新請求第一頁，第二頁仍正常讀入。當前卡、最後一張、空列及遲到回覆等邊界另由 queue／model 測試覆蓋。服務計數為 `state-after-exclusion.json`。
- QA 4 在約 9% 按中央按鈕暫停，按鈕變「播放」，本機試看標記仍為 11 筆且不含 QA 4；繼續播放後才達到累計門檻。先前較長的 QA 1／2／3 已從原先 8 筆增加為 11 筆。精確的 10 秒、短片及倍速邊界由注入單調時鐘的測試核對，不以 GUI 工具耗時當精確計時器。
- 新卡 QA 5 在只允許最初 256 bytes 的載入狀態下，實際點空白處收起 HUD，畫面仍保留獨立「正在準備試看」提示；解除資料限制後進度到 21%，等待提示消失，HUD 沒有自行出現。一般閒置隱藏與片尾中央播放按鈕亦已看到。這次穩定核對的是初始載入恢復；小型素材可被播放器預先緩存，中途網路緩衝尚未形成可重複對照，不當作全網路情境驗收。
- QA 5 試看播完後按「追這部」，正式播放器開啟第 2 集，中央按鈕可在約 12 秒暫停；關閉後返回同張試看卡並顯示手動「繼續試看」。兩秒容差的不同集／完成邊界由正式 launcher 測試驗證。

完成後已透過 App 設定恢復內建播放與內建目錄，回到首頁並停止合成服務。合成影片無音軌，不驗收聲音；本輪沒有重做官方片源速度、長時間耗電、真人帳號同步或所有 Duo 姿態的實機對照。

### 本輪手機部署

同一份 build 21 已覆蓋安裝，讀回 0.8.2／21。首次啟動由 iOS 明確以 Locked 拒絕；使用者解鎖後重新啟動成功，程序清單確認同一個 Hongguo 程序仍在執行。105 份 App 來源與已建置清單相符。這是安裝、版號、啟動與程序驗證；本輪互動測試在模擬器進行，沒有把啟動成功當作真機四項操作驗收。

本機證據為 `build/ios-real-device-0.8.2-build21-install.json`、`…-app.json`、`…-launch.json`、`…-launch-unlocked.json` 與 `…-processes-unlocked.json`。裝置與簽署識別只保留本機。

## 0.8.1 試看底部安全區

使用者回報外螢幕推薦下方有黑邊。本輪以外螢幕直向重現：影片已使用填滿模式，Card 的 region 與 bounds 都是 382×644 pt，並非影片比例或 Duo 避讓另外縮短畫布；畫布外另留有 34 pt 底部安全區。修正後 pager 與每張卡片同為 382×678 pt，region 仍與 bounds 相同，HUD 的獨立安全底距為 34 pt，原生側邊保留區仍是 84 pt。修正前量測為 `build/preview-edge-canvas-before.stderr.log`，修補階段為 `build/preview-edge-after.stderr.log`，正式 build 20 為 `build/preview-edge-final.stderr.log`。

最終 Core／AppSupport 完整回歸仍登錄 376 項：Core 317 項／40 個 suites（316 通過、1 項可選 `currentWebsiteSnapshot` 略過），AppSupport 59 項／5 個 suites 全數通過；`build/core-0.8.1-validated-tests.log`。這次沒有新增鏡像布局測試。Duo 模擬器與 iPhoneOS／arm64 Debug build 20 均建置成功，且嚴格簽章檢查通過；記錄為 `build/ios-0.8.1-build20-final.log`、`build/ios-real-device-0.8.1-build20-final.log`。102 個 App 原碼雜湊與兩平台版號保存在 `build/ios-0.8.1-build20-validation.json`；公開工程團隊保持空白，未另外產生 Release IPA。

程式提交 `224b171` 的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42363353796) 核心測試同樣通過，登錄 376 項／45 個 suites，含同一項可選快照略過。遠端 runner 的 App 建置因缺少 Duo SDK 明確略過，兩平台實際建置以上述本機結果為準。

當次模擬器觀察：

- 外螢幕直向的實際影片已延伸至底部，原固定黑帶消失，原生側欄仍保留。試看底圖改為等比填滿，選劇網格海報沿用完整比例。
- 延伸後仍以同一 GeometryReader 決定每頁高度與座標，保留頁面裁切和穩定 ID。修補階段一次拖曳停穩時為 offset 2712、當頁 minY 0、idle 1、aligned 4，接著出現首集準備；沒有用 offset／舊頁高猜目前卡片。
- 正式 build 20 看到動態影片及底部滿版畫面，中央按鈕可暫停於約 49%；點片名進詳情再返回，同卡與位置仍保留，等待手動繼續。外螢幕旋轉後診斷為 594×466 pt，頁面仍對齊；展開直向時，海報延伸至原生底部分頁列後方，資訊與「追這部」按鈕保留在分頁列上方。
- 準備／取消及錯誤浮層亦獨立套用安全底距，沒有替整個 pager 增加 padding。該保護由程式核對及兩平台建置驗證，本輪未另外注入每一種錯誤畫面。

測後已收合並正常重新啟動至首頁，未保留診斷啟動旗標；沒有新增真人帳號操作、收藏變更或正式觀看紀錄。本輪不是實機手勢、長播／耗電、所有折疊角度或精準單次滑動距離的驗收。手機部署結果如下。

同一批 build 20 已經既有無線通道覆蓋安裝，App 清單讀回 0.8.1／20，沒有刪除 App 或重新登入。首次啟動遇到 RSD 連線配置失敗；重新確認通道已連線後，iOS 曾因手機鎖定拒絕啟動。2026-11-07 使用者解鎖後重新啟動成功，程序查詢確認同一個 Hongguo 程序仍在執行，版號再次讀回 0.8.1／20，102 個 App 原碼雜湊仍與建置驗證清單相符。這是安裝、版本與啟動證據，本次未重新驗收真機黑帶、觸控手勢、帳號同步或耗電。初次證據為本機 `build/ios-real-device-0.8.1-build20-install.json`、`build/ios-real-device-0.8.1-build20-app.json`、`build/ios-real-device-0.8.1-build20-launch.json`、`build/ios-real-device-0.8.1-build20-details.json`、`build/ios-real-device-0.8.1-build20-launch-recheck.json`；解鎖後為 `build/ios-real-device-0.8.1-build20-launch-unlocked.json`、`build/ios-real-device-0.8.1-build20-processes-unlocked.json`、`build/ios-real-device-0.8.1-build20-app-unlocked.json`。裝置與簽署識別只保留本機。

## 0.8.0 推薦、試看接續與中央控制

最終完整回歸登錄 376 項：Core 317 項／40 個 suites，316 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 59 項／5 個 suites 全數通過。記錄為 `build/core-0.8.0-validated-tests.log`。新增推薦排序 16 項、試看位置政策 6 項、正式 launcher 7 項，以及 queue 1 項／CatalogModel 2 項。沒有發送簡訊、登入或寫入真人帳號片庫。

程式提交 `cd7410f` 的 [GitHub Actions](https://github.com/Mountain-P/Hongguo-iPhone-Duo/actions/runs/42361002887) 核心測試亦通過：單一 runner 登錄 376 項／45 個 suites，其中同一項可選快照略過。遠端 runner 缺少包含 Duo API 的 SDK，因此 iPhone 模擬器建置明確略過；本機兩平台的實際建置及畫面結果另列如下，沒有將遠端 SDK 檢查成功當作 App 建置成功。

本機推薦只對來源已提供的新批候選排序：收藏較強、足夠保存位置較弱，使用真實題材、保留來源探索與題材交錯，按目前片庫及來源隔離。保存位置可能包含拖曳，不當成實際觀看時長或喜歡的證明；沒有使用官方帳號個人化推薦 API，亦未量測推薦命中率。首次啟動曾發現排序在非同步片庫還原前捕捉空快照，已改成新頁回覆到達後再讀當下快照；實際延遲回覆回歸涵蓋此情境。既有卡片不因進度或收藏變動重新移位，取消收藏後原理由會隱藏。

Duo 模擬器 Debug 最終建置成功，記錄為 `build/ios-0.8.0-build19-initial-profile.log`；iPhoneOS／arm64 Debug 最終成功記錄為 `build/ios-real-device-0.8.0-build19-final.log`。兩種產物均通過嚴格簽章核對，版號為 0.8.0／19，公開工程的團隊仍為空白，沒有另外產生 Release IPA。102 個 App 原碼檔與兩種產物版號清單保存於本機 `build/ios-0.8.0-build19-validation.json`。

當次 Duo 模擬器觀察：

- 目前為訪客本機片庫，測試收藏一部愛情劇後重新啟動，首頁與試看出現「因你收藏《…》」及真實共同題材，候選順序改變；測後取消該收藏，首頁理由消失且原有卡片順序保持。這是排序及理由接線證據，不代表推薦效果已優於來源。
- 真人首集試看暫停於約 96%；實際點影片空白處可收起／喚回玻璃控制，中央仍為播放，沒有自行恢復。按「追這部」後，在準備期間 AX 只保留取消入口，背景收藏／詳情不可操作；正式播放器的首集準備位置為 1:45，沒有先進詳情頁，後續自然進入第 2 集。
- 正式第 2 集以中央按鈕暫停在 0:20。點空白處兩次，資訊收起／出現後仍是 0:20；中央播放後點空白處，控制隱藏且影片繼續，喚回時為 0:32，中央再暫停於 0:33。原生控制列沒有右上重複播放鍵。
- 返回仍是原試看卡片與約 96% 位置，等待手動繼續。再次按「追這部」，明確顯示「接續原進度：第 2 集 0:33」與「從試看位置看：第 1 集 1:45」。選擇原進度後，正式準備位置為第 2 集 0:33；後續暫停於 0:42。選項取消、選擇期間紀錄改變／刪除、選擇試看位置等其他分支另由正式 model 測試驗證。
- 展開直向仍顯示影片畫面、中央播放鈕與原生上下工具列，保持第 2 集 0:42 暫停；返回試看仍保留原卡片。一次實際上滑可換到其他作品，收合後仍顯示該片單；沒有把這一次拖曳宣稱為全部折疊姿態或逐頁停靠手感驗收。

測後還原收合畫面與首頁，臨時收藏已取消，原第 8 集紀錄仍在。新增正式測試觀看紀錄只留在模擬器訪客片庫。這些是短程模擬器及實網取源觀察，尚未驗證本版真機觸控手感、真人帳號同步、實機長播／耗電或行動網路切換。

同一批 build 19 已透過既有無線通道覆蓋安裝至手機，App 清單讀回 0.8.0／19。首次遠端啟動遇到 XPC 連線失效，重新確認通道後啟動成功，程序查詢確認同一個 Hongguo 程序仍在執行；沒有刪除 App 或重新登入。證據為本機 `build/ios-real-device-0.8.0-build19-install.json`、`build/ios-real-device-0.8.0-build19-app.json`、`build/ios-real-device-0.8.0-build19-launch.json`、`build/ios-real-device-0.8.0-build19-launch-recheck.json`、`build/ios-real-device-0.8.0-build19-processes.json`。這是安裝、版本及啟動證據，本輪未在真人手機重做播放、帳號同步或耗電驗收；裝置、帳號與簽署識別不放入公開倉庫。

## 0.7.0 畫質、海報與一鍵續播

最終完整回歸登錄 344 項：Core 294 項／38 個 suites，293 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 50 項／5 個 suites，全部通過。記錄為 `build/core-0.7.0-validated-tests.log`。CI 曾發現海報測試在 transport 真正進入前就讀取計數；測試改用已安裝 pending continuation 的同步屏障，保留精確共用請求／最大並行斷言，沒有修改正式 App 管線。補修後完整本機回歸記錄為 `build/core-0.7.0-poster-barrier-combined-tests.log`。新增畫質 7 項、progressive 品質隔離 1 項、正式海報管線 14 項及正式續播 launcher 9 項。測試範圍與命令見 [TESTING-CORE.md](TESTING-CORE.md)；沒有發簡訊或寫入真人官方片庫。

### 來源畫質與解碼

相同真人劇第 4 集的兩次唯讀 macOS 取源／AVAssetReader startup 均成功。自動模式實際選到 HEVC 1080×1920／1080p，來源檔長 7,506,580 bytes，準備 3.18 秒、首個解碼影格 5.72 秒；省流量選到 HEVC 360×640／360p，來源檔長 2,436,342 bytes，準備 2.44 秒、首個解碼影格 2.71 秒，兩次均未 fallback。安全摘要為 `build/quality-0.7.0/validation.txt`。檔長不是此次已下載 bytes；單次分開量測不能推算一般網速、流量節省百分比或 iPhone 啟播／耗電。畫質依來源實際模型選取，未發明固定 720p／480p 選項，亦非播放中 ABR。

### 海報記憶體與網路

正式 ImageIO 大圖測試的 4096×6144 合成圖，原解碼量 100,663,296 bytes，512px 長邊縮圖為 704,512 bytes；獨立基準兩次請求相較於管線並行消費者共用一次請求。這是實際縮圖位元組與計數，不是原 AsyncImage 或手機程序記憶體比較。

Mac 公開八張海報／三工作批次全部載入，下載 1,218,644 bytes、冷載 16.613 秒／8 請求，解碼快取共 5,947,392 bytes；同批暖快取 8／8 成功，0.00187 秒且零額外下載。記錄為 `build/poster-image-batch-live.json`。另以固定八個 URL、三並行與相同 512px ImageIO 目標交替測試 session 取捨：單一 session 第一輪 25 秒截止、已完成 7／8（26.501 秒含取消收尾），第二輪 9.896 秒；正式每下載獨立 session 為 8.041 與 12.136 秒，均 8／8。網路波動及 DNS／TLS／CDN 暖度未控制，共享實驗也與正式串流上限 delegate 不同，不能判定首次載入優劣。詳見 `build/poster-image-session-compare/summary.json`；原始 `success=0` 是逾時 sentinel，不是零張載入。

正式管線保留每下載獨立的 ephemeral session，無 cookie、憑據或磁碟圖片快取；最多三個工作、解碼 LRU 32 MiB／80 項，每下載 12 MiB、來源 32M pixels、縮圖長邊 2048px 上限。這些是各資源預算，不能把 32 MiB 當成 App 全部記憶體上限。相同 URL 調整尺寸時先保留現圖，像素足夠就沿用，較大縮圖成功後才替換；不同 URL 不顯舊圖，離屏釋放 view 圖片。

### Duo 畫面與播放整合

Duo 模擬器與 iPhoneOS／arm64 Debug 均建置成功並通過嚴格簽章檢查。主要記錄為 `build/ios-0.7.0-build18-final.log`、`build/ios-real-device-0.7.0-build18-final.log`；最後海報尺寸銜接與續播圖示輔助標籤的產物為 `build/ios-0.7.0-build18-resize-final.log`、`build/ios-real-device-0.7.0-build18-resize-final.log`。測試期間已安裝並啟動當版模擬器，最終產物再覆蓋啟動確認；公開工程團隊仍空白，本輪未另產生 Release IPA。

當次畫面觀察：

- 首頁在原主網格上方顯示緊湊「接著看」卡與原有第 8 集紀錄，海報完整顯示，未點播放前維持瀏覽。按獨立 CTA 後直接進第 8 集播放器，看到實際影片；點畫面暫停在 0:37，返回後首頁與片庫更新為約 32%。
- 從片庫歷史的獨立 CTA 再次進同一第 8 集，後續暫停於 1:13，進度保存為約 64%；未先經詳情頁。進入歷史編輯模式時 CTA 消失，仍為選取／全選／移除，退出後恢復續播，沒有刪除紀錄。
- 設定「省流量」後終止並重啟 App，回設定仍顯示省流量，期間兩個續播入口均可正常播放。測後還原「自動（最佳可用）」。UI 不自行聲稱當集解析度，前述 1080p／360p 為另一次同集 macOS 管線量測。
- 最終版在收合橫向與展開直向均能顯示續播卡、原生分頁與完整比例海報，展開後主網格依寬度增加欄數；收合後回到首頁。續播小海報的詳情入口有完整輔助標籤。

以上不代替真人帳號續播／跨帳號實測、實體收合手勢、行動網路切換、真耳機／來電或真機長播／耗電驗收。續播的取消、晚回覆與 scope 保護以正式 model 測試核對；實機部署結果另記於下方。

同一批 0.7.0／build 18 真機產物已經既有 `localNetwork` 通道覆蓋安裝，沒有刪除 App 或重新登入。首次啟動回報無線遠端連線失效，緊接的 App 查詢雖成功但清單為空，因此當時未判定部署驗收完成；重新確認通道後，App 清單讀回 0.7.0／build 18，另一次啟動成功，程序查詢亦確認同一個 Hongguo 程序仍在執行。記錄為 `build/ios-real-device-0.7.0-build18-install.json`、`build/ios-real-device-0.7.0-build18-launch.json`、`build/ios-real-device-0.7.0-build18-app-recheck.json`、`build/ios-real-device-0.7.0-build18-launch-recheck.json`、`build/ios-real-device-0.7.0-build18-processes.json`。100 個 App 原碼檔雜湊及兩種平台產物版號核對保存於 `build/ios-0.7.0-build18-validation.json`；簽署／裝置識別只保留本機。這是安裝、版本及程序啟動證據，本輪未在真人手機重做播放、帳號同步或耗電驗收。

## 0.6.1 播放與資料恢復

最終完整回歸登錄 313 項：Core 286 項／37 個 suites，285 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 27 項／3 個 suites，全部通過。記錄為 `build/core-0.6.1-tests.log`。新測試直接執行正式目錄／片庫 model 與 Controller，涵蓋重複或空頁後繼續、錯頁拒絕、取消隔離、完整相同結果快取，以及首批永久失敗後人工重試可到後續項目；未操作真人帳號或官方片庫。

正式 `PlayerModel.swift` 在 macOS 以真正 AVPlayer 與本機四秒合成 MP4 執行七組驗證，全部通過：音訊中斷暫停／保存／撤加速、中斷結束不自啟且一次按播放恢復、一般路由變化不誤停而舊裝置移除會暫停、先暫停再收到 EOF 不換集或取源、舊 item／排隊 EOF 世代隔離、真正 AVPlayer 自然播畢仍換下一集、背景 EOF 不換集／回前景不自啟，以及 stop／start 後舊音訊 callback 不污染新週期。相關分支合併為七組結果，見 `build/player-interruption-check/results.txt`。此 harness 的 AVAudioSession 與 UIKit 診斷 singleton 使用測試 shim，正式 Model、NotificationCenter 與 AVPlayer 實際執行；不能當成 iOS 系統中斷接線、真耳機拔除或真人來電驗收。兩平台正式建置另外核對 iOS API。

Duo 模擬器與 iPhoneOS／arm64 Debug 均建置成功並通過嚴格簽章檢查。主要記錄為 `build/ios-0.6.1-build17-final.log`、`build/ios-real-device-0.6.1-build17-final.log`；最後的詳情收藏作用域防護另以 `build/ios-0.6.1-build17-source-guard.log`、`build/ios-real-device-0.6.1-build17-source-guard.log` 核對。公開工程團隊保持空白，個人簽署只經命令列指定；本輪未另產生 Release IPA。

當次最終模擬器觀察：

- 先從本機 fixture 成功讀到三集詳情，再停止該服務並按「更新劇集」，畫面明確顯示「更新未完成，顯示上次資料」及連線錯誤，原有三集資訊、選集與播放入口仍保留。恢復服務後再更新，錯誤提示消失。
- 同一段四秒合成片正常從第 1 集自動銜接至第 3 集並於片尾停下；片尾重播回到零秒。接著點影片暫停，等待後進度與第 3 集保持不變，原生與中央按鈕均提供播放動作。晚到 EOF 的競態另由上述正式 Model 注入驗證。
- 測後切回內建播放與原有本機片庫，原有第 8 集觀看紀錄仍在；來源切換即撤去舊詳情的選集與播放入口。收藏追加的 UI 與動作入口成功快照檢查，另經程式審查及兩平台建置核對，未對真人片庫試寫。最後覆蓋安裝的模擬器亦重新載入正常內建首頁。

以上不是實網長時間播放或真機耗電量測；0.6.0 的 297 集合成長播保留為該版歷史證據，沒有冒稱本版重新完成同樣長測。真耳機／來電及真人帳號重試仍待對應實機驗收。

0.6.1／build 17 已經既有 `localNetwork` 通道覆蓋安裝至手機，App 清單讀回相同版號；最後的收藏作用域防護也已再次安裝並讀回。前兩次啟動因 iOS 鎖定狀態拒絕；2026-11-07 使用者解鎖後重新啟動成功，程序查詢確認同一個 Hongguo 程序仍在執行，版本再次讀回為 0.6.1／build 17，96 個 App 原碼雜湊與原驗證清單相符。這是部署、版本及啟動證據，未重新驗收本版真機手勢、播放、耳機／來電或帳號同步。初次記錄為 `build/ios-real-device-0.6.1-build17-install.json`、`build/ios-real-device-0.6.1-build17-app.json`、`build/ios-real-device-0.6.1-build17-launch-locked.json`；最終覆蓋與讀回為 `build/ios-real-device-0.6.1-build17-source-guard-install.json`、`build/ios-real-device-0.6.1-build17-source-guard-app.json`、`build/ios-real-device-0.6.1-build17-source-guard-launch.json`。解鎖後的成功證據為 `build/ios-real-device-0.6.1-build17-launch-unlocked.json`、`build/ios-real-device-0.6.1-build17-app-unlocked.json`、`build/ios-real-device-0.6.1-build17-processes-unlocked.json`；原碼與產物核對保存於 `build/ios-0.6.1-build17-validation.json`。裝置、簽署識別及私人產物只保留本機。

## 0.6.0 播放、搜尋與片庫整理

最終完整測試合計登錄 291 項：Core 279 項／35 個 suites，278 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 12 項／1 個 suite，全部通過。記錄為 `build/core-0.6.0-validated-tests.log`。測試涵蓋片尾重播判斷、偏好保存、預取資格與取消、繁簡補查、來源題材篩選、片庫排序與批次操作，以及首幀／恢復等待的量測政策；詳細範圍見 [TESTING-CORE.md](TESTING-CORE.md)。

本機 Duo 模擬器 Debug 建置成功，採 Xcode ad hoc 簽署並通過嚴格簽章檢查；已安裝並啟動 0.6.0／build 16。初次建置記錄為 `build/ios-0.6.0-build16-validated.log`，片庫背景搜尋補修後最終記錄為 `build/ios-0.6.0-build16-library-background-final.log`，已重新安裝與啟動。當次畫面觀察：

- 搜尋「總裁」載入 10 部；以來源題材「剧情（1）」篩成 1／10 部，仍保留載入更多入口。原始查詢當次已有結果；繁簡空結果補查的觸發與分頁沿用另外由政策測試驗證。
- 搜尋歷史能單筆移除。片庫中以繁體「榮耀」找到簡體片名，並能切換名稱排序。
- 片庫多選會顯示已選數量；移除確認清楚列出本機 1 筆及不刪官方紀錄的範圍。當次取消確認，保留原有觀看紀錄；帳號批次寫入沒有在真人片庫執行。

1,500 筆繁簡混合的合成片庫 CPU microbenchmark 發現，中文多詞搜尋加收藏名稱排序在 Mac Release 的七次暖跑約 185–198ms，歷史同條件約 186–487ms；空查詢的歷史時間排序約 0.36–0.70ms。這是與長播並行的開發機量測，尖峰受負載影響，不能推算 iPhone UI 耗時。為避免這段同步工作佔住畫面，片庫搜尋／排序已移到串行背景 worker，並加入 180ms 輸入防抖、完整 context／世代檢查，以及處理中批次操作限制。原始 microbenchmark 保存在本機 `build/library-browser-benchmark/`。

補修後以正式 `LibraryBrowserModel.swift` 與 Release Core 編譯一次性併行檢查：收藏／歷史各 1,500 筆，舊搜尋執行中改查詢只發佈最新的 750 筆匹配；換帳號與同帳號換來源立即清空舊列表；取消後沒有晚到回填，之後新搜尋可正常完成。五種情境均通過。MainActor 的 5ms heartbeat 取得 598 筆，間隔中位 5.97ms、最大 9.20ms，搜尋 CPU 窗口仍有 heartbeat。這是開發機併行證據，沒有宣稱真機改善幅度；結果為 `build/library-browser-benchmark/concurrency-results.txt`。最終模擬器畫面亦確認匹配、無結果及清除查詢後的 1／1、0／1、1／1 狀態，原有片庫仍在。

本機四秒合成影片連播從既有續播第 4 集至第 300 集，本輪新播 297 集全部完成，零失敗、零取消、零自動重試；末集正常停在 0:04。觀察器從已完成第 34 集時開始連續採樣 1,121.85 秒（約 18.7 分鐘），113 筆讀取均成功；累積取得 297 次已結束測量，首幀中位約 0.142 秒、播放中等待合計約 3.00 秒。Mac 模擬器程序 RSS 為 146.23–178.25 MB，末筆 147.25 MB，這段樣本未見持續上升；不能據此證明所有情境沒有記憶體洩漏。結果為 `build/soak-0.6.0-samples.jsonl`、`build/soak-0.6.0-samples.summary.json`、`build/soak-0.6.0-fixture.log`。合成橋接不會觸發內建下一集預取，該政策另由核心測試驗證；上述首幀不是官方片源或真機效能。長測與最終背景搜尋補修使用相同播放器／Core 原碼，之後補修只涉及片庫 UI 及其新 model，並已重做建置與片庫畫面。

最終模擬器另觀察到：停在第 300 集片尾按中央播放，進度回到零秒並重新播放；手動 2 倍速及關閉自動下一集，在終止並重啟 App 後仍保持。測後還原 1 倍速與自動下一集，切回內建播放及原有片庫。播放診斷顯示有界 80 次與模擬器提示，最近測量的「原片重播」首幀為「—」，系統報告顯示尚未收到，沒有把 MetricKit 範例當作量測。

唯讀 macOS 原生取源／解碼探針同次讀取一部 102 集作品的第 4 集：startup 準備 1.49 秒、首個解碼影格 2.00 秒；直接 seek 至 70% 準備 1.48 秒、首個解碼影格 2.07 秒。記錄為 `build/native-0.6.0-startup.log`、`build/native-0.6.0-seek.log`。這是分次 macOS 管線量測，不能視為 iPhone 首幀、前後版本效能比較或預載收益。

播放診斷僅保存最多 80 筆去識別本機數值；重播另外標記，不混入冷啟播首幀。自動重試次數代表嘗試次數，恢復等待包含重建至恢復播放的空檔。模擬器不能驗證實機耗電；本輪沒有注入 MetricKit 範例報告作為效能證據。

同一批 App 原碼另完成 iPhoneOS／arm64 Debug 簽署建置與嚴格簽章檢查，經既有 `localNetwork` 通道覆蓋安裝至已配對手機。安裝及啟動均回報成功，App 清單讀回 0.6.0／build 16；未刪除 App 或重新登入。初次部署後，背景搜尋補修亦重新簽署建置、覆蓋安裝並成功啟動。這是部署與啟動證據，本輪沒有重做真人帳號同步、實機手勢或實機長播／耗電驗收。初次記錄為 `build/ios-real-device-0.6.0-build16-build.log`、`build/ios-real-device-0.6.0-build16-install.json`、`build/ios-real-device-0.6.0-build16-launch.json`、`build/ios-real-device-0.6.0-build16-app.json`；最終補修記錄為 `build/ios-real-device-0.6.0-build16-library-background-final.log`、`build/ios-real-device-0.6.0-build16-background-final-install.json`、`build/ios-real-device-0.6.0-build16-background-final-launch.json`。原碼雜湊與產物平台／版號核對保存於 `build/ios-0.6.0-build16-validation.json`。裝置及簽署識別只留本機，公開工程的開發團隊仍為空白。本輪未另產生 Release IPA。

## 0.5.0 試看與片庫體驗

完整測試以 `swift test --disable-sandbox --disable-xctest` 執行：Core 登錄 245 項／29 個 suites，244 通過、1 項可選 `currentWebsiteSnapshot` 略過；AppSupport 8 項／1 個 suite 全部通過。合計 253 項、252 通過、1 略過，記錄於 `build/core-0.5.0-validated-tests.log`。AppSupport 直接編譯正式 Controller 與保存流程，使用合成資料及注入儲存器，沒有登入真人帳號或寫入官方片庫。

新增回歸涵蓋分頁取消、偏好去重／清單上限／還原、長劇及稀疏集數定位、原生暫時錯誤恢復、同區塊共用與取消隔離、首段快取／預取上限，以及大型片庫補資料的公平輪替與失敗退避。實際 Controller 測試覆蓋延遲載入後收藏／進度、清除順序、跨來源隔離、載入失敗不覆空、最後進度 flush 等待最新版本，以及舊 metadata 任務不能清掉新工作。

本機 Xcode 27.2 的 Duo 模擬器 Debug 最終建置成功，使用 Xcode ad hoc 簽署，開發團隊保持空白；已安裝並啟動 0.5.0／build 15。最終建置記錄為 `build/ios-0.5.0-build15-layout-fixed.log`。開發驗證階段只使用模擬器，未另產生新的 Release IPA；後續實機交付另記如下。

2026-11-07 依使用者要求，以 `ec55beb` 的已驗原碼重新建置 iPhoneOS／arm64 Debug，沿用既有開發簽署，嚴格簽章檢查通過；115 個原碼雜湊與模擬器驗證清單一致。手機透過 `localNetwork` 無線通道完成覆蓋安裝，App 清單從 0.4.4／build 14 更新為 0.5.0／build 15。第一次啟動被 iOS 鎖定狀態拒絕，使用者解鎖後再次啟動成功，隨後程序查詢確認有 Hongguo 執行中。未解除配對、刪除 App 或重新登入；這是簽署、安裝、版本及啟動證據，沒有重做本版真機手勢、長時間播放或帳號同步驗收。公開專案的開發團隊設定仍留空。證據保存在本機 `build/ios-real-device-0.5.0-build15-build.log`、`build/ios-real-device-0.5.0-build15-install.json`、`build/ios-real-device-0.5.0-build15-app.json`、`build/ios-real-device-0.5.0-build15-launch-unlocked.json`、`build/ios-real-device-0.5.0-build15-processes.json` 與 `build/ios-real-device-0.5.0-build15-validation.json`；裝置與簽署識別不放入公開倉庫。

當次模擬器觀察：

- 真人試看有動態影片與持續更新的第一集進度；卡片愛心即時切換。重啟 App 後首頁仍顯示已收藏，測後取消本次測試新增的收藏。
- 推薦偏好在收合與展開畫面均可操作；略過開關及分類重啟後保留。從漫劇切回真人後載入新片單，已試看過的第一部被排除，按「繼續試看」後播放另一部第一集。
- 102 集作品可定位上次第 8 集，以及輸入 100 後切至 91–102 集範圍並標出第 100 集；兩項定位都停在詳情，不會開始播放。收合與展開旋轉後仍保留定位。
- 最終對齊修正版在展開畫面以無障礙「下一部試看／上一部試看」確認切至另一部第一集、返回原部並繼續播放；收合後再換下一部，也顯示新片名及增加的進度。暫停操作後中央按鈕同步顯示「播放」。此項不代替實體拖曳手勢驗收。
- 「不感興趣」會重建片單並排除當前作品；偏好頁顯示已隱藏 1 部。按「恢復這些推薦」後歸零；測後將模擬器略過開關還原為關閉。
- 漫劇目錄能載入實際作品；當次第一部取源回報未提供 iPhone 支援的格式，介面顯示明確錯誤與重試／換劇選項，沒有假造可播來源。這不表示全部漫劇均可播。

模擬器檢查曾抓到切換偏好後永久空片單：已取消但尚未執行的舊工作仍能佔用新佇列的 pending page。現於 claim 前檢查取消及世代，取消清理只處理同代工作；新增真正取消 Task 的回歸案例，確認新工作仍可正常取得第一頁。另補首幀回報的 current-item／item generation 檢查，並移除可能晚到取消新預取的非限定取消指令。

展開畫面換頁另實測到外層高度 786 pt、系統停靠 offset 704 pt，但可見卡片 origin 已為 0；舊 offset／外層高度除法會永久判為未對齊。現以 viewport 相對卡片 frame 判斷，frame 更新即重新檢查啟播資格，對齊與影格保留共用座標。數值診斷只在 Debug 明確帶入 `-preview-layout-diagnostics` 時啟用，不印劇集 ID、片源網址或帳號。修正前後證據保存在本機 `build/preview-layout-0.5.0-before.log`、`build/preview-layout-0.5.0-after.log`。

上述是短程模擬器與合成測試，尚未量測實機切劇等待的改善幅度、長時間記憶體／耗電、行動網路或低耗電模式實測，也未重做真人帳號同步及實體觸控驗收。預取政策及快取界線見 [NATIVE-PLAYBACK.md](NATIVE-PLAYBACK.md)，保存界線見 [ACCOUNT.md](ACCOUNT.md)。

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
