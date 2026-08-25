# Praecipe

## Vision

Praecipe is an attorney-shaped mail + practice client. The ambition is a full Outlook replacement — email and practice in one product (matters, time, File & Bill, calendar, people) instead of bouncing between a generic inbox and a separate case system. That bar is high; honesty matters more than slogans.

**Floor that always matters:** Even if Praecipe never fully displaces Outlook, it still fills a core need — **capture time** from email and practice work. For attorneys, that alone is valuable.

**Where it sits next to other tools (no claim of ownership):**

- **Destrier** (separate product) is strong at mobile practice / File & Bill–style work — matters, time, calendar, people — but it does not handle email.
- Kenneth’s **Outlook add-in** covers File & Bill on desktop Outlook.
- **Praecipe** fills the **email gap on mobile**, and can grow into the fuller mail + practice replacement. It is not Destrier, and it is not the desktop add-in.

There has never been an email client designed around how lawyers actually work. Attorneys live in email, but the tools they use were built for everyone else. Case management products then sell back, at high cost, basic practice functions that should sit next to the inbox. Much of that stack can be built leaner when mail and practice share one client — or when mobile mail at least captures time reliably.

**Mobile-first, usable on larger screens.** The design center is the phone, not a native Windows Outlook clone. Build mobile apps that also work well on iPad, laptop, and desktop-sized windows (responsive / large-screen friendly). Kenneth is not here to design desktop-first apps.

The iPhone app is the main line of work; a local Mac/Python app remains in this repo as a companion.

Built for Florida family-law practice, including deadline counting under **Fla. Fam. L. R. P. 12.090** / **Rule 2.514**. Practice aid, not legal advice.

## Design

Apple Mail is a **design tip**, not a product target. Use it for a familiar iOS look, a simple distraction-free UI, and a trustworthy feel that reads as legitimate mail. Praecipe is not an Apple Mail clone and does not chase Apple Mail’s product goals. The product stays what Vision says: attorney mail + practice, mobile-first, Outlook replacement or gap-filler.

## Built for ADHD (and lawyers who live with it)

We make apps to help ADHD — not as an afterthought. Focus on **executive function**, not popular design myths about what “helps ADHD.”

A landmark ABA study found that **12.5% of lawyers** have Attention-Deficit/Hyperactivity Disorder (ADHD), compared with about **4.5% of the general population**. Most lawyers already carry heavy stress; that stress can worsen ADHD symptoms and hit professional performance, personal relationships, and emotional well-being.

ADHD is largely about **dopamine**. People with ADHD are dopamine-deficient and live in a constant chase for it. Mundane practice work — **time entry, calendaring, organization** — is not hard. It is mindless. That is why it gets skipped. An attorney who could record a simple time entry in seconds may instead spend that window learning to code, playing an instrument, or studying medicine: higher-dopamine work wins; executive-function tasks lose.

**Strike while the iron is hot.** Praecipe must make those mindless-but-necessary tasks frictionless at the moment of need — capture time on the email, get it on the calendar, keep the matter organized — so the attorney does not antagonize over them or abandon them for the dopamine chase. Ease of doing the boring thing is the feature.

**Common task struggles (executive function, not intellect):**

- **Time tracking and billing** — forgetting to log billable hours in real time, or delaying timesheets because recording incremental time feels tedious.
- **Task initiation and prioritization** — “ADHD paralysis” when choosing which case file or memo to open first among competing demands.
- **Routine disorganization** — physical or digital clutter, misplaced notes, and losing track of verbose verbal instructions from senior partners.
- **Time blindness and deadlines** — underestimating how long brief-writing or document review will take, then last-minute crunches.
- **Mundane follow-ups** — delaying low-dopamine work: routine emails, administrative forms, organizing discovery packets.

**ADHD is not intelligence.** ADHD does not determine how smart someone is. People with ADHD span the full intellectual range — gifted to intellectually disabled — like everyone else. Formal IQ tests sometimes show a small average gap of a few points; researchers tie that to executive-function load during testing (sustained attention, working memory, impulse control), not a lack of real intelligence. High intelligence can mask ADHD traits and delay diagnosis. Many people with ADHD excel at spontaneous, non-linear, out-of-the-box problem solving even when structured, fast-paced logic tests are hard. The product problem is executive function and dopamine for mundane work — not “making lawyers smarter.”

## iPhone app

Open [`ios/Praecipe.xcodeproj`](ios/Praecipe.xcodeproj) in Xcode (26.3+). Scheme **Praecipe**, bundle id `com.kenturnerlaw.praecipe`.

1. Select your Team under Signing & Capabilities.
2. Run on a simulator or a plugged-in iPhone.
3. In **Settings**, add Gmail / iCloud / Yahoo / Microsoft 365 with an **app password**.
4. Tap **Get Mail**. File & Bill is on the open message. **Rules** counts Fla. Fam. L. R. P. 12.090 / Rule 2.514 onto the calendar.

Mail passwords live in the iOS Keychain, not in git.

## Run (Mac / local web)

```bash
python3 praecipe.py
```

Open [http://127.0.0.1:12090](http://127.0.0.1:12090).

## Replace Outlook (local app)

1. **Settings** — choose Gmail, Microsoft 365, Yahoo, or iCloud. Gmail needs an app password. Paste a signature if you use one.
2. **Send/Receive** — Inbox, Sent, and other IMAP folders sync. After that, Praecipe checks every two minutes on its own.
3. Daily mail: **New Email**, **Reply**, **Reply All**, **Forward**, **Delete**, **Unread**, **Flag**, search in the top bar.
4. Open a message. **File & Bill** is one pass: it guesses the matter (with a confidence %), you check connect / save-to-folder-by-type / download service URLs / email the client / time entry, and hit **Do all checked**.
5. Put the client’s email on the matter so “Email the client” has an address.
6. **Calendar** is month or week, with clock times and reminders. **Rules** computes Family Law deadlines onto that calendar.
7. **People** fills from the mail you send and receive. Compose autocompletes those addresses.

Keys: `N` new · `R` reply · `A` reply all · `F` forward · `Del` delete · `J`/`K` next/previous · `U` unread · `/` search.

Time CSV is on the Time pane. Calendar `.ics` is on Calendar.

The Mac Python app (`python3 praecipe.py`) stays in this repo.
