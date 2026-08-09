# Getting started with Intercom

Intercom lets you reach DeskPilot from your phone. When the agent needs an
answer, finishes a job, fails, or goes quiet, it messages you on Telegram — and
you can reply to answer it or give it a new instruction, without a remote
desktop session.

This guide takes about ten minutes and assumes nothing. Follow it in order.

## Before you start

You need three things:

- DeskPilot running on the machine that does the work.
- Telegram installed on your phone, with an account.
- Five quiet minutes. Do not do this while a long job is running.

**Read this first.** A message from your phone can tell the agent to do
anything it is allowed to do on the machine — including changing files, running
commands, and publishing your work to a server. That is the point of the
feature, and it is why every step below matters. Intercom is off until you
switch it on, and stays off for every project until you allow that project
individually.

## Step 1 — Create your bot

A "bot" is a Telegram account DeskPilot speaks through. You create it inside
Telegram, on your phone, in about six taps.

1. Open Telegram and search for **@BotFather**. It has a blue verified tick.
2. Open the chat and tap **Start**.
3. Send `/newbot`.
4. It asks for a name. Type anything you like, for example `My DeskPilot`.
5. It asks for a username. It must end in `bot`, for example
   `randre_deskpilot_bot`. If the name is taken, try another.
6. BotFather replies with a message containing a line like:

   ```text
   123456789:AAHrandomlettersandnumbershere
   ```

   That is your **bot token**.

**The token is a key to your machine.** Anyone who has it can send messages as
your bot. Do not paste it into a chat, an email, a screenshot, or a support
ticket. If you ever think it has leaked, send `/revoke` to BotFather — that
invalidates it instantly, and Intercom stops working until you paste in the new
one.

## Step 2 — Give the token to DeskPilot

1. On the machine, open DeskPilot.
2. Click the **⚙ Settings** button at the bottom of the left sidebar.
3. Choose the **Intercom** tab.
4. Paste the token into **Bot token** and click **Save token**.

The field clears itself immediately. DeskPilot stores the token encrypted for
your Windows account, in its own file — never in your settings file — so a
settings backup can never carry it. It is never shown again, and never sent back
to the browser.

## Step 3 — Link your phone

Your bot does not yet know which chat is yours, and **Intercom will not reply to
a chat it has not been told to trust — not even to `/start`.** That is by design:
until you finish this step, your bot will stay silent no matter what you send it.
DeskPilot can find the number for you.

1. In DeskPilot, still on the **Intercom** tab, click **Link my phone**.
   It starts listening for five minutes.
2. In Telegram, search for the username you chose in step 1, for example
   `@randre_deskpilot_bot`. Open the chat and tap **Start**, or just send it
   anything — `hello` will do.
3. Within a second or two, DeskPilot lists the message it saw, with the sender's
   name. Click **This is me** next to yours.

That is the link made. DeskPilot fills in the chat id, closes the window, and
your bot starts answering.

If you would rather type the number yourself, send `/start` to **@userinfobot**
in Telegram — it replies with your **Id** — and paste that into the box under
the Link button.

**Only the chat you confirmed can reach DeskPilot.** A message from anyone else
is counted and thrown away without ever being read as an instruction — you can
see those attempts in the **Status** box. DeskPilot never adopts a chat on its
own: the click has to happen at the machine, so nobody who guesses your bot's
username can link themselves.

## Step 4 — Check it works

Click **Send a test message**. A message should arrive on your phone within a
couple of seconds. If it does, the link works.

## Step 5 — Allow a project to be controlled

This is the safety switch, and it is off for every project.

1. In Settings, go to the **Projects** tab.
2. Find the project you want to work on remotely.
3. Tick **allow phone control** on that project.

Only projects with this ticked can be controlled from your phone. A project
without it is invisible to Intercom: it will not run instructions for it, and it
will not forward the agent's questions from it. If you keep sensitive work in a
project, simply leave the tick off.

## Step 6 — Switch Intercom on

Back on the **Intercom** tab, tick **Let me reach DeskPilot from my phone**.

Your phone gets a short "Intercom is on" message, and the **📻 Intercom on**
chip appears at the top of the DeskPilot window. You are done.

## Using it

Start a job in DeskPilot as normal, then walk away. From your phone:

