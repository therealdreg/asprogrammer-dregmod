program bp5probe;

{
  Exercises the Pascal BPIO2 engine in buspirate5hw.pas against a real
  Bus Pirate v5/v6/v7, without the GUI.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  This drives TBusPirate5 directly - the same encoder, decoder, COBS and
  transport the AsProgrammer back end uses - so a pass here means the Pascal
  implementation itself works on the wire, not just that it compiles.

    bp5probe                 auto-detect the BPIO2 port and run every check
    bp5probe COM19           use that port
    bp5probe COM19 dump 4096 read N bytes and print a hash

  The device must already be in BPIO2 binmode: on its terminal port run
  "binmode", pick "BPIO2 flatbuffer interface" and answer y to "Save setting?".
}

{$mode objfpc}{$H+}

uses
  //Interfaces only so the LCL links: buspirate5hw pulls in main for the menu
  //settings, and main is a GUI unit. No form is ever created here - the engine
  //layer this program drives never touches MainForm.
  Interfaces, Classes, SysUtils, StrUtils, buspirate5hw;

const
  //The sizes that matter: 254 is where a COBS block fills up and the code byte
  //has to overflow into a new one.
  TSizes: array[0..3] of integer = (253, 254, 255, 256);

var
  Failures: integer = 0;
  //Overridable so a suspect chip can be re-read slowly.  By Dreg
  spiHz: integer = 8000000;

procedure Check(const Name: string; Ok: boolean; const Detail: string = '');
begin
  if Ok then
    WriteLn(Format('  PASS  %-44s %s', [Name, Detail]))
  else
  begin
    WriteLn(Format('  FAIL  %-44s %s', [Name, Detail]));
    Inc(Failures);
  end;
end;

//LastError is only ever written on failure, so it still holds the previous
//message after a call that worked. Only ask for it when the check failed.
procedure CheckE(const Name: string; Ok: boolean; bp: TBusPirate5);
begin
  if Ok then Check(Name, true) else Check(Name, false, bp.LastError);
end;

procedure ShowDevices;
var
  devs: TBP5DeviceArray;
  i: integer;
begin
  devs := BP5EnumerateDevices;
  WriteLn('Bus Pirate USB interfaces found in the registry:');
  if Length(devs) = 0 then
    WriteLn('  (none)')
  else
    for i := 0 to High(devs) do
      WriteLn(Format('  %-14s terminal %-6s BPIO2 %-6s %s',
        [devs[i].Name, devs[i].TermPort, devs[i].DataPort,
         BoolToStr(devs[i].Present, 'present', 'not present')]));
  WriteLn;
end;

function AutoPort: string;
var
  devs: TBP5DeviceArray;
  i: integer;
begin
  result := '';
  devs := BP5EnumerateDevices;
  for i := 0 to High(devs) do
    if devs[i].Present then Exit(devs[i].DataPort);
end;

//COBS has to survive the cases that actually bite: a leading zero, a trailing
//zero, and a run of exactly 254 non-zero bytes where the code byte overflows.
procedure TestCobs;
var
  i, n: integer;
  src, enc, dec: TBytes;
  ok: boolean;

  function RoundTrip(const What: string; const Data: TBytes): boolean;
  var
    e, d: TBytes;
    k: integer;
  begin
    e := BP5CobsEncode(Data);
    for k := 0 to High(e) do
      if e[k] = 0 then
      begin
        Check('COBS ' + What, false, 'encoded form contains a zero byte');
        Exit(false);
      end;
    if not BP5CobsDecode(e, d) then
    begin
      Check('COBS ' + What, false, 'decode refused its own output');
      Exit(false);
    end;
    if Length(d) <> Length(Data) then
    begin
      Check('COBS ' + What, false, Format('length %d became %d', [Length(Data), Length(d)]));
      Exit(false);
    end;
    for k := 0 to High(Data) do
      if d[k] <> Data[k] then
      begin
        Check('COBS ' + What, false, Format('byte %d differs', [k]));
        Exit(false);
      end;
    Check('COBS ' + What, true, Format('%d -> %d bytes', [Length(Data), Length(e)]));
    result := true;
  end;

