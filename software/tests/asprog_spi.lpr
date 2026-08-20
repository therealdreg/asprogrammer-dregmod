program asprog_spi;

{
  Drives AsProgrammer's OWN erase / write / read / verify paths against a real
  SPI flash through the BusPirateV5+ (BPIO2) back end, with no clicking.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  Same idea as asprog_i2c: build the real TMainForm, select a chip out of
  chiplist.xml exactly as clicking it would, then call ButtonEraseClick /
  ButtonWriteClick / ButtonReadClick / ButtonVerifyClick. Everything in
  between - OpenDevice, EnterProgMode25, the chunk ladders, ReadFlash25 /
  WriteFlash25 / VerifyFlash25, the busy waits, the 3 vs 4 byte addressing - is
  the code a user actually runs.

  Passing ComboItem1 as the Sender is how the program's own
  "unprotect / erase / write / verify" macro suppresses the confirmation
  dialogs, so this uses the same trick.

    asprog_spi COM19 backup.bin            read the chip and compare
    asprog_spi COM19 backup.bin cycles 3   DESTRUCTIVE: three random
                                           erase/write/read rounds, then
                                           restore from backup.bin

  The form is created but never shown.
}

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Classes, SysUtils, StrUtils,
  main, basehw, spi25, findchip, buspirate5hw, msgstr;

const
  DEFAULT_CHIP = 'W25Q64BV';

var
  //Both come from the chip list once the part is selected, so this harness
  //works on anything in chiplist.xml rather than one hardcoded Winbond.
  CHIP: string = DEFAULT_CHIP;
  SIZE: integer = 0;

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

//The program reports the outcome of a verify only through its log: a clean pass
//ends in STR_DONE, and any mismatch logs STR_VERIFY_ERROR and returns before
//reaching it. Asserting that the call "ran" proves nothing at all, so mark the
//log first and then read the lines it actually added. The markers are
//resourcestrings, so referencing them here picks up whatever translation is
//loaded, exactly as LogPrint wrote it.  By Dreg
function LogMark: integer;
begin
  result := MainForm.Log.Lines.Count;
end;

function LogSaysPassed(Mark: integer; out Detail: string): boolean;
var
  i: integer;
  line: string;
  done: boolean;
begin
  done := false;
  for i := Mark to MainForm.Log.Lines.Count - 1 do
  begin
    line := MainForm.Log.Lines[i];
    if (STR_VERIFY_ERROR <> '') and (Pos(STR_VERIFY_ERROR, line) > 0) then
    begin
      Detail := 'mismatch reported: ' + line;
      Exit(false);
    end;
    if (STR_WRONG_BYTES_READ <> '') and (Pos(STR_WRONG_BYTES_READ, line) > 0) then
    begin
      Detail := 'short read reported: ' + line;
      Exit(false);
    end;
    if (STR_DONE <> '') and (Pos(STR_DONE, line) > 0) then done := true;
  end;
  if done then
    Detail := 'the log reports a clean pass'
  else if MainForm.Log.Lines.Count = Mark then
    Detail := 'the verify logged nothing at all'
  else
    Detail := 'no completion line, the verify stopped early';
  result := done;
end;

function Snapshot: TBytes;
var
  ms: TMemoryStream;
begin
  SetLength(result, 0);
  ms := TMemoryStream.Create;
  try
    MainForm.MPHexEditorEx.SaveToStream(ms);
    SetLength(result, ms.Size);
    if ms.Size > 0 then
    begin
      ms.Position := 0;
      ms.ReadBuffer(result[0], ms.Size);
    end;
  finally
    ms.Free;
  end;
end;

procedure LoadIntoEditor(const Data: TBytes);
var
  ms: TMemoryStream;
begin
  ms := TMemoryStream.Create;
  try
    if Length(Data) > 0 then ms.WriteBuffer(Data[0], Length(Data));
    ms.Position := 0;
    MainForm.MPHexEditorEx.LoadFromStream(ms);
  finally
    ms.Free;
  end;
end;

//A read that silently does nothing would leave the editor holding the image we
//put there ourselves, and the comparison after it would pass without the chip
//having proved anything. Fill the editor with the complement first: it differs
//from the expected image at every single byte, so a read that does not happen
//cannot look like a read that succeeded.  By Dreg
procedure PoisonEditor(const Expected: TBytes);
var
  poison: TBytes;
  i: integer;
begin
  SetLength(poison, Length(Expected));
  for i := 0 to High(poison) do poison[i] := byte(not Expected[i]);
  LoadIntoEditor(poison);
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

function LoadFile(const FN: string): TBytes;
var
  fs: TFileStream;
begin
  SetLength(result, 0);
  if not FileExists(FN) then Exit;
  fs := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
  try
    SetLength(result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure SaveFile(const FN: string; const Data: TBytes);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FN, fmCreate);
  try
    if Length(Data) > 0 then fs.WriteBuffer(Data[0], Length(Data));
  finally
    fs.Free;
  end;
end;

