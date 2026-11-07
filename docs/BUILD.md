# 建置與安裝

## 0.12.1／build 30

一般播放器與試看加入左右雙點前後 10 秒及短暫方向提示，沿用公開 SwiftUI／UIKit 手勢和既有 seek／觸覺回饋，不增加套件、權限或外部服務。`generate_project.py` 收錄共用提示 View，簽署方式不變；當版測試、畫面與手機部署見 [TESTING.md](TESTING.md)。

## 0.12.0／build 29

本版增加倍速緩衝偏好、512 MiB 磁碟分段 LRU、目前影片的有界預讀與設定中的用量／清除入口，不增加外部服務或權限。漸進起播、帳號與簽署方式保留；測試與手機部署以 [TESTING.md](TESTING.md) 為準。

## 0.11.1／build 28

本版只補播放操作的 UIKit 觸覺回饋，不增加建置或外部服務依賴；0.11.0 的交接、推薦及滿版功能保留。模擬器可檢查操作流程，不能驗證實體觸覺馬達的震感；當版建置、GUI 與手機結果見 [TESTING.md](TESTING.md)。

## 0.11.0／build 27

2026-11-08 更新。本版加入符合條件時重用同一 AVPlayer／item 的試看追劇交接、換集保留舊實際影格至新畫面與定位完成、明確多／少推薦題材及跨頁題材交錯，並加入試看頁內滿版與縮放。既有 0.10.0 短期試看記憶、拖曳提示與精細進度保留。`generate_project.py` 自動收錄新的 Swift 檔，公開專案仍不保存簽署 team；實機 team 僅由本機命令列提供。此處記錄實作與建置方法，Core／AppSupport、Duo 模擬器、iPhoneOS 建置及手機安裝的當版結果請見 [TESTING.md](TESTING.md)。

## 前置條件

- macOS、完整 Xcode 與 iOS 平台支援；本機驗證版本為 Xcode 27.2，並安裝 Duo 專用 runtime。當前程式版本為 0.12.1／build 30；播放器交接、題材偏好與滿版操作不增加外部服務依賴，原有上下換集、畫質偏好及原生手機簡訊登入持續保留。
- iPhone 執行 iOS 17+；工程只啟用 iPhone device family。
- 完整 App 建置需包含 Duo API 的 iOS 27.1+ SDK，本機使用 27.2。iOS 17 是執行下限；availability guard 不能讓舊 SDK 解析不存在的 API。
- 選定自己的 Apple 開發團隊／簽署身分。專案不附任何開發者憑證、私鑰或 provisioning profile。

本機檢查：

```sh
xcodebuild -version
xcrun simctl list devices available
```

若 active developer directory 仍指向 Command Line Tools，可在安裝 Xcode 後切換：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 本次已驗證環境

2026-11-06 已在 `/Applications/Xcode.app` 安裝完整 Xcode 27.2，完成授權與開發工具路徑切換。初版使用 iOS 27.2 SDK 的 generic iOS Simulator 建置成功，包含 arm64 與 x86_64。0.2.0 已完成原生漸進取源、84 項核心測試與指定 Duo 的原生工具列建置；這些是版本對應的既有記錄。0.3.0 的完整核心與來源探針見 [TESTING-CORE.md](TESTING-CORE.md)，簽署安裝、UI 驗收及 Release 產出狀態見 [TESTING.md](TESTING.md)。

0.2.0／build 3 已以開發者身分完成真機簽署安裝與播放畫面檢查，使用者確認有聲音。0.2.1／build 4 也已安裝，但點播入口出現 scrollPosition 取消競態；0.2.2／build 5 已安裝，其首頁屬中間版。0.2.4 的既有版面、0.3.0 的選劇驗收、0.4.0 的帳號／片庫初版與 0.4.4 歷史建置／裝置狀態分別記於 [TESTING.md](TESTING.md)。歷史產物保留，當前程式版號由根目錄 `VERSION` 決定。

