# App Store paperwork (creatrr)

Public pages (in `docs/`, served by GitHub Pages):
- Support URL: `<pages-url>/docs/`
- Privacy Policy URL: `<pages-url>/docs/privacy.html`
- Terms of Use (EULA link in the description): `<pages-url>/docs/terms.html`

## App Privacy ("nutrition label") answers
Tracking: **No** (no ads, no cross-app tracking, no analytics).

Data collected, all "linked to the user", used only for **App Functionality**, **not** used for tracking:
| Type | Why |
|---|---|
| Contact Info → Email Address | account sign-in |
| User Content → Photos or Videos | cover/reference photos |
| User Content → Audio Data | uploaded tracks |
| User Content → Other User Content | projects, notes, shot lists |
| Identifiers → User ID | account + subscription |
| Purchases → Purchase History | subscription status (via Apple/RevenueCat) |

Re-check this table after adding RevenueCat; if you ever add analytics or crash reporting, update it and the privacy page.

## Subscription metadata Apple requires
- Group name: creatrr. Levels: Pro (top), Plus, Artist.
- Prices: Artist $1.99, Plus $9.99, Pro $29.99 monthly. Artist: 7-day free trial.
- In the app description, include: plan prices and length, "payment charged to Apple ID", auto-renewal and cancel-24h-before wording, and links to the Terms and Privacy Policy.
- Paywall must show price, period, trial terms, Restore Purchases, and Terms / Privacy links.

## Review notes (paste in App Review Information)
- Demo account: create a test email + password in the app first, list them here.
- Account deletion: tap the account button → Delete account.
- No login is required to use the app on the device.

## Before submitting
- [ ] Paid Apps agreement, bank and tax info
- [ ] Small Business Program application
- [ ] Support email reachable
- [ ] Screenshots (6.9" iPhone minimum; others are optional)
- [ ] Age rating questionnaire (expected 4+)
- [ ] Export compliance: app uses only standard HTTPS encryption (answer "No" to proprietary encryption / exempt)

## RevenueCat setup (do after the Apple account is approved)
1. Create the free RevenueCat account, add an iOS app (bundle id `art.gavingeddes.producrr`), and paste the App Store Connect shared secret / API key when it asks.
2. In App Store Connect create one subscription group "creatrr" with three monthly products. Product IDs must be exactly:
   `creatrr_artist_monthly` ($1.99, 7-day free trial intro offer), `creatrr_plus_monthly` ($9.99), `creatrr_pro_monthly` ($29.99).
3. In RevenueCat: create **entitlements** named exactly `artist`, `plus`, `pro`, attach each product to its entitlement, and put all three in the default **Offering**.
4. Copy RevenueCat's **public Apple SDK key** (starts `appl_`) into `scripts/subs.config.json` as `revenueCatAppleKey`, set `"live": true`, then `npm install && npm run sync`.
5. In Xcode add the **In-App Purchase** capability (Signing & Capabilities → + Capability).
6. Test with a Sandbox Apple ID; check purchase, cancel, restore, and a plan upgrade.

While `"live"` is false the app behaves exactly as today (plan switcher in testing mode, no paywall).
