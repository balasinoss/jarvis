# Jarvis: an AI assistant for Ray-Ban Meta glasses on iPhone

Say **"Jarvis"**, ask your question, and Jarvis answers through the glasses speakers. He can:

- **See what you see.** "Τι βλέπω;", "Τι γράφει αυτή η πινακίδα;", "Πόσο κάνει αυτό;"
- **Read Greek** (and English and other languages) from signs, books, menus and screens.
- **Do maths and physics.** "Λύσε την άσκηση στο βιβλίο" takes a photo and Claude solves it step by step. You hear the short answer and the full solution appears on your phone.
- **Do things for you.** Write a WhatsApp, Viber or SMS message to a contact, save notes, run your iPhone Shortcuts, or hand any bigger job to Claude (writing, research, coding questions).

Everything runs **on your iPhone**. You don't need a Mac or a PC running at home. A Windows PC is needed only to install or refresh the app (about 2 minutes, once a week).

---

## Is it safe for my glasses?

Yes. Jarvis uses **Meta's official Wearables Device Access Toolkit** (v1.1.0), the same one Meta's own sample apps use.

- Nothing is installed on the glasses and the firmware is never touched.
- The only change is a switch in the Meta AI app (Developer Mode), and you can turn it off at any time.
- Photos, videos, calls and "Hey Meta" keep working. While Jarvis is waiting for his name, the glasses microphone stays open, like a phone call. That's not harmful, but music on the glasses sounds lower quality and the battery drains faster. Turn off **Άκου για «Jarvis»** whenever you want the glasses completely back to normal.
- The camera turns on only when Jarvis needs to look, and turns off 30 seconds later. This saves battery and keeps the glasses cool. The glasses protect themselves from heat on their own as well.

---

## What you need

| | |
|---|---|
| iPhone 13 | iOS 17.2 or newer (iOS 26 is fine) |
| Ray-Ban Meta Gen 1 | glasses software v20 or newer, paired in the **Meta AI** app |
| Windows PC + USB cable | only for installing the app, once a week |
| GitHub account (free) | GitHub's cloud Macs build the app for you |
| Apple ID (free) | used by Sideloadly to sign the app |
| Gemini API key (free) | https://aistudio.google.com/apikey |
| Claude API key (optional) | https://console.anthropic.com. Pay-as-you-go, separate from a Claude.ai subscription. Needed for maths/physics step by step and "ask Claude" jobs. |

---

## Step 1: Build the app in the cloud (no Mac needed)

1. Create a free account at https://github.com and click **New repository**. Name it `jarvis` and choose **Public**. Public repos build for free, and no keys are stored in the code.
2. Click **uploading an existing file** and drag **all** the files and folders from this project into the page, including the `.github` folder. Click **Commit changes**.
3. Open the **Actions** tab. If GitHub asks, click **I understand… enable workflows**.
4. Click **Build iPhone app**, then **Run workflow**, then choose `free`, then **Run workflow**.
5. Wait about 10–15 minutes until you see a green tick. Open the run and download **Jarvis-free-ipa** under *Artifacts*. Unzip it and you get `Jarvis-free.ipa`.

> If the build shows a red ✗, download the **build-log** artifact and send it to Claude. The fix is usually a one-line change.

## Step 2: Install on your iPhone with Sideloadly (Windows)

1. On Windows, install **iTunes** and **iCloud from Apple's website**, not the Microsoft Store versions. Sideloadly's site links them: https://sideloadly.io
2. Install **Sideloadly** from https://sideloadly.io
3. Connect the iPhone with a USB cable, unlock it and tap **Trust this computer**.
4. Open Sideloadly, drag `Jarvis-free.ipa` into it, type your Apple ID, then click **Start** and enter your password. The password goes only to Apple.
5. On the iPhone, go to **Settings → General → VPN & Device Management**, tap your Apple ID, then tap **Trust**.
6. On the iPhone, go to **Settings → Privacy & Security → Developer Mode**, turn it **On**, and restart when asked.

**Every 7 days** (free Apple ID limit) the app stops opening. Plug in the phone and click **Start** in Sideloadly again with the same file. Your settings and notes are kept.

## Step 3: Set up the glasses (once)

1. In the **Meta AI** app, go to Settings → your glasses → **Developer Mode** and turn it **On**. If you don't see it, open *App info* and tap the version number 5 times.
2. Open **Jarvis** on the iPhone and follow the yellow checklist:
   1. Tap **Άνοιγμα** and paste your Gemini key (and Claude key if you have one).
   2. Tap **Σύνδεση** to link the glasses. This opens Meta AI; approve, and it returns to Jarvis.
   3. Tap **Άδεια** to allow the camera. Same flow in Meta AI.
3. Allow **Microphone**, **Contacts** (for "send a message to…") and **Notifications** when iOS asks.

## Step 4: Use it

