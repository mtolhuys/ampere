# Changelog

## 0.2.0

- Notifications you can tune: a minimum turn length (30 s by default, so
  quick turns stay quiet), quiet hours, and nothing while the panel is open.
- A bell in the panel header (`b`) cycles on, snoozed for an hour, off.
- Mute a single thread's notifications from its row (`q`).
- IPC: notifications, snooze <minutes>, mute, unmute.
- Ask Amp prompts never appear in a process's command line: the helper gets
  them in its environment, background and orb asks pipe them into `amp -x` on
  stdin, and a terminal ask reads them from a 0600 file in the runtime
  directory that it deletes before it starts Amp.

## 0.1.0

First release.

- Bar icon that glows and pulses while Amp threads work, with a count badge.
- Panel: live-current oscilloscope, agent usage and orb hours on pace, recent
  threads with continue, open, copy link, copy Markdown, rename, archive and
  delete, search, Ask Amp (terminal, background or orb) with directory, mode
  and Fast, and a toolbox of Amp commands.
- Color from the active theme's own palette: a wave and dot per working
  thread, project hues, pace-colored meters, colored modes, routes and tools.
- Notification when a working thread finishes a turn; several at once arrive
  as one.
- Background asks run detached with the session's PATH and survive a shell
  restart.
- IPC: toggle, ask, search, resume, newThread, top, refresh, working.
- Works on stock Omarchy 4.0.4 and current omarchy-dev, on horizontal and
  vertical bars, in dark and light themes.
