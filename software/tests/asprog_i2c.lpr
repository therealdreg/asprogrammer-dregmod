program asprog_i2c;

{
  Drives AsProgrammer's OWN read / write / verify paths against a real I2C
  EEPROM, with no clicking.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  bp3probe exercises the driver engine. This exercises the program: it builds
  the real TMainForm, selects a chip out of chiplist.xml exactly as clicking the
  chip menu would, sets the I2C address toggles through the same code the scan
  dialog uses, and then calls ButtonReadClick / ButtonWriteClick /
  ButtonVerifyClick. Everything in between - OpenDevice, the chunk size
  ladders, ReadFlashI2C / WriteFlashI2C / VerifyFlashI2C, the acknowledge
  polling, the page arithmetic - is the code a user actually runs.

    asprog_i2c COM22                read the whole chip and check it twice
    asprog_i2c COM22 write          DESTRUCTIVE: random fill, write, verify,
                                    then put the original contents back

  The form is created but never shown.
}

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Classes, SysUtils, StrUtils, Menus,
  main, basehw, i2c, findchip, buzzpirathw, buspirate5hw, msgstr;

const
  CHIP = '_24C256';
  DEV7 = $50;

var
  Failures: integer = 0;

var
  LogShown: integer = 0;

//On a failure, print what the program itself said. Without this a failing run
//reports the symptom and hides the one line that explains it.  By Dreg
procedure DumpLog;
var
  i: integer;
begin
  if MainForm = nil then Exit;
  for i := LogShown to MainForm.Log.Lines.Count - 1 do
    WriteLn('        log| ', MainForm.Log.Lines[i]);
  LogShown := MainForm.Log.Lines.Count;
end;

procedure Check(const Name: string; Ok: boolean; const Detail: string = '');
begin
  if Ok then
    WriteLn(Format('  PASS  %-46s %s', [Name, Detail]))
  else
  begin
    WriteLn(Format('  FAIL  %-46s %s', [Name, Detail]));
    DumpLog;
    Inc(Failures);
  end;
end;

//Snapshot of the hex editor, which is where every operation leaves its data.
//A verify reports its result only through the log: a clean pass ends in
//STR_DONE, any mismatch logs STR_VERIFY_ERROR and returns before reaching it.
//Checking that the call "ran" proves nothing, and on this back end it hid a
//verify that could never succeed at all.  By Dreg
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
    if (STR_I2C_NO_ANSWER <> '') and (Pos(STR_I2C_NO_ANSWER, line) > 0) then
    begin
      Detail := 'the chip stopped answering: ' + line;
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

//A read that silently does nothing leaves the editor holding whatever we put
//there, and the comparison after it passes without the chip proving anything.
//The complement differs at every byte, so a read that did not happen cannot
//look like one that worked.  By Dreg
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

var
  port, detail: string;
  destructive: boolean = false;
  useBP5: boolean = false;
  i, diff, mark: integer;
  ok: boolean;
  original, first, second, pattern, back, corrupt: TBytes;
