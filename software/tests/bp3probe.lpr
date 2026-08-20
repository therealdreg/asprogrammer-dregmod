program bp3probe;

{
  Exercises the Pascal BBIO engine in buzzpirathw.pas against a real Bus Pirate
  v3.x / Buzzpirat, without the GUI.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  This drives TBusPirate directly - the same transport, bitbang walk, banner
  parsing, serial speed negotiation and SPI engine the AsProgrammer back end
  uses - so a pass here means the Pascal implementation works on the wire.

    bp3probe COM22                   run every check at 115200
    bp3probe COM22 baud 2000000      also negotiate up and re-test there
    bp3probe COM22 dump 65536 f.bin  read N bytes to a file

  Build with tests\build_bp3probe.cmd after building AsProgrammer.
}

{$mode objfpc}{$H+}

uses
  //Interfaces only so the LCL links: buzzpirathw pulls in main for the menu
  //settings, and main is a GUI unit. No form is created here - the engine
  //layer this program drives never touches MainForm.
  Interfaces, Classes, SysUtils, StrUtils, buzzpirathw;

var
  Failures: integer = 0;

procedure Check(const Name: string; Ok: boolean; const Detail: string = '');
begin
  if Ok then
    WriteLn(Format('  PASS  %-46s %s', [Name, Detail]))
  else
  begin
    WriteLn(Format('  FAIL  %-46s %s', [Name, Detail]));
    Inc(Failures);
  end;
end;

procedure ShowVersionRules(bp: TBusPirate);
const
  Rates: array[0..4] of LongWord = (115200, 230400, 250000, 1000000, 2000000);
var
  i: integer;
  usable: LongWord;
  reason: string;
begin
  WriteLn;
  WriteLn('Version rules (flashrom buspirate_spi.c, unchanged)');
  WriteLn(Format('    hardware  : v%d.%d', [bp.HwMajor, bp.HwMinor]));
  WriteLn(Format('    firmware  : v%d.%d', [bp.FwMajor, bp.FwMinor]));
  WriteLn(Format('    buzzpirat : %s', [BoolToStr(bp.IsBuzzpirat, 'yes', 'no')]));
  Check('binary SPI supported (firmware >= 2.4)', bp.SupportsBinarySPI);

  for i := 0 to High(Rates) do
  begin
    usable := bp.UsableSerialSpeed(Rates[i], reason);
    if usable = Rates[i] then
      WriteLn(Format('    %7d baud -> allowed', [Rates[i]]))
    else
      WriteLn(Format('    %7d baud -> %d  (%s)', [Rates[i], usable, reason]));
  end;
end;

function ReadFlash(bp: TBusPirate; Addr, Len: integer; var Buf: array of byte): boolean;
var
  cmd: array[0..3] of byte;
begin
  cmd[0] := $03;
  cmd[1] := byte((Addr shr 16) and $FF);
  cmd[2] := byte((Addr shr 8) and $FF);
  cmd[3] := byte(Addr and $FF);
  result := bp.SPIQueueWrite(@cmd[0], 4) and
            bp.SPITransfer(nil, 0, @Buf[0], Len, true);
end;

procedure TestSPI(bp: TBusPirate; const Where: string; SpiIdx: byte;
                  DumpLen: integer; const DumpFile: string);
var
  spi: TBPSPISettings;
  jid: array[0..2] of byte;
  cmd: array[0..0] of byte;
  sr: byte;
  buf, buf2: array of byte;
  i, n: integer;
  ok, same: boolean;
  t0: QWord;