| What you send | What happens |
| --- | --- |
| **Reply** to a question message | Answers that question; the agent carries on |
| Any other message | The agent treats it as a new instruction |
| `/status` | What is happening right now |
| `/chats` | Lists your conversations, newest first, and marks the one you are in |
| `/chat 2` | Switches to conversation 2 from that list |
| `/archive 2` | Hides it from the list (it stays in DeskPilot under **Show archived**) |
| `/delete 2` | Removes it for good — asks you to confirm first |
| `/new` | Starts a fresh conversation and switches to it |
| `/new summarise yesterday's notes` | Starts a fresh conversation and does that |
| `/stop` | Stops the running job |
| `/steer clean up the tests instead` | Stops the job, then does that instead |
| `/help` | The list above |

Three things worth knowing:

- **Answer by replying.** Use Telegram's reply function on the question message
  itself — swipe it, or hold it and tap Reply. That is how DeskPilot knows which
  question you are answering, so there is no code to type.
- **A message sent while a job is running is queued**, not jammed in. It runs as
  soon as the current job finishes. Use `/steer` if you want to interrupt.
- **The agent cannot switch conversations itself.** If you ask it to, it will say
  so — it has no way to see or change which conversation it is in. Use `/chats`
  and `/chat 2`, which are handled by DeskPilot rather than the agent.
- **Editing a message does not resend it.** If you fix a typo in a command you
  already sent, DeskPilot will reply *"I did not run that"* — send it again as a
  new message instead. Edits are deliberately never acted on, because Telegram
  delivers them as fresh updates and a command that already ran could otherwise
  run again with different text.
- **Watch it from the machine too.** While a job you started from your phone is
  running, the DeskPilot window marks that conversation with 📻 and shows the
  answer being written — including the model's thinking when that is switched on.
  No page refresh needed.

## The status message, and what silence means

DeskPilot keeps **one** status message in your chat and quietly updates it as it
works. It never notifies you, so it costs nothing to leave running. It always
ends with a line like:

```text
Next check-in by: 14:35:10 - if this time has passed, DeskPilot has stopped.
```

**This is the most important line in the whole feature.** Read it this way:

- The time is in the future → DeskPilot is alive and working.
- The time has passed → DeskPilot has stopped. The machine may have gone to
  sleep, lost its network, lost power, or been shut down.

DeskPilot cannot message you about those things, because there is nothing left
running to send the message. It tells you when it stops *cleanly* — closing the
window, or restarting for an update — but a power cut or a lost connection can
only ever look like silence. The check-in time is how you tell the difference.

## Before you walk away — a checklist

- The **📻 Intercom on** chip is showing in DeskPilot.
- The project you are working in has **allow phone control** ticked.
- You received the test message on your phone.
- The machine is set **not to sleep**. Intercom lives inside DeskPilot; if the
  machine sleeps, everything stops.
- The DeskPilot window stays open. Closing it turns Intercom off.

## What Intercom does not do

- **It does not cover VS Code.** Jobs you started with Copilot inside VS Code
  run in a different program that DeskPilot cannot see, interrupt, or answer for.
  Only jobs running in DeskPilot are covered.
- **It is one person only.** Exactly one Telegram chat, and no way to add a
  second.
- **It does not survive DeskPilot closing.** No background service is installed
  and nothing keeps running when you close the window.
- **It has no timed lock-out.** If your phone is lost or stolen while unlocked,
  whoever has it can control DeskPilot until you revoke the token. To cut it off
  from any other device: open Telegram, message **@BotFather**, send `/revoke`,
  and choose your bot.

## If something is not working

| What you see | What to do |
| --- | --- |
| **Intercom needs a token** | Step 2 — paste the token from BotFather |
| **The bot never answers, not even `/start`** | Your phone is not linked yet. Intercom deliberately ignores every chat until you confirm one — do step 3 |
| **Intercom: link your phone** | Same thing — click **Link my phone** and send your bot a message |
| **Listening… but nothing appears** | Make sure you are messaging *your* bot (the username you chose in step 1), not BotFather. The window closes after five minutes; click **Link my phone** again |
| **Telegram did not accept the token** | The token is wrong or has been revoked. Send `/token` to BotFather to get the current one |
| **The test message was not delivered** | You have not messaged your bot yet. Open the bot chat in Telegram and tap **Start**, then test again |
| **"I cannot do that from here"** | The open project does not have **allow phone control** ticked — step 5 |
| **Messages you sent before linking did nothing** | Expected. DeskPilot throws away anything that arrived while it was not listening, rather than acting on an hour-old instruction. Send it again |
| **A rising "rejected" count** | Messages are arriving from a chat that is not yours. Nothing was executed, but it is worth knowing |
| **You want it off, now** | Untick **Let me reach DeskPilot from my phone**. It stops immediately |

## See Also

- [Spec 110 — Intercom](../specs/110-intercom.md)
- [Spec 050 — Security model](../specs/050-security-model.md)
