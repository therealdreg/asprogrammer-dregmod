# Bus Pirate link tests

By Dreg

https://github.com/therealdreg/asprogrammer-dregmod

Six programs, in two tiers.

**Tier one reimplements the protocol independently.** `bp_stress.py` speaks BBIO
in Python without touching a line of this project's Pascal. When it and the
driver agree, that agreement means something, because two unrelated
implementations had to be wrong in the same way to fake it.

**Tier two links the shipping code.** The five Pascal harnesses compile against
the real units and, in two cases, build the real form and call the real button
handlers. They test what users run, not a copy of it.

| program | what it drives | needs |
| --- | --- | --- |
| `bp_stress.py` | BBIO, reimplemented in Python | a Bus Pirate v3.x or Buzzpirat, an SPI flash |
| `bp3probe.lpr` | `TBusPirate` in `buzzpirathw.pas`, directly | the same |
| `bp3clocks.lpr` | the SPI clock menu to firmware index mapping | either device, an SPI flash with real content |
| `bp5probe.lpr` | `TBusPirate5` in `buspirate5hw.pas`, directly | a Bus Pirate v5 or newer, an SPI flash. The COBS checks need no hardware |
| `asprog_spi.lpr` | AsProgrammer's own erase, write, read and verify | a Bus Pirate v5 or newer, an SPI flash |
| `asprog_i2c.lpr` | AsProgrammer's own I2C paths | an I2C EEPROM, either back end |
| `i18ncheck.lpr` | that the interface can be translated and that no language file can crash the program | nothing at all |

Build the Pascal ones with the matching `build_*.cmd`, run from the `software`
directory. They reuse the units Lazarus leaves in `lib\i386-win32`, so build
AsProgrammer first.

**Close AsProgrammer before running any of them.** Only one program can hold a
serial port.

They apply the language the same way the program does. A harness has its own
startup and so never reaches the `Translate` call in `AsProgrammer.lpr`, which
meant they used to run untranslated and test a state no user ever sees. Two
things came out of fixing that: every dialog and log line now matches what a
user reads, and a bug in a translated string can actually be caught.

# i18ncheck - can the interface be translated?

The only program here that needs no hardware, so it is also the one to run first
when something looks wrong.

    tests\build_i18ncheck.cmd
    tests\build\i18ncheck.exe

It builds the five forms the Language menu translates, switches through every
file in `lang`, and checks that nothing raises, that no menu caption goes blank,
that a real translation is applied, and that an untranslated entry falls back to
its English original rather than to nothing.

Then it reads the language files as text and looks for the two shapes that have
actually broken them: an identifier that appears twice, which makes the parser
mark the entry fuzzy and silently refuse a translation it holds, and rubbish
after the closing quote, which ends up inside the caption. Both shipped once
before an audit caught them.

**A .po entry whose msgid and msgstr are both empty crashes the program** at the
moment a user selects that language. That is what this test exists to prevent.

## What none of them cover

No Microwire, because neither Bus Pirate driver implements it. No chip above
16 MB, so the four byte addressing paths are exercised only by reading the code.
No repeated write cycles on an SST part: the AAI path was proven by a full
restore, but at two bytes per command a 1 Mbit chip takes hours per pass.
No unattended regression run: every one of these needs hardware on the bench and
a person to confirm what is connected.

---

# bp_stress.py

`bp_stress.py` drives a Bus Pirate v3.6 / Buzzpirat over its binary I/O (BBIO)
protocol using **exactly the byte sequences `buzzpirathw.pas` emits** - same
opcodes, same 4096 byte bulk limit, same CS framing, same fixed 115200 baud
link. What it proves about the wire is therefore true of the Pascal driver.

It exists to answer one question with evidence instead of opinion: *can this
link lose, duplicate or reorder a byte?*

    pip install pyserial
    python bp_stress.py --port COM22 id

Close AsProgrammer first - only one program can hold the serial port.

## Commands

| command | what it does | writes to the chip |
| --- | --- | --- |
| `id` | JEDEC id, capacity, status registers | no |
| `speeds` | reads one region at all twelve firmware clocks, every result must match a reference taken at 30 kHz | no |
| `limits` | every transfer size around the firmware's 4096 byte buffer, and proves 4097 is refused and recoverable | no |
| `dump FILE` | reads the whole chip to a file, with sha256 | no |
| `compare FILE` | re-reads and compares byte for byte | no |
| `soak` | reads the same region N times; every pass must be identical | no |
| `abuse` | breaks transfers on purpose and proves the link recovers | no |
| `roundtrip` | erase → write random → read back, plus page-crossing writes | **YES** |
| `restore FILE` | writes an image back and verifies it | **YES** |

Options: `--speed 0..11` (firmware clock index), `--region ADDR[:LEN]`,
`--passes N`, `--sectors N`, `--seed N`, `--pullups`, `--no-power`.

Image files are treated as **whole-chip images indexed by absolute address**, so
`compare backup.bin --region 0x7F0000:0x10000` lines the right part of the file
up with the right part of the chip.