begin
  WriteLn;
  WriteLn(Format('SPI at %s, clock index %d = %d Hz',
                 [Where, SpiIdx, BP_SPI_SPEED_HZ[SpiIdx]]));

  FillChar(spi, SizeOf(spi), 0);
  spi.Speed := SpiIdx;
  spi.PushPull := true;
  spi.Power := true;
  spi.AuxHigh := true;
  spi.ClockEdgeActiveToIdle := true;
  Check('enter SPI', bp.EnterSPI(spi), bp.LastError);

  cmd[0] := $9F;
  FillChar(jid, SizeOf(jid), 0);
  ok := bp.SPIQueueWrite(@cmd[0], 1) and bp.SPITransfer(nil, 0, @jid[0], 3, true);
  Check('JEDEC id', ok, Format('%.2x %.2x %.2x', [jid[0], jid[1], jid[2]]));
  //The 2^n convention for the third byte is not universal. SST parts answer
  //0x8E for 8 Mbit and 0x8C for 2 Mbit, which are catalogue numbers rather than
  //exponents, so the old check called a perfectly good SST25VF080B "0 Mbit" and
  //failed on it. What this can honestly assert is that something answered with
  //a manufacturer byte, and it reports a size only where the exponent
  //convention actually applies.  By Dreg
  Check('JEDEC id looks like a flash chip',
        ok and (jid[0] <> 0) and (jid[0] <> $FF) and
        not ((jid[1] = 0) and (jid[2] = 0)),
        IfThen((jid[2] >= 16) and (jid[2] <= 27),
               Format('%d Mbit', [(1 shl jid[2]) * 8 div 1024 div 1024]),
               'size not encoded as a power of two, check the chip list'));

  cmd[0] := $05;
  sr := $FF;
  ok := bp.SPIQueueWrite(@cmd[0], 1) and bp.SPITransfer(nil, 0, @sr, 1, true);
  Check('status register', ok, Format('SR1 = 0x%.2x', [sr]));

  //Two reads of the same region must agree, and must survive slicing.
  n := 8192;
  SetLength(buf, n);
  SetLength(buf2, n);
  t0 := GetTickCount64;
  ok := ReadFlash(bp, 0, n, buf);
  t0 := GetTickCount64 - t0;
  if t0 = 0 then t0 := 1;
  Check(Format('read %d bytes across %d slices', [n, (n + 4095) div 4096]), ok,
        Format('%.1f kB/s', [n / t0]));

  if ok then
  begin
    Write('    @0x0      : ');
    for i := 0 to 15 do Write(IntToHex(buf[i], 2));
    WriteLn;

    ok := ReadFlash(bp, 0, n, buf2);
    same := ok;
    if ok then
      for i := 0 to n - 1 do
        if buf[i] <> buf2[i] then
        begin
          same := false;
          Check('re-read is byte identical', false, Format('differs at +0x%X', [i]));
          Break;
        end;
    if same then Check('re-read is byte identical', true);
  end;

  if DumpLen > 0 then
  begin
    SetLength(buf, DumpLen);
    t0 := GetTickCount64;
    i := 0;
    ok := true;
    while i < DumpLen do
    begin
      n := DumpLen - i;
      if n > 4096 then n := 4096;
      if not ReadFlash(bp, i, n, PByte(@buf[i])^) then
      begin
        ok := false;
        Break;
      end;
      Inc(i, n);
    end;
    if ok then
    begin
      t0 := GetTickCount64 - t0;
      if t0 = 0 then t0 := 1;
      Check('bulk dump', true, Format('%d bytes in %d ms = %.1f kB/s',
                                      [DumpLen, t0, DumpLen / t0]));
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
    end
    else
      Check('bulk dump', false, bp.LastError);
  end;
end;

//An AT24C256 style part: 32 KB, 64 byte pages, two byte internal address.
//Everything here goes through the same calls AsProgrammer's I2C paths use.
procedure TestI2C(bp: TBusPirate; DevAddr: byte; Destructive: boolean);
const
  PAGE = 64;
var
  i2c: TBPI2CSettings;
  found: TBytes;
  wr: array[0..1] of byte;
  buf, ref, pat: array of byte;
  i, n, addr: integer;
  ok, same, acked: boolean;
  b: byte;
  list: string;
