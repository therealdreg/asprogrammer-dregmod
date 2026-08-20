# -*- coding: utf-8 -*-
"""
Bus Pirate v3.6 / Buzzpirat - SPI flash link stress and integrity tests.

By Dreg
https://github.com/therealdreg/asprogrammer-dregmod

This talks to the device over its binary I/O (BBIO) protocol using exactly the
same byte sequences buzzpirathw.pas emits: same commands, same 4096 byte bulk
limit, same CS framing, same fixed 115200 baud link. So what it proves here is
true of the Pascal driver too.

What it is for: proving that not one byte is lost, duplicated or reordered
between the host and the flash chip, at every clock the firmware offers, at
every transfer size around the firmware's buffer boundary, and across
deliberately broken transfers.

    python bp_stress.py --port COM22 id
    python bp_stress.py --port COM22 speeds
    python bp_stress.py --port COM22 limits
    python bp_stress.py --port COM22 dump backup.bin
    python bp_stress.py --port COM22 compare backup.bin
    python bp_stress.py --port COM22 soak --passes 4 --region 0x700000:0x40000
    python bp_stress.py --port COM22 abuse
    python bp_stress.py --port COM22 roundtrip --sectors 8      # DESTRUCTIVE
    python bp_stress.py --port COM22 restore backup.bin         # DESTRUCTIVE

Nothing writes to the chip unless the command says DESTRUCTIVE.
"""

import argparse
import hashlib
import os
import random
import struct
import sys
import time

import serial

# ---------------------------------------------------------------- BBIO opcodes
BBIO_RESET_BITBANG = 0x00
BBIO_ENTER_SPI     = 0x01
BBIO_RESET_DEVICE  = 0x0F

SPI_CS_LOW         = 0x02
SPI_CS_HIGH        = 0x03
SPI_WR_RD_CS       = 0x04   # firmware drives CS around the transfer
SPI_WR_RD_NOCS     = 0x05
SPI_SPEED          = 0x60
SPI_CONFIG         = 0x80
PERIPHERALS        = 0x40

PERIPH_CS      = 0x01
PERIPH_AUX     = 0x02
PERIPH_PULLUPS = 0x04
PERIPH_POWER   = 0x08

CFG_OUT_3V3    = 0x08
CFG_CKP        = 0x04
CFG_CKE        = 0x02
CFG_SMP        = 0x01

BP_MAX_BULK    = 4096       # BP_TERMINAL_BUFFER_SIZE in the firmware
BAUD           = 115200

# The firmware's own twelve entry spi_bus_speed[] table (spi.c), which is what
# the 0x60|n nibble indexes - NOT the eight speeds the BBIO documentation lists.
SPI_SPEEDS_HZ = [30000, 125000, 250000, 1000000, 50000, 1300000,
                 2000000, 2600000, 3200000, 4000000, 5300000, 8000000]

# ------------------------------------------------------------- flash opcodes
CMD_JEDEC_ID   = 0x9F
CMD_READ       = 0x03
CMD_WREN       = 0x06
CMD_WRDI       = 0x04
CMD_RDSR1      = 0x05
CMD_RDSR2      = 0x35
CMD_PAGE_PROG  = 0x02
CMD_SECTOR_ERS = 0x20       # 4 KB
CMD_BLOCK_ERS  = 0xD8       # 64 KB
CMD_CHIP_ERASE = 0xC7

PAGE   = 256
SECTOR = 4096

VENDORS = {0xEF: 'Winbond', 0xC2: 'Macronix', 0x20: 'Micron/ST',
           0x1F: 'Adesto/Atmel', 0xBF: 'SST', 0x01: 'Spansion', 0x9D: 'ISSI'}


class BPError(Exception):
    pass


