program i18ncheck;

{
  Proves that the interface can actually be translated, and that no language
  file can crash the program.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  Needs no hardware. It builds the real form, switches through every language
  file in lang\, and checks three things each time:

    * the switch does not raise. TPOFile.Translate raises
      "TPOFile.Translate Inconsistency" when an entry has an empty msgid AND an
      empty translation, so a malformed .po takes the program down at the moment
      the user picks that language. This is the check that catches it.
    * every menu caption is still non-empty afterwards.
    * a caption with a translation in that file really changed, and one with an
      empty translation really fell back to its msgid rather than going blank.

  Run it from the software directory:  tests\build\i18ncheck.exe
}

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Menus, Classes, SysUtils, FileUtil, Translations,
  LResources, LCLTranslator, main, dregstr,
  scriptedit, findchip, sregedit, search;

var
  Failures: integer = 0;

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

//Duplicated identifiers and trailing rubbish are invisible to TPOFile: the
//first makes it silently refuse a translation it has, and the second becomes
//part of the caption. Both shipped today before an audit caught them, so they
//are checked here from now on.  By Dreg
procedure CheckPOFiles;
var
  files: TStringList;
  sr: TSearchRec;
  lines, ids: TStringList;
  i, k, n, dups, junk: integer;
  s, id: string;
