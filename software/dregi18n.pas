unit dregi18n;

{
  English under every language.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  The source text of the forms and of msgstr.pas is Russian, so an entry that a
  language file does not translate shows in Russian. LangPOFile reads the
  chosen language and gives every entry it does not translate the English
  translation from en.po. Only real translations go in: an entry that en.po
  does not translate either (the ones this fork added have English source
  text) keeps what the language file gives it. Russian is the source language
  and gets no English layer. The language files are not changed.

  Lazarus has a fallback language of its own, TranslateResourceStrings with
  FallbackLang, but its second pass puts the source text back on every entry
  the language lacks (translations.pas, Translate returns the original), and
  the forms have no fallback at all.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, LazFileUtils, Translations;

//Dir + Lang + '.po' with the English of en.po under it; en.po alone when the
//language file is missing, nil when there is nothing to load. Full as for
//TPOFile.Create: true keeps the untranslated entries, as TPOTranslator reads
//its file for the forms, false drops them, as TranslateResourceStrings reads
//it, so an untranslated resourcestring keeps the text of the code rather than
//a msgid that may be older.
function LangPOFile(const Dir, Lang: string; Full: boolean): TPOFile;

implementation

//Translate uses an entry's translation only when it has one that is not fuzzy
//and not flagged badformat. TPOFile marks an untranslated entry fuzzy when it
//gives it a copy of a twin's translation.
function Usable(Item: TPOFileItem): boolean;
begin
  result := (Item <> nil) and (Item.Translation <> '') and
            (Pos(sFuzzyFlag, Item.Flags) = 0) and
            (Pos(sBadFormatFlag, Item.Flags) = 0);
end;

function LangPOFile(const Dir, Lang: string; Full: boolean): TPOFile;
var
  english: TPOFile;
  e, t: TPOFileItem;
  i: integer;
begin
  result := nil;
  if FileExistsUTF8(Dir + Lang + '.po') then
    result := TPOFile.Create(Dir + Lang + '.po', Full);
  if (Lang = 'en') or (Lang = 'ru') or (not FileExistsUTF8(Dir + 'en.po')) then
    Exit;
  english := TPOFile.Create(Dir + 'en.po', Full);
  if result = nil then
    Exit(english);
  try
    for i := 0 to english.Count - 1 do
    begin
      e := english.PoItems[i];
      if not Usable(e) then
        Continue;
      t := result.FindPoItem(e.IdentifierLow);
      if Usable(t) then
        Continue;
      if t = nil then
        result.FillItem(t, e.IdentifierLow, e.Original, e.Translation, '', '', '', '')
      else
      begin
        t.Translation := e.Translation;
        t.ModifyFlag(sFuzzyFlag, false);
        t.ModifyFlag(sBadFormatFlag, false);
      end;
    end;
  finally
    english.Free;
  end;
end;

end.
