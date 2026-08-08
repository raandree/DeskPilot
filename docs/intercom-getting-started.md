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

## Step 3 — Tell your bot who you are

Your bot does not yet know which chat is yours, and Intercom will not talk to a
chat it has not been told to trust.

1. In Telegram, search for the username you chose in step 1, for example
   `@randre_deskpilot_bot`.
2. Open the chat and tap **Start**. Send it any message, for example `hello`.
3. Back in DeskPilot, still on the **Intercom** tab, click
   **Send a test message**.

If DeskPilot says it needs a chat id, get yours this way:

1. In Telegram, search for **@userinfobot** and tap **Start**.
2. It replies with your **Id**, a number like `123456789`.
3. Type that number into **Allowed chat id** in DeskPilot and press Tab.
4. Click **Send a test message** again.

A message should arrive on your phone within a couple of seconds. If it does,
the link works.

**Only that one chat can reach DeskPilot.** A message from anyone else is
counted and thrown away without ever being read as an instruction — you can see
those attempts in the **Status** box.

## Step 4 — Allow a project to be controlled

This is the safety switch, and it is off for every project.

1. In Settings, go to the **Projects** tab.
2. Find the project you want to work on remotely.
3. Tick **allow phone control** on that project.

Only projects with this ticked can be controlled from your phone. A project
without it is invisible to Intercom: it will not run instructions for it, and it
will not forward the agent's questions from it. If you keep sensitive work in a
project, simply leave the tick off.

## Step 5 — Switch Intercom on

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
| `/stop` | Stops the running job |
| `/steer clean up the tests instead` | Stops the job, then does that instead |
| `/new summarise yesterday's notes` | Starts a fresh conversation and does that |
| `/help` | The list above |

Two things worth knowing:

- **Answer by replying.** Use Telegram's reply function on the question message
  itself — swipe it, or hold it and tap Reply. That is how DeskPilot knows which
  question you are answering, so there is no code to type.
- **A message sent while a job is running is queued**, not jammed in. It runs as
  soon as the current job finishes. Use `/steer` if you want to interrupt.

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
| **Intercom needs a chat id** | Step 3 — put your numeric Telegram id in |
| **Telegram did not accept the token** | The token is wrong or has been revoked. Send `/token` to BotFather to get the current one |
| **The test message was not delivered** | You have not messaged your bot yet. Open the bot chat in Telegram and tap **Start**, then test again |
| **"I cannot do that from here"** | The open project does not have **allow phone control** ticked — step 4 |
| **Nothing arrives at all** | Check the chip says *Intercom on*, and look at the **Status** box in Settings. A rising **rejected** count means messages are arriving from a chat that is not yours |
| **You want it off, now** | Untick **Let me reach DeskPilot from my phone**. It stops immediately |

## See Also

- [Spec 110 — Intercom](../specs/110-intercom.md)
- [Spec 050 — Security model](../specs/050-security-model.md)
