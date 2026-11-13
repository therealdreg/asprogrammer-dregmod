program AsProgrammer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, main, i2c, microwire,
  spi95, search, sregedit, findchip, ScriptEdit, spi25;

{$R *.res}

begin
  LoadXML;
  Translate(SettingsFile);
  RequireDerivedFormResource := True;
  Application.Scaled:=True;
  //Every form opened after the main one is owned by it, so none can go behind
  //it. Without this they belong to the application window, which Windows
  //orders apart from the main one, and the LCL takes the stay on top flag off
  //the ones that have it while a message box is shown, so a click on the main
  //window could cover them.  By Dreg
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  {$POP}
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.CreateForm(TSearchForm, SearchForm);
  Application.CreateForm(TsregeditForm, sregeditForm);
  Application.CreateForm(TChipSearchForm, ChipSearchForm);
  Application.CreateForm(TScriptEditForm, ScriptEditForm);
  Application.Run;
end.