Always `dump` before anything destructive. `restore` puts it back.

## Results on the reference rig

Bus Pirate v3.6 (Buzzpirat firmware) → 30 cm dupont wires → Winbond **W25Q64**
(`EF 40 17`, 8 MB, 3.3 V), host link at 115200 baud.

| test | result |
| --- | --- |
| all twelve SPI clocks, 3 passes each | 12/12 identical to the 30 kHz reference |
| transfer sizes 1 … 4096 bytes | 38/38 |
| 4097 byte transfer | refused with `0x00`, link recovered |
| full 8 MB compare at 8 MHz vs a 2 MHz dump | **0 mismatches in 8 388 608 bytes** |
| soak, 5 × 1 MB at 8 MHz | 5/5 identical, 0 short reads, 0 bad acks, 0 resyncs |
| abandoned mid-transfer × 3, truncated header, garbage opcodes | 6/6 recovered |
| erase / random write / read-back, 16 sectors | 32/32 |
| page-crossing and unaligned writes | 8/8, neighbours untouched |

### What the numbers say

**The twelve entry speed table is the real one.** The BBIO documentation
describes `0x60|n` as 30k/125k/250k/1M/2M/2.6M/4M/8M. Measured throughput says
otherwise:

| index | measured | firmware table | BBIO docs |
| --- | --- | --- | --- |
| 0 | 2.6 kB/s | 30 kHz | 30 kHz |
| **4** | **3.6 kB/s** | **50 kHz** | *2 MHz* |
| 1 | 6.0 kB/s | 125 kHz | 125 kHz |
| 2 | 7.7 kB/s | 250 kHz | 250 kHz |
| 3 | 9.6 kB/s | 1 MHz | 1 MHz |
| 6 | 10.0 kB/s | 2 MHz | 2.6 MHz |
| 11 | 10.4 kB/s | 8 MHz | , |

If index 4 were 2 MHz it would saturate the serial link at ~10 kB/s. It gives
3.6, which is 50 kHz. `spi.c`'s `spi_bus_speed[]` wins.

**Above about 1 MHz the UART is the bottleneck, not the SPI bus.** 2 MHz gives
10.0 kB/s and 8 MHz gives 10.4 - a 4% difference, against a theoretical ceiling
of 11.5 kB/s at 115200 baud. There is nothing to gain from the fast clocks and
less noise margin to lose, so 1-2 MHz is the sensible default whatever the
wiring. A full 8 MB read takes about 13 minutes at any clock at or above 1 MHz.

**The 4096 byte limit is exact.** Asking for 4097 makes the firmware answer
`0x00` and drop back to its command loop *without* consuming the payload, which
would then be executed as commands. `BP_MAX_BULK` guards precisely the right
boundary.

**Recovery works.** Abandoning a 4096 byte read leaves exactly 4032 bytes in
flight - the bytes that would otherwise be read as the next command's answer.
Draining until the line goes quiet, then re-entering bitbang and re-arming the
mode, recovers cleanly every time, which is what `TBusPirate.Resync` does.

# bp5probe - the Bus Pirate v5+ (BPIO2) driver

`bp5probe.lpr` is a console program that drives `TBusPirate5` from
`buspirate5hw.pas` directly - the same hand-written FlatBuffers encoder, generic
decoder, COBS and transport the AsProgrammer back end uses. A pass here means
the **Pascal** implementation works on the wire, not merely that it compiles.

    tests\build_bp5probe.cmd            (build AsProgrammer first)
    tests\build\bp5probe.exe            auto-detect and run everything
    tests\build\bp5probe.exe COM19
    tests\build\bp5probe.exe COM19 dump 8388608 chip.bin

The device must be in BPIO2 binmode: on its **terminal** port run `binmode 2`
and answer `y` to "Save setting?". The factory default is the SUMP logic
analyser, which answers on the same port and will not speak BPIO2.

### Results on the reference rig

Bus Pirate **6 REV2** (firmware Aug 2026, RP2350B) -> the same Winbond W25Q64,
BPIO2 on COM19, terminal on COM18.

| test | result |
| --- | --- |
| COBS round trips incl. 253/254/255/256 byte runs, leading and trailing zeros | 10/10 |
| COBS rejects a zero inside a frame, and a truncated frame | pass |
| registry enumeration of both USB interfaces | both units found, ports paired correctly |
| BPIO2 handshake and status decode | Bus Pirate 6 REV2, limits 640/512/512 |
| SPI configure 8 MHz 3.3 V, JEDEC id | `EF 40 17` |
| 2048 byte read split across four 512 byte slices | pass, re-read byte identical |
| **full 8 MB dump** | **208 kB/s, SHA-256 identical to the BBIO dump of the same chip** |

That last row is the strongest check in this directory: the same physical chip,
read through two unrelated protocols on two hardware generations by two
independent implementations, produced the same 8 388 608 bytes.

### What the numbers say