iOS 27.2 的一般 runtime 24B8117 與 Duo 專用 runtime 24B91016s 均已安裝。一般 runtime 明確排除 Duo 的裝置型號，因此不能只以版本號 27.2 判斷相容性。Duo 專用 runtime identifier 為 `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`。需要安裝相同版本時，可執行：

```sh
xcodebuild -downloadPlatform iOS -buildVersion 24B91016s
```

Duo 模擬器已完成安裝、開機與 Xcode Run 啟動。0.2.0 播放器曾在 Device Hub 檢查原生工具列、收合／展開與暫停操作。首頁採劇場式 adaptive 直式海報網格，依寬度調整欄數、自然垂直捲動，按「開始觀看」才播放；0.4.4 的「試看」則使用同頁連續垂直卡片，停穩且對齊後試播第一集。一般播放器預設等比裁切，控制資訊以透明原生列與緊湊 Liquid Glass 框覆蓋影片。各版行為的驗收以 [TESTING.md](TESTING.md) 為準。

## Xcode 直接執行

開啟 `iOS/Hongguo.xcodeproj`，等待本機 Swift Package 的 `HongguoCore` 與 `HongguoPlayback` 載入；不需要 CocoaPods 或外部 Swift package。後者的 `NativeMediaAssetLoader` 由 App 與 macOS 驗證工具共用，負責將按需解密的 Range 交給 AVFoundation。內建簽章 JS 與 MIT 相依項已附在 Core resources，不需要 Node 或 npm 才能建置 iPhone App。JavaScriptCore、CommonCrypto、CryptoKit 與 zlib 使用 Apple SDK／系統版本。

0.3.0 的目錄、榜單、新劇、藝人與相關作品讀取是 Core 中的附加 metadata 功能，不需官方帳號；選片後沿用相同內建播放體系，沒有新增播放服務設定。命令列來源探針的操作與驗證界線見 [TESTING-CORE.md](TESTING-CORE.md)。