//One full round: erase the chip, write the buffer, read it back, compare.
function Cycle(const Want: TBytes; const Label_: string): boolean;
var
  back: TBytes;
  diff: integer;
  t0: TDateTime;
begin
  WriteLn;
  WriteLn(Label_);
  t0 := Now;

  LoadIntoEditor(Want);
  //ComboItem1 as the Sender is what the program's own macro passes to skip the
  //"are you sure" dialogs; without it these calls would block on a modal box.
  MainForm.ButtonEraseClick(MainForm.ComboItem1);
  MainForm.ButtonWriteClick(MainForm.ComboItem1);

  PoisonEditor(Want);
  MainForm.ButtonReadClick(nil);

  back := Snapshot;
  result := Same(Want, back, diff);
  if result then
    Check(Label_ + ': read back matches', true,
          Format('%d bytes, %s', [Length(back), FormatDateTime('n:ss', Now - t0)]))
  else
    if Length(back) <> Length(Want) then
      Check(Label_ + ': read back matches', false,
            Format('got %d bytes, wanted %d', [Length(back), Length(Want)]))
    else
      Check(Label_ + ': read back matches', false,
            Format('differs at 0x%X: wrote %.2x got %.2x',
                   [diff, Want[diff], back[diff]]));
end;

var
  port, backupFile, detail: string;
  useBP3: boolean = false;
  doUnprotect: boolean = false;
  cycles: integer = 0;
  i, c, diff, mark: integer;
  ok: boolean;
  reference, first, pattern, corrupt: TBytes;