begin
  WriteLn('COBS round trips');

  SetLength(src, 0);
  RoundTrip('empty', src);

  SetLength(src, 1); src[0] := 0;
  RoundTrip('a single zero', src);

  SetLength(src, 4);
  src[0] := 0; src[1] := 0; src[2] := 1; src[3] := 0;
  RoundTrip('leading and trailing zeros', src);

  //An array, not a set: [253,254,255,256] as a set constant wraps 256 to 0 and
  //silently tests the wrong sizes.
  for n in TSizes do
  begin
    SetLength(src, n);
    for i := 0 to n - 1 do src[i] := byte(1 + (i mod 254));
    RoundTrip(Format('%d non-zero bytes', [n]), src);
  end;

  SetLength(src, 600);
  for i := 0 to High(src) do src[i] := byte((i * 7) mod 256);
  RoundTrip('600 mixed bytes', src);

  //A zero inside a frame is impossible by construction, so the decoder must
  //refuse it rather than produce something plausible.
  SetLength(enc, 3);
  enc[0] := 2; enc[1] := 0; enc[2] := 1;
  ok := not BP5CobsDecode(enc, dec);
  Check('COBS rejects a zero inside a frame', ok);

  //A code byte that runs past the end of the frame is a truncated frame.
  SetLength(enc, 2);
  enc[0] := 9; enc[1] := 1;
  ok := not BP5CobsDecode(enc, dec);
  Check('COBS rejects a truncated frame', ok);
  WriteLn;
end;

//An AT24C256 style part on BPIO2: 32 KB, 64 byte pages, two byte internal
//address. Every call here is one the AsProgrammer back end uses.
procedure TestI2C(bp: TBusPirate5; DevAddr: byte; Destructive: boolean);
const
  PAGE = 64;
var
  i2c: TBP5I2CSettings;
  found: TBytes;
  wr: array[0..1] of byte;
  buf, ref, pat: array of byte;
  i, polls: integer;
  ok, same, acked: boolean;
  list, msg: string;
begin
  WriteLn;
  WriteLn('I2C');

  FillChar(i2c, SizeOf(i2c), 0);
  i2c.SpeedHz := 100000;
  i2c.Pullups := true;      //no pull-ups, no bus
  i2c.Power := true;
  i2c.PsuMv := 5000;        //a 24C256 is happy at 5 V, and so are its pull-ups
  i2c.PsuMa := 300;
  CheckE('enter I2C 100 kHz, pull-ups and 5 V', bp.EnterI2C(i2c), bp);

  ok := bp.I2CScan(8, 119, found);
  list := '';
  for i := 0 to High(found) do list := list + IntToHex(found[i], 2) + ' ';
  //Ok first, then the detail: the detail reads what Ok's call produced.
  msg := Format('%d device(s): %s', [Length(found), list]);
  Check('bus scan', ok, msg);
  if not ok then Exit;

  if Length(found) = 0 then
  begin
    Check('an EEPROM answered', false,
          'nothing on the bus - check SDA/SCL, a common ground and Vpullup');
    Exit;
  end;

  ok := false;
  for i := 0 to High(found) do
    if found[i] = (DevAddr shr 1) then ok := true;
  if not ok then
  begin
    DevAddr := byte((found[0] shl 1) and $FF);
    WriteLn(Format('    using 7-bit 0x%.2x (write 0x%.2x)', [found[0], DevAddr]));
  end;

  //--- read through the write-then-read path the back end really uses --------
  SetLength(ref, PAGE);
  wr[0] := 0; wr[1] := 0;
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @ref[0], PAGE);
  CheckE('read 64 bytes from address 0', ok, bp);
  if ok then
  begin
    Write('    @0x0000   : ');
    for i := 0 to 15 do Write(IntToHex(ref[i], 2));
    WriteLn;
  end;

  SetLength(buf, PAGE);
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], PAGE);
  same := ok;
  if ok then
    for i := 0 to PAGE - 1 do
      if buf[i] <> ref[i] then begin same := false; Break; end;
  CheckE('re-read is byte identical', same, bp);

  //--- a read longer than one page, and one at the 512 byte limit ------------
  SetLength(buf, 256);
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], 256);
  same := ok;
  if ok then
    for i := 0 to PAGE - 1 do
      if buf[i] <> ref[i] then begin same := false; Break; end;
  CheckE('read 256 bytes, first 64 still match', same, bp);

  SetLength(buf, 512);
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], 512);
  CheckE('read 512 bytes, the protocol maximum', ok, bp);

  //--- the byte level primitives --------------------------------------------
  ok := bp.I2CStart;
  if ok then ok := bp.I2CWriteByte(DevAddr, acked);
  CheckE('start + address byte acknowledged', ok and acked, bp);
  if ok then bp.I2CStop;

  ok := bp.I2CStart;
  if ok then ok := bp.I2CWriteByte(byte(DevAddr or $F0), acked);
  CheckE('an address nobody owns is NOT acknowledged', ok and (not acked), bp);
  if ok then bp.I2CStop;

  if not Destructive then
  begin
    WriteLn('    (add "write" to also test program and verify)');
    Exit;
  end;

  //--- write / read back ----------------------------------------------------
  WriteLn;
  WriteLn('  DESTRUCTIVE: page write and verify at 0x0000');
  Write('    original  : ');
  for i := 0 to PAGE - 1 do Write(IntToHex(ref[i], 2));
  WriteLn;

  SetLength(pat, PAGE);
  for i := 0 to PAGE - 1 do pat[i] := byte((i * 11 + 29) and $FF);

  SetLength(buf, PAGE + 2);
  buf[0] := 0; buf[1] := 0;
  Move(pat[0], buf[2], PAGE);
  ok := bp.I2CWriteRead(DevAddr, @buf[0], PAGE + 2, nil, 0);
  CheckE('page program', ok, bp);

  polls := 0;
  repeat
    Sleep(2);
    Inc(polls);
    acked := false;
    if bp.I2CStart then
    begin
      bp.I2CWriteByte(DevAddr, acked);
      bp.I2CStop;
    end;
  until acked or (polls > 100);
  Check('acknowledge polling finished', acked, Format('%d polls', [polls]));

  SetLength(buf, PAGE);
  wr[0] := 0; wr[1] := 0;
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], PAGE);
  same := ok;
  if ok then
    for i := 0 to PAGE - 1 do
      if buf[i] <> pat[i] then
      begin
        same := false;
        Check('read back matches what was written', false,
              Format('differs at +%d: wrote %.2x got %.2x', [i, pat[i], buf[i]]));
        Break;
      end;
  if same then Check('read back matches what was written', true);

  //--- restore --------------------------------------------------------------
  SetLength(buf, PAGE + 2);
  buf[0] := 0; buf[1] := 0;
  Move(ref[0], buf[2], PAGE);
  bp.I2CWriteRead(DevAddr, @buf[0], PAGE + 2, nil, 0);
  polls := 0;
  repeat
    Sleep(2);
    Inc(polls);
    acked := false;
    if bp.I2CStart then
    begin
      bp.I2CWriteByte(DevAddr, acked);
      bp.I2CStop;
    end;
  until acked or (polls > 100);
  SetLength(buf, PAGE);
  wr[0] := 0; wr[1] := 0;
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], PAGE);
  same := ok;
  if ok then
    for i := 0 to PAGE - 1 do
      if buf[i] <> ref[i] then begin same := false; Break; end;
  CheckE('original contents restored', same, bp);
