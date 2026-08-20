program bp3clocks;

{
  Drives every entry of the Buzzpirat / BusPirateV3 SPI clock menu through
  AsProgrammer's own back end and reads the chip at each one.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  This is the only test that covers the menu to firmware index mapping, and it
  exists because that mapping is not one table but two. The real Bus Pirate v3
  firmware indexes its own twelve entry spi_bus_speed[], whose order stops
  agreeing with the BBIO documentation above 1 MHz. The Bus Pirate v5/v6/v7
  legacy emulation is a separate implementation that decodes the documented
  order and only accepts 0x60..0x67, so a PIC index of 9 or 11 is not merely
  the wrong clock there: it falls outside that range, is taken as the 0x40
  peripheral command instead, and switches the target supply on while leaving
  the SPI clock unconfigured. The driver picks the table from the banner, and
  what this program checks is that whichever table it picked, every entry in
  the menu still reads the chip correctly.

  Run it against either device. Point it at a chip you do not mind reading:
  nothing here writes.

    tests\build\bp3clocks.exe COM19
    tests\build\bp3clocks.exe COM19 W25Q64BV
}

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Menus, Classes, SysUtils, StrUtils,
  main, basehw, spi25, findchip, buzzpirathw;

const
  //Enough to catch a clock that is wrong rather than dead, without waiting for
  //a whole chip at 115200 baud.
  SAMPLE = 4096;

var
  Failures: integer = 0;

procedure Check(const Name: string; Ok: boolean; const Detail: string = '');
begin
  if Ok then
    WriteLn(Format('  PASS  %-42s %s', [Name, Detail]))
  else
  begin
    WriteLn(Format('  FAIL  %-42s %s', [Name, Detail]));
    Inc(Failures);
  end;
end;

//Reads through the same path the Read IC button uses, so the clock really is
//the one the menu selected.
function ReadSample(out Data: TBytes): boolean;
var
  got: integer;
begin
  SetLength(Data, SAMPLE);
  FillChar(Data[0], SAMPLE, $A5);
  got := UsbAsp25_Read($03, 0, Data[0], SAMPLE);
  result := got = SAMPLE;
end;

function Same(const A, B: TBytes; out FirstDiff: integer): boolean;
var
  i: integer;
begin
  FirstDiff := -1;
  if Length(A) <> Length(B) then Exit(false);
  for i := 0 to High(A) do
    if A[i] <> B[i] then
    begin
      FirstDiff := i;
      Exit(false);
    end;
  result := true;
end;

//A region that is blank, or all one value, compares equal at every clock
//whatever the driver sent, so it cannot tell a right index from a wrong one.
//Count the distinct byte values rather than just looking for 0xFF: an erased
//sector, a region of zeros and a repeated pattern are all equally useless.
function VariedEnough(const D: TBytes): boolean;
var
  seen: array[0..255] of boolean;
  i, distinct: integer;
begin
  FillChar(seen, SizeOf(seen), 0);
  distinct := 0;
  for i := 0 to High(D) do
    if not seen[D[i]] then
    begin
      seen[D[i]] := true;
      Inc(distinct);
      if distinct >= 16 then Exit(true);
    end;
  result := false;
end;

function Hex16(const D: TBytes): string;
var
  i: integer;
begin
  result := '';
  for i := 0 to 15 do
    if i <= High(D) then result := result + IntToHex(D[i], 2);
end;

type
  TClockEntry = record
    Item: ^TMenuItem;
    Name: string;
  end;

var
  port, chip: string;
  entries: array[0..7] of TClockEntry;
  reference, got: TBytes;
  i, diff: integer;
  ok: boolean;
  bp: TBuzzpiratHardware;

procedure ClearClocks;
begin
  MainForm.MenuBuzzpiratSPI30KHz.Checked := false;
  MainForm.MenuBuzzpiratSPI125KHz.Checked := false;
  MainForm.MenuBuzzpiratSPI250KHz.Checked := false;
  MainForm.MenuBuzzpiratSPI1MHz.Checked := false;
  MainForm.MenuBuzzpiratSPI2MHz.Checked := false;
  MainForm.MenuBuzzpiratSPI2P6MHz.Checked := false;
  MainForm.MenuBuzzpiratSPI4MHz.Checked := false;
  MainForm.MenuBuzzpiratSPI8MHz.Checked := false;
end;