class BusPirate(object):
    """The transport, mirroring TBPSerialPort + TBusPirate."""

    def __init__(self, port, verbose=False):
        self.verbose = verbose
        self.port_name = port
        self.s = serial.Serial(port, BAUD, timeout=0.2, write_timeout=10)
        self.speed_idx = 1
        self.stats = {'commands': 0, 'tx_bytes': 0, 'rx_bytes': 0,
                      'short_reads': 0, 'bad_acks': 0, 'resyncs': 0}
        time.sleep(0.05)
        self.s.reset_input_buffer()
        self.s.reset_output_buffer()

    # ---------------------------------------------------------------- plumbing
    def close(self):
        try:
            self.s.close()
        except Exception:
            pass

    def drain(self, idle=0.15, cap=5.0):
        out = bytearray()
        t0 = last = time.time()
        while time.time() - t0 < cap:
            n = self.s.in_waiting
            if n:
                out += self.s.read(n)
                last = time.time()
            elif time.time() - last > idle:
                break
            else:
                time.sleep(0.004)
        return bytes(out)

    def write(self, data):
        self.s.write(data)
        self.s.flush()
        self.stats['tx_bytes'] += len(data)

    def read_exact(self, n, timeout=20.0):
        if n == 0:
            return b''
        out = bytearray()
        deadline = time.time() + timeout
        while len(out) < n and time.time() < deadline:
            c = self.s.read(min(n - len(out), 65536))
            if c:
                out += c
                deadline = time.time() + timeout   # inter-packet timeout
        self.stats['rx_bytes'] += len(out)
        if len(out) != n:
            self.stats['short_reads'] += 1
            raise BPError('short read: %d of %d bytes' % (len(out), n))
        return bytes(out)

    def expect_ack(self, what):
        b = self.read_exact(1, 20.0)
        if b != b'\x01':
            self.stats['bad_acks'] += 1
            raise BPError('%s: device answered 0x%02X, expected 0x01' % (what, b[0]))

    # ------------------------------------------------------------ mode entry
    def enter_bitbang(self):
        """One 0x00 at a time - a burst overruns the PIC's 4 byte UART FIFO."""
        self.drain(0.05, 0.5)
        for attempt in range(1, 41):
            self.write(bytes([BBIO_RESET_BITBANG]))
            time.sleep(0.02)
            if self.s.in_waiting:
                r = self.s.read(self.s.in_waiting)
                if b'BBIO1' in r:
                    self.drain(0.05, 0.5)
                    return attempt
        raise BPError('no BBIO1 from %s' % self.port_name)

    def enter_spi(self, speed_idx=1, power=True, pullups=False, push_pull=True):
        self.write(bytes([BBIO_ENTER_SPI]))
        time.sleep(0.08)
        r = self.drain(0.08, 2.0)
        if b'SPI1' not in r:
            raise BPError('device would not enter raw SPI (got %r)' % r)

        periph = PERIPHERALS | PERIPH_CS | PERIPH_AUX
        if power:
            periph |= PERIPH_POWER
        if pullups:
            periph |= PERIPH_PULLUPS
        self.write(bytes([periph]))
        self.expect_ack('peripherals')

        self.write(bytes([SPI_SPEED | speed_idx]))
        self.expect_ack('spi speed')
        self.speed_idx = speed_idx

        cfg = SPI_CONFIG | CFG_CKE          # mode 0 as flash chips expect
        if push_pull and not pullups:
            cfg |= CFG_OUT_3V3
        self.write(bytes([cfg]))
        self.expect_ack('spi config')

        self.write(bytes([SPI_CS_HIGH]))
        self.expect_ack('cs high')

    def set_speed(self, idx):
        self.write(bytes([SPI_SPEED | idx]))
        self.expect_ack('spi speed')
        self.speed_idx = idx
        # The speed command re-runs spi_setup() on the device, which drives CS
        # high again - exactly what ApplySPISettings relies on.

    def resync(self):
        """What TBusPirate.Resync does: wait for silence, discard, re-arm."""
        self.stats['resyncs'] += 1
        junk = self.drain(0.4, 20.0)
        self.s.reset_input_buffer()
        idx = self.speed_idx
        self.enter_bitbang()
        self.enter_spi(idx)
        return len(junk)

    def park(self):
        try:
            self.write(bytes([SPI_CS_HIGH]))
            self.read_exact(1, 2.0)
        except Exception:
            pass
        try:
            self.write(bytes([BBIO_RESET_BITBANG]))
            time.sleep(0.05)
            self.drain(0.05, 0.5)
        except Exception:
            pass

    # ------------------------------------------------------------- transfers
    def xfer(self, wr=b'', rdlen=0, timeout=None):
        """One 0x04 write-then-read, the firmware framing CS. Sizes are checked
        against the firmware buffer exactly as SPIExecSlice does."""
        if len(wr) > BP_MAX_BULK or rdlen > BP_MAX_BULK:
            raise ValueError('slice over the %d byte firmware limit' % BP_MAX_BULK)
        if timeout is None:
            # Generous: bus time at the slowest clock plus wire time at 115200.
            hz = SPI_SPEEDS_HZ[self.speed_idx]
            timeout = 5.0 + (len(wr) + rdlen) * 9.0 / hz + (len(wr) + rdlen) * 12.0 / BAUD
        hdr = struct.pack('>BHH', SPI_WR_RD_CS, len(wr), rdlen)
        self.write(hdr + wr)
        self.stats['commands'] += 1
        self.expect_ack('spi transfer')
        return self.read_exact(rdlen, timeout) if rdlen else b''

    def raw(self, data):
        """Send bytes with no framing, for the deliberately abusive tests."""
        self.write(data)