end;

//Defined below TestDevice, which calls them.
procedure TestSizes(bp: TBusPirate5); forward;
procedure TestSoak(bp: TBusPirate5; Passes, Bytes: integer); forward;
procedure TestAbuse(bp: TBusPirate5); forward;

procedure TestDevice(const APort: string; DumpLen: integer; const DumpFile: string; Stress, DoI2C, DoWrite: boolean);
var
  bp: TBusPirate5;
  spi: TBP5SPISettings;
  jid: array[0..2] of byte;
  sr: byte;
  cmd: array[0..3] of byte;
  buf: array of byte;
  i, n: integer;
  t0: QWord;
  sum: LongWord;
  ok: boolean;
begin
  bp := TBusPirate5.Create;
  try
    WriteLn('Opening ', APort, ' ...');
    if not bp.Open(APort) then
    begin
      Check('open and handshake', false, bp.LastError);
      Exit;
    end;
    Check('open and handshake', true,
      Format('Bus Pirate %d REV%d', [bp.Status.HwMajor, bp.Status.HwMinor]));
    WriteLn('    firmware  : ', bp.Status.FwDate, '  (', bp.Status.GitHash, ')');
    WriteLn('    flatbuf   : ', bp.Status.FbMajor, '.', bp.Status.FbMinor);
    WriteLn('    mode      : ', bp.Status.ModeCurrent);
    WriteLn('    modes     : ', bp.Status.Modes);
    WriteLn('    limits    : packet ', bp.Status.MaxPacket,
            ', write ', bp.Status.MaxWrite, ', read ', bp.Status.MaxRead);
    WriteLn;

    Check('status limits are sane',
      (bp.Status.MaxRead >= 64) and (bp.Status.MaxRead <= 4096) and
      (bp.Status.MaxWrite >= 64),
      Format('%d / %d', [bp.Status.MaxWrite, bp.Status.MaxRead]));

    Check('ping', bp.Ping);

    //I2C replaces the SPI checks: there is one bus on the pins, not two.
    if DoI2C then
    begin
      TestI2C(bp, $A0, DoWrite);
      CheckE('back to HiZ with the supply off', bp.EnterHiZ, bp);
      Exit;
    end;

    FillChar(spi, SizeOf(spi), 0);
    spi.SpeedHz := spiHz;
    spi.ChipSelectIdleHigh := true;
    spi.Power := true;
    spi.PsuMv := 3300;
    spi.PsuMa := 300;
    CheckE(Format('enter SPI %d kHz, 3.3 V', [spiHz div 1000]), bp.EnterSPI(spi), bp);

    //JEDEC id through the queue-then-read path the back end really uses.
    cmd[0] := $9F;
    FillChar(jid, SizeOf(jid), 0);
    //Into a local first: FPC does not define the order in which a call's
    //arguments are evaluated, so building the Detail string inline printed the
    //buffer as it was BEFORE the transfer filled it.
    ok := bp.SPIQueueWrite(@cmd[0], 1) and bp.SPITransfer(nil, 0, @jid[0], 3, true);
    Check('SPI queued write + read (JEDEC id)', ok,
      Format('%.2x %.2x %.2x', [jid[0], jid[1], jid[2]]));

    //Same correction bp3probe carries. The 2^n convention for the third byte is
    //not universal: SST parts answer 0x8E for 8 Mbit and 0x8C for 2 Mbit, which
    //are catalogue numbers, so demanding an exponent range failed a perfectly
    //good chip and called it 0 Mbit.  By Dreg
    Check('JEDEC id looks like a flash chip',
      (jid[0] <> 0) and (jid[0] <> $FF) and not ((jid[1] = 0) and (jid[2] = 0)),
      IfThen((jid[2] >= 16) and (jid[2] <= 27),
             Format('%d Mbit', [(1 shl jid[2]) * 8 div 1024 div 1024]),
             'size not encoded as a power of two, check the chip list'));

    cmd[0] := $05;
    sr := $FF;
    ok := bp.SPIQueueWrite(@cmd[0], 1) and bp.SPITransfer(nil, 0, @sr, 1, true);
    Check('read status register', ok, Format('SR1 = 0x%.2x', [sr]));

    //A read longer than one BPIO2 slice, so the splitting is exercised.
    n := 2048;
    SetLength(buf, n);
    cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
    Check(Format('read %d bytes across %d slices', [n, (n + 511) div 512]),
      bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @buf[0], n, true),
      '');

    if Length(buf) >= 16 then
    begin
      Write('    @0x0      : ');
      for i := 0 to 15 do Write(IntToHex(buf[i], 2));
      WriteLn;
    end;

    //The same bytes read a second time must be identical.
    if Length(buf) = n then
    begin
      sum := 0;
      for i := 0 to n - 1 do sum := sum + buf[i];
      cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
      if bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @buf[0], n, true) then
      begin
        for i := 0 to n - 1 do sum := sum - buf[i];
        Check('re-read is byte identical', sum = 0);
      end
      else
        Check('re-read is byte identical', false, bp.LastError);
    end;

    if DumpLen > 0 then
    begin
      SetLength(buf, DumpLen);
      t0 := GetTickCount64;
      i := 0;
      while i < DumpLen do
      begin
        n := DumpLen - i;
        if n > 512 then n := 512;
        cmd[0] := $03;
        cmd[1] := byte((i shr 16) and $FF);
        cmd[2] := byte((i shr 8) and $FF);
        cmd[3] := byte(i and $FF);
        if not (bp.SPIQueueWrite(@cmd[0], 4) and
                bp.SPITransfer(nil, 0, @buf[i], n, true)) then
        begin
          Check('bulk dump', false, bp.LastError);
          Break;
        end;
        Inc(i, n);
      end;
      if i >= DumpLen then
      begin
        t0 := GetTickCount64 - t0;
        if t0 = 0 then t0 := 1;
        sum := 0;
        for i := 0 to DumpLen - 1 do sum := ((sum shl 1) or (sum shr 31)) xor buf[i];
        Check('bulk dump', true, Format('%d bytes in %d ms = %.1f kB/s, checksum %.8x',
          [DumpLen, t0, DumpLen / t0, sum]));
        if DumpFile <> '' then
        begin
          with TFileStream.Create(DumpFile, fmCreate) do
          try
            WriteBuffer(buf[0], DumpLen);
          finally
            Free;
          end;
          WriteLn('    saved     : ', DumpFile);
        end;
      end;
    end;

    if Stress then
    begin
      TestSizes(bp);
      TestSoak(bp, 5, 262144);
      TestAbuse(bp);
    end;

    //Leave the bench safe: no supply, pins high impedance.
    CheckE('back to HiZ with the supply off', bp.EnterHiZ, bp);
  finally
    bp.Free;
  end;