begin
  WriteLn('bp3clocks - every SPI clock the v3 menu offers, on real hardware');
  WriteLn('===============================================================');
  WriteLn;

  port := 'COM19';
  chip := 'W25Q64BV';
  if (ParamCount >= 1) and (UpperCase(Copy(ParamStr(1), 1, 3)) = 'COM') then
    port := ParamStr(1);
  if ParamCount >= 2 then chip := ParamStr(2);

  LoadXML;
  Translate(SettingsFile);
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);

  Buzzpirat_COMPort := port;
  MainForm.MenuBuzzpiratPower.Checked := true;
  MainForm.MenuBuzzpiratPullups.Checked := false;
  MainForm.MenuBuzzpiratSerial115200.Checked := true;
  MainForm.MenuHWBUZZPIRAT.Checked := true;
  MainForm.MenuHWBUZZPIRATClick(nil);

  findchip.SelectChip(ChipListFile, chip);
  MainForm.StartAddressEdit.Text := '0';

  WriteLn('port  : ', port);
  WriteLn('chip  : ', chip);
  WriteLn;

  if not OpenDevice then
  begin
    Check('open the device', false, 'could not open ' + port);
    Halt(1);
  end;

  bp := BuzzpiratDev;
  WriteLn('banner: ', bp.BannerSummary);
  if bp.UsesDocumentedTable then
    WriteLn('table : the documented BBIO order, so this is a v5+ legacy emulation')
  else
    WriteLn('table : the firmware spi_bus_speed[] order, so this is a real v3');
  WriteLn;

  entries[0].Item := @MainForm.MenuBuzzpiratSPI30KHz;  entries[0].Name := '30 kHz';
  entries[1].Item := @MainForm.MenuBuzzpiratSPI125KHz; entries[1].Name := '125 kHz';
  entries[2].Item := @MainForm.MenuBuzzpiratSPI250KHz; entries[2].Name := '250 kHz';
  entries[3].Item := @MainForm.MenuBuzzpiratSPI1MHz;   entries[3].Name := '1 MHz';
  entries[4].Item := @MainForm.MenuBuzzpiratSPI2MHz;   entries[4].Name := '2 MHz';
  entries[5].Item := @MainForm.MenuBuzzpiratSPI2P6MHz; entries[5].Name := '2.6 MHz';
  entries[6].Item := @MainForm.MenuBuzzpiratSPI4MHz;   entries[6].Name := '4 MHz';
  entries[7].Item := @MainForm.MenuBuzzpiratSPI8MHz;   entries[7].Name := '8 MHz';

  //125 kHz sets the reference every other clock has to reproduce. Not the
  //slowest entry: 30 kHz would be more conservative, but the whole run happens
  //over a 115200 baud link and 125 kHz is already far below anything the wiring
  //struggles with.
  //
  //The sample is the first 4 KB of the chip, and it is only as good as that
  //data: on a blank or uniform region every clock agrees trivially, so a
  //reference with no variation in it is rejected rather than trusted.
  ClearClocks;
  entries[1].Item^.Checked := true;

  //The same disconnect and reopen every loop entry does. Without it the driver
  //takes its fast path and keeps the clock the saved settings already applied,
  //so this read happens at whatever buzzpirat_spi_speed says in settings.xml
  //and not at the rate this line claims. A reference captured at a marginal
  //clock then disagrees with all eight entries and the run blames the index
  //mapping for it.  By Dreg
  MainForm.MenuBuzzpiratDisconnectClick(nil);
  if not OpenDevice then
  begin
    Check('reference read at 125 kHz', false, 'could not reopen the device');
    Halt(1);
  end;

  if not ReadSample(reference) then
  begin
    Check('reference read at 125 kHz', false, 'no data');
    Halt(1);
  end;
  //Print the index that was really in force rather than asserting the rate in a
  //string, so the record shows what happened.
  Check(Format('reference read at 125 kHz (index %d)', [bp.SPIClockIndex]),
        true, Hex16(reference));

  //Without this the whole run can pass on a blank chip while proving nothing.
  if not VariedEnough(reference) then
  begin
    Check('the reference carries enough variation to compare', false,
          'fewer than 16 distinct byte values in the first 4 KB, so every clock ' +
          'would agree whatever index was sent. Point this at a chip with real ' +
          'content in its first sector.');
    Halt(1);
  end;
  Check('the reference carries enough variation to compare', true);
  WriteLn;

  for i := 0 to High(entries) do
  begin
    ClearClocks;
    entries[i].Item^.Checked := true;

    //Force the settings signature to change so the driver re-arms the mode and
    //actually sends the new clock, which is the thing under test.
    MainForm.MenuBuzzpiratDisconnectClick(nil);
    if not OpenDevice then
    begin
      Check(entries[i].Name, false, 'could not reopen the device');
      Continue;
    end;

    if not ReadSample(got) then
    begin
      Check(entries[i].Name, false, 'short read');
      Continue;
    end;

    ok := Same(reference, got, diff);
    if ok then
      Check(entries[i].Name, true,
            Format('index %d, %d bytes match', [bp.SPIClockIndex, SAMPLE]))
    else
      Check(entries[i].Name, false,
            Format('index %d, differs at 0x%X: %.2x instead of %.2x',
                   [bp.SPIClockIndex, diff, got[diff], reference[diff]]));
  end;

  MainForm.MenuBuzzpiratDisconnectClick(nil);

  WriteLn;
  WriteLn('===============================================================');
  if Failures = 0 then
    WriteLn('all checks passed')
  else
    WriteLn(Failures, ' check(s) FAILED');
  Halt(Ord(Failures <> 0));
end.