begin
  WriteLn('asprog_spi - AsProgrammer''s own erase, write, read and verify paths');
  WriteLn('=======================================================');
  WriteLn;

  port := 'COM19';
  backupFile := '';
  if (ParamCount >= 1) and (UpperCase(Copy(ParamStr(1), 1, 3)) = 'COM') then
    port := ParamStr(1);
  //Positional, but skip the words that are options or the value of one, or the
  //back end flag ends up being used as the name of the reference image.
  for i := 2 to ParamCount do
    if (LowerCase(ParamStr(i)) <> 'bp3') and
       (LowerCase(ParamStr(i)) <> 'cycles') and
       (LowerCase(ParamStr(i)) <> 'chip') and
       (LowerCase(ParamStr(i)) <> 'unprotect') and
       (LowerCase(ParamStr(i - 1)) <> 'cycles') and
       (LowerCase(ParamStr(i - 1)) <> 'chip') then
    begin
      backupFile := ParamStr(i);
      Break;
    end;
  for i := 1 to ParamCount do
  begin
    if LowerCase(ParamStr(i)) = 'bp3' then useBP3 := true;
    if LowerCase(ParamStr(i)) = 'unprotect' then doUnprotect := true;
    if (LowerCase(ParamStr(i)) = 'chip') and (i < ParamCount) then
      CHIP := ParamStr(i + 1);
    if (LowerCase(ParamStr(i)) = 'cycles') and (i < ParamCount) then
      cycles := StrToIntDef(ParamStr(i + 1), 0);
  end;

  LoadXML;
  Translate(SettingsFile);
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);

  //--- set the program up the way a user would --------------------------------
  if useBP3 then
  begin
    Buzzpirat_COMPort := port;
    //2 Mbaud because the link, not the bus, is what limits a v3: at 115200 an
    //8 MB chip takes about thirteen minutes. The driver drops back to 115200 by
    //itself if the banner says the hardware cannot follow.
    MainForm.MenuBuzzpiratSerial2M.Checked := true;
    MainForm.MenuBuzzpiratPower.Checked := true;
    MainForm.MenuBuzzpiratPullups.Checked := false;
    MainForm.MenuBuzzpiratSPINormal.Checked := true;
    MainForm.MenuBuzzpiratSPI8MHz.Checked := true;
    MainForm.MenuHWBUZZPIRAT.Checked := true;
    MainForm.MenuHWBUZZPIRATClick(nil);
  end
  else
  begin
    BusPirate5_COMPort := port;
    MainForm.MenuBP5Power.Checked := true;
    MainForm.MenuBP5Pullups.Checked := false;
    MainForm.MenuBP5V3V3.Checked := true;
    MainForm.MenuBP5Cur300.Checked := true;
    MainForm.MenuBP5SPI8M.Checked := true;
    MainForm.MenuHWBUSPIRATE5.Checked := true;
    MainForm.MenuHWBUSPIRATE5Click(nil);
  end;

  findchip.SelectChip(ChipListFile, CHIP);
  MainForm.StartAddressEdit.Text := '0';

  //Whatever the chip list said, which is what the program itself will use.
  SIZE := StrToIntDef(MainForm.ComboChipSize.Text, 0);
  if SIZE < 1 then
  begin
    Check('chip selected and sized', false,
          'chiplist.xml has no usable size for ' + CHIP);
    Halt(1);
  end;

  WriteLn('back end    : ', IfThen(useBP3, 'Buzzpirat / Bus Pirate v3 (BBIO)',
                                          'BusPirateV5+ (BPIO2)'));
  WriteLn('port        : ', port);
  WriteLn('chip        : ', CHIP, '  ', MainForm.ComboChipSize.Text, ' bytes, page ',
          MainForm.ComboPageSize.Text);
  //SSTB and SSTW are not page sizes, they select the byte at a time and AAI
  //word write routines, which are a different code path entirely.
  if (UpperCase(MainForm.ComboPageSize.Text) = 'SSTB') or
     (UpperCase(MainForm.ComboPageSize.Text) = 'SSTW') then
    WriteLn('write path  : SST ', UpperCase(MainForm.ComboPageSize.Text),
            ', not ordinary page programming');
  WriteLn('mode        : SPI=', MainForm.RadioSPI.Checked);
  if useBP3 then
    WriteLn('SPI clock   : 8 MHz,  link 2 Mbaud')
  else
    WriteLn('SPI clock   : 8 MHz,  supply 3.3 V / 300 mA');
  WriteLn;

  Check('chip selected and sized', SIZE > 0,
        Format('%d bytes, page %s', [SIZE, MainForm.ComboPageSize.Text]));
  Check('SPI mode selected by the chip', MainForm.RadioSPI.Checked);

  //--- read the whole chip ----------------------------------------------------
  WriteLn;
  WriteLn('Read the whole chip (ButtonReadClick)');
  MainForm.ButtonReadClick(nil);
  first := Snapshot;
  Check('read produced a full image', Length(first) = SIZE,
        Format('%d bytes', [Length(first)]));
  if Length(first) >= 16 then
  begin
    Write('    @0x000000 : ');
    for i := 0 to 15 do Write(IntToHex(first[i], 2));
    WriteLn;
  end;

  //--- against the known good image, if one was given -------------------------
  if backupFile <> '' then
  begin
    reference := LoadFile(backupFile);
    if Length(reference) = 0 then
    begin
      WriteLn('    no reference file yet, saving this read as ', backupFile);
      SaveFile(backupFile, first);
      reference := first;
    end
    else
    begin
      ok := Same(reference, first, diff);
      Check('matches the reference image', ok,
            IfThen(ok, backupFile, Format('differs at 0x%X', [diff])));
    end;
  end
  else
    reference := first;

  //--- read it again ----------------------------------------------------------
  WriteLn;
  WriteLn('Read it again');
  PoisonEditor(first);
  MainForm.ButtonReadClick(nil);
  ok := Same(first, Snapshot, diff);
  Check('second read is byte identical', ok,
        IfThen(ok, '', Format('differs at 0x%X', [diff])));

  //--- verify ------------------------------------------------------------------
  WriteLn;
  WriteLn('Verify the image against the chip (ButtonVerifyClick)');
  LoadIntoEditor(first);
  mark := LogMark;
  MainForm.ButtonVerifyClick(nil);
  ok := LogSaysPassed(mark, detail);
  Check('verify reports a clean pass', ok, detail);

  //And it has to fail when it should. Corrupting one byte of the image the
  //verify is given must produce a mismatch at that address; if it still says
  //the chip matches, the check above was worthless.
  if Length(first) = SIZE then
  begin
    corrupt := Copy(first, 0, Length(first));
    corrupt[SIZE div 3] := byte(not corrupt[SIZE div 3]);
    LoadIntoEditor(corrupt);
    mark := LogMark;
    MainForm.ButtonVerifyClick(nil);
    ok := (not LogSaysPassed(mark, detail)) and (Pos('mismatch reported', detail) = 1);
    Check('verify catches a single flipped byte', ok,
          IfThen(ok, detail, 'it failed, but not by spotting the flip: ' + detail));
    LoadIntoEditor(first);
  end;

  //--- destructive rounds ------------------------------------------------------
  if cycles > 0 then
  begin
    //SST 25 series parts power up with every block protected, so an erase and a
    //write both do nothing and still report success. Clearing that is what the
    //Unprotect button is for, and without it a run here passes for the wrong
    //reason: the chip keeps its old contents, so the restore at the end
    //"matches" without anything having been written.  By Dreg
    if doUnprotect then
    begin
      WriteLn;
      WriteLn('Clearing the write protection (ButtonBlockClick)');
      MainForm.ButtonBlockClick(nil);
    end;

    Randomize;
    for c := 1 to cycles do
    begin
      SetLength(pattern, SIZE);
      for i := 0 to High(pattern) do pattern[i] := byte(Random(256));
      if not Cycle(pattern, Format('Round %d of %d, random data', [c, cycles])) then
        Break;
    end;

    if Length(reference) = SIZE then
      Cycle(reference, 'Restore the original contents')
    else
      WriteLn('  no reference image, leaving the random data on the chip');
  end
  else
  begin
    WriteLn;
    WriteLn('  (add "cycles N" to also run N erase/write/read rounds)');
  end;

  AsProgrammer.Programmer.DevClose;

  WriteLn;
  WriteLn('=======================================================');
  if Failures = 0 then
    WriteLn('all checks passed')
  else
    WriteLn(Failures, ' check(s) FAILED');
  ExitCode := Ord(Failures <> 0);
end.