end;

//Every transfer size around the firmware's 512 byte boundary, each verified
//against a reference taken in one go. A size that silently returns the wrong
//number of bytes, or the right number of wrong bytes, shows up here.
procedure TestSizes(bp: TBusPirate5);
const
  Sizes: array[0..17] of integer =
    (1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 63, 64, 127, 128, 255, 256, 511, 512);
var
  ref: array of byte;
  got: array of byte;
  tail: array of byte;
  cmd: array[0..3] of byte;
  i, k, n: integer;
  ok, same: boolean;
begin
  WriteLn;
  WriteLn('Transfer sizes around the 512 byte firmware limit');
  SetLength(ref, 512);
  cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
  if not (bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @ref[0], 512, true)) then
  begin
    Check('reference read', false, bp.LastError);
    Exit;
  end;

  for i := 0 to High(Sizes) do
  begin
    n := Sizes[i];
    SetLength(got, n);
    FillChar(got[0], n, $A5);
    cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
    ok := bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @got[0], n, true);
    same := ok;
    if ok then
      for k := 0 to n - 1 do
        if got[k] <> ref[k] then
        begin
          same := false;
          Break;
        end;
    Check(Format('read of %3d bytes', [n]), same, IfThen(ok, '', bp.LastError));
  end;

  //513 bytes must never reach the firmware as a single request: its over-limit
  //path jumps past the start of its own response table and corrupts the builder
  //for later responses too. Splitting it is therefore the driver's job, and what
  //is asserted here is that it did split it, and that the pieces came back as
  //the right bytes in the right order.
  //A read past the limit has to come back split and still be correct, so build
  //a 513 byte reference the firmware can hold: the 512 already read, plus the
  //byte at 0x200 fetched on its own. Poison the buffer first, or a read that
  //does nothing at all would compare equal to whatever was there.
  SetLength(tail, 1);
  cmd[0] := $03; cmd[1] := 0; cmd[2] := 2; cmd[3] := 0;
  if not (bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @tail[0], 1, true)) then
  begin
    Check('read of 513 bytes is split and still correct', false, bp.LastError);
    Exit;
  end;

  SetLength(got, 513);
  FillChar(got[0], 513, $A5);
  cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
  ok := bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @got[0], 513, true);
  same := ok;
  if ok then
  begin
    for k := 0 to 511 do
      if got[k] <> ref[k] then
      begin
        same := false;
        Break;
      end;
    if same and (got[512] <> tail[0]) then same := false;
  end;
  Check('read of 513 bytes is split and still correct', same,
        IfThen(ok, '', bp.LastError));
