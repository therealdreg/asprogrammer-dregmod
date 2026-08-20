# What this fork changes

AsProgrammer dregmod is a fork of
[nofeletru/UsbAsp-flash](https://github.com/nofeletru/UsbAsp-flash).
This file tracks what is different and why, so that a change can be traced back
to a reason and so that future upstream work can be merged without guessing.

The user facing summary of a release lives in the CHANGELOG at the end of
[README.md](README.md). This file is for whoever has to maintain the code.

## Regenerating this comparison

Everything below was derived by diffing against an upstream checkout, ignoring
whitespace and line ending noise:

```
diff -u -w --strip-trailing-cr UsbAsp-flash/software/main.pas software/main.pas
```

To see the whole picture at once:

```
for f in UsbAsp-flash/software/*.pas UsbAsp-flash/software/*.lfm; do
  b=$(basename "$f")
  n=$(diff -u -w --strip-trailing-cr "$f" "software/$b" | grep -cE '^[+-][^+-]')
  [ "$n" -gt 0 ] && printf "%-18s %6s lines\n" "$b" "$n"
done
```

## Scope

| | |
| --- | --- |
| New units | `software/buzzpirathw.pas`, `software/buspirate5hw.pas`, `software/dregstr.pas` |
| Substantially changed | `main.pas`, `main.lfm` |
| Lightly changed | `spi25.pas`, `sregedit.pas`, `scriptsfunc.pas`, `findchip.pas`, `basehw.pas`, `findchip.lfm`, `AsProgrammer.lpi` |
| Identical to upstream | 29 of the 38 shared files, including **every other programmer back end** |
| Byte identical | `chiplist.xml` |
| Added at the root | `.gitignore`, `.github/`, `assets/`, `software/tests/` |
| Removed vs upstream | the tracked `settings.xml` |
| Removed vs earlier dregmod releases | `software/buzzpirathlp/`, `buzzpirathlp.dll`, `tail.exe` |

**The fork does not touch any other programmer.** `arduinohw.pas`,
`avrisphw.pas`, `ch341hw.pas`, `ch347hw.pas`, `ft232hhw.pas` and `usbasphw.pas`
are byte for byte upstream, and so are `i2c.pas`, `microwire.pas`, `msgstr.pas`,
`spimulti.pas` and the whole Synapse tree. `spi45.pas` and `spi95.pas` are
identical in content but were rewritten with different line endings, so they
compare equal only once those are ignored. Upstream changes to any of these
merge cleanly. All the reconciliation work in a future merge is in `main.pas`
and `main.lfm`.

Counted precisely: of the 38 files present in both trees under `software/`
(units, forms, the program file, the include and the project file), 29 are
identical once line endings are ignored and 27 of those are byte identical.

`basehw.pas` gains two enum values and nothing else, so the `TBaseHardware`
contract is unchanged and no existing back end needed a single edit.

---

# New: two Bus Pirate drivers

## `buzzpirathw.pas`, Bus Pirate v3.x and Buzzpirat

Speaks the device's binary I/O protocol (BBIO) directly from Pascal, in three
layers: the serial port on top of Synapse, the protocol engine, and the
`TBaseHardware` back end. It replaces `buzzpirathlp.dll`, a C DLL this fork
deleted along with its Visual Studio project, its log file and the `tail.exe`
console window it used to open.

Things it does that are worth knowing about:

- **Bitbang entry is paced one byte at a time.** The PIC24 polls a four byte
  UART FIFO with no interrupt buffer, so more than four bytes of backlog while
  it is bit-banging latches an overrun error that only the user terminal
  clears. There is also an escape sequence for a terminal left stuck inside a
  configuration submenu.
- **The link has an explicit out of sync state.** Any short or late reply means
  the device is still talking and its bytes would be read as the next command's
  answer, so the driver refuses to send anything until it has drained the line
  and re-armed the mode.
- **The session is kept alive between operations** and only verified with a
  short round trip, which is what makes reads and writes fast. There is a menu
  option to reset the device after every operation instead.
- **Two different SPI clock index tables**, chosen from the device banner. The
  real v3 firmware indexes its own twelve entry table, whose order stops
  matching the BBIO documentation above 1 MHz. A Bus Pirate v5 or newer running
  the legacy emulation decodes the documented order instead and accepts only
  indices 0 to 7, so a PIC index of 9 or 11 is not merely the wrong clock
  there: it falls outside the range, is taken as a peripheral command, and
  switches the target supply on while leaving the clock unset.

It does not support Microwire. Neither does the BPIO2 driver.

## `buspirate5hw.pas`, Bus Pirate v5, v6 and v7

Speaks BPIO2: FlatBuffers packets inside COBS frames on the device's second USB
serial interface. The requests are built from fixed byte templates patched in
place rather than by a FlatBuffers library, and the responses go through a
generic vtable decoder written to survive a malformed frame.

It carries guards for three firmware behaviours found by reading the firmware
source and confirmed on hardware:

- A read larger than the advertised maximum corrupts the firmware's own
  response builder, so oversized transfers are split by the driver and never
  reach the device.
- A contents type of zero calls a null handler and reboots the device.
- Every I2C error path returns before the firmware's cleanup label, so a failed
  transfer leaves the bus held and the next request fails too. The driver
  releases it explicitly.

Port discovery reads the USB registry to work out which of a device's two
serial ports carries BPIO2 and which is the user terminal, and labels the menu
accordingly. It is used only for labelling, so a machine where the lookup finds
nothing still gets a complete and usable port list.

---

# Fixes to upstream behaviour

These are the entries a maintainer most needs to know about, because they change
what the program does on hardware that has nothing to do with the Bus Pirate.

## Uninitialised memory shown as chip data

**The status register editor and Read SREG printed whatever was on the stack.**
`sreg2` and `sreg3` are ordinary locals that were only written for Macronix and
Winbond parts, so on any other chip, and on any failed read, the leftover stack
bytes were painted into the checkboxes and logged as the chip's status.
`UsbAsp25_ReadSR` returns a byte count and nobody looked at it. All three are
now initialised and the first read is checked.

## Memory safety

**The page size box could smash a stack buffer.** `ComboPageSize` is an editable
combo, and its value indexes fixed 2048 byte stack arrays in `WriteFlash25`,
`WriteFlash95`, `WriteFlash45`, `WriteFlashKB`, `EraseEEPROM25`,
`WriteFlashI2C`, `EraseFlashI2C`, `ReadFlash45` and `VerifyFlash45`. Upstream
checked only the lower bound, so typing 4096 and pressing Program IC made
`ReadBuffer` write past the end of the array. There is now a single
`PageSizeFromUI` that every call site goes through, and it says in the log when
it has to clamp.

## Data integrity

**A failed chunk could end up in your dump.** `ReadFlash25`, `VerifyFlash25`,
`ReadFlashI2C` and `VerifyFlashI2C` added the transfer's return value, which may
be negative, straight into the byte count and used the buffer regardless. The
consequence differs by path: the two read paths wrote the *previous* chunk's
contents into the image, a plausible looking duplicate that nothing downstream
can tell from real data, while the two verify paths compared against a stale
buffer and could therefore pass or fail for the wrong reason. All four now check
the count before touching the buffer. `ReadFlash95`, `ReadFlash45`,
`ReadFlashKB` and the Microwire read still carry the upstream pattern.

**Writes above 16 MB wrapped to the wrong address.** The choice between three
and four byte addressing was made from the transfer size alone, so writing or
verifying a small buffer high up a 32 MB chip used three address bytes and the
address wrapped to a low location. Verify carried the same bug, so it wrapped to
the same place and confirmed the wrong data. Both now decide from the highest
address the pass actually touches.

**A chip could be left latched in four byte mode.** `EX4B` was called after the
loop, which every early exit skipped. The mode survives chip select and a device
close, so it poisons every later operation until the part is power cycled. The
calls are now in `try ... finally`. Separately, `UsbAsp25_EN4B` writes the
Spansion bank register as well as sending the opcode, and `UsbAsp25_EX4B` never
cleared it; on those parts the bank register bit is the mechanism, so `EX4B` now
mirrors the enter sequence.

**The write time read back could pass a page that was never programmed.** With
the auto check option on, a failed read back left the comparison buffer holding
the previous page, which could compare equal. It now checks its byte count and
uses the same addressing width as the write.

**A read from a non-zero start address always reported failure.** The final byte
count was compared against the chip size while the loop only covers
`StartAddress` to the end, so any non-zero Start Address ended in a spurious
"wrong number of bytes read" instead of "Done".

## Hangs

**A dead link looked exactly like a busy chip.** `UsbAsp25_Busy` seeds the
status byte with `$FF` and ignores the read result, so a link that will never
answer reads as permanently busy and the interface spins at full speed for ever.
Reporting "ready" instead would be worse, because an erase or a page program
would carry on against a chip still mid cycle and finish with "Done". There is
now a `UsbAsp25_WaitReady` that fails on a link error, and every open coded busy
loop in `main.pas` and `sregedit.pas` goes through it.

**I2C acknowledge polling had no bound.** A page write waits for the chip to
stop refusing its address, and a dead transport is indistinguishable from a busy
chip at that level. Both the write and the erase loop now give up after five
seconds per page, which is thousands of times longer than an EEPROM page write.

**A page aligned start address wrote nothing, for ever.** The first chunk of a
write is trimmed so it does not cross a page boundary. Upstream computed that
from the chip size rather than the offset into the page, which evaluates to zero
for any page aligned non-zero start address, so the page size became zero,
nothing was written, and the address never advanced.

## Reachability and lifetime

**Menu clicks landed in the middle of transfers.** The flash loops pump the
message queue, so upstream a click during a read could close the port under it,
re-enter the driver, change the COM port or rewrite the buffer the write loop
was reading from. The menus that can reach the device are now disabled while an
operation runs, and so are the two modeless windows, the status register editor
and the script editor, which stay clickable otherwise and reach the device
through their own `OpenDevice` and `DevClose` calls.

**The script runner never released anything.** It opened the device and returned
without closing it or unlocking the interface, so the port stayed held, the
target stayed powered, and the toolbar stayed live enough to start a second
operation on top of the first. The benchmark did release on its normal path;
what it lacked was a `try ... finally`, so an early exit leaked the same way.

**A missing chip script returned an unassigned function result.**
`GetScriptSectionsFromFile` exited before creating its result when the script
file was not there, so the caller received whatever was in that register, used
it as a `TStrings` and freed it. Selecting a chip whose script is missing is
enough to reach it.

**The I2C bus scanner reported 112 devices on a dead bus.** The v3 firmware's
binary write path discards the return value of its own start condition, while
its interactive path checks it and warns about pull-ups. With the bus held low,
typically because the Vpullup pin is not fed, the address byte is clocked with
no start, the grounded line reads back as an acknowledgement, and every address
looks present. The scanner now recognises an all-address answer for what it is.

**A Microwire failure was ignored.** `MWInit` returns a boolean and three of its
four call sites discarded it, so a Microwire write, verify or erase carried on
against an uninitialised bus and reported whatever came back. Upstream already
checked it on the read path.

**`SetSPISpeed` could return an uninitialised value.** There was no branch for
the CH341a, so the local was read uninitialised and a garbage clock index went
to `SPIInit`.

---

# New features

| | |
| --- | --- |
| Bus Pirate v3.x and Buzzpirat support | its own menu, in tree, no DLL |
| Bus Pirate v5, v6 and v7 support | its own menu, BPIO2 protocol |
| Live COM port menus | rebuilt from the ports the machine reports, on a timer |
| I2C bus scanner | an address map, a guess at each part, and a button that copies the address into the settings |
| Fill the hex editor with random data | Ctrl+R, for write and read back testing |
| Device info windows | firmware and hardware version, and on Buzzpirat firmware the rail voltages and a supply short check |
| Serial link speed for the v3.x | negotiated through the firmware's own terminal menu, with flashrom's rules for when it is not safe to raise |
| Settings persistence | everything both new back ends need is saved in `settings.xml` |

## Translation

The interface this fork added is translatable, and there is a test that proves
it: `software/tests/i18ncheck.lpr`, which needs no hardware.

Two mechanisms are involved and it matters which is which. Form captions are
translated by `TPOTranslator.UpdateTranslation`, which looks up
`tmainform.<component>.<property>` in the active `.po`, so they need an entry in
the language files and nothing else. Text built in code is translated by
`TranslateResourceStrings`, so it has to be a `resourcestring`.

Both were missing. Every caption this fork added, and a number of upstream ones,
had no entry in any of the twelve language files, and the strings built in code
were plain literals. 99 entries were added to every `.po` and to the `.pot`, and
the code built strings moved into `software/dregstr.pas`.

`dregstr.pas` is a separate unit rather than additions to `msgstr.pas` on
purpose: `msgstr.pas` is still byte for byte upstream and should stay that way.

Two things are worth knowing before touching this again:

- **`lazbuild` does not regenerate the `.pot`.** Neither the form captions nor
  the resourcestrings appear there after a command line build. Only a build
  inside the Lazarus IDE extracts them, which is why the entries were written by
  hand in the shape the IDE produces. `EnableI18NForLFM` is now set so the IDE
  picks up captions as well as resourcestrings.
- **An empty `msgstr` falls back to the `msgid`**, which is what an untranslated
  language should show. But an entry whose `msgid` is *also* empty makes
  `TPOFile.Translate` raise, at the moment the user picks that language. Never
  write one.

What is deliberately left in English: the protocol diagnostics in both drivers,
the device report field labels, the hexadecimal header of the I2C grid, and the
tokens written into `settings.xml`, which would break saved settings if a
translation changed them.

---

# Behaviour changes

- **The default programmer is the Bus Pirate**, not UsbAsp. A saved
  `settings.xml` still wins.
- **The default language is English**, not Russian.
- **Switching programmer now disconnects the one you left**, which parks its
  pins and drops the target supply.
- **The chip search window is always on top**, and search hits are echoed to the
  main log.
- The window title is `AsProgrammer dregmod v5`.

---

# Removals

- `software/buzzpirathlp/`, the C DLL project, and the built
  `buzzpirathlp.dll`. Everything it did is now in `buzzpirathw.pas`.
- `tail.exe` and the console window the DLL used for logging. Use the **Verbose
  log** menu item instead.
- The "Fix SPI Firmware Bug" checkbox. It worked around a bug some Community
  Firmware builds have in the binary SPI mode. Install a firmware without the
  bug instead.
- The "List FREE COM Ports" menu, replaced by the live port list.
- A tracked `settings.xml`. The defaults now come from the code, and the file is
  in `.gitignore` so a working copy cannot leak one into a release.

---

# Test tooling

`software/tests/` has no upstream equivalent. It exists because the claims this
fork makes about reliability need evidence rather than opinion. See
[software/tests/README.md](software/tests/README.md) for how to run it.

| program | what it proves | needs |
| --- | --- | --- |
| `i18ncheck.lpr` | that the interface can be translated, that no language file can crash the program, and that the language files are well formed | nothing, it needs no hardware |
| `bp_stress.py` | the BBIO protocol itself, independently reimplemented in Python, so a pass is about the wire and not about our Pascal | a v3.x or Buzzpirat, an SPI flash |
| `bp3probe.lpr` | the shipping BBIO engine in `buzzpirathw.pas`, driven directly | the same |
| `bp3clocks.lpr` | that every entry of the v3 SPI clock menu maps to the right firmware index, on both the real hardware and the v5+ legacy emulation | either device, an SPI flash |
| `bp5probe.lpr` | the shipping BPIO2 engine: COBS, the encoder, the decoder, transfer sizes, a soak, and recovery from garbage on the wire | a v5 or newer, an SPI flash. The COBS checks need no hardware |
| `asprog_spi.lpr` | AsProgrammer's own erase, write, read and verify paths, by calling the button handlers | a v5 or newer, an SPI flash |
| `asprog_i2c.lpr` | the same for I2C, on either back end | an I2C EEPROM |

The harnesses link the real units and call the real button handlers, so they
exercise the shipping code rather than a copy of it. They also apply the
language the way `AsProgrammer.lpr` does, because a harness with its own
startup does not otherwise reach `Translate` and would be testing an
untranslated program no user ever sees. They carry negative
controls on purpose: the hex editor is poisoned with the complement before every
read back, so a read that silently does nothing cannot look like one that
worked, and the verify tests flip a byte and require the verify to catch it.

The strongest single result in there: the same 8388608 bytes read through two
unrelated protocols by two independent implementations produced the same
SHA-256.

---

# Things a merge should watch

Honest notes, including where this fork is inconsistent.

- **`main.pas` and `main.lfm` are where all the conflict is.** Nothing else has
  enough change to be difficult.
- **`main.lfm` is hand edited.** Opening the form in the Lazarus designer will
  reorder properties and can disturb the translation system. Prefer editing the
  file directly, which is why the new blocks use tab indentation and
  non-designer property order.
- **`ReadFlash25` still picks its addressing width from the chip size**, while
  the write and verify paths pick it from the highest address touched. That is
  correct for a full chip read but it is a different rule, and the two should
  probably be reconciled.
- **`UsbAsp25_WaitReady` has no timeout.** It ends on a link failure or on
  cancel, which is a large improvement on spinning for ever, but a chip that
  answers and never becomes ready still waits indefinitely.
- **`UsbAsp25_Busy` is still exported and has no callers left** in this fork. It
  is upstream API and chip scripts can reach it, so it was left in place rather
  than removed.
- **The short read guard was only applied to four of the read paths.**
  `ReadFlash95`, `ReadFlash45`, `ReadFlashKB` and the Microwire read still add a
  possibly negative transfer result into the byte count and use the buffer
  regardless, exactly as upstream does. Nothing in this fork exercises them, but
  they are the same bug.
- **The walkthrough screenshots predate this version.** They show the older menu
  name and the old port list.
- **SST parts are only half covered.** Reading, verifying and a full restore
  were proven on an SST25VF080B, which is what exercises the AAI write path, but
  repeated write cycles were not: two bytes per command over a serial link means
  hours per pass on a part that size.
- **No chip above 16 MB has ever been on the bench**, so the four byte
  addressing paths are still only reviewed, not run.