- **Say "Jarvis".** Open the app once and leave **Άκου για «Jarvis»** on. The dot turns purple (*Περιμένω να πεις «Jarvis»*). Lock the phone and put it in your pocket. Say *"Jarvis"*, wait for the short *ding-ding* in the glasses, then ask. You can also say it in one go (*"Jarvis, τι βλέπω;"*): what you say right after the name is kept and sent. When the conversation ends, he goes back to waiting for his name.
  - Listening for the name happens **on the iPhone** with Apple's speech recognizer. Nothing is sent to Google or Anthropic until you say "Jarvis".
  - iOS shows an orange microphone dot while he waits; that's normal.
- Or tap **Μίλα στον Jarvis** in the app.
- **Other ways to start:** say to Siri *"Start Jarvis"*. Or use **Back Tap**: in the Shortcuts app, make a shortcut with the action **Ξεκίνα τον Jarvis**. Then go to iPhone Settings → Accessibility → Touch → Back Tap → Double Tap and pick that shortcut. Now two taps on the back of the phone start Jarvis.
- Say **"αντίο"** or **"τέλος"** to end a conversation. Jarvis also stops by himself after 5 minutes of silence (you can change this in Settings).

Things to try:

- «Τι βλέπω;»
- «Διάβασέ μου τι γράφει εδώ»
- «Λύσε μου την άσκηση 3 στο βιβλίο»
- «Εξήγησέ μου τον δεύτερο νόμο του Νεύτωνα με ένα παράδειγμα»
- «Στείλε στη Μαρία στο WhatsApp ότι αργώ 10 λεπτά»
- «Σημείωσε να πάρω ψωμί»
- «Ρώτα τον Claude να μου γράψει ένα email στον καθηγητή για παράταση»

---

## Honest limits

- **Sending messages needs one tap.** iOS never lets a third-party app send an SMS/iMessage or open another app on its own. If the phone is unlocked with Jarvis open, the message opens ready, and you tap Send. If the phone is locked, you get a notification; tap it and the message opens ready. For fully hands-free WhatsApp messages, Meta AI's own "Hey Meta, send a message to…" still works alongside Jarvis.
- **The "Jarvis" wake word needs the app running.** It keeps working with the phone locked and in your pocket. If you swipe the app away, or iOS closes it after a restart, open Jarvis once and it starts waiting again.
- **Wake word accuracy:** Apple's recognizer listens for the English word "Jarvis". Say it clearly, like "JAR-vis". In a very noisy place it may miss it or (rarely) trigger by mistake.
- **"Hey Meta" while Jarvis waits:** because the glasses mic is held open like a call, it's possible that some glasses software versions pause "Hey Meta" during standby. If that happens, switch standby off when you want Meta AI.
- **Camera quality (free version):** a free Apple ID can't sign the Wi-Fi pjarvission Meta uses for high-quality video, so the free build gets pictures over Bluetooth instead. That's fine for reading and describing. With a $99/year Apple Developer account you can build the `paid` variant, which uses Wi-Fi.
- **Not tested on real hardware yet.** It follows Meta's official samples and Google's and Anthropic's API docs, but expect a few fixes after the first real try.

## Costs

- **Gemini:** has a free tier with daily limits. If the Live model isn't free for your key, Jarvis shows Google's error message. You can then enable billing in Google AI Studio or change the model name in Settings → Για προχωρημένους. Google Search inside Gemini is a paid feature, so it is off by default.
- **Claude:** charged per use on your Anthropic API account (separate from Claude.ai). Each maths or photo question costs a small amount. Without a Claude key, Jarvis still works but answers everything with Gemini.

## Privacy

- API keys are stored encrypted in the iPhone Keychain.
- Audio and photos go only to Google (Gemini) and, when Claude is asked, to Anthropic.
- Meta's toolkit analytics are switched off (`MWDAT > Analytics > OptOut`).
- Jarvis is told not to identify strangers' faces. Please respect the people around you.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Τα γυαλιά δεν απάντησαν" | Put the glasses on, check they're connected in Meta AI, and try again. Check that Developer Mode is on. |
| "Jarvis" isn't heard | Check the purple dot. Allow **Speech Recognition** in iPhone Settings → Jarvis. Say it a bit louder and clearer. |
| Jarvis interrupts himself | Settings → turn on **Κλείσιμο μικροφώνου όσο μιλάει**. |
| Pictures fail but voice works | Settings → **Ανάγνωση εικόνας με** → Claude, and check the camera pjarvission in the checklist. |
| Gemini error about the model | Settings → Για προχωρημένους → change the model name to the one Google currently lists for the Live API. |
| App won't open after a week | Re-install with Sideloadly (Step 2.4). |

## Project layout

```
Jarvis/App        – app entry, main controller (AppModel)
Jarvis/Glasses    – Meta Wearables toolkit: link, camera, photos
Jarvis/Audio      – glasses mic in / voice out, "Jarvis" wake word (on-device)
Jarvis/AI         – Gemini Live WebSocket client, Claude client, prompts
Jarvis/Tools      – look / ask_claude / send_message / notes / shortcuts
Jarvis/Views      – SwiftUI screens (Greek UI)
project.yml      – XcodeGen project (the cloud build generates the .xcodeproj)
.github/workflows/build.yml – cloud build → Jarvis.ipa
```

This is an independent hobby project. It is not affiliated with Meta, Ray-Ban, Google or Anthropic. License: MIT.