end;

//The same bytes read over and over. This is what catches a dropped or
//duplicated USB packet, which a single read cannot.
procedure TestSoak(bp: TBusPirate5; Passes, Bytes: integer);
var
  ref, got: array of byte;
  cmd: array[0..3] of byte;
  p, i: integer;
  ok, same: boolean;
  t0: QWord;
begin
  WriteLn;
  WriteLn(Format('Soak: %d passes over %d bytes', [Passes, Bytes]));
  SetLength(ref, Bytes);
  SetLength(got, Bytes);

  for p := 1 to Passes do
  begin
    t0 := GetTickCount64;
    i := 0;
    ok := true;
    while i < Bytes do
    begin
      cmd[0] := $03;
      cmd[1] := byte((i shr 16) and $FF);
      cmd[2] := byte((i shr 8) and $FF);
      cmd[3] := byte(i and $FF);
      if not (bp.SPIQueueWrite(@cmd[0], 4) and
              bp.SPITransfer(nil, 0, @got[i], 512, true)) then
      begin
        ok := false;
        Break;
      end;
      Inc(i, 512);
    end;
    if not ok then
    begin
      Check(Format('pass %d', [p]), false, bp.LastError);
      Continue;
    end;
    t0 := GetTickCount64 - t0;
    if t0 = 0 then t0 := 1;
    if p = 1 then
    begin
      Move(got[0], ref[0], Bytes);
      Check(Format('pass %d', [p]), true,
        Format('%.0f kB/s  (reference)', [Bytes / t0]));
    end
    else
    begin
      same := true;
      for i := 0 to Bytes - 1 do
        if got[i] <> ref[i] then
        begin
          Check(Format('pass %d', [p]), false, Format('differs at +0x%X', [i]));
          same := false;
          Break;
        end;
      if same then
        Check(Format('pass %d', [p]), true, Format('%.0f kB/s', [Bytes / t0]));
    end;
  end;
