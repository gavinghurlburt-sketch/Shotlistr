# Push notifications and "share to creatrr" setup

Code for both is in the repo. A few things only you can do (Apple account + Xcode). About 15 minutes total.

## 1. Push notifications

1. developer.apple.com > Certificates, IDs & Profiles > **Keys** > **+**. Name it "creatrr push", tick **Apple Push Notifications service (APNs)**, Continue, Register, **Download** the `.p8` file (you only get one download). Note the **Key ID** shown.
2. Your **Team ID** is under Membership details on the same site.
3. Supabase dashboard > project `anuybnbilfjthbhsxhdk` > Edge Functions > Secrets. Add four:
   - `APNS_KEY` = the full text of the .p8 file (including the BEGIN/END lines)
   - `APNS_KEY_ID` = the Key ID
   - `APNS_TEAM_ID` = your Team ID
   - `APNS_TOPIC` = `art.gavingeddes.producrr`
4. In Xcode, open `ios/App/App.xcodeproj`, select the **App** target > Signing & Capabilities. You should already see **Push Notifications** (the entitlement file is in place). If not, click **+ Capability** and add it.
5. `git pull origin ios-app && npm run sync`, then run on a **real iPhone** (push does not work in the simulator). Create a band link; iOS asks to allow notifications. Say Allow.

Test: open the band link on a computer, add anything, tap **Finish & notify**. Your phone should buzz.

## 2. Share audio to creatrr (Messages, Files, Voice Memos, Mail)

1. Xcode > App target > Signing & Capabilities > **+ Capability** > **App Groups** > **+** > name it `group.art.gavingeddes.producrr`.
2. File > New > Target > iOS **Share Extension**. Product name `ShareExtension`, language Swift, Team = yours. If Xcode asks to activate the scheme, choose Cancel.
3. In the new `ShareExtension` folder, delete the generated `ShareViewController.swift`, `MainInterface.storyboard` and (if present) its Info.plist contents. Then drag in the three files from `ios/ShareExtension/` in this repo: `ShareViewController.swift`, and use `Info.plist` and `ShareExtension.entitlements` (replace the generated ones; in the extension target's Build Settings make sure Info.plist File and Code Signing Entitlements point at them).
4. Select the **ShareExtension** target > Signing & Capabilities > **+ Capability** > **App Groups** > tick the same `group.art.gavingeddes.producrr`.
5. Build and run on your iPhone. In Messages, long-press an audio attachment > Share > **creatrr** (scroll the share row and tap More if it isn't visible, then enable it).
6. Open creatrr. Tap the bell. The file is in your **Audio inbox**. Pick the artist and tap **Add as song**.

How it works: the extension copies the file into the shared App Group folder. When creatrr next opens, it moves it into its own storage and opens the inbox.

## No app needed (web / any device)

The bell > **Audio inbox** > **Add audio files…** works in the web app and the iPhone app, and you can drag audio onto the web app. On an iPhone without the extension, use Messages > Save to Files, then pick it from there.