begin
  WriteLn;
  WriteLn('I2C');

  FillChar(i2c, SizeOf(i2c), 0);
  i2c.Speed := 2;          //100 kHz
  i2c.Pullups := true;     //no pull-ups, no bus
  i2c.Power := true;
  i2c.AuxHigh := true;
  Check('enter I2C 100 kHz, pull-ups and power on', bp.EnterI2C(i2c), bp.LastError);

  ok := bp.I2CScan(8, 119, found);
  list := '';
  for i := 0 to High(found) do
    list := list + IntToHex(found[i], 2) + ' ';
  Check('bus scan', ok, Format('%d device(s): %s', [Length(found), list]));
  if not ok then Exit;

  if Length(found) = 0 then
  begin
    Check('an EEPROM answered', false,
          'nothing on the bus - check SDA/SCL, a common ground, and that Vpullup is fed');
    Exit;
  end;

  //Prefer the address the caller asked for, else take the first hit.
  ok := false;
  for i := 0 to High(found) do
    if found[i] = (DevAddr shr 1) then ok := true;
  if not ok then
  begin
    DevAddr := byte((found[0] shl 1) and $FF);
    WriteLn(Format('    using 7-bit 0x%.2x (write 0x%.2x)', [found[0], DevAddr]));
  end;

  //--- read through the write-then-read path AsProgrammer really uses --------
  n := 64;
  SetLength(ref, n);
  wr[0] := 0; wr[1] := 0;
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @ref[0], n);
  Check('read 64 bytes from address 0', ok, bp.LastError);
  if ok then
  begin
    Write('    @0x0000   : ');
    for i := 0 to 15 do Write(IntToHex(ref[i], 2));
    WriteLn;
  end;

  //--- the same bytes twice must agree --------------------------------------
  SetLength(buf, n);
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], n);
  same := ok;
  if ok then
    for i := 0 to n - 1 do
      if buf[i] <> ref[i] then begin same := false; Break; end;
  Check('re-read is byte identical', same, bp.LastError);

  //--- a read that crosses the device's internal page boundary --------------
  SetLength(buf, 256);
  wr[0] := 0; wr[1] := 0;
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], 256);
  same := ok;
  if ok then
    for i := 0 to 63 do
      if buf[i] <> ref[i] then begin same := false; Break; end;
  Check('read 256 bytes, first 64 still match', same, bp.LastError);

  //--- the byte level primitives, which the busy poll uses ------------------
  ok := bp.I2CStart;
  if ok then ok := bp.I2CWriteByte(DevAddr, acked);
  Check('start + address byte acknowledged', ok and acked, bp.LastError);
  if ok then bp.I2CStop;

  ok := bp.I2CStart;
  if ok then ok := bp.I2CWriteByte(byte(DevAddr or $F0), acked);
  Check('an address nobody owns is NOT acknowledged', ok and (not acked), bp.LastError);
  if ok then bp.I2CStop;

  if not Destructive then
  begin
    WriteLn('    (add "write" to also test erase/program/verify)');
    Exit;
  end;

  //--- write / read back ----------------------------------------------------
  WriteLn;
  WriteLn('  DESTRUCTIVE: page write and verify at 0x0000');
  //Print the original page in full first: if anything goes wrong after this
  //point, these bytes are what the chip held and can be put back by hand.
  Write('    original  : ');
  for i := 0 to PAGE - 1 do Write(IntToHex(ref[i], 2));
  WriteLn;
  SetLength(pat, PAGE);
  for i := 0 to PAGE - 1 do pat[i] := byte((i * 7 + 13) and $FF);

  SetLength(buf, PAGE + 2);
  buf[0] := 0; buf[1] := 0;
  Move(pat[0], buf[2], PAGE);
  ok := bp.I2CWriteRead(DevAddr, @buf[0], PAGE + 2, nil, 0);
  Check('page program', ok, bp.LastError);

  //The part stops answering while it burns; poll until it does.
  addr := 0;
  repeat
    Sleep(2);
    Inc(addr);
    ok := bp.I2CStart;
    if ok then ok := bp.I2CWriteByte(DevAddr, acked);
    if ok then bp.I2CStop;
  until (ok and acked) or (addr > 100);
  Check('acknowledge polling finished', ok and acked, Format('%d polls', [addr]));

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

  //--- put the original bytes back -----------------------------------------
  SetLength(buf, PAGE + 2);
  buf[0] := 0; buf[1] := 0;
  Move(ref[0], buf[2], PAGE);
  ok := bp.I2CWriteRead(DevAddr, @buf[0], PAGE + 2, nil, 0);
  addr := 0;
  repeat
    Sleep(2);
    Inc(addr);
    if bp.I2CStart then
    begin
      bp.I2CWriteByte(DevAddr, acked);
      bp.I2CStop;
    end;
  until acked or (addr > 100);
  SetLength(buf, PAGE);
  wr[0] := 0; wr[1] := 0;
  ok := bp.I2CWriteRead(DevAddr, @wr[0], 2, @buf[0], PAGE);
  same := ok;
  if ok then
    for i := 0 to PAGE - 1 do
      if buf[i] <> ref[i] then begin same := false; Break; end;
  Check('original contents restored', same, bp.LastError);