end;

//Break the link on purpose and prove it comes back with correct data.
procedure TestAbuse(bp: TBusPirate5);
var
  ref, got: array[0..63] of byte;
  cmd: array[0..3] of byte;
  junk: array[0..15] of byte;
  i, trial: integer;
  ok, same: boolean;
begin
  WriteLn;
  WriteLn('Abuse and recovery');
  cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
  if not (bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @ref[0], 64, true)) then
  begin
    Check('reference read', false, bp.LastError);
    Exit;
  end;

  for trial := 1 to 3 do
  begin
    //Raw garbage straight at the device: not a valid COBS frame, so the
    //firmware answers "COBS decode failed" or ignores it.
    for i := 0 to High(junk) do junk[i] := byte($41 + i);
    bp.Port.WriteAll(junk[0], SizeOf(junk));

    //Whatever state that left, a resync must clear it.
    bp.Resync;

    cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
    ok := bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @got[0], 64, true);
    same := ok;
    if ok then
      for i := 0 to 63 do
        if got[i] <> ref[i] then
        begin
          same := false;
          Break;
        end;
    Check(Format('garbage on the wire, trial %d, recovered', [trial]), same,
          IfThen(ok, '', bp.LastError));
  end;

  //A truncated frame: a COBS delimiter with nothing useful before it.
  junk[0] := 5; junk[1] := 1; junk[2] := 0;
  bp.Port.WriteAll(junk[0], 3);
  bp.Resync;
  cmd[0] := $03; cmd[1] := 0; cmd[2] := 0; cmd[3] := 0;
  ok := bp.SPIQueueWrite(@cmd[0], 4) and bp.SPITransfer(nil, 0, @got[0], 64, true);
  same := ok;
  if ok then
    for i := 0 to 63 do
      if got[i] <> ref[i] then begin same := false; Break; end;
  Check('truncated frame recovered', same, IfThen(ok, '', bp.LastError));
end;

var
  port: string;
  dumpfile: string = '';
  dump: integer = 0;
  stress: boolean = false;
  doI2C: boolean = false;
  doWrite: boolean = false;
  ai: integer;
begin
  WriteLn('bp5probe - Bus Pirate v5+ (BPIO2) Pascal driver check');
  WriteLn('=====================================================');
  WriteLn;

  ShowDevices;
  TestCobs;

  if (ParamCount >= 1) and (UpperCase(Copy(ParamStr(1), 1, 3)) = 'COM') then
    port := ParamStr(1)
  else
    port := AutoPort;

  for ai := 1 to ParamCount do
  begin
    if LowerCase(ParamStr(ai)) = 'stress' then stress := true;
    //A wrong or unstable JEDEC id is usually the wiring, not the chip, and the
    //way to tell is to read it again slowly. Without this the probe could only
    //ever ask at 8 MHz.  By Dreg
    if (LowerCase(ParamStr(ai)) = 'spi') and (ai < ParamCount) then
      spiHz := StrToIntDef(ParamStr(ai + 1), 0);
    if LowerCase(ParamStr(ai)) = 'i2c' then doI2C := true;
    if LowerCase(ParamStr(ai)) = 'write' then doWrite := true;
  end;

  if (ParamCount >= 3) and (LowerCase(ParamStr(2)) = 'dump') then
  begin
    dump := StrToIntDef(ParamStr(3), 0);
    if ParamCount >= 4 then dumpfile := ParamStr(4);
  end;

  if port = '' then
    WriteLn('No Bus Pirate v5+ detected; skipping the hardware checks.')
  else
    TestDevice(port, dump, dumpfile, stress, doI2C, doWrite);

  WriteLn;
  WriteLn('=====================================================');
  if Failures = 0 then
    WriteLn('all checks passed')
  else
    WriteLn(Failures, ' check(s) FAILED');
  ExitCode := Ord(Failures <> 0);
end.
