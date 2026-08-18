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
5. **Calendar** is month or week, with clock times and reminders. **Rules** computes Family Law deadlines onto that calendar.
6. **People** fills from the mail you send and receive. Compose autocompletes those addresses.

Keys: `N` new · `R` reply · `A` reply all · `F` forward · `Del` delete · `J`/`K` next/previous · `U` unread · `/` search.

Time CSV is on the Time pane. Calendar `.ics` is on Calendar.
