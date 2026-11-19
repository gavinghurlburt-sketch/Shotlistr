# App Store paperwork (creatrr)

Last checked Nov 19, 2026. creatrr now includes the video editor (Edits), formerly the separate editrr app.
There is no separate editrr App Store record; everything ships as creatrr (bundle `art.gavingeddes.producrr`).

## URLs (live on Vercel, deployed from `main`)
- Support URL: https://www.creatrr.co/support
- Privacy Policy URL: https://www.creatrr.co/privacy
- Terms of Use (EULA, link in the description): https://www.creatrr.co/terms
- Marketing URL (optional): https://www.creatrr.co
- Support email: apps@gavingeddes.art

## Store listing
**Name:** creatrr
**Subtitle (30 max):** Plan, film & edit music videos
**Promotional text (170 max):** Film takes to your song and they line up on their own. Cut between them, add lyrics, and export for Reels and TikTok. Plan every shoot in one place.
**Keywords (100 max):** music video,video editor,shot list,lyrics,multicam,videography,storyboard,artist,call sheet
**Category:** Photo & Video (secondary: Productivity)
**Age rating:** 4+ (answer "None"/"No" to every question; no user-generated content shared publicly, no web browsing, no chat)
**Copyright:** 2026 Gavin Geddes

### Description
creatrr is the music video app for artists and the people who film them. Plan the shoot, film your takes to the song, and cut the video, all on your iPhone.

FILM TO THE SONG
- Pick a song and a section, hit record, and the song plays while you film
- Every take lines up with the music on its own, up to 10 takes per section
- Count-in and click from your song's tempo, lens and zoom controls, slow motion

EDIT LIKE A MULTICAM
- All your takes stacked on one timeline, synced to the song
- Tap to cut between takes, trim, move, add photos and overlays
- Masks, keyframes and on-screen lyrics
- Type what you want ("faster cuts, more close-ups") and Auto edit does it, on iPhones with Apple Intelligence
- Export vertical 1080x1920 for Reels, TikTok and Shorts, or save to Photos
- Editing happens on your iPhone; your videos are never uploaded

PLAN EVERY SHOOT
- Songs with their sections, colors and tempo
- Shot lists per section, with reference photos, notes and hooks
- Share a band link so your bandmates can add notes
- Plus and Pro add artists, projects and a calendar; Pro adds call sheets and an on-set tracker

SUBSCRIPTIONS
creatrr is free to download. A plan is needed to use it:
- creatrr Artist: $1.99 per month, songs and edits for 1 artist, 7-day free trial for new subscribers
- creatrr Plus: $9.99 per month, up to 10 artists
- creatrr Pro: $29.99 per month, up to 50 artists plus video production tools

Payment is charged to your Apple ID at confirmation of purchase (or at the end of the free trial). Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in Settings > your name > Subscriptions. Prices are in USD and may vary by region.

Terms of Use: https://www.creatrr.co/terms
Privacy Policy: https://www.creatrr.co/privacy

(Prices above match the live RevenueCat products; change them here and in docs/terms.html if the plan prices change.)

## App Privacy ("nutrition label") answers
Tracking: **No** (no ads, no cross-app tracking, no analytics, no crash reporting SDK).

Data collected, all "linked to the user", used only for **App Functionality**, **not** used for tracking:
| Type | Why |
|---|---|
| Contact Info > Email Address | account sign-in |
| User Content > Photos or Videos | cover/reference photos synced to the account |
| User Content > Audio Data | uploaded tracks |
| User Content > Other User Content | projects, notes, shot lists, band link notes |
| Identifiers > User ID | account + subscription |
| Purchases > Purchase History | subscription status (Apple via RevenueCat) |

Not collected (stay on the phone): videos and takes in the editor, camera and microphone recordings, speech-to-lyrics (Apple on-device), Auto edit typed requests (Apple Intelligence, on-device).
Hook import frames go to Anthropic for a few seconds and aren't stored, so they count as not collected under Apple's definition, but the app asks permission first (guideline 5.1.2(i)) and the privacy policy names Anthropic.
The app's PrivacyInfo.xcprivacy (ios/App/App/Editrr) lists the same six types.

## Export compliance
`ITSAppUsesNonExemptEncryption` is NO in Info.plist (standard HTTPS only), so App Store Connect won't ask.

## Screenshots
Required (Apple spec page, read Nov 19, 2026): at least one "iPhone with Dynamic Island (medium display)" screenshot, 1206 x 2622 or 1179 x 2556 portrait (a regular iPhone 16/17 screenshot). Up to 10.
Suggested set (Artist plan, home tabs are Songs and Edits):
1. Songs: the artist page with songs and sections
2. Shoot: camera with the song section title and the record button
3. Edits: timeline with several synced takes
4. Lyrics on a video
5. Export screen
If iPad stays supported (TARGETED_DEVICE_FAMILY 1,2), Apple also requires at least one 13" iPad screenshot (2064 x 2752 or 2048 x 2732).

## Review notes (paste in App Review Information)
creatrr is a music video app: plan shoots, film takes to a song, and edit them. A subscription is required (Apple in-app purchase, entitlements via RevenueCat); sandbox purchases work on the paywall.
Sign in: account button (top right) > Sign in.
Demo account: creatrr.test.user@gmail.com / PASSWORD   <-- set the password in the app first
Video editor: the Edits tab (swipe left from Songs). Filming: open a song, tap the red record button on a section. Camera, microphone and Photos are used only for filming and editing on the device.
Lyrics from audio use Apple's on-device speech recognition. Typed Auto edit requests use Apple Intelligence's on-device model where available.
Hook import (Import a hook) sends a few frames to Anthropic's Claude after the user agrees on a permission screen.
Restore Purchases and Terms / Privacy links are on the paywall. Account deletion: account button > Delete account.
Contact: apps@gavingeddes.art

## Before submitting
- [ ] Paid Apps agreement, bank and tax info active
- [ ] Subscription group "creatrr" with the three products approved or "Ready to Submit" (submit them with the first build)
- [ ] Demo account password set and tested
- [ ] Screenshots
- [ ] Age rating questionnaire
- [ ] App Privacy answers (table above)

## RevenueCat (already live)
`scripts/subs.config.json` has `"live": true` and the public Apple key. Product IDs: `creatrr_artist_monthly` ($1.99, 7-day free trial), `creatrr_plus_monthly` ($9.99), `creatrr_pro_monthly` ($29.99). Entitlements `artist`, `plus`, `pro` in the default Offering.