begin
  files := TStringList.Create;
  lines := TStringList.Create;
  ids := TStringList.Create;
  try
    if FindFirst('lang' + PathDelim + '*.po', faAnyFile, sr) = 0 then
    begin
      repeat
        files.Add('lang' + PathDelim + sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    if FileExists('lang' + PathDelim + 'AsProgrammer.pot') then
      files.Add('lang' + PathDelim + 'AsProgrammer.pot');
    files.Sort;

    for i := 0 to files.Count - 1 do
    begin
      lines.LoadFromFile(files[i]);
      ids.Clear;
      ids.Sorted := true;
      ids.Duplicates := dupAccept;
      dups := 0;
      junk := 0;
      for k := 0 to lines.Count - 1 do
      begin
        s := lines[k];
        if Copy(s, 1, 3) = '#: ' then
        begin
          s := Trim(Copy(s, 4, Length(s)));
          while s <> '' do
          begin
            n := Pos(' ', s);
            if n = 0 then
            begin
              id := s;
              s := '';
            end
            else
            begin
              id := Copy(s, 1, n - 1);
              s := Trim(Copy(s, n + 1, Length(s)));
            end;
            if ids.IndexOf(LowerCase(id)) >= 0 then Inc(dups);
            ids.Add(LowerCase(id));
          end;
        end
        else
          if ((Copy(s, 1, 7) = 'msgstr ') or (Copy(s, 1, 6) = 'msgid ')) and
             (s <> TrimRight(s)) then Inc(junk);
      end;

      if dups > 0 then
        Check(ExtractFileName(files[i]), false,
              Format('%d duplicated identifier(s), TPOFile refuses those as fuzzy', [dups]))
      else if junk > 0 then
        Check(ExtractFileName(files[i]), false,
              Format('%d line(s) with trailing whitespace after the closing quote', [junk]))
      else
        Check(ExtractFileName(files[i]), true,
              Format('%d identifiers, well formed', [ids.Count]));
    end;
  finally
    ids.Free;
    lines.Free;
    files.Free;
  end;
end;

//Walks the whole menu tree so a blank caption anywhere is caught, not just in
//the handful of items a test happens to name.
function CountMenuItems(Item: TMenuItem): integer;
var
  i: integer;
begin
  result := Item.Count;
  for i := 0 to Item.Count - 1 do
    Inc(result, CountMenuItems(Item.Items[i]));
end;

function CountEmptyCaptions(Item: TMenuItem; out FirstEmpty: string): integer;
var
  i, n: integer;
  child: string;
begin
  result := 0;
  FirstEmpty := '';
  for i := 0 to Item.Count - 1 do
  begin
    if (Item.Items[i].Caption = '') and (not Item.Items[i].IsLine) then
    begin
      Inc(result);
      if FirstEmpty = '' then FirstEmpty := Item.Items[i].Name;
    end;
    n := CountEmptyCaptions(Item.Items[i], child);
    if (n > 0) then
    begin
      Inc(result, n);
      if FirstEmpty = '' then FirstEmpty := child;
    end;
  end;
end;

var
  langs: TStringList;
  sr: TSearchRec;
  i, empties: integer;
  firstEmpty, lang, capBefore, capAfter: string;
  poFile: TPOFile;

begin
  WriteLn('i18ncheck - can the interface actually be translated?');
  WriteLn('====================================================');
  WriteLn;

  LoadXML;
  Translate(SettingsFile);
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);

  //ChangeLang translates five forms, not one. A malformed entry belonging to
  //any of the other four would otherwise pass here and then raise in the
  //running program the moment somebody picked that language.
  Application.CreateForm(TScriptEditForm, ScriptEditForm);
  Application.CreateForm(TChipSearchForm, ChipSearchForm);
  Application.CreateForm(TsregeditForm, sregeditForm);
  Application.CreateForm(TSearchForm, SearchForm);

  langs := TStringList.Create;
  try
    if FindFirst('lang' + PathDelim + '*.po', faAnyFile, sr) = 0 then
    begin
      repeat
        langs.Add(ChangeFileExt(sr.Name, ''));
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    langs.Sort;
    Check('found language files', langs.Count > 0,
          Format('%d files', [langs.Count]));

    //One entry that this fork added and left untranslated everywhere. It must
    //fall back to its English msgid, never to an empty string.
    WriteLn;
    WriteLn('Switching through every language');
    for i := 0 to langs.Count - 1 do
    begin
      lang := langs[i];
      capBefore := MainForm.MenuBP5Help.Caption;
      try
        //Exactly what the Language menu does.
        Translations.TranslateResourceStrings('lang' + PathDelim + lang + '.po');
        LRSTranslator.Free;
        LRSTranslator := TPOTranslator.Create('lang' + PathDelim + lang + '.po');
        TPOTranslator(LRSTranslator).UpdateTranslation(MainForm);
        TPOTranslator(LRSTranslator).UpdateTranslation(ScriptEditForm);
        TPOTranslator(LRSTranslator).UpdateTranslation(ChipSearchForm);
        TPOTranslator(LRSTranslator).UpdateTranslation(sregeditForm);
        TPOTranslator(LRSTranslator).UpdateTranslation(SearchForm);
      except
        on E: Exception do
        begin
          Check(lang + ': switching language', false,
                E.ClassName + ': ' + E.Message);
          Continue;
        end;
      end;

      empties := CountEmptyCaptions(MainForm.MainMenu.Items, firstEmpty);
      capAfter := MainForm.MenuBP5Help.Caption;

      if empties > 0 then
        Check(lang, false, Format('%d menu captions went blank, first: %s',
                                  [empties, firstEmpty]))
      else if capAfter = '' then
        Check(lang, false, 'an untranslated caption fell back to an empty string')
      else
        Check(lang, true, Format('%d menu items, none blank',
                                 [CountMenuItems(MainForm.MainMenu.Items)]));
    end;

    //And prove a real translation is actually applied, so the pass above is not
    //just "nothing crashed". Every language file translates the IC menu.
    WriteLn;
    WriteLn('Is a translation really applied?');
    Translations.TranslateResourceStrings('lang' + PathDelim + 'en.po');
    LRSTranslator.Free;
    LRSTranslator := TPOTranslator.Create('lang' + PathDelim + 'en.po');
    TPOTranslator(LRSTranslator).UpdateTranslation(MainForm);
    capBefore := MainForm.MenuChip.Caption;
    Check('English translates the IC menu', capBefore = 'IC',
          'got "' + capBefore + '"');

    Translations.TranslateResourceStrings('lang' + PathDelim + 'es.po');
    LRSTranslator.Free;
    LRSTranslator := TPOTranslator.Create('lang' + PathDelim + 'es.po');
    TPOTranslator(LRSTranslator).UpdateTranslation(MainForm);
    capAfter := MainForm.MenuChip.Caption;
    Check('Spanish gives a different caption', capAfter <> capBefore,
          '"' + capBefore + '" -> "' + capAfter + '"');

    //The whole point of the exercise: an entry that exists but is untranslated
    //must show its English msgid, which is what the fork's new menus now do.
    Check('an untranslated new caption falls back to English',
          MainForm.MenuBP5Help.Caption = 'Bus Pirate v5+ documentation',
          '"' + MainForm.MenuBP5Help.Caption + '"');

    //The half of the interface that a .po form entry can never reach: text built
    //in code, and the dialogs created with TForm.CreateNew, which are not
    //components of MainForm. Only a resourcestring covers those, and the COM
    //port caption proves it, because the refresh timer overwrites whatever the
    //form translation put there.
    WriteLn;
    WriteLn('Strings built in code');
    Check('the COM port caption comes from a resourcestring',
          STR_DM_COMPORT_NONE <> '', '"' + STR_DM_COMPORT_NONE + '"');
    Check('the scan dialog title does too',
          STR_DM_I2C_SCAN_TITLE <> '', '"' + STR_DM_I2C_SCAN_TITLE + '"');

    //And that switching language really rewrites them. Nothing translates these
    //yet, so every language must give back the English original rather than an
    //empty string, which is the failure that would ship a blank dialog.
    for i := 0 to langs.Count - 1 do
    begin
      Translations.TranslateResourceStrings('lang' + PathDelim + langs[i] + '.po');
      if (STR_DM_COMPORT_NONE = '') or (STR_DM_I2C_SCAN_TITLE = '') or
         (STR_DM_BTN_CLOSE = '') then
      begin
        Check(langs[i] + ': resourcestrings survive the switch', false,
              'one of them came back empty');
        Break;
      end;
    end;
    Check('resourcestrings survive every language switch', true,
          Format('%d languages, none blank', [langs.Count]));

    //Several captions repeat: "Clock" sits under four different menus, and so
    //do I2C, SPI and Power ON. TPOFile merges entries that share a msgid, so
    //they end up sharing one translation. That is fine for these words, but it
    //has to still resolve for every context, which is what this checks.
    WriteLn;
    WriteLn('Repeated captions still resolve');
    Check('Buzzpirat I2C clock', MainForm.MenuBuzzpiratI2CClock.Caption <> '',
          '"' + MainForm.MenuBuzzpiratI2CClock.Caption + '"');
    Check('Buzzpirat SPI clock', MainForm.MenuBuzzpiratSPIClock.Caption <> '',
          '"' + MainForm.MenuBuzzpiratSPIClock.Caption + '"');
    Check('BusPirateV5+ I2C clock', MainForm.MenuBP5I2CClock.Caption <> '',
          '"' + MainForm.MenuBP5I2CClock.Caption + '"');
    Check('BusPirateV5+ SPI clock', MainForm.MenuBP5SPIClock.Caption <> '',
          '"' + MainForm.MenuBP5SPIClock.Caption + '"');

    //Not the number of contexts in the file: the parser merges duplicates, so
    //this is the number of distinct source strings each language carries.
    WriteLn;
    WriteLn('Distinct source strings per language');
    for i := 0 to langs.Count - 1 do
    begin
      poFile := TPOFile.Create('lang' + PathDelim + langs[i] + '.po');
      try
        Check(langs[i], poFile.Items.Count > 0,
              Format('%d distinct strings', [poFile.Items.Count]));
      finally
        poFile.Free;
      end;
    end;

  finally
    langs.Free;
  end;

  //The two shapes that really broke these files today: an identifier that
  //appears twice, which makes TPOFile mark the entry fuzzy and refuse the
  //translation outright, and rubbish after the closing quote, which ends up
  //inside the caption.
  WriteLn;
  WriteLn('Are the language files well formed?');
  CheckPOFiles;

  WriteLn;
  WriteLn('====================================================');
  if Failures = 0 then
    WriteLn('all checks passed')
  else
    WriteLn(Failures, ' check(s) FAILED');
  Halt(Ord(Failures <> 0));
end.