begin
  WriteLn('asprog_i2c - AsProgrammer''s own I2C paths against real hardware');
  WriteLn('================================================================');
  WriteLn;

  port := 'COM22';
  if (ParamCount >= 1) and (UpperCase(Copy(ParamStr(1), 1, 3)) = 'COM') then
    port := ParamStr(1);
  for i := 1 to ParamCount do
  begin
    if LowerCase(ParamStr(i)) = 'write' then destructive := true;
    if LowerCase(ParamStr(i)) = 'bp5' then useBP5 := true;
  end;

  //Same startup the real program does, minus showing anything.
  LoadXML;
  Translate(SettingsFile);
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);

  //--- set the program up the way a user would --------------------------------
  //The same calls the menu clicks make, so the hardware switch goes through
  //exactly the path a user takes.
  if useBP5 then
  begin
    BusPirate5_COMPort := port;
    MainForm.MenuBP5Pullups.Checked := true;
    MainForm.MenuBP5Power.Checked := true;
    MainForm.MenuBP5V5V0.Checked := true;
    MainForm.MenuBP5I2C100K.Checked := true;
    MainForm.MenuHWBUSPIRATE5.Checked := true;
    MainForm.MenuHWBUSPIRATE5Click(nil);
  end
  else
  begin
    Buzzpirat_COMPort := port;
    MainForm.MenuBuzzpiratSerial2M.Checked := true;
    MainForm.MenuBuzzpiratPullups.Checked := true;
    MainForm.MenuBuzzpiratPower.Checked := true;
    MainForm.MenuBuzzpiratI2C100KHz.Checked := true;
    MainForm.MenuHWBUZZPIRAT.Checked := true;
    MainForm.MenuHWBUZZPIRATClick(nil);
  end;

  //Selecting the chip fills CurrentICParam and the size/page/addrtype combos,
  //exactly as clicking it in the chip menu does.
  findchip.SelectChip(ChipListFile, CHIP);
  MainForm.ApplyI2CAddress(DEV7);
  MainForm.StartAddressEdit.Text := '0';

  WriteLn('back end    : ', IfThen(useBP5, 'BusPirateV5+ (BPIO2)', 'Buzzpirat / Bus Pirate v3'));
  WriteLn('port        : ', port);
  WriteLn('chip        : ', CHIP, '  ', MainForm.ComboChipSize.Text, ' bytes, page ',
          MainForm.ComboPageSize.Text, ', addrtype ', MainForm.ComboAddrType.ItemIndex);
  WriteLn('I2C address : 7-bit 0x', IntToHex(DEV7, 2));
  WriteLn('mode        : I2C=', MainForm.RadioI2C.Checked, ' SPI=', MainForm.RadioSPI.Checked);
  WriteLn;

  Check('chip selected and sized', MainForm.ComboChipSize.Text = '32768',
        MainForm.ComboChipSize.Text + ' bytes');
  Check('I2C mode selected by the chip', MainForm.RadioI2C.Checked);

  //--- read the whole chip ----------------------------------------------------
  WriteLn;
  WriteLn('Read the whole chip (ButtonReadClick)');
  MainForm.ButtonReadClick(nil);
  first := Snapshot;
  Check('read produced a full image', Length(first) = 32768,
        Format('%d bytes', [Length(first)]));
  if Length(first) >= 16 then
  begin
    Write('    @0x0000   : ');
    for i := 0 to 15 do Write(IntToHex(first[i], 2));
    WriteLn;
  end;
  original := Copy(first, 0, Length(first));

  //--- read it again; the two must agree --------------------------------------
  WriteLn;
  WriteLn('Read it again');
  MainForm.ButtonReadClick(nil);
  second := Snapshot;
  //Into a local first: FPC does not define the order in which a call's
  //arguments are evaluated, so building the Detail from `diff` inline read it
  //before Same() had set it.
  ok := Same(first, second, diff);
  Check('second read is byte identical to the first', ok,
        IfThen(ok, '', Format('differs at 0x%X', [diff])));

  //--- verify the image we just read against the chip -------------------------
  WriteLn;
  WriteLn('Verify the image against the chip (ButtonVerifyClick)');
  mark := LogMark;
  MainForm.ButtonVerifyClick(nil);
  ok := LogSaysPassed(mark, detail);
  Check('verify of a freshly read image reports a clean pass', ok, detail);

  //And it has to fail when it should. Flip one byte of the image the verify is
  //given: if it still says the chip matches, the check above proves nothing.
  corrupt := Copy(first, 0, Length(first));
  if Length(corrupt) > 0 then
  begin
    corrupt[Length(corrupt) div 3] := byte(not corrupt[Length(corrupt) div 3]);
    LoadIntoEditor(corrupt);
    mark := LogMark;
    MainForm.ButtonVerifyClick(nil);
    ok := (not LogSaysPassed(mark, detail)) and (Pos('mismatch reported', detail) = 1);
    Check('verify catches a single flipped byte', ok,
          IfThen(ok, detail, 'it failed, but not by spotting the flip: ' + detail));
    LoadIntoEditor(first);
  end;

  if not destructive then
  begin
    WriteLn;
    WriteLn('  (add "write" to also test a full-chip write and restore)');
  end
  else
  begin
    //--- fill with random, write the whole chip, read it back ----------------
    WriteLn;
    WriteLn('DESTRUCTIVE: fill 32768 bytes with random data and write it');
    Randomize;
    SetLength(pattern, 32768);
    for i := 0 to High(pattern) do pattern[i] := byte(Random(256));
    LoadIntoEditor(pattern);
    Check('hex editor holds the pattern', Length(Snapshot) = 32768);

    MainForm.ButtonWriteClick(MainForm.ComboItem1);
    WriteLn;
    WriteLn('Read the chip back');
    PoisonEditor(pattern);
    MainForm.ButtonReadClick(nil);
    back := Snapshot;
    ok := Same(pattern, back, diff);
    if ok then
      Check('the chip now holds exactly what was written', true)
    else
      Check('the chip now holds exactly what was written', false,
            Format('differs at 0x%X: wrote %.2x got %.2x',
                   [diff, pattern[diff], back[diff]]));

    //--- put the original contents back --------------------------------------
    WriteLn;
    WriteLn('Restore the original contents');
    LoadIntoEditor(original);
    MainForm.ButtonWriteClick(MainForm.ComboItem1);
    PoisonEditor(original);
    MainForm.ButtonReadClick(nil);
    back := Snapshot;
    ok := Same(original, back, diff);
    Check('original contents restored', ok,
          IfThen(ok, '', Format('differs at 0x%X', [diff])));
  end;

  AsProgrammer.Programmer.DevClose;

  WriteLn;
  WriteLn('================================================================');
  if Failures = 0 then
    WriteLn('all checks passed')
  else
    WriteLn(Failures, ' check(s) FAILED');
  ExitCode := Ord(Failures <> 0);
end.