class Flash(object):
    """25-series SPI flash on top of the transport."""

    def __init__(self, bp):
        self.bp = bp
        self.jedec = None
        self.size = 0

    def identify(self):
        self.jedec = self.bp.xfer(bytes([CMD_JEDEC_ID]), 3)
        self.size = 1 << self.jedec[2]
        return self.jedec

    def sr1(self):
        return self.bp.xfer(bytes([CMD_RDSR1]), 1)[0]

    def sr2(self):
        return self.bp.xfer(bytes([CMD_RDSR2]), 1)[0]

    def busy(self):
        return bool(self.sr1() & 0x01)

    def wait_ready(self, timeout=120.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if not self.busy():
                return True
            time.sleep(0.002)
        raise BPError('chip still busy after %.0fs' % timeout)

    def wren(self):
        self.bp.xfer(bytes([CMD_WREN]), 0)
        if not (self.sr1() & 0x02):
            raise BPError('write enable latch did not set')

    def read(self, addr, length):
        """Split into firmware sized slices, like SPITransfer does."""
        out = bytearray()
        while length > 0:
            n = min(length, BP_MAX_BULK)
            cmd = bytes([CMD_READ, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF])
            out += self.bp.xfer(cmd, n)
            addr += n
            length -= n
        return bytes(out)

    def erase_sector(self, addr):
        self.wren()
        self.bp.xfer(bytes([CMD_SECTOR_ERS, (addr >> 16) & 0xFF,
                            (addr >> 8) & 0xFF, addr & 0xFF]), 0)
        self.wait_ready(5.0)

    def program_page(self, addr, data):
        if len(data) > PAGE:
            raise ValueError('page program over %d bytes' % PAGE)
        if (addr % PAGE) + len(data) > PAGE:
            raise ValueError('page program would wrap the page buffer')
        self.wren()
        cmd = bytes([CMD_PAGE_PROG, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF])
        self.bp.xfer(cmd + data, 0)
        self.wait_ready(5.0)

    def write(self, addr, data):
        off = 0
        while off < len(data):
            n = min(PAGE - ((addr + off) % PAGE), len(data) - off)
            self.program_page(addr + off, data[off:off + n])
            off += n


# ------------------------------------------------------------------ reporting
class Report(object):
    def __init__(self):
        self.rows = []
        self.failures = 0

    def ok(self, name, detail=''):
        self.rows.append(('PASS', name, detail))
        print('  PASS  %-46s %s' % (name, detail))

    def fail(self, name, detail=''):
        self.failures += 1
        self.rows.append(('FAIL', name, detail))
        print('  FAIL  %-46s %s' % (name, detail))

    def info(self, text):
        print('        %s' % text)

    def summary(self):
        print('\n' + '=' * 78)
        n = len(self.rows)
        if self.failures:
            print('%d of %d checks FAILED' % (self.failures, n))
        else:
            print('all %d checks passed' % n)
        print('=' * 78)
        return 1 if self.failures else 0


def connect(args):
    bp = BusPirate(args.port, args.verbose)
    nuls = bp.enter_bitbang()
    bp.enter_spi(args.speed, power=not args.no_power, pullups=args.pullups)
    fl = Flash(bp)
    fl.identify()
    print('port      : %s @ %d baud' % (args.port, BAUD))
    print('bitbang   : BBIO1 after %d NULs' % nuls)
    print('spi clock : %d Hz (index %d)' % (SPI_SPEEDS_HZ[args.speed], args.speed))
    print('flash     : %s  %s, %d bytes (%d Mbit)' % (
        fl.jedec.hex(), VENDORS.get(fl.jedec[0], '?'), fl.size, fl.size * 8 // 1024 // 1024))
    print('status    : SR1=0x%02X SR2=0x%02X' % (fl.sr1(), fl.sr2()))
    print()
    return bp, fl


# ---------------------------------------------------------------- commands
def cmd_id(args):
    bp, fl = connect(args)
    bp.park()
    bp.close()
    return 0


def cmd_speeds(args):
    """Read the same region at every firmware clock; every read must be
    identical to the reference taken at the slowest, safest clock."""
    bp, fl = connect(args)
    rep = Report()
    region = args.region_addr
    length = args.region_len or 4096

    print('reference read of %d bytes @ 0x%06X at 30 kHz' % (length, region))
    bp.set_speed(0)
    ref = fl.read(region, length)
    ref_h = hashlib.sha256(ref).hexdigest()[:16]
    print('  sha256[:16] = %s\n' % ref_h)

    order = sorted(range(len(SPI_SPEEDS_HZ)), key=lambda i: SPI_SPEEDS_HZ[i])
    for idx in order:
        hz = SPI_SPEEDS_HZ[idx]
        try:
            bp.set_speed(idx)
            good = True
            for rep_i in range(args.passes):
                t0 = time.time()
                data = fl.read(region, length)
                dt = time.time() - t0
                if data != ref:
                    diff = sum(1 for a, b in zip(data, ref) if a != b)
                    rep.fail('%7d Hz (idx %2d)' % (hz, idx),
                             'pass %d: %d/%d bytes differ' % (rep_i + 1, diff, length))
                    good = False
                    break
            if good:
                rep.ok('%7d Hz (idx %2d)' % (hz, idx),
                       '%d passes identical, %.1f kB/s' % (args.passes, length / dt / 1024))
        except BPError as e:
            rep.fail('%7d Hz (idx %2d)' % (hz, idx), str(e))
            bp.resync()

    bp.set_speed(args.speed)
    bp.park()
    bp.close()
    return rep.summary()


def cmd_limits(args):
    """Transfer sizes around the firmware's 4096 byte buffer boundary."""
    bp, fl = connect(args)
    rep = Report()
    base = args.region_addr

    ref = fl.read(base, BP_MAX_BULK + 16)

    for n in (1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 127, 128, 129,
              255, 256, 257, 511, 512, 1023, 1024, 2047, 2048,
              4093, 4094, 4095, 4096):
        try:
            cmd = bytes([CMD_READ, (base >> 16) & 0xFF, (base >> 8) & 0xFF, base & 0xFF])
            got = bp.xfer(cmd, n)
            if got == ref[:n]:
                rep.ok('read of %4d bytes' % n)
            else:
                bad = sum(1 for a, b in zip(got, ref[:n]) if a != b)
                rep.fail('read of %4d bytes' % n, '%d bytes differ' % bad)
        except BPError as e:
            rep.fail('read of %4d bytes' % n, str(e))
            bp.resync()

    # Write side at the boundary: the header counts the opcode and address, so
    # the largest payload that still fits is 4096 - 4. A payload of the read
    # opcode followed by (wn - 4) dummy clocks leaves the flash presenting the
    # byte at base + wn - 4, so the single byte read back afterwards can be
    # checked against the reference. Calling the size "accepted" without
    # looking at that byte proved only that nothing raised.  By Dreg
    cmd = bytes([CMD_READ, (base >> 16) & 0xFF, (base >> 8) & 0xFF, base & 0xFF])
    for wn in (1, 2, 4, 5, 256, 1024, 4095, 4096):
        try:
            if wn >= 4:
                got = bp.xfer(cmd + b'\x00' * (wn - 4), 1)
                want = ref[wn - 4:wn - 3]
                if got == want:
                    rep.ok('write of %4d bytes, byte read back matches' % wn)
                else:
                    rep.fail('write of %4d bytes' % wn,
                             'got %s wanted %s' % (got.hex(), want.hex()))
            else:
                # Too short to carry an opcode, so there is nothing here to
                # compare. What it can prove is that the device swallowed it
                # and the very next transfer still lines up.
                bp.xfer(b'\x00' * wn, 0)
                got = bp.xfer(cmd, 1)
                if got == ref[:1]:
                    rep.ok('write of %4d bytes, link still in step' % wn)
                else:
                    rep.fail('write of %4d bytes' % wn,
                             'link out of step afterwards, got %s' % got.hex())
        except BPError as e:
            rep.fail('write of %4d bytes' % wn, str(e))
            bp.resync()

    # And one byte over the limit must be refused by the firmware, not executed.
    print('\n  over-limit behaviour (must be refused, and must be recoverable):')
    try:
        hdr = struct.pack('>BHH', SPI_WR_RD_CS, 4, BP_MAX_BULK + 1)
        bp.write(hdr + bytes([CMD_READ, 0, 0, 0]))
        answer = bp.read_exact(1, 5.0)
        if answer == b'\x00':
            rep.ok('read of 4097 bytes refused with 0x00')
        else:
            rep.fail('read of 4097 bytes', 'answered 0x%02X' % answer[0])
    except BPError as e:
        rep.fail('read of 4097 bytes', str(e))
    junk = bp.resync()
    rep.ok('link recovered after the over-limit command', '%d stray bytes discarded' % junk)

    check = fl.read(base, 64)
    if check == ref[:64]:
        rep.ok('bus still correct after the abuse')
    else:
        rep.fail('bus still correct after the abuse')

    bp.park()
    bp.close()
    return rep.summary()


def cmd_dump(args):
    bp, fl = connect(args)
    length = args.region_len or fl.size
    addr = args.region_addr
    print('reading %d bytes from 0x%06X at %d Hz...' % (length, addr, SPI_SPEEDS_HZ[args.speed]))
    t0 = time.time()
    out = bytearray()
    step = BP_MAX_BULK
    while len(out) < length:
        n = min(step, length - len(out))
        out += fl.read(addr + len(out), n)
        done = len(out)
        if done % (256 * 1024) == 0 or done == length:
            el = time.time() - t0
            rate = done / el / 1024
            eta = (length - done) / (rate * 1024) if rate else 0
            sys.stdout.write('\r  %7d / %d kB  %5.1f kB/s  eta %4.0fs' %
                             (done // 1024, length // 1024, rate, eta))
            sys.stdout.flush()
    dt = time.time() - t0
    print('\n  %d bytes in %.1fs (%.1f kB/s)' % (len(out), dt, len(out) / dt / 1024))
    with open(args.file, 'wb') as f:
        f.write(out)
    print('  sha256 = %s' % hashlib.sha256(out).hexdigest())
    print('  saved  : %s' % args.file)
    bp.park()
    bp.close()
    return 0


def cmd_compare(args):
    bp, fl = connect(args)
    with open(args.file, 'rb') as f:
        ref = f.read()
    addr = args.region_addr
    # The file is a whole-chip image, indexed by absolute address - so a
    # partial compare lines the right part of the file up with the right part
    # of the chip instead of always starting at the beginning of the file.
    length = args.region_len or (len(ref) - addr)
    if addr + length > len(ref):
        raise BPError('%s holds %d bytes, too short for 0x%X..0x%X'
                      % (args.file, len(ref), addr, addr + length))
    rep = Report()
    print('re-reading %d bytes from 0x%06X and comparing...' % (length, addr))
    t0 = time.time()
    bad = 0
    first_bad = None
    done = 0
    while done < length:
        n = min(BP_MAX_BULK, length - done)
        got = fl.read(addr + done, n)
        exp = ref[addr + done:addr + done + n]
        if got != exp:
            for i, (a, b) in enumerate(zip(got, exp)):
                if a != b:
                    bad += 1
                    if first_bad is None:
                        first_bad = (addr + done + i, a, b)
        done += n
        if done % (256 * 1024) == 0 or done == length:
            sys.stdout.write('\r  %7d / %d kB, %d mismatches' % (done // 1024, length // 1024, bad))
            sys.stdout.flush()
    print('\n  %.1fs' % (time.time() - t0))
    if bad == 0:
        rep.ok('full compare', '%d bytes identical' % length)
    else:
        rep.fail('full compare', '%d mismatched bytes, first at 0x%06X (%02X != %02X)' %
                 ((bad,) + first_bad))
    bp.park()
    bp.close()
    return rep.summary()


def cmd_soak(args):
    """Read the same region over and over; every pass must be byte identical.
    This is the test that catches a dropped or duplicated USB packet."""
    bp, fl = connect(args)
    rep = Report()
    addr = args.region_addr
    length = args.region_len or 256 * 1024

    print('soak: %d passes over %d kB from 0x%06X at %d Hz\n' %
          (args.passes, length // 1024, addr, SPI_SPEEDS_HZ[args.speed]))

    ref = None
    for p in range(1, args.passes + 1):
        t0 = time.time()
        data = fl.read(addr, length)
        dt = time.time() - t0
        h = hashlib.sha256(data).hexdigest()[:16]
        if ref is None:
            ref = data
            rep.ok('pass %d' % p, 'sha=%s  %.1f kB/s  (reference)' % (h, length / dt / 1024))
        elif data == ref:
            rep.ok('pass %d' % p, 'sha=%s  %.1f kB/s' % (h, length / dt / 1024))
        else:
            diff = [i for i, (a, b) in enumerate(zip(data, ref)) if a != b]
            rep.fail('pass %d' % p, '%d bytes differ, first at +0x%X' % (len(diff), diff[0]))

    s = bp.stats
    rep.info('%d commands, %d bytes out, %d bytes in, %d short reads, %d bad acks, %d resyncs'
             % (s['commands'], s['tx_bytes'], s['rx_bytes'],
                s['short_reads'], s['bad_acks'], s['resyncs']))
    bp.park()
    bp.close()
    return rep.summary()


def cmd_abuse(args):
    """Break transfers on purpose and prove the link comes back every time."""
    bp, fl = connect(args)
    rep = Report()
    base = args.region_addr
    ref = fl.read(base, 256)

    # 1. Ask for a big read and walk away before it has all arrived.
    for trial in range(1, 4):
        try:
            cmd = bytes([CMD_READ, (base >> 16) & 0xFF, (base >> 8) & 0xFF, base & 0xFF])
            hdr = struct.pack('>BHH', SPI_WR_RD_CS, len(cmd), BP_MAX_BULK)
            bp.write(hdr + cmd)
            bp.read_exact(1, 5.0)          # the ack
            bp.read_exact(64, 5.0)         # a token part of the payload
            junk = bp.resync()             # abandon the other ~4032 bytes
            after = fl.read(base, 256)
            if after == ref:
                rep.ok('abandoned mid-read #%d recovered' % trial,
                       '%d stray bytes discarded' % junk)
            else:
                rep.fail('abandoned mid-read #%d recovered' % trial, 'data wrong afterwards')
        except BPError as e:
            rep.fail('abandoned mid-read #%d' % trial, str(e))
            bp.resync()

    # 2. A truncated command header: the firmware is left waiting for bytes.
    try:
        bp.write(bytes([SPI_WR_RD_CS, 0x00]))     # 3 of the 5 header bytes missing
        time.sleep(0.2)
        junk = bp.resync()
        after = fl.read(base, 256)
        rep.ok('truncated command header recovered', '%d stray bytes' % junk) \
            if after == ref else rep.fail('truncated command header recovered', 'data wrong')
    except BPError as e:
        rep.fail('truncated command header', str(e))
        bp.resync()

    # 3. Garbage in the command stream.
    try:
        bp.write(bytes([0x7A, 0x7B, 0x7C]))
        time.sleep(0.2)
        junk = bp.resync()
        after = fl.read(base, 256)
        rep.ok('garbage opcodes recovered', '%d stray bytes' % junk) \
            if after == ref else rep.fail('garbage opcodes recovered', 'data wrong')
    except BPError as e:
        rep.fail('garbage opcodes', str(e))
        bp.resync()

    # 4. Interleaved CS control, the shape SPIExecSlice emits: one bulk command
    #    with a single trailing byte. More than that would overrun the FIFO.
    try:
        cmd = bytes([CMD_READ, (base >> 16) & 0xFF, (base >> 8) & 0xFF, base & 0xFF])
        hdr = struct.pack('>BHH', SPI_WR_RD_NOCS, len(cmd), 256)
        bp.write(bytes([SPI_CS_LOW]) + hdr + cmd + bytes([SPI_CS_HIGH]))
        bp.expect_ack('cs low')
        bp.expect_ack('transfer')
        got = bp.read_exact(256, 10.0)
        bp.expect_ack('cs high')
        if got == ref:
            rep.ok('CS low + bulk + CS high in one write')
        else:
            rep.fail('CS low + bulk + CS high in one write', 'data differs')
    except BPError as e:
        rep.fail('CS low + bulk + CS high in one write', str(e))
        bp.resync()

    s = bp.stats
    rep.info('%d resyncs, %d short reads, %d bad acks'
             % (s['resyncs'], s['short_reads'], s['bad_acks']))
    bp.park()
    bp.close()
    return rep.summary()


def cmd_roundtrip(args):
    """DESTRUCTIVE. erase -> write random -> read back -> compare, over a
    handful of sectors, with awkward alignments."""
    bp, fl = connect(args)
    rep = Report()
    rng = random.Random(args.seed)

    nsec = args.sectors
    base = args.region_addr
    print('DESTRUCTIVE: %d sectors of %d bytes from 0x%06X\n' % (nsec, SECTOR, base))

    for i in range(nsec):
        addr = base + i * SECTOR
        try:
            fl.erase_sector(addr)
            blank = fl.read(addr, SECTOR)
            if blank != b'\xFF' * SECTOR:
                n = sum(1 for b in blank if b != 0xFF)
                rep.fail('sector 0x%06X erase' % addr, '%d bytes not 0xFF' % n)
                continue
            rep.ok('sector 0x%06X erased to 0xFF' % addr)

            payload = bytes(rng.randrange(256) for _ in range(SECTOR))
            fl.write(addr, payload)
            back = fl.read(addr, SECTOR)
            if back == payload:
                rep.ok('sector 0x%06X write/read-back' % addr,
                       'sha=%s' % hashlib.sha256(payload).hexdigest()[:16])
            else:
                bad = [j for j, (a, b) in enumerate(zip(back, payload)) if a != b]
                rep.fail('sector 0x%06X write/read-back' % addr,
                         '%d bytes differ, first at +0x%X' % (len(bad), bad[0]))
        except BPError as e:
            rep.fail('sector 0x%06X' % addr, str(e))
            bp.resync()

    # Unaligned and odd-length writes, several of which straddle a 256 byte
    # page boundary. Each one gets a freshly erased sector: NOR flash can only
    # clear bits, so writing over a previous test's cells would compare the AND
    # of the two patterns and fail for reasons that have nothing to do with the
    # link.
    addr = base + (nsec - 1) * SECTOR
    for off, ln in ((1, 1), (3, 5), (250, 12), (255, 2), (255, 258),
                    (700, 333), (2047, 1025), (4095, 1)):
        try:
            fl.erase_sector(addr)
            data = bytes(rng.randrange(256) for _ in range(ln))
            fl.write(addr + off, data)
            back = fl.read(addr + off, ln)
            if back != data:
                bad = [j for j, (x, y) in enumerate(zip(back, data)) if x != y]
                rep.fail('unaligned write +0x%03X len %4d' % (off, ln),
                         '%d bytes differ, first at +%d' % (len(bad), bad[0]))
                continue
            # And nothing outside the written range may have been touched.
            if off > 0 and fl.read(addr, off) != bytes([0xFF]) * off:
                rep.fail('unaligned write +0x%03X len %4d' % (off, ln),
                         'bytes before the range were disturbed')
                continue
            tail = SECTOR - off - ln
            if tail > 0 and fl.read(addr + off + ln, tail) != bytes([0xFF]) * tail:
                rep.fail('unaligned write +0x%03X len %4d' % (off, ln),
                         'bytes after the range were disturbed')
                continue
            rep.ok('unaligned write +0x%03X len %4d' % (off, ln),
                   'page-crossing' if (off % PAGE) + ln > PAGE else '')
        except BPError as e:
            rep.fail('unaligned write +0x%03X len %4d' % (off, ln), str(e))
            bp.resync()

    bp.park()
    bp.close()
    return rep.summary()


def cmd_restore(args):
    """DESTRUCTIVE. Put a dump file back on the chip and verify it."""
    bp, fl = connect(args)
    rep = Report()
    with open(args.file, 'rb') as f:
        whole = f.read()
    addr = args.region_addr
    # Same rule as compare: absolute addresses into a whole-chip image.
    length = args.region_len or (len(whole) - addr)
    if addr + length > len(whole):
        raise BPError('%s holds %d bytes, too short for 0x%X..0x%X'
                      % (args.file, len(whole), addr, addr + length))
    image = whole[addr:addr + length]

    print('DESTRUCTIVE: restoring %d bytes to 0x%06X from %s\n' % (length, addr, args.file))
    t0 = time.time()
    nsec = (length + SECTOR - 1) // SECTOR
    for i in range(nsec):
        a = addr + i * SECTOR
        fl.erase_sector(a)
        chunk = image[i * SECTOR:(i + 1) * SECTOR]
        if chunk:
            fl.write(a, chunk)
        if (i + 1) % 16 == 0 or i + 1 == nsec:
            el = time.time() - t0
            sys.stdout.write('\r  sector %5d / %d  %.0fs elapsed' % (i + 1, nsec, el))
            sys.stdout.flush()
    print()
    back = fl.read(addr, length)
    if back == image:
        rep.ok('restore verified', '%d bytes, %.0fs' % (length, time.time() - t0))
    else:
        bad = [j for j, (a2, b) in enumerate(zip(back, image)) if a2 != b]
        rep.fail('restore verified', '%d bytes differ, first at +0x%X' % (len(bad), bad[0]))
    bp.park()
    bp.close()
    return rep.summary()


def parse_region(text):
    if not text:
        return 0, 0
    if ':' in text:
        a, l = text.split(':', 1)
        return int(a, 0), int(l, 0)
    return int(text, 0), 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', default='COM22')
    p.add_argument('--speed', type=int, default=1,
                   help='firmware SPI speed index 0..11 (default 1 = 125 kHz)')
    p.add_argument('--passes', type=int, default=3)
    p.add_argument('--sectors', type=int, default=4)
    p.add_argument('--seed', type=int, default=12345)
    p.add_argument('--region', default='0:0', help='ADDR[:LEN], e.g. 0x700000:0x40000')
    p.add_argument('--pullups', action='store_true')
    p.add_argument('--no-power', action='store_true')
    p.add_argument('--verbose', action='store_true')
    p.add_argument('command', choices=['id', 'speeds', 'limits', 'dump', 'compare',
                                       'soak', 'abuse', 'roundtrip', 'restore'])
    p.add_argument('file', nargs='?')
    args = p.parse_args()
    args.region_addr, args.region_len = parse_region(args.region)

    if args.command in ('dump', 'compare', 'restore') and not args.file:
        p.error('%s needs a file argument' % args.command)

    fn = globals()['cmd_' + args.command]
    try:
        return fn(args)
    except BPError as e:
        print('\nLINK ERROR: %s' % e)
        return 2


if __name__ == '__main__':
    sys.exit(main())