**BPIO2 is about twenty times faster than BBIO here.** 208 kB/s against
10 kB/s, so a full 8 MB chip takes 40 seconds instead of 13.6 minutes. The v3.x
is capped by its 115200 baud UART; the v5+ runs over USB CDC where the SPI clock
is what matters again.

**Read what arrived, not a fixed block.** The first version of `ReadFrame` asked
`RecvBufferEx` for a buffer-sized chunk, and RecvBufferEx waits for the full
count it is given - so every response paid the whole inter-byte timeout after
its last byte, turning a 7 ms round trip into 47 ms and the driver into
11 kB/s. Ask `WaitingDataEx` how much is really there first.

**Three BPIO2 limits are not negotiable** (`bpio.c`): `bytes_read` must never
exceed 512 - the firmware's over-limit path jumps past the start of its own
response table and corrupts the builder for later responses too; `data_write`
is not checked by the firmware at all, so the host has to keep it under 512 or
overflow the 643 byte frame buffer; and `contents_type` must be 1, 2 or 3
because 0 indexes a NULL handler and reboots the device. The encoder asserts all
three.

**An I2C read that opens with a start must carry at least one write byte.** The
firmware reads `data_write[0]` to build the read address without checking that
the vector exists.


---

# bp3probe - the Bus Pirate v3.x driver

Drives `TBusPirate` from `buzzpirathw.pas` with no form and no GUI, so a pass
here is about the Pascal engine on the wire rather than about the interface.

    tests\build_bp3probe.cmd
    tests\build\bp3probe.exe COM22
    tests\build\bp3probe.exe COM22 baud 2000000 spi 11
    tests\build\bp3probe.exe COM22 dump 8388608 chip.bin

It opens the port, enters bitbang, resets to the terminal and parses the banner,
then prints what flashrom's own version rules make of it: which serial speeds
this hardware may use and whether binary SPI is supported at all. That section
is the one to look at when a device refuses to leave 115200, because it shows
the reason rather than just the outcome.

`i2c` adds an I2C block, `write` makes the run destructive.

# bp3clocks - the SPI clock menu

The only test that covers the menu to firmware index mapping, and it exists
because that mapping is not one table but two. A real Bus Pirate v3 indexes the
firmware's own twelve entry table; a v5 or newer in legacy binary mode decodes
the documented eight entry order instead, and an index outside 0 to 7 is not
merely the wrong clock there, it is read as a different command entirely.

    tests\build_bp3clocks.cmd
    tests\build\bp3clocks.exe COM19
    tests\build\bp3clocks.exe COM19 W25Q64BV

It reports which table the driver chose from the device banner, then reads the
chip at every one of the eight menu entries and requires all eight to reproduce
a reference taken at 125 kHz.

**Point it at a chip with real content.** The reference is the first 4 KB, and
on a blank or uniform region every clock agrees whatever index was sent, which
would make the whole run pass while proving nothing. The program refuses to
continue if it finds fewer than sixteen distinct byte values there.

# asprog_spi and asprog_i2c - the program's own paths

These two build the real `TMainForm`, select a chip out of `chiplist.xml` exactly
as clicking it would, and then call `ButtonEraseClick`, `ButtonWriteClick`,
`ButtonReadClick` and `ButtonVerifyClick`. Everything under those handlers is the
shipping code: the chunking, the busy waits, the three versus four byte
addressing, the page loop.

    tests\build\asprog_spi.exe COM19 backup\w25q64_original.bin cycles 5
    tests\build\asprog_spi.exe COM22 bp3 chip SST25VF080B backup\sst.bin
    tests\build\asprog_i2c.exe COM19 bp5 write

`asprog_spi` takes a reference image: on the first run it saves what it read, on
later runs it compares against it, and after the destructive rounds it puts the
original back. `cycles N` runs N erase, write and read back rounds with fresh
random data each time. Without it the run is read only.

`asprog_spi` defaults to the BusPirateV5+ back end and to a W25Q64BV; `bp3`
switches back ends and `chip <name>` picks any part in `chiplist.xml`, taking
its size from there. That matters for more than convenience: a part whose page
column reads `SSTB` or `SSTW` is not page programmed at all, it is written two
bytes at a time through a completely separate routine, and until a chip like
that is selected none of that code runs.

`asprog_i2c` defaults to the Bus Pirate v3.x back end; `bp5` switches it to the
v5+ one. `write` makes it destructive, and it restores the original contents
afterwards.

**Both carry negative controls, on purpose.** The hex editor is filled with the
complement of the expected image before every read back, so a read that silently
does nothing cannot compare equal and pass. The verify step is checked by
reading the program's own log rather than by assuming the call worked, and it is
then given a deliberately corrupted image and required to report a mismatch. A
verify that fails for any other reason does not count as catching it.

---

## Writing new tests

Flash cells only go from 1 to 0. Programming over a region a previous test
already wrote compares the AND of the two patterns and fails for reasons that
have nothing to do with the link - erase first. The unaligned-write cases here
each start from a freshly erased sector for exactly that reason.