end;

var
  bp: TBusPirate;
  port: string;
  dumpfile: string = '';
  dump: integer = 0;
  wantBaud: LongWord = 0;
  spiIdx: byte = 1;
  doI2C: boolean = false;
  doWrite: boolean = false;
  i2cAddr: byte = $A0;
  usable: LongWord;
  reason: string;
  i: integer;
begin
  WriteLn('bp3probe - Bus Pirate v3.x / Buzzpirat Pascal driver check');
  WriteLn('==========================================================');
  WriteLn;
  WriteLn('serial ports: ', BPSerialPortList);
  WriteLn;

  port := 'COM22';
  if (ParamCount >= 1) and (UpperCase(Copy(ParamStr(1), 1, 3)) = 'COM') then
    port := ParamStr(1);
  for i := 1 to ParamCount - 1 do
  begin
    if LowerCase(ParamStr(i)) = 'baud' then wantBaud := StrToIntDef(ParamStr(i + 1), 0);
    if LowerCase(ParamStr(i)) = 'spi' then spiIdx := byte(StrToIntDef(ParamStr(i + 1), 1));
    if LowerCase(ParamStr(i)) = 'dump' then
    begin
      dump := StrToIntDef(ParamStr(i + 1), 0);
      if ParamCount >= i + 2 then dumpfile := ParamStr(i + 2);
    end;
  end;

  for i := 1 to ParamCount do
  begin
    if LowerCase(ParamStr(i)) = 'i2c' then doI2C := true;
    if LowerCase(ParamStr(i)) = 'write' then doWrite := true;
  end;

  bp := TBusPirate.Create;
  try
    WriteLn('Opening ', port, ' ...');
    if not bp.Open(port) then
    begin
      Check('open and enter bitbang', false, bp.LastError);
      WriteLn;
      WriteLn(Failures, ' check(s) FAILED');
      ExitCode := 1;
      Exit;
    end;
    Check('open and enter bitbang', true, IntToStr(bp.Port.BaudRate) + ' baud');

    Check('reset to terminal and read the banner', bp.ResetToTerminal, bp.LastError);
    WriteLn('    banner    : ', StringReplace(Trim(bp.Banner), LineEnding, ' | ', [rfReplaceAll]));

    ShowVersionRules(bp);

    if wantBaud > BP_DEFAULT_BAUD then
    begin
      usable := bp.UsableSerialSpeed(wantBaud, reason);
      if usable <> wantBaud then
        Check(Format('negotiate %d baud', [wantBaud]), true,
              Format('held at %d - %s', [usable, reason]))
      else
      begin
        Check(Format('negotiate %d baud', [wantBaud]),
              bp.SetHighSpeedSerial(wantBaud), bp.LastError);
        Check('link really is at the new rate', bp.Port.BaudRate = wantBaud,
              IntToStr(bp.Port.BaudRate) + ' baud');
      end;
    end;

    Check('enter bitbang from the terminal', bp.EnterBitbang, bp.LastError);

    if doI2C then
      TestI2C(bp, i2cAddr, doWrite)
    else
      TestSPI(bp, IntToStr(bp.Port.BaudRate) + ' baud', spiIdx, dump, dumpfile);

    //Park it the way the driver would.
    if not doI2C then bp.SPISetCS(false);
  finally
    bp.Close(true);
    bp.Free;
  end;

  WriteLn;
  WriteLn('==========================================================');
  if Failures = 0 then
    WriteLn('all checks passed')
  else
    WriteLn(Failures, ' check(s) FAILED');
  ExitCode := Ord(Failures <> 0);
end.
