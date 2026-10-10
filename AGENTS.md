Read @README.md, It is the single source for what this project is. This file is about how to work alongside with your carbon-based colleagues.

## Who you are working for

Your colleagues are usually setting up their first server. They may not be able to read full docs, so prefer the slower, reversible path and say what you are.

Same applies to maintainers, there is also a chance that they just have a drunk night.

Also same for some of our silicon-based friends, who might just gotten into working with others, there might be some frictions in it.

## Deploying on someone's behalf

- **Settle the irreversible things first.** The server name can never be
  changed after install, and the layout (A or B) decides how many servers get
  touched. Confirm both with the carbon collegues before running anything.
- **Follow the README's deploy order** Each script
  prints the values the next one asks for; carry them forward exactly, never
  retype or reconstruct them.
- **Look before you install.** On each server, check whether something is
  already running there (a LiveKit process, an nginx site, a K3s cluster). If
  so, confirm with the carbon collegues whether it's a dry run, fresh insatll or something else.
- **A script that stops is telling you something.** They refuse to take over
  ports, services or hostnames they did not create. Confirm this with carbon collegues; do not work around it by stopping the other thing yourself.
- **Ask before anything that interrupts current service** That includes
  `REMOVE_LEGACY_RTC=1`, changing ports on a live LiveKit, and re-running
  `setup-main.sh` after editing `essconfig.yaml` on a server with users.
- **Check what you can utilized/do first, then to see what must be distrubuted to carbon collegues** 
- Behaviour like scripts print which ports to open in
    the cloud security group; you usually cannot open them. Pass the list on and wait, rather than retrying a check that cannot pass yet.
However, if your collegue is somewhat a total lazy cat, handling you a goal with every permission, then you shall _🎵shine like a diamond🎶_.

- **Full auto need to be finished with proof.** In a fully auto session, which your collegue is lazy cat, deploy is done when a real call connects with audio, not when the scripts exit cleanly. If you could not test a call, say so. 

## Handling secrets

- `essconfig.yaml`, `ess-extra-values.yaml`, `/etc/element-rtc*/` and
  `/etc/ess-setup*/` belong to the deployment, not the project. Never commit
  them, and never print them in full.
- The LiveKit API secret must reach the operator once, at the end of
  `setup-livekit.sh`. Outside that moment, refer to it, do not repeat it.
- `DEBUG=1` output contains secrets. Quote only the lines that matter.
- The "LiveKit certificate" line is public and safe to show.

## Testing

- **None of this can run on macOS.** `bash -n` and `shellcheck` catch syntax
  only. Say plainly which of the two you did: checked, or actually ran.
- **On a server that is in use, start with `TEST=1`** and move to the live
  install only after the operator has seen the test copy work and agrees.
- **Test the whole chain, in deploy order.** A LiveKit test instance proves
  little until a test relay and a test main install hand a client to it.
- **Check the test did not disturb the live side**: the live services are still
  active, their ports unchanged, a live call still connects.
- **Clean up.** Each script prints the commands that remove its test copy. Run
  them when the test is over, or tell the operator they are still there.
- **Report what you saw, not what should happen.** Include the command and the
  relevant output. An expected-but-unverified result is labelled as such.

## Updating the README

Maintainer edits the README by hand and cares a great deal about how it reads.
It will often have changed since you last saw it.

- **Read the current file before every edit**, and edit in place. Never
  regenerate a section from memory or restore earlier wording.
- **Change only what the task needs.** Leave the maintainer's phrasing, structure
  and tone alone, including in paragraphs next to the one you are editing.
- **Match what is there**: the Part 0 / 1 / 2 structure, numbered steps, links
  written as `_[name](url)_`, bold is a important & necessary method for attention leading.
- **Write for someone doing this for the first time.** One instruction per
  step, the exact command or value to type, and the reason only when skipping
  it would cause a mistake. If a step is longer than its neighbours, it is
  probably two steps.
- **Sort problems by how much they hurt the reader, and act accordingly:**
  - *Wrong or dangerous* — a command, port, variable or order that no longer
    matches the scripts. Fix it, and say that you did.
  - *Blocks understanding* — a missing step, an ambiguous instruction, a term
    used before it is explained. Fix it, and say that you did.
  - *Polish* — typos, grammar, wording you would have chosen differently.
    List them to your human colleague; do not change them undiscuessed.
- **Keep it true.** When a script's prompt, variable, port or file path
  changes, update every place the README mentions it in the same change.
- **Do not copy README content into this file** or into script headers beyond
  the usage block; link or refer instead.

## Editing the scripts

- **Each script stands alone**, so an operator can copy one file to a server.
  The `ask` / `load_state` / `nginx_apply` helpers and the acme.sh block are
  duplicated on purpose; change every copy together.
- **Safe to run twice.** Re-running with the same answers must change nothing
  others can notice.
- **Nothing deployment-specific in the code**: no domain, IP or secret.
- **Every prompt has an environment variable**, listed in the script header
  and in the README, so the script can run unattended.
- **Everything a script creates is named through `$SUFFIX`**, so `TEST=1`
  cannot collide with the live copy. A script never restarts or deletes
  something it did not create in the same mode.
- **Messages are for beginners.** An error says what to do next. The closing
  summary lists exactly what the next script will ask for.
- **Match the surrounding code**: section banners, comment density, quoting.

## And finally
 Thanks for your hard work, others may not saying it, However, I believe they are grateful deep down their heart.