自 0.4.1 起，選用帳號功能使用原生 SwiftUI 手機號碼、國碼與簡訊驗證碼介面，透過 `NativePhoneAuthService` 呼叫官方 App 登入 API；不再使用 0.4.0 的 WKWebView 官網登入流程。使用者需自行閱讀[紅果使用者服務協議](https://reading.snssdk.com/wap-hongguo/dr-agreement-v2.html)及[隱私政策](https://reading.snssdk.com/wap-hongguo/dr-privacy-v3.html)、勾選同意，再按「取得驗證碼」才發送簡訊；介面有重發倒數。更換手機號碼、取消或離開會清除這次驗證流程。若官方要求上行簡訊 MFA，畫面只顯示本次來源給定的收件號碼與內容，由使用者手動發送後繼續驗證；不會自動發送或繞過其他驗證。

手機號碼與簡訊驗證碼不寫入 UserDefaults、片庫 JSON 或 Keychain。成功登入後，會話憑證與同次註冊的 `AccountAppDevice` 一起保存在這部裝置的 Keychain，帳號 Cloud 請求重用該身分；本機片庫與每個帳號、播放來源分開保存。收藏與進度同步使用內建 Core，不需另設服務。`validateForLibrary` 只檢查本地會話、帳號與有效期限，沒有宣稱已完成獨立的線上身分驗證；會話是否仍被接受，由實際 Cloud 請求的回應判定。真人發碼、登入、收藏寫入與跨裝置續播仍須依 [TESTING.md](TESTING.md) 的實際結果判斷；操作、儲存及同步界線見 [ACCOUNT.md](ACCOUNT.md)。公開選劇與匿名播放仍可直接使用。

0.4.2 將片庫清單同步與海報／劇集資料補齊分開。來源只提供劇集 ID 時先保存並顯示片庫，再以有並行與時間上限的背景請求補齊 metadata；不再等待每部劇的詳情全部讀取後才顯示清單。補齊只更新既存劇集資料，不改觀看位置、時間、收藏狀態或待同步操作編號。

0.4.4 的原生「試看」分頁使用目前目錄逐部試播第 1 集，不宣稱是官方個人化推薦 feed。每劇佔一個可用畫面，卡片跟手拖曳，鄰頁顯示海報；拖曳期間暫停並保留當前影格，停穩對齊後才允許當頁播放。試看不寫入歷史或原有續播位置；「看整部」在同一個 NavigationStack 推入詳情，返回保留位置並等待手動「繼續試看」。試看長按只暫時 2 倍速，上下滑交給分頁；一般全螢幕播放器的原生工具列與倍速鎖定維持獨立。首頁與劇場仍需手動開始。操作與來源界線見 [NATIVE-PLAYBACK.md](NATIVE-PLAYBACK.md) 及 [DISCOVERY.md](DISCOVERY.md)。

0.2.4 的資訊框在 iOS 26+ 使用系統 `.glassEffect(.regular)`，較舊系統使用 ultraThinMaterial；Reduce Transparency 啟用時使用不透明背景。這些 UI 分支以 availability 保留 iOS 17 執行相容性，視覺與裝置驗收結果見 [TESTING.md](TESTING.md)。

在 Hongguo target 的 Signing & Capabilities 選 Team，使用 Automatic Signing，必要時改用自己的 Bundle Identifier。接上 iPhone 並選為執行裝置，依 Xcode 指示完成信任與 Developer Mode，再執行 Run。

Apple 官方操作：[在模擬器或實機執行 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)、[啟用 Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

## 已簽署真機 Debug 與命令列安裝

先在 Xcode 的 Accounts 加入開發者帳號，確認可用的 Team，並讓 iPhone 信任這部 Mac、啟用 Developer Mode。下列命令從專案根目錄執行；`TEAM_ID` 與 `DEVICE_UDID` 都是占位值，請換成自己的資料。真機 UDID 可由 `xcodebuild -project iOS/Hongguo.xcodeproj -scheme Hongguo -showdestinations` 查得，不要填入模擬器 UUID。

```sh
TEAM_ID="YOUR_TEAM_ID"
DEVICE_UDID="YOUR_PHYSICAL_DEVICE_UDID"

xcodebuild -project iOS/Hongguo.xcodeproj -scheme Hongguo \
  -configuration Debug -destination "platform=iOS,id=$DEVICE_UDID" \
  -derivedDataPath build/RealDeviceDerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_ALLOWED=YES build

APP_PATH="$PWD/build/RealDeviceDerivedData/Build/Products/Debug-iphoneos/Hongguo.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist")
codesign --verify --deep --strict "$APP_PATH"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"
xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID"
```

這條路徑使用 Automatic Signing 與 Apple Development，產物與未簽署 Release 隔離。兩個 provisioning 參數允許 Xcode 使用已登入的帳號建立／更新描述檔、App ID、簽署憑證，以及在需要時登記目的裝置。若目前的 Bundle Identifier 無法由該 Team 簽署，先在工程中換成自己可用的 ID；啟動命令會從建置產物讀取實際的 Bundle Identifier。

`devicectl` 安裝的是已簽署的 `.app`，不需先包成 IPA。原有 `sh scripts/build-ios.sh device` 仍明確使用 `CODE_SIGNING_ALLOWED=NO`，只產生未簽署 Release，不能取代上面的真機簽署步驟。

## 命令列建置

```sh
sh scripts/build-ios.sh simulator
sh scripts/build-ios.sh device
sh scripts/package-ipa.sh
python3 scripts/package-source.py
sh scripts/build-ios.sh archive
```

`simulator` 透過 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` 讓 Xcode 產生本機 ad hoc 簽署與 simulated app identity；不需個人開發團隊，可正常測試 Keychain。產生的模擬器 `.app` 不能裝到 iPhone。`device` 產生未簽署實機 Release，`package-ipa.sh` 將它包成未簽署 IPA，供側載工具重新簽署；`package-source.py` 另產生原始碼 ZIP。檔名依根目錄 `VERSION` 產生，規則為 `dist/Hongguo-iPhone-<VERSION>-unsigned.ipa` 與 `dist/Hongguo-iPhone-<VERSION>-source.zip`，當次產出與驗證狀態見 [TESTING.md](TESTING.md)。`archive` 使用 Xcode 工程內設定的開發團隊建立 `build/Hongguo.xcarchive`，可在 Xcode Organizer 依自己的分發方式匯出、簽署與安裝。實機安裝仍需適合該裝置的簽署與描述檔。

既有 0.2.0、0.3.0、0.4.2、0.4.3 Release 與 IPA 檢查屬各版歷史記錄。歷史 0.4.4 的 Release／重新打包狀態及各版驗收集中記於 [TESTING.md](TESTING.md)。

建置腳本保留已有工程的簽署設定。新增／刪除 Swift 檔案後，可執行 `python3 scripts/generate_project.py` 重建工程；**重建會覆蓋工程內手動修改的 build settings**，之後需重新選擇 Team。圖示已包含在原始碼包；若修改圖示生成器，從專案根目錄執行 `swift scripts/generate_icon.swift`。

工程採用 Apple 標準架構設定：Debug 的 `ONLY_ACTIVE_ARCH=YES`，Release 為 `NO`。這已修正指定 Duo 執行時 App 同時編譯 x86_64、套件卻只產生 arm64 module 的不一致；指定 Duo 的 CLI 與 Xcode Run 建置均已通過。參考 [Apple TN3117](https://developer.apple.com/documentation/technotes/tn3117-resolving-build-errors-for-apple-silicon)。

Duo 的原生列使用 TabView／NavigationStack 與帶名稱、symbol 的 toolbar items。外螢幕與內螢幕橫向可使用側欄，內螢幕直向則使用上下列；位置由系統依姿態處理。播放器點影片空白處顯示／隱藏控制，使用中央按鈕播放／暫停；控制列透明覆蓋影片，播放時可閒置隱藏，影片畫布保持不縮小。實作依據見 Apple [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/) 與 [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)。

0.11.0 的試看頁內滿版會隱藏原生 Tab／狀態列與控制資訊；點空白只切控制顯隱，雙指可縮放至 0.5–3 倍，選單提供放大、縮小、還原、完整比例及填滿。追劇重用須通過同劇同集／item、2 秒位置容差、片庫與來源 revision／畫質、前景及未滿 60 秒檢查，否則正常準備。明確題材偏好在本機隔離保存，不需新增帳號權限或後端設定。滿版、縮放與轉場的 GUI／手機驗收仍以 [TESTING.md](TESTING.md) 為準。

0.9.2 的長按 2 倍速開始／放開，以及一般播放器鎖定／解除鎖定，都不再喚回整組 HUD；頂部提示獨立呈現，試看提示也移出 HUD opacity，保留操作前的控制列顯隱。點空白、中央播放及手動速度選單維持原有行為，不新增建置需求。當版測試、建置、GUI 與手機結果以 [TESTING.md](TESTING.md) 為準。

0.9.3 在一般播放器加入明確上滑下一集、下滑上一集，成功換緊鄰分集時從零播放；短距離不觸發，邊界或鄰集未開放只顯示約 2 秒頂部提示，不跳過未開放集、不喚 HUD。長按後上下滑優先鎖速，試看仍上下換劇。建置方式不變，當版驗證見 [TESTING.md](TESTING.md)。

## 區域網路測試

預設內建播放直接使用 HTTPS，不需設定區網服務或允許連到 Mac。以下只適用選用的自訂播放服務：橋接支援 HTTPS，以及 localhost、`.local`、私有 IP 的 HTTP。iPhone 首次連區域網路時依需要允許系統權限。**實機上的 `127.0.0.1` 是 iPhone 自己**；連 Mac 服務需填 Mac 的區網位址，並讓服務監聽區網介面。

參考 [BRIDGE.md](BRIDGE.md) 啟動真實橋接或明確標示為測試資料的合成影片 fixture。測試片源能檢查播放器整合，不能證明紅果平台片源可用。

## 本機模擬器長時間連播

`Backend/fixtures/server.mjs` 預設 3 集，亦可指定 1–600 集；每集使用同一段本機產生的四秒影片，不連平台或使用帳號。以下從專案根目錄啟動 300 集合成目錄：

```sh
FIXTURE_EPISODES=300 PORT=8788 node Backend/fixtures/server.mjs
```

模擬器 App 的設定中選自訂播放服務與自訂服務目錄，驗證並儲存 `http://127.0.0.1:8788`，再手動開始測試片段並開啟自動下一集。另開終端機取得目前模擬器與 App 程序的 ID，將資料容器路徑留在已忽略的 `build` 中：

```sh
SIMULATOR_ID="YOUR_SIMULATOR_ID"
APP_PID="YOUR_RUNNING_SIMULATOR_APP_PID"
mkdir -p build
xcrun simctl get_app_container "$SIMULATOR_ID" tw.mountainp.hongguo data > build/soak-container.txt
python3 scripts/monitor-simulator-soak.py \
  --container-file build/soak-container.txt --pid "$APP_PID" \
  --duration 1200 --last-episode 300 --output build/soak-samples.jsonl
```

觀察器只讀訪客片庫中的指定合成作品及本機診斷數值；不控制 UI、不讀帳號片庫、不輸出片源或帳號。每 10 秒記錄換集、完成集數及 Mac 模擬器程序 RSS；到指定末集或期限即輸出相鄰的 `.summary.json`。RSS 與真機 `phys_footprint`、耗電不同；合成橋接的首幀時間也不代表官方片源的等待時間。測後在 App 還原內建播放與官網目錄，並以 Ctrl-C 停止該 fixture。

## 驗收記錄

建置、核心測試、真實取源／完整解碼、Duo 各版面的播放與手勢，以及實體 iPhone 的簽署安裝分別記於 [TESTING.md](TESTING.md)。0.2.0 的真機畫面與使用者確認音訊、0.4.2／build 12 的真機 Debug 與未簽署 Release 建置保留為歷史記錄。

歷史 0.4.3／build 13 已通過本機 Duo 模擬器最終建置，記錄為 `build/ios-0.4.3-build13-simulator-final.log`；完整 Core 為 190 項、22 個 suites，189 項通過、1 項可選快照略過，記錄為 `build/core-0.4.3-tests-final.log`。該版模擬器曾觀察第一集試播、切劇、暫停／倍速、正確 96 集詳情與返回；四秒合成三集影片也完成兩次自動銜接。這些結果保留為該版歷史驗收。

0.4.4／build 14 的完整同頁試看已通過模擬器建置，記錄為 `build/ios-0.4.4-build14-simulator-final-ui.log`；Core 為 199 項、23 個 suites，198 項通過、1 項可選快照略過，記錄為 `build/core-0.4.4-tests.log`，包含 7 項 feed activation 與 9 項片單測試。建置和純狀態測試不等於新介面 GUI 或本版真機驗收；最後增量修正、畫面／手勢、部署與帳號實測統一依 [TESTING.md](TESTING.md) 更新。

## 0.5.0 體驗與片庫改善

試看類型、略過已試看與不感興趣只存在本機；收藏沿用目前選取的片庫。詳情提供每 30 集分組、輸入集數定位及上次觀看定位，定位不會自動播放。預取僅在內建播放、非昂貴／非受限網路且未開啟低耗電時進行；只準備下一部的首段，不建立額外播放器。快取與一次網路重試界線見 [NATIVE-PLAYBACK.md](NATIVE-PLAYBACK.md)。

片庫的 JSON 編碼及檔案寫入改由背景串行儲存器處理，取消／切換來源仍保留分帳號順序。`HongguoAppSupport` 測試 target 直接編譯正式片庫控制器，以注入儲存器驗證載入、切換、最後進度 flush 與同步前落盤；App 建置仍只連結原本的 Core／Playback，沒有額外的套件依賴。完整測試指令與結果見 [TESTING-CORE.md](TESTING-CORE.md)，本版模擬器與實機界線見 [TESTING.md](TESTING.md)。
