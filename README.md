# Praecipe

Local Outlook replacement for Florida family-law practice: IMAP/SMTP mail, calendar, contacts, matters, time, files, notes, and deadline counting under **Fla. Fam. L. R. P. 12.090** / **Rule 2.514**.

Practice aid, not legal advice.

## Run

```bash
python3 praecipe.py
```

Open [http://127.0.0.1:12090](http://127.0.0.1:12090).

## Replace Outlook

1. **Settings** — choose Gmail, Microsoft 365, Yahoo, or iCloud. Gmail needs an app password. Paste a signature if you use one.
2. **Send/Receive** — Inbox, Sent, and other IMAP folders sync. After that, Praecipe checks every two minutes on its own.
3. Daily mail: **New Email**, **Reply**, **Reply All**, **Forward**, **Delete**, **Unread**, **Flag**, search in the top bar.
4. Open a message. **File & Bill** is one pass: it guesses the matter (with a confidence %), you check connect / save-to-folder-by-type / download service URLs / email the client / time entry, and hit **Do all checked**.
5. Put the client’s email on the matter so “Email the client” has an address.
6. **Calendar** is month or week, with clock times and reminders. **Rules** computes Family Law deadlines onto that calendar.
7. **People** fills from the mail you send and receive. Compose autocompletes those addresses.

Keys: `N` new · `R` reply · `A` reply all · `F` forward · `Del` delete · `J`/`K` next/previous · `U` unread · `/` search.

Time CSV and PDF billing reports are on the Time pane. Calendar `.ics` is on Calendar.

## LawPay billing

Praecipe creates LawPay Payment Portal invoices through LawPay's supported partner OAuth flow. LawPay credentials never ship in the iPhone app or the repository.

Requirements:

1. Ask 8am/LawPay Support to approve a **partner OAuth application** with the `payments` scope and set its redirect URI to `https://YOUR-BILLING-SERVER/oauth/lawpay`. LawPay's invoice API is not available through a merchant's “My Website” gateway keys alone.
2. Run the Praecipe server behind HTTPS and set these server environment variables:

   ```bash
   PRAECIPE_HOST=127.0.0.1
   PRAECIPE_LAWPAY_CLIENT_ID=...
   PRAECIPE_LAWPAY_CLIENT_SECRET=...
   PRAECIPE_LAWPAY_REDIRECT_URI=https://YOUR-BILLING-SERVER/oauth/lawpay
   PRAECIPE_API_TOKEN=AN-INDEPENDENT-RANDOM-SERVER-TOKEN
   ```

3. In the iPhone app, open **Settings → LawPay**, enter the HTTPS server address and the independent Praecipe API token, connect the LawPay merchant account, and select the operating or trust deposit account.
4. In **Time**, select stopped, unbilled entries for one matter and choose **Create LawPay invoice**. Praecipe confirms the returned LawPay invoice ID before marking those entries billed. Failed requests remain unbilled and display the error.

The LawPay access token is stored in the Mac system Keychain. The iPhone stores only the separate Praecipe server token in its Keychain. Do not reuse the LawPay OAuth secret as the server token.

## iPhone app

Open [`ios/Praecipe.xcodeproj`](ios/Praecipe.xcodeproj) in Xcode (26.3+). Scheme **Praecipe**, bundle id `com.kenturnerlaw.praecipe`.

1. Select your Team under Signing & Capabilities.
2. Run on a simulator or a plugged-in iPhone.
3. In **Settings**, add Gmail / iCloud / Yahoo / Microsoft 365 with an **app password**.
4. Tap **Get Mail**. File & Bill is on the open message. **Rules** counts Fla. Fam. L. R. P. 12.090 / Rule 2.514 onto the calendar.

The Mac Python app (`python3 praecipe.py`) stays in this repo. Mail passwords live in the iOS Keychain, not in git.

The iOS data store is configured for private CloudKit synchronization through `iCloud.com.kenturnerlaw.praecipe`. Apple does not permit the iCloud capability on a free Personal Team; installing the CloudKit-enabled build on a physical device requires a paid Apple Developer Program team. **Settings → Create practice backup** remains available for an encrypted-at-rest, user-controlled backup containing matters, billing, notes, calendar entries, people, document files, signatures, and app settings. Restore validates and stages the entire archive before replacing current data. Keychain credentials are intentionally never exported.
