unit main;

//TODO: at45 установка размера странцы
//TODO: at45 Проверка размера страницы перед операциями


{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LazFileUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, Menus, ActnList, Buttons, StrUtils, spi25,
  spi45, spi95, i2c, microwire, spimulti, ft232hhw,
  XMLRead, XMLWrite, DOM, msgstr, dregstr, dregi18n, Translations, LCLProc, LCLType, LCLTranslator,
  LResources, MPHexEditorEx, MPHexEditor, search, sregedit,
  utilfunc, findchip, DateUtils, lazUTF8,
  pascalc, ScriptsFunc, ScriptEdit, baseHW, UsbAspHW, ch341hw, ch347hw, avrisphw, arduinohw,
  buzzpirathw, buspirate5hw;

type

  { TMainForm }

  TMainForm = class(TForm)
    CheckBox_I2C_A1: TToggleBox;
    CheckBox_I2C_A0: TToggleBox;
    CheckBox_I2C_ByteRead: TCheckBox;
    CheckBox_I2C_DevA6: TToggleBox;
    CheckBox_I2C_DevA5: TToggleBox;
    CheckBox_I2C_DevA4: TToggleBox;
    CheckBox_I2C_A2: TToggleBox;
    ComboAddrType: TComboBox;
    ComboBox_chip_scriptrun: TComboBox;
    ComboSPICMD: TComboBox;
    ComboChipSize: TComboBox;
    ComboMWBitLen: TComboBox;
    ComboPageSize: TComboBox;
    Label6: TLabel;
    Label_StartAddress: TLabel;
    MenuHWFT232H: TMenuItem;
    MenuFT232SPIClock: TMenuItem;
    MenuFT232SPI30Mhz: TMenuItem;
    MenuFT232SPI6Mhz: TMenuItem;
    MenuHWCH347: TMenuItem;
    MenuCH347SPIClock: TMenuItem;
    MenuCH347SPIClock468_75KHz: TMenuItem;
    MenuCH347SPIClock60MHz: TMenuItem;
    MenuCH347SPIClock30MHz: TMenuItem;
    MenuCH347SPIClock15MHz: TMenuItem;
    MenuCH347SPIClock7_5MHz: TMenuItem;
    MenuCH347SPIClock3_75MHz: TMenuItem;
    MenuCH347SPIClock1_875MHz: TMenuItem;
    MenuCH347SPIClock937_5KHz: TMenuItem;
    MenuSendAB: TMenuItem;
    StartAddressEdit: TEdit;
    GroupChipSettings: TGroupBox;
    ImageList: TImageList;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label_chip_scripts: TLabel;
    Label_I2C_DevAddr: TLabel;
    LabelSPICMD: TLabel;
    LabelChipName: TLabel;
    MainMenu: TMainMenu;
    Log: TMemo;
    Menu32Khz: TMenuItem;
    Menu93_75Khz: TMenuItem;
    MenuChip: TMenuItem;
    MenuAutoCheck: TMenuItem;
    ComboItem1: TMenuItem;
    Menu3Mhz: TMenuItem;
    MenuIgnoreBusyBit: TMenuItem;
    MenuGotoOffset: TMenuItem;
    MenuFind: TMenuItem;
    MenuItem1: TMenuItem;
    MenuCopyToClip: TMenuItem;
    CopyLogMenuItem: TMenuItem;
    ClearLogMenuItem: TMenuItem;
    MenuHWUSBASP: TMenuItem;
    MenuHWCH341A: TMenuItem;
    MenuFindChip: TMenuItem;
    MenuHWAVRISP: TMenuItem;
    MenuAVRISPSPIClock: TMenuItem;
    MenuAVRISP8MHz: TMenuItem;
    MenuAVRISP4MHz: TMenuItem;
    MenuAVRISP2MHz: TMenuItem;
    MenuAVRISP1MHz: TMenuItem;
    MenuAVRISP500KHz: TMenuItem;
    MenuAVRISP250KHz: TMenuItem;
    MenuAVRISP125KHz: TMenuItem;
    LangMenuItem: TMenuItem;
    BlankCheckMenuItem: TMenuItem;
    AllowInsertItem: TMenuItem;
    MenuHWARDUINO: TMenuItem;
    MenuHWBUZZPIRAT: TMenuItem;
    MenuHWBUSPIRATE5: TMenuItem;
    MenuBP5: TMenuItem;
    MenuBP5COMPort: TMenuItem;
    MenuBP5Power: TMenuItem;
    MenuBP5Voltage: TMenuItem;
    MenuBP5V1V2: TMenuItem;
    MenuBP5V1V8: TMenuItem;
    MenuBP5V2V5: TMenuItem;
    MenuBP5V3V3: TMenuItem;
    MenuBP5V5V0: TMenuItem;
    MenuBP5Current: TMenuItem;
    MenuBP5CurUnlimited: TMenuItem;
    MenuBP5Cur100: TMenuItem;
    MenuBP5Cur300: TMenuItem;
    MenuBP5Cur500: TMenuItem;
    MenuBP5Pullups: TMenuItem;
    MenuBP5Verbose: TMenuItem;
    MenuBP5ResetEach: TMenuItem;
    MenuBP5SubSPI: TMenuItem;
    MenuBP5SPIClock: TMenuItem;
    MenuBP5SPI125K: TMenuItem;
    MenuBP5SPI250K: TMenuItem;
    MenuBP5SPI500K: TMenuItem;
    MenuBP5SPI1M: TMenuItem;
    MenuBP5SPI2M: TMenuItem;
    MenuBP5SPI4M: TMenuItem;
    MenuBP5SPI8M: TMenuItem;
    MenuBP5SPI16M: TMenuItem;
    MenuBP5SubI2C: TMenuItem;
    MenuBP5I2CClock: TMenuItem;
    MenuBP5I2C50K: TMenuItem;
    MenuBP5I2C100K: TMenuItem;
    MenuBP5I2C400K: TMenuItem;
    MenuBP5I2C1M: TMenuItem;
    MenuBP5I2CScan: TMenuItem;
    MenuBP5Labels: TMenuItem;
    MenuBP5Disconnect: TMenuItem;
    MenuBP5Info: TMenuItem;
    MenuBP5Help: TMenuItem;
    MenuArduinoSPIClock: TMenuItem;
    MenuArduinoISP8MHz: TMenuItem;
    MenuArduinoISP4MHz: TMenuItem;
    MenuArduinoISP2MHz: TMenuItem;
    MenuArduinoISP1MHz: TMenuItem;
    MenuArduinoCOMPort: TMenuItem;
    MenuBuzzpiratCOMPort: TMenuItem;
    MenuSkipFF: TMenuItem;
    MPHexEditorEx: TMPHexEditorEx;
    ScriptsMenuItem: TMenuItem;
    CreditsMenuItem: TMenuItem;
    BzHelpMenuItem: TMenuItem;
    DebugconsoleMenuItem: TMenuItem;
    ComPortTimer: TTimer;
    MenuHexEditor: TMenuItem;
    MenuHexEditorRandom: TMenuItem;
    MenuHexEditorPopupRandom: TMenuItem;
    MenuItemHardware: TMenuItem;
    MenuBuzzpirat: TMenuItem;
    MenuBuzzpiratPullups: TMenuItem;
    MenuBuzzpiratResetEach: TMenuItem;
    MenuBuzzpiratDisconnect: TMenuItem;
    MenuBuzzpiratPower: TMenuItem;
    MenuBuzzpiratVerbose: TMenuItem;
    MenuBuzzpiratSerialSpeed: TMenuItem;
    MenuBuzzpiratSerial115200: TMenuItem;
    MenuBuzzpiratSerial230400: TMenuItem;
    MenuBuzzpiratSerial250000: TMenuItem;
    MenuBuzzpiratSerial1M: TMenuItem;
    MenuBuzzpiratSerial2M: TMenuItem;
    MenuBuzzpiratSubI2C: TMenuItem;
    MenuBuzzpiratSubSPI: TMenuItem;
    MenuBuzzpiratSPIClock: TMenuItem;
    MenuBuzzpiratSPINormal: TMenuItem;
    MenuBuzzpiratSPIHiz: TMenuItem;
    MenuBuzzpiratSPI8MHz: TMenuItem;
    MenuBuzzpiratSPI4MHz: TMenuItem;
    MenuBuzzpiratSPI2P6MHz: TMenuItem;
    MenuBuzzpiratSPI2MHz: TMenuItem;
    MenuBuzzpiratSPI1MHz: TMenuItem;
    MenuBuzzpiratSPI250KHz: TMenuItem;
    MenuBuzzpiratSPI125KHz: TMenuItem;
    MenuBuzzpiratSPI30KHz: TMenuItem;
    MenuBuzzpiratI2CClock: TMenuItem;
    MenuBuzzpiratI2C400KHz: TMenuItem;
    MenuBuzzpiratI2C100KHz: TMenuItem;
    MenuBuzzpiratI2C50KHz: TMenuItem;
    MenuBuzzpiratI2C5KHz: TMenuItem;
    MenuBuzzpiratI2CScan: TMenuItem;
    MenuItemBenchmark: TMenuItem;
    MenuItemEditSreg: TMenuItem;
    MenuItemReadSreg: TMenuItem;
    MenuItemLockFlash: TMenuItem;
    MenuItem4: TMenuItem;
    MenuMW8Khz: TMenuItem;
    MenuMW16Khz: TMenuItem;
    MenuMicrowire: TMenuItem;
    MenuMW32Khz: TMenuItem;
    MenuMWClock: TMenuItem;
    MenuOptions: TMenuItem;
    MenuSPI: TMenuItem;
    MenuSPIClock: TMenuItem;
    Menu1_5Mhz: TMenuItem;
    Menu750Khz: TMenuItem;
    Menu375Khz: TMenuItem;
    Menu187_5Khz: TMenuItem;
    OpenDialog: TOpenDialog;
    DropDownMenu: TPopupMenu;
    EditorPopupMenu: TPopupMenu;
    LogPopupMenu: TPopupMenu;
    DropdownMenuLock: TPopupMenu;
    Panel_I2C_DevAddr: TPanel;
    BlankCheckDropDownMenu: TPopupMenu;
    ProgressBar: TProgressBar;
    RadioI2C: TRadioButton;
    RadioMw: TRadioButton;
    RadioSPI: TRadioButton;
    SaveDialog: TSaveDialog;
    SpeedButton1: TSpeedButton;
    Splitter1: TSplitter;
    StatusBar: TStatusBar;
    CheckBox_I2C_DevA7: TToggleBox;
    ToolBar: TToolBar;
    ButtonRead: TToolButton;
    ButtonWrite: TToolButton;
    ButtonVerify: TToolButton;
    ToolButton1: TToolButton;
    ButtonReadID: TToolButton;
    ButtonErase: TToolButton;
    ToolButton2: TToolButton;
    ToolButton3: TToolButton;
    ButtonBlock: TToolButton;
    ButtonOpenHex: TToolButton;
    ButtonSaveHex: TToolButton;
    ButtonCancel: TToolButton;
    ToolButton4: TToolButton;
    ToolButton5: TToolButton;
    procedure BlankCheckMenuItemClick(Sender: TObject);
    procedure ButtonEraseClick(Sender: TObject);
    procedure ButtonReadClick(Sender: TObject);
    procedure ClearLogMenuItemClick(Sender: TObject);
    procedure ComboSPICMDChange(Sender: TObject);
    procedure CopyLogMenuItemClick(Sender: TObject);
    procedure AllowInsertItemClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ChipClick(Sender: TObject);
    procedure ChangeLang(Sender: TObject);
    procedure ComboItem1Click(Sender: TObject);
    procedure MenuArduinoCOMPortClick(Sender: TObject);
    procedure MenuBuzzpiratDisconnectClick(Sender: TObject);
    procedure MenuBuzzpiratI2CScanClick(Sender: TObject);
    procedure MenuHexEditorRandomClick(Sender: TObject);
    procedure ComPortTimerTimer(Sender: TObject);
    procedure MenuHWARDUINOClick(Sender: TObject);
    procedure MenuHWBUZZPIRATClick(Sender: TObject);
    procedure MenuHWBUSPIRATE5Click(Sender: TObject);
    procedure MenuBP5DisconnectClick(Sender: TObject);
    procedure MenuBP5I2CScanClick(Sender: TObject);
    procedure MenuBP5LabelsClick(Sender: TObject);
    procedure MenuBP5InfoClick(Sender: TObject);
    procedure MenuBP5HelpClick(Sender: TObject);
    procedure MenuHWAVRISPClick(Sender: TObject);
    procedure MenuCopyToClipClick(Sender: TObject);
    procedure MenuFindChipClick(Sender: TObject);
    procedure MenuFindClick(Sender: TObject);
    procedure MenuGotoOffsetClick(Sender: TObject);
    procedure MenuHWCH341AClick(Sender: TObject);
    procedure MenuHWCH347Click(Sender: TObject);
    procedure MenuHWFT232HClick(Sender: TObject);
    procedure MenuHWUSBASPClick(Sender: TObject);
    procedure MenuItemBenchmarkClick(Sender: TObject);
    procedure MenuItemEditSregClick(Sender: TObject);
    procedure MenuItemLockFlashClick(Sender: TObject);
    procedure MenuItemReadSregClick(Sender: TObject);
    procedure MPHexEditorExChange(Sender: TObject);
    procedure RadioI2CChange(Sender: TObject);
    procedure RadioMwChange(Sender: TObject);
    procedure RadioSPIChange(Sender: TObject);
    procedure ButtonWriteClick(Sender: TObject);
    procedure ButtonVerifyClick(Sender: TObject);
    procedure ButtonBlockClick(Sender: TObject);
    procedure ButtonReadIDClick(Sender: TObject);
    procedure ButtonOpenHexClick(Sender: TObject);
    procedure ButtonSaveHexClick(Sender: TObject);
    procedure ButtonCancelClick(Sender: TObject);
    procedure I2C_DevAddrChange(Sender: TObject);
    procedure ScriptsMenuItemClick(Sender: TObject);
    procedure CreditsMenuItemClick(Sender: TObject);
    procedure BzHelpMenuItemClick(Sender: TObject);
    procedure DebugconsoleMenuItemClick(Sender: TObject);
    procedure SpeedButton1Click(Sender: TObject);
    procedure StartAddressEditChange(Sender: TObject);
    procedure StartAddressEditKeyPress(Sender: TObject; var Key: char);
    procedure VerifyFlash(BlankCheck: boolean = false);
  private
    { private declarations }
    //The state each COM port submenu was last built from, so the polling timer
    //only rebuilds a menu when that state changes.
    FCOMPortMenuSig: string;
    FBP5PortMenuSig: string;
    //Set by ButtonEraseClick for the combined erase and program command: true
    //after an erase that ended well, and after an I2C erase where the chip
    //refused some pages but not all.  By Dreg
    FEraseOK: boolean;
    //True once FormCloseQuery has written settings.xml.  By Dreg
    FSettingsSaved: boolean;
    procedure BuzzpiratCOMPortItemClick(Sender: TObject);
    procedure BP5COMPortItemClick(Sender: TObject);
    //Shared by the report windows built at run time.
    procedure ReportCopyClick(Sender: TObject);
    procedure ReportListDblClick(Sender: TObject);
  public
    { public declarations }
    //Rebuilds the Buzzpirat COM port submenu from the ports the system reports.
    procedure RefreshCOMPortMenu;
    //Same, for the Bus Pirate v5+: every serial port, with the ones found in
    //the USB registry labelled as the BPIO2 or the terminal interface.
    procedure RefreshBP5PortMenu;
    //Renders one I2C scan result and lets the user adopt an address. Shared by
    //both Bus Pirate back ends, so the caller supplies the descriptions and the
    //hints shown when nothing answers, which name that back end's pins.
    procedure ShowI2CScanResult(const Found: TBytes; const APort, ABusDesc: string;
                                ALines: TStrings; const AEmptyHints: string);
    //Copies a 7-bit I2C address into the A0..A2 / device type toggles.
    procedure ApplyI2CAddress(Addr: byte);

  end;

  procedure LogPrint(text: string);
  function PageSizeFromUI: word;
  //'' once settings.xml is written, else why it could not be.  By Dreg
  function SaveOptions(XMLfile: TXMLDocument): string;
  Procedure LoadOptions(XMLfile: TXMLDocument);
  procedure LoadXML;
  procedure Translate(XMLfile: TXMLDocument);
  function OpenDevice: boolean;
  function SetSPISpeed(OverrideSpeed: byte): integer;
  procedure SyncUI_ICParam();
  function UserCancel(): boolean;
  function WaitChipReady: boolean;
  function MenuCheckedTag(Parent: TMenuItem; Default: PtrInt): PtrInt;
  procedure MenuCheckByTag(Parent: TMenuItem; Value: PtrInt);
  //chiplist.xml, settings.xml, scripts and lang as full paths, all in AppDir.
  //By Dreg
  function AppDir: string;
  function ChipListFileName: string;
  function SettingsFileName: string;
  function ScriptsPath: string;
  function LangPath: string;

const
  SPI_CMD_25             = 0;
  SPI_CMD_45             = 1;
  SPI_CMD_KB             = 2;
  SPI_CMD_95             = 3;

type

  TCurrentICParam = record
    Name: string;
    Page: integer;
    Size: Longword;
    SpiCmd: byte;
    I2CAddrType: byte;
    MWAddLen: byte;

    Script: string;
  end;


var
  MainForm: TMainForm;
  ChipListFile: TXMLDocument;
  SettingsFile: TXMLDocument;
  CurrentICParam: TCurrentICParam;
  ScriptEngine: TPasCalc;
  RomF: TMemoryStream;

  AsProgrammer: TAsProgrammer;

  Arduino_COMPort: string;
  Arduino_BaudRate: integer = 921600;
  Buzzpirat_COMPort: string;

  //The one Buzzpirat back end, kept here so the COM port menu, the bus scanner
  //and the device report can reach it even when another programmer is selected.
  BuzzpiratDev: TBuzzpiratHardware = nil;

  //Same for the Bus Pirate v5+ back end. The two are independent and can hold
  //different COM ports open at the same time.
  BusPirate5_COMPort: string;
  BusPirate5Dev: TBusPirate5Hardware = nil;

//Shows text in a resizable window with a fixed pitch font, for reports whose
//columns have to line up.
procedure ShowMonospaceReport(const ATitle, AText: string);
//Lock and unlock the interface around an operation. Public so that the status
//register editor and the script editor can lock the main window while they
//talk to the device.  By Dreg
procedure LockControl;
procedure UnlockControl;
implementation


var
  TimeCounter: TDateTime;
  CurrentLang: string = 'en';

const
  //What to check when an I2C scan finds nothing. The pins and the supply differ
  //between a Bus Pirate v3 and a v5 or newer, so each scan passes its own list.
  //By Dreg
  I2C_EMPTY_HINTS_V3 =
    '  - SDA on MOSI, SCL on CLK, and a ground shared with the target' + LineEnding +
    '  - pull-ups: switch "Pull UPs ON" on, and remember the Bus Pirate' + LineEnding +
    '    needs its Vpullup pin fed (tie it to 3V3 or 5V)' + LineEnding +
    '  - target power: "Power ON" drives the 3V3 and 5V rails' + LineEnding +
    '  - a slower clock (50 kHz or 5 kHz) for long or unterminated wires';
  I2C_EMPTY_HINTS_V5 =
    '  - SDA on IO0, SCL on IO1, and a ground shared with the target' + LineEnding +
    '  - pull-ups: switch "Pull UPs ON" on if the board has none. They take' + LineEnding +
    '    their voltage from VOUT, so the supply has to be on' + LineEnding +
    '  - target power: "Power ON" and "Voltage" set the supply on VOUT' + LineEnding +
    '  - a slower clock (50 kHz) for long or unterminated wires';

{$R *.lfm}

procedure SyncUI_ICParam();
begin
  CurrentICParam.SpiCmd := MainForm.ComboSPICMD.ItemIndex;
  CurrentICParam.I2CAddrType := MainForm.ComboAddrType.ItemIndex;

  if IsNumber(MainForm.ComboMWBitLen.Text) then
    CurrentICParam.MWAddLen := StrToInt(MainForm.ComboMWBitLen.Text) else
      CurrentICParam.MWAddLen := 0;

  if IsNumber(MainForm.ComboPageSize.Text) then
    CurrentICParam.Page := StrToInt(MainForm.ComboPageSize.Text)
  else if UpCase(MainForm.ComboPageSize.Text) = 'SSTB' then
    CurrentICParam.Page := -1
  else if UpCase(MainForm.ComboPageSize.Text) = 'SSTW' then
    CurrentICParam.Page := -2
  else
    CurrentICParam.Page := 0;

  if IsNumber(MainForm.ComboChipSize.Text) then
    CurrentICParam.Size := StrToInt(MainForm.ComboChipSize.Text) else
      CurrentICParam.Size := 0;
end;

var
  FAppDir: string = '';

//The folder of chiplist.xml, settings.xml, lang and scripts, fixed at the
//first call: the program's own, so that a start from another folder still
//finds them. Without lang the menus show the Russian of the forms. When
//neither chiplist.xml nor lang is next to the program but one of them is in
//the current directory, the current directory.  By Dreg
function AppDir: string;

  function HasFiles(const Dir: string): boolean;
  begin
    result := FileExistsUTF8(Dir + 'chiplist.xml') or DirectoryExistsUTF8(Dir + 'lang');
  end;

var
  cwd: string;
begin
  if FAppDir = '' then
  begin
    FAppDir := ExtractFilePath(ParamStrUTF8(0));
    cwd := IncludeTrailingPathDelimiter(GetCurrentDirUTF8);
    if (not HasFiles(FAppDir)) and HasFiles(cwd) then
      FAppDir := cwd;
  end;
  result := FAppDir;
end;

function ChipListFileName: string;
begin
  result := AppDir + 'chiplist.xml';
end;

function SettingsFileName: string;
begin
  result := AppDir + 'settings.xml';
end;

function ScriptsPath: string;
begin
  result := AppDir + 'scripts' + DirectorySeparator;
end;

function LangPath: string;
begin
  result := AppDir + 'lang' + DirectorySeparator;
end;

function UserCancel(): boolean;
begin
  Result := false;
  if MainForm.ButtonCancel.Tag <> 0 then
  begin
    LogPrint(STR_USER_CANCEL);
    MainForm.ProgressBar.Style := pbstNormal;
     MainForm.ProgressBar.Position:= 0;
    Result := true;
  end;
end;

procedure LoadXML;
var
  RootNode: TDOMNode;
begin
  ChipListFile := nil;
  SettingsFile := nil;
  if FileExists(ChipListFileName) then
  begin
    try
      ReadXMLFile(ChipListFile, ChipListFileName);
    except
      on E: EXMLReadError do
      begin
        ShowMessage(E.Message);
        ChipListFile := nil;
      end;
    end;
  end;

  if FileExists(SettingsFileName) then
  begin
    try
      ReadXMLFile(SettingsFile, SettingsFileName);
    except
      on E: EXMLReadError do
      begin
        ShowMessage(E.Message);
        //Start a fresh document rather than leaving it nil: with nil the save
        //when the program closes does nothing, so the session's settings would
        //be lost and the broken file would stay broken.  By Dreg
        SettingsFile := TXMLDocument.Create;
        SettingsFile.AppendChild(SettingsFile.CreateElement('settings'));
      end;
    end;
  end else
  begin
    SettingsFile := TXMLDocument.Create;
    // Create a root node
    RootNode := SettingsFile.CreateElement('settings');
    SettingsFile.Appendchild(RootNode);
  end;

end;

//The skip menu names the byte an erased page holds: 00 for the KB family, FF
//for everything else. STR_DM_SKIP_TOKEN has a placeholder for it, so a
//translation can put the byte anywhere in its caption.  By Dreg
procedure UpdateSkipFFCaption;
begin
  if MainForm.ComboSPICMD.ItemIndex = SPI_CMD_KB then
    MainForm.MenuSkipFF.Caption := Format(STR_DM_SKIP_TOKEN, ['00'])
  else
    MainForm.MenuSkipFF.Caption := Format(STR_DM_SKIP_TOKEN, ['FF']);
end;

//Lang with English under it (dregi18n): translates the resourcestrings and
//returns the translator for the forms, nil when no language file is there. A
//missing file is no error: TPOFile.Create raises on one, so LangPOFile only
//opens what is there, and a lang directory that did not ship leaves the
//program untranslated rather than down at startup.  By Dreg
function LoadLanguage(const Dir, Lang: string): TPOTranslator;
var
  forms, strings: TPOFile;
begin
  result := nil;
  forms := LangPOFile(Dir, Lang, true);
  if forms = nil then Exit;
  strings := LangPOFile(Dir, Lang, false);
  try
    if strings <> nil then
      Translations.TranslateResourceStrings(strings);
  finally
    strings.Free;
  end;
  result := TPOTranslator.Create(forms);   //it frees forms
end;

procedure TMainForm.ChangeLang(Sender: TObject);
var
  translator: TPOTranslator;
  chipSize, pageSize, mwBits: string;
  i: integer;
begin
  translator := LoadLanguage(LangPath, TMenuItem(Sender).Hint);
  if translator = nil then
  begin
    //The click moved the radio mark: put it back on the language in use, which
    //is also the one the settings keep.  By Dreg
    for i := 0 to LangMenuItem.Count - 1 do
      LangMenuItem.Items[i].Checked := LangMenuItem.Items[i].Hint = CurrentLang;
    Exit;
  end;
  CurrentLang := TMenuItem(Sender).Hint;
  LRSTranslator.Free;
  LRSTranslator := translator;

  //Once a chip is picked these hold its size, page size and Microwire address
  //length, and a language file with an entry for their Text would put its
  //placeholder over the value.  By Dreg
  chipSize := ComboChipSize.Text;
  pageSize := ComboPageSize.Text;
  mwBits := ComboMWBitLen.Text;
  TPOTranslator(LRSTranslator).UpdateTranslation(MainForm);
  TPOTranslator(LRSTranslator).UpdateTranslation(ScriptEditForm);
  TPOTranslator(LRSTranslator).UpdateTranslation(ChipSearchForm);
  TPOTranslator(LRSTranslator).UpdateTranslation(sregeditForm);
  TPOTranslator(LRSTranslator).UpdateTranslation(SearchForm);
  if IsNumber(chipSize) then
    ComboChipSize.Text := chipSize;
  if IsNumber(pageSize) or SameText(pageSize, 'SSTB') or SameText(pageSize, 'SSTW') then
    ComboPageSize.Text := pageSize;
  if IsNumber(mwBits) then
    ComboMWBitLen.Text := mwBits;

  //UpdateTranslation writes the static caption back on every component, also
  //on those whose caption the program builds at run time. Build those again:
  //the skip menu, the Arduino port, and both Bus Pirate port menus, whose timer
  //only repaints them when the port list changes.  By Dreg
  UpdateSkipFFCaption;
  MenuArduinoCOMPort.Caption := 'Arduino COMPort: ' + Arduino_COMPort;
  FCOMPortMenuSig := '';
  FBP5PortMenuSig := '';
  RefreshCOMPortMenu;
  RefreshBP5PortMenu;
end;

procedure LoadLangList();
var
  LangDir: string;
  LangName: string;
  LangFile: Text;
  SearchRec : TSearchRec;
  MenuItem: TMenuItem;
begin
  LangDir := LangPath;

  If FindFirstUTF8(LangDir+'*.po', faAnyFile, SearchRec) = 0 then
  begin
    Repeat
      AssignFile(LangFile, LangDir+SearchRec.Name);
      Reset(LangFile);
      ReadLn(LangFile, LangName);
      CloseFile(LangFile);
      Delete(LangName, 1, 1);

      MenuItem := NewItem(LangName, 0, False, True, @MainForm.ChangeLang, 0, '');
      MenuItem.Hint := ExtractFileNameOnly(SearchRec.Name);
      MenuItem.AutoCheck := true;
      MenuItem.RadioItem := true;
      MainForm.LangMenuItem.Add(MenuItem);
      if MenuItem.Hint = Currentlang then MenuItem.Checked := true;

    Until FindNextUTF8(SearchRec) <> 0;
  end;

  FindCloseUTF8(SearchRec);
end;

procedure Translate(XMLfile: TXMLDocument);
var
   PODirectory: String;
   Node: TDOMNode;
   translator: TPOTranslator;
begin

  PODirectory:= LangPath;
  CurrentLang:='';

  if XMLfile <> nil then
  begin

      Node := XMLfile.DocumentElement.FindNode('locale');

      if (Node <> nil) then
      if (Node.HasAttributes) then
      begin

        if  Node.Attributes.GetNamedItem('lang') <> nil then
          CurrentLang := UTF16ToUTF8(Node.Attributes.GetNamedItem('lang').NodeValue);

      end;
  end;

  if CurrentLang = '' then
    CurrentLang := 'en';

  translator := LoadLanguage(PODirectory, CurrentLang);
  if translator <> nil then
    LRSTranslator := translator;
end;               

procedure LogPrint(text: string);
begin
  MainForm.Log.Lines.Add(text);
end;

//The page size box is an editable combo, so the number in it is whatever the
//user typed. It sizes the transfers into the 2048 byte DataChunk arrays on the
//stack, and no routine checks it against them. Clamp it here, once: the box
//then shows the size used, and a cut to 2048 is logged.
//By Dreg
function PageSizeFromUI: word;
const
  MAX_PAGE = 2048;   //the size of the DataChunk arrays every writer uses
var
  n: int64;
begin
  n := StrToInt64Def(Trim(MainForm.ComboPageSize.Text), 0);
  if n < 1 then
  begin
    n := 1;
    MainForm.ComboPageSize.Text := '1';
  end;
  if n > MAX_PAGE then
  begin
    LogPrint(Format('Page size %d is larger than this program can transfer in ' +
                    'one go, using %d instead', [n, MAX_PAGE]));
    n := MAX_PAGE;
    MainForm.ComboPageSize.Text := IntToStr(MAX_PAGE);
  end;
  result := word(n);
end;

//The Start address box as a number, -1 when it holds none. Hex2Dec reads it
//through a Longint: from 80000000 up it returns a negative number, which
//passes every size check that subtracts it, and FF000000 sends four byte
//addresses to a 16 MB chip. The text is read as the operations read it, with
//no Trim: a pasted " 100" passing here would raise in Hex2Dec after the chip
//was opened.  By Dreg
function StartAddressFromUI: int64;
begin
  try
    result := Hex2Dec64('$' + MainForm.StartAddressEdit.Text);
  except
    on EConvertError do result := -1;
  end;
end;


function OpenDevice: boolean;
begin
  if not AsProgrammer.Programmer.DevOpen then
  begin
    if not AsProgrammer.Programmer.ErrorWasLogged then
      LogPrint(AsProgrammer.Programmer.GetLastError);
    result := false;
    Exit;
  end;

  LogPrint(STR_CURR_HW+AsProgrammer.Programmer.HardwareName);
  result := true
end;


//The SR1 bits that are block protection on the part that answers 9Fh. Several
//of bits 2 to 7 protect nothing: SRP0 or SRWD (bit 7), Macronix QE (bit 6),
//TB and SEC on Winbond and GigaDevice parts below 256 Mbit (bits 5 and 6),
//Micron TB (bit 5), and on the Atmel AT25DF family the WP pin level (bit 4,
//1 while WP is high) and EPE (bit 5). The layouts follow flashrom's chip
//database, except bits 5 and 6 of the GigaDevice parts it decodes as BP4_SRWD
//(GD25Q16C datasheet). SR2 is not read: a Winbond or GigaDevice part with CMP
//set and its BP bits clear is fully protected, and that is not caught.  By Dreg
function SR1ProtectMask: byte;
var
  op: byte;
  id: array[0..2] of byte = ($FF, $FF, $FF);
begin
  op := $9F;
  spi25.SPIWrite(0, 1, op);
  spi25.SPIRead(1, 3, id);
  result := $3C;                //BP0 to BP3: Macronix, ISSI, SST and the rest
  case id[0] of
    $1F:
      //AT25DF, AT26DF, AT25DL, AT25DQ, AT25F512B (flashrom), AT25DF256 and
      //AT25DF512C (datasheets): SWP or BP0, bit 4 the WP pin level
      if ((id[1] in [$40, $42..$48]) and (id[2] <= $03)) or
         ((id[1] = $65) and (id[2] <= $01)) or
         ((id[1] = $86) and (id[2] = $00)) then
        result := $0C
      else if id[1] in [$42..$48] then
        result := $1C           //AT25SL, AT25FF: TB is bit 5, SEC bit 6
      else
        result := $7C;          //AT25FS, AT25SF, AT25EU: BP4 is bit 6
    $85, $0B:                   //Puya, XTX: BP4 is bit 6
      result := $7C;
    $EF, $C8:                   //Winbond, GigaDevice: BP3 (bit 5) from 256 Mbit
      if id[2] < $19 then
        result := $1C;
    $20:                        //Micron N25Q and MT25Q: TB is bit 5, BP3 bit 6
      if id[1] in [$BA, $BB] then
        result := $5C;
    $2C:                        //Micron MT35X
      result := $5C;
  end;
end;

function IsLockBitsEnabled: boolean;
var
  sreg, mask: byte;
begin
  result := false;
  sreg := 0;
  if MainForm.ComboSPICMD.ItemIndex = SPI_CMD_25 then
  begin
    mask := SR1ProtectMask;
    UsbAsp25_ReadSR(sreg);
    if (sreg and mask) <> 0 then
    begin
      LogPrint(STR_BLOCK_EN);
      Result := true;
    end;
  end;

  if MainForm.ComboSPICMD.ItemIndex = SPI_CMD_45 then
  begin
    UsbAsp45_ReadSR(sreg);
    if (sreg and 2 <> 0) then
    begin
      LogPrint(STR_BLOCK_EN);
      Result := true;
    end;
  end;

end;

//Установка скорости spi и Microwire
function SetSPISpeed(OverrideSpeed: byte): integer;
var
  Speed: byte;
begin
  //Not every programmer has a speed menu that this function reads, so start
  //from a defined value.
  Speed := 0;
  if AsProgrammer.Current_HW = CHW_ARDUINO then
  begin
    if MainForm.MenuArduinoISP8Mhz.Checked then Speed := MainForm.MenuArduinoISP8Mhz.Tag;
    if MainForm.MenuArduinoISP4Mhz.Checked then Speed := MainForm.MenuArduinoISP4Mhz.Tag;
    if MainForm.MenuArduinoISP2Mhz.Checked then Speed := MainForm.MenuArduinoISP2Mhz.Tag;
    if MainForm.MenuArduinoISP1Mhz.Checked then Speed := MainForm.MenuArduinoISP1Mhz.Tag;
  end;

  //Neither Bus Pirate back end takes its clock from here. Both read their own
  //menu inside the driver, because the number this function returns is an index
  //into a table that is specific to the programmer, and theirs are not the same
  //table.  By Dreg

  if AsProgrammer.Current_HW = CHW_AVRISP then
  begin
    if MainForm.MenuAVRISP8Mhz.Checked then Speed := MainForm.MenuAVRISP8Mhz.Tag;
    if MainForm.MenuAVRISP4Mhz.Checked then Speed := MainForm.MenuAVRISP4Mhz.Tag;
    if MainForm.MenuAVRISP2Mhz.Checked then Speed := MainForm.MenuAVRISP2Mhz.Tag;
    if MainForm.MenuAVRISP1Mhz.Checked then Speed := MainForm.MenuAVRISP1Mhz.Tag;
    if MainForm.MenuAVRISP500Khz.Checked then Speed := MainForm.MenuAVRISP500Khz.Tag;
    if MainForm.MenuAVRISP250Khz.Checked then Speed := MainForm.MenuAVRISP250Khz.Tag;
    if MainForm.MenuAVRISP125Khz.Checked then Speed := MainForm.MenuAVRISP125Khz.Tag;
  end;

  if (MainForm.RadioSPI.Checked) and (AsProgrammer.Current_HW = CHW_USBASP) then
  begin
    if MainForm.Menu3Mhz.Checked then Speed := MainForm.Menu3Mhz.Tag;
    if MainForm.Menu1_5Mhz.Checked then Speed := MainForm.Menu1_5Mhz.Tag;
    if MainForm.Menu750Khz.Checked then Speed := MainForm.Menu750Khz.Tag;
    if MainForm.Menu375Khz.Checked then Speed := MainForm.Menu375Khz.Tag;
    if MainForm.Menu187_5Khz.Checked then Speed := MainForm.Menu187_5Khz.Tag;
    if MainForm.Menu93_75Khz.Checked then Speed := MainForm.Menu93_75Khz.Tag;
    if MainForm.Menu32Khz.Checked then Speed := MainForm.Menu32Khz.Tag;
  end;

  if (MainForm.RadioMw.Checked) and (AsProgrammer.Current_HW = CHW_USBASP) then
  begin
    if MainForm.MenuMW32Khz.Checked then Speed := MainForm.MenuMW32Khz.Tag;
    if MainForm.MenuMW16Khz.Checked then Speed := MainForm.MenuMW16Khz.Tag;
    if MainForm.MenuMW8Khz.Checked then Speed := MainForm.MenuMW8Khz.Tag;
  end;

  if (MainForm.RadioSPI.Checked) and (AsProgrammer.Current_HW = CHW_FT232H) then
  begin
    if MainForm.MenuFT232SPI30Mhz.Checked then Speed := MainForm.MenuFT232SPI30Mhz.Tag;
    if MainForm.MenuFT232SPI6Mhz.Checked then Speed := MainForm.MenuFT232SPI6Mhz.Tag;
  end;

  //Whatever the radio says: a chip script can enter SPI with I2C or Microwire
  //selected, the CH347's Microwire ignores the clock, and a Speed left at 0
  //picks its fastest clock, 60 MHz.  By Dreg
  if AsProgrammer.Current_HW = CHW_CH347 then
  begin
    if MainForm.MenuCH347SPIClock60MHz.Checked then Speed := MainForm.MenuCH347SPIClock60MHz.Tag;
    if MainForm.MenuCH347SPIClock30MHz.Checked then Speed := MainForm.MenuCH347SPIClock30MHz.Tag;
    if MainForm.MenuCH347SPIClock15MHz.Checked then Speed := MainForm.MenuCH347SPIClock15MHz.Tag;
    if MainForm.MenuCH347SPIClock7_5MHz.Checked then Speed := MainForm.MenuCH347SPIClock7_5MHz.Tag;
    if MainForm.MenuCH347SPIClock3_75MHz.Checked then Speed := MainForm.MenuCH347SPIClock3_75MHz.Tag;
    if MainForm.MenuCH347SPIClock1_875MHz.Checked then Speed := MainForm.MenuCH347SPIClock1_875MHz.Tag;
    if MainForm.MenuCH347SPIClock937_5KHz.Checked then Speed := MainForm.MenuCH347SPIClock937_5KHz.Tag;
    if MainForm.MenuCH347SPIClock468_75KHz.Checked then Speed := MainForm.MenuCH347SPIClock468_75KHz.Tag;
  end;

  if OverrideSpeed <> 0 then Speed := OverrideSpeed;

  result := speed;
end;


function SetI2CDevAddr(): byte;
begin
    result := 0;
    With MainForm do
    begin
      if (CheckBox_I2C_A0.Checked) then result := SetBit(result, 1);
      if (CheckBox_I2C_A1.Checked) then result := SetBit(result, 2);
      if (CheckBox_I2C_A2.Checked) then result := SetBit(result, 3);

      if (CheckBox_I2C_DevA4.Checked) then result := SetBit(result, 4);
      if (CheckBox_I2C_DevA5.Checked) then result := SetBit(result, 5);
      if (CheckBox_I2C_DevA6.Checked) then result := SetBit(result, 6);
      if (CheckBox_I2C_DevA7.Checked) then result := SetBit(result, 7);
    end;
end;

procedure ReadFlashMW(var RomStream: TMemoryStream; AddrBitLen: byte; StartAddress, ChipSize: cardinal);
var
  ChunkSize: Word;
  BytesRead: integer;
  DataChunk: array[0..2047] of byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := 2;
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_READING_FLASH);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  RomStream.Clear;

  while Address < ChipSize div 2 do
  begin
    //if ChunkSize > ((ChipSize div 2) - Address) then ChunkSize := (ChipSize div 2) - Address;

    BytesRead := BytesRead + UsbAspMW_Read(AddrBitLen, Address, datachunk, ChunkSize);
    RomStream.WriteBuffer(datachunk, ChunkSize);
    Inc(Address, ChunkSize div 2);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 2;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if BytesRead <> ChipSize then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure WriteFlashMW(var RomStream: TMemoryStream; AddrBitLen: byte; StartAddress, ChipSize: cardinal);
var
  DataChunk: array[0..2047] of byte;
  Address, BytesWrite: cardinal;
  ChunkSize: Word;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  LogPrint(STR_WRITING_FLASH);
  BytesWrite := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize;

  ChunkSize := 2;

  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  UsbAspMW_EWEN(AddrBitLen);

  while Address < ChipSize div 2 do
  begin
    RomStream.ReadBuffer(DataChunk, ChunkSize);

    BytesWrite := BytesWrite + UsbAspMW_Write(AddrBitLen, Address, datachunk, ChunkSize);
    Inc(Address, ChunkSize div 2);

    while UsbAspMW_Busy do
    begin
       Application.ProcessMessages;
       if UserCancel then Exit;
    end; 

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + ChunkSize;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if BytesWrite <> ChipSize then
    LogPrint(STR_WRONG_BYTES_WRITE)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

//EN4B, checked. On a failure the caller stops before its loop: the loop sends
//four byte addresses, which a chip in three byte mode takes wrongly, address 0
//included. EN4B sends WREN and B7h, then on a Spansion or ISSI part (the 9Fh
//ID) a bank register write, so an earlier one may have gone through: EX4B
//goes out too.  By Dreg
function EnterFourByteMode: boolean;
begin
  result := UsbAsp25_EN4B() >= 1;
  if not result then
  begin
    UsbAsp25_EX4B();
    LogPrint(STR_DM_EN4B_FAILED);
  end;
end;

procedure WriteFlash25(var RomStream: TMemoryStream; StartAddress, WriteSize: cardinal; PageSize: word; WriteType: integer);
const
  FLASH_SIZE_128MBIT = 16777216;
var
  DataChunk: array[0..2047] of byte;
  DataChunk2: array[0..2047] of byte;
  Address, BytesWrite: cardinal;
  PageSizeTemp: word;
  i, Got: integer;
  SkipPage: boolean = false;
  InAAI: boolean = false;
  waitUntil: QWord;
begin
  if (WriteSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if MainForm.MenuAutoCheck.Checked then
    LogPrint(STR_WRITING_FLASH_WCHK) else
      LogPrint(STR_WRITING_FLASH);

  PageSizeTemp := PageSize;
  BytesWrite := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := WriteSize div PageSize;

  //Four byte mode depends on the highest address this pass touches, not on how
  //many bytes it moves: three byte addressing cannot express anything at or
  //above 16 MB. With the mode picked from WriteSize, a small buffer written
  //high up a 32 MB chip would wrap to a low address, and a Verify that picks
  //it the same way would read it back from there and pass.
  if (StartAddress + WriteSize) > FLASH_SIZE_128MBIT then
    if not EnterFourByteMode then Exit;
try
  while (Address-StartAddress) < WriteSize do
  begin
    //Только вначале aai
    if ((WriteType = WT_SSTB) and (Address = StartAddress)) or
    //Вначале страницы
    (WriteType = WT_PAGE) then UsbAsp25_WREN();

    //The first chunk stops at the next page boundary; every chunk after it is a
    //whole page. For SSTW that makes an odd start a chunk of one byte, and a
    //page size of 2 typed by hand (no chip in the list has one) aligns the same
    //way, so none of its chunks crosses a page boundary.
    if (Address = StartAddress) and (PageSizeTemp >= 2) then
      PageSize := PageSizeTemp - (StartAddress mod PageSizeTemp)
    else
      PageSize := PageSizeTemp;

    if (WriteSize - (Address-StartAddress)) < PageSize then PageSize := (WriteSize - (Address-StartAddress));
    RomStream.ReadBuffer(DataChunk, PageSize);

    if (WriteType = WT_SSTB) then
      if (Address = StartAddress) then //Пишем первый байт с адресом
        BytesWrite := BytesWrite + UsbAsp25_Write($AF, Address, datachunk, PageSize)
        else
        //Пишем остальные(без адреса)
        BytesWrite := BytesWrite + UsbAsp25_WriteSSTB($AF, datachunk[0]);

    //AAI Word Program writes whole words: the chip puts the first byte at
    //[A23-A1] with A0 = 0 and the second with A0 = 1, whatever A0 was sent
    //(SST25VF080B datasheet DS20005045D, 4.4.4). So a byte with no partner in
    //its word, at an odd start or as a last byte at an even address, goes in
    //with Byte Program (02h): outside AAI, so after a WRDI if AAI is running,
    //and with its own WREN. Sent as a word, it would land one byte lower or
    //write a stale second byte past the end.  By Dreg
    if (WriteType = WT_SSTW) then
      if PageSize = 1 then
      begin
        if InAAI then
        begin
          UsbAsp25_Wrdi();
          InAAI := false;
        end;
        UsbAsp25_WREN();
        BytesWrite := BytesWrite + UsbAsp25_Write($02, Address, datachunk, 1);
      end
      else if not InAAI then //Пишем первые два байта с адресом
      begin
        UsbAsp25_WREN();
        BytesWrite := BytesWrite + UsbAsp25_Write($AD, Address, datachunk, 2);
        InAAI := true;
      end
      else
        //Пишем остальные(без адреса)
        BytesWrite := BytesWrite + UsbAsp25_WriteSSTW($AD, datachunk[0], datachunk[1]);

    if WriteType = WT_PAGE then
    begin
      //Если страница вся FF то не пишем ее
      if MainForm.MenuSkipFF.Checked then
      begin
        SkipPage := True;
        for i:=0 to PageSize-1 do
          if DataChunk[i] <> $FF then
          begin
            SkipPage := False;
            Break;
          end;
      end;

      if not SkipPage then
      begin
        if (StartAddress + WriteSize) > FLASH_SIZE_128MBIT then
        begin
          //4 байтная адресация
          BytesWrite := BytesWrite + UsbAsp25_Write32bitAddr($02, Address, datachunk, PageSize)
        end
        else //Память в пределах 128Мбит
          BytesWrite := BytesWrite + UsbAsp25_Write($02, Address, datachunk, PageSize);
      end else BytesWrite := BytesWrite + PageSize;
    end;

    if (not MainForm.MenuIgnoreBusyBit.Checked) and (not SkipPage) then  //Игнорировать проверку
      if not WaitChipReady then Exit;

    if (MainForm.MenuAutoCheck.Checked) and (WriteType = WT_PAGE) then
    begin
      //Same condition as EN4B above: a read-back with three address bytes from
      //a chip in four byte mode compares the wrong page and fails a write that
      //worked.
      if (StartAddress + WriteSize) > FLASH_SIZE_128MBIT then
        Got := UsbAsp25_Read32bitAddr($03, Address, datachunk2, PageSize)
      else
        Got := UsbAsp25_Read($03, Address, datachunk2, PageSize);

      //A failed read-back leaves DataChunk2 holding the previous page, which
      //can match and pass a page that was never written.
      if Got <> PageSize then
      begin
        LogPrint(STR_WRONG_BYTES_READ + ' @ 0x' + IntToHex(Address, 8));
        MainForm.ProgressBar.Position := 0;
        Exit;
      end;

      for i:=0 to PageSize-1 do
        if DataChunk2[i] <> DataChunk[i] then
        begin
          LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
          MainForm.ProgressBar.Position := 0;
          Exit;
        end;
    end;

    Inc(Address, PageSize);
    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;
finally
  //Must match the EN4B condition and run on the abort paths too: a chip left
  //in four byte address mode breaks every later operation that picks three
  //byte addressing. The mode is volatile but survives CS, DevClose and
  //anything short of a power cycle.
  if (StartAddress + WriteSize) > FLASH_SIZE_128MBIT then
  begin
    //A cancel lands here while the last page program may still run, and a
    //busy chip ignores EX4B. A page program takes a few ms, so wait for WIP to
    //clear, 50 ms at most, without asking about a cancel that already came.
    waitUntil := GetTickCount64 + 50;
    while UsbAsp25_Busy and (GetTickCount64 < waitUntil) do ;
    UsbAsp25_EX4B();
  end;
  UsbAsp25_Wrdi(); //Для sst
end;

  if BytesWrite <> WriteSize then
    LogPrint(STR_WRONG_BYTES_WRITE)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure WriteFlash95(var RomStream: TMemoryStream; StartAddress, WriteSize: cardinal; PageSize: word; ChipSize: integer);
var
  DataChunk: array[0..2047] of byte;
  DataChunk2: array[0..2047] of byte;
  Address, BytesWrite: cardinal;
  PageSizeTemp: word;
  i: integer;
begin
  if (WriteSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if MainForm.MenuAutoCheck.Checked then
    LogPrint(STR_WRITING_FLASH_WCHK) else
      LogPrint(STR_WRITING_FLASH);

  PageSizeTemp := PageSize;
  BytesWrite := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := WriteSize div PageSize;

  while (Address-StartAddress) < WriteSize do
  begin
    UsbAsp95_WREN();

    //Trims the first chunk so a page write does not roll over a page boundary,
    //as WriteFlash25 and WriteFlashI2C do.  By Dreg
    if (Address = StartAddress) and (PageSizeTemp > 1) then
      PageSize := PageSizeTemp - (StartAddress mod PageSizeTemp)
    else
      PageSize := PageSizeTemp;

    if (WriteSize - (Address-StartAddress)) < PageSize then PageSize := (WriteSize - (Address-StartAddress));
    RomStream.ReadBuffer(DataChunk, PageSize);

    BytesWrite := BytesWrite + UsbAsp95_Write(ChipSize, Address, datachunk, PageSize);

    if not MainForm.MenuIgnoreBusyBit.Checked then  //Игнорировать проверку
      if not WaitChipReady then Exit;

    if MainForm.MenuAutoCheck.Checked then
    begin
      UsbAsp95_Read(ChipSize, Address, datachunk2, PageSize);
      for i:=0 to PageSize-1 do
        if DataChunk2[i] <> DataChunk[i] then
        begin
          LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
          MainForm.ProgressBar.Position := 0;
          Exit;
        end;
    end;

    Inc(Address, PageSize);
    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then Break;
  end;

  if BytesWrite <> WriteSize then
    LogPrint(STR_WRONG_BYTES_WRITE)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

//True when every byte was erased, which is when it logs Done.  By Dreg
function EraseEEPROM25(StartAddress, WriteSize: cardinal; PageSize: word; ChipSize: integer): boolean;
var
  DataChunk: array[0..2047] of byte;
  DataChunk2: array[0..2047] of byte;
  Address, BytesWrite: cardinal;
  i: integer;
begin
  result := false;
  if (StartAddress >= WriteSize) or (WriteSize = 0) {or (PageSize > WriteSize)} then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  BytesWrite := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := WriteSize div PageSize;

  while Address < WriteSize do
  begin
    UsbAsp95_WREN();

    if (WriteSize - Address) < PageSize then PageSize := (WriteSize - Address);

    FillByte(DataChunk, PageSize, $FF);

    BytesWrite := BytesWrite + UsbAsp95_Write(ChipSize, Address, datachunk, PageSize);

    if not MainForm.MenuIgnoreBusyBit.Checked then  //Игнорировать проверку
      if not WaitChipReady then Exit;

    if MainForm.MenuAutoCheck.Checked then
    begin
      UsbAsp95_Read(ChipSize, Address, datachunk2, PageSize);
      for i:=0 to PageSize-1 do
        if DataChunk2[i] <> DataChunk[i] then
        begin
          LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
          MainForm.ProgressBar.Position := 0;
          Exit;
        end;
    end;

    Inc(Address, PageSize);
    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if BytesWrite <> WriteSize then
    LogPrint(STR_WRONG_BYTES_WRITE)
  else
  begin
    LogPrint(STR_DONE);
    result := true;
  end;

  MainForm.ProgressBar.Position := 0;
end;

//False when the user cancelled or a command did not go out, which it logs.
//By Dreg
function EraseFlashKB(chipsize: longword; pagesize: word): boolean;
var
  i: integer;
  busy: boolean;

  function NotSent: boolean;
  begin
    if not AsProgrammer.Programmer.ErrorWasLogged then
      LogPrint(STR_DM_ERASE_NOT_SENT);
    MainForm.ProgressBar.Position := 0;
    result := false;
  end;

begin
  result := false;
  MainForm.ProgressBar.Max := chipsize div pagesize;

  if (UsbAspMulti_EnableEDI() < 1) or
     (UsbAspMulti_WriteReg($FEA7, $A4) < 1) then //en write
    Exit(NotSent);

  for i:= 0 to (chipsize div pagesize)-1 do
  begin
    if UsbAspMulti_ErasePage(i * pagesize) < 1 then Exit(NotSent);
    //busy
    repeat
      if UserCancel then Exit;
      busy := UsbAspMulti_Busy();
    until busy = false;

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
  end;

  MainForm.ProgressBar.Position := 0;
  result := true;
end;

procedure WriteFlashKB(var RomStream: TMemoryStream; StartAddress, WriteSize: cardinal; PageSize: word);
var
  DataChunk: array[0..2047] of byte;
  DataChunk2: array[0..2047] of byte;
  Address, BytesWrite: cardinal;
  i: integer;
  busy: boolean;
  SkipPage: boolean = false;
begin
  if (StartAddress >= WriteSize) or (WriteSize = 0) {or (PageSize > WriteSize)} then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if MainForm.MenuAutoCheck.Checked then
    LogPrint(STR_WRITING_FLASH_WCHK) else
      LogPrint(STR_WRITING_FLASH);

  BytesWrite := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := WriteSize div PageSize;

  UsbAspMulti_EnableEDI();
  UsbAspMulti_WriteReg($FEA7, $A4); //en write

  while Address < WriteSize do
  begin

    //if (WriteSize - Address) < PageSize then PageSize := (WriteSize - Address);
    RomStream.ReadBuffer(DataChunk, PageSize);


    //Если страница вся 00 то не пишем ее
    if MainForm.MenuSkipFF.Checked then
    begin
      SkipPage := True;
      for i:=0 to PageSize-1 do
        if DataChunk[i] <> $00 then
        begin
          SkipPage := False;
          Break;
        end;
    end;

    if not SkipPage then
      UsbAspMulti_WritePage(Address, datachunk);

    //busy
    repeat
      if UserCancel then Exit;
      busy := UsbAspMulti_Busy();
    until busy = false;

    BytesWrite := BytesWrite + PageSize;

     if (MainForm.MenuAutoCheck.Checked) then
      begin
        for i:=0 to PageSize-1 do
        begin
          UsbAspMulti_Read(Address+i, DataChunk2[0]);
          if DataChunk2[0] <> DataChunk[i] then
          begin
            LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
            MainForm.ProgressBar.Position := 0;
            Exit;
          end;
        end;
      end;

    Inc(Address, PageSize);
    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then Exit;
  end;

  if BytesWrite <> WriteSize then
    LogPrint(STR_WRONG_BYTES_WRITE)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure WriteFlash45(var RomStream: TMemoryStream; StartAddress, ChipSize: cardinal; PageSize: word; WriteType: integer);
var
  DataChunk: array[0..2047] of byte;
  DataChunk2: array[0..2047] of byte;
  PageAddress, BytesWrite: cardinal;
  i: integer;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) or (PageSize > ChipSize) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if MainForm.MenuAutoCheck.Checked then
    LogPrint(STR_WRITING_FLASH_WCHK) else
      LogPrint(STR_WRITING_FLASH);

  BytesWrite := 0;
  PageAddress := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div PageSize;

  while PageAddress < ChipSize div PageSize do
  begin
    //UsbAsp45_WREN(hUSBDev);
    RomStream.ReadBuffer(DataChunk, PageSize);

    if WriteType = WT_PAGE then
      BytesWrite := BytesWrite + UsbAsp45_Write(PageAddress, datachunk, PageSize);

    while UsbAsp45_Busy() do
    begin
      Application.ProcessMessages;
      if UserCancel then Exit;
    end;

    if MainForm.MenuAutoCheck.Checked then
    begin
      UsbAsp45_Read(PageAddress, datachunk2, PageSize);
      for i:=0 to PageSize-1 do
        if DataChunk2[i] <> DataChunk[i] then
        begin
          LogPrint(STR_VERIFY_ERROR+IntToHex((PageAddress*PageSize )+i, 8));
          Exit;
        end;
    end;

    Inc(PageAddress, 1);
    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then Break;
  end;

  if BytesWrite <> ChipSize then
    LogPrint(STR_WRONG_BYTES_WRITE)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure ReadFlash25(var RomStream: TMemoryStream; StartAddress, ChipSize: cardinal);
const
  FLASH_SIZE_128MBIT = 16777216;
var
  ChunkSize: Word;
  BytesRead, Got: integer;
  DataChunk: array[0..65534] of byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if ASProgrammer.Current_HW = CHW_FT232H then
    ChunkSize := 16787 else
  if ASProgrammer.Current_HW = CHW_CH347 then
    ChunkSize := SizeOf(DataChunk)
  else
  if ASProgrammer.Current_HW = CHW_BUZZPIRAT then
    //One firmware side bulk buffer, so one round trip per chunk.
    ChunkSize := BP_MAX_BULK
  else
  if ASProgrammer.Current_HW = CHW_BUSPIRATE5 then
    //BPIO2's own limit, read back from the device at connect time.
    ChunkSize := BusPirate5Dev.MaxRead
  else
    ChunkSize := 2048;



  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_READING_FLASH);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  RomStream.Clear;

  if ChipSize > FLASH_SIZE_128MBIT then
    if not EnterFourByteMode then Exit;
try
  while Address < ChipSize do
  begin
    if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    if ChipSize > FLASH_SIZE_128MBIT then
      Got := UsbAsp25_Read32bitAddr($03, Address, datachunk, ChunkSize)
    else
      Got := UsbAsp25_Read($03, Address, datachunk, ChunkSize);

    //A failed chunk must never reach the image. DataChunk still holds the
    //previous one, and writing that would put a plausible looking duplicate in
    //the dump that nothing downstream can tell apart from real data.
    if Got <> ChunkSize then
    begin
      LogPrint(STR_WRONG_BYTES_READ + ' @ 0x' + IntToHex(Address, 8));
      Break;
    end;

    Inc(BytesRead, Got);
    RomStream.WriteBuffer(datachunk, chunksize);
    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;
finally
  //As in the other four byte mode loops: an exception anywhere above would
  //leave the chip latched, which breaks every later operation that picks three
  //byte addressing until the part is power cycled.  By Dreg
  if ChipSize > FLASH_SIZE_128MBIT then UsbAsp25_EX4B();
end;

  //The loop covers StartAddress..ChipSize, so a complete read produces
  //ChipSize - StartAddress bytes.
  if BytesRead <> integer(ChipSize - StartAddress) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure ReadFlash95(var RomStream: TMemoryStream; StartAddress, ChipSize: cardinal);
var
  ChunkSize: Word;
  BytesRead: integer;
  DataChunk: array[0..2047] of byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := SizeOf(DataChunk);
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_READING_FLASH);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  RomStream.Clear;

  while Address < ChipSize do
  begin
    if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    BytesRead := BytesRead + UsbAsp95_Read(ChipSize, Address, datachunk, ChunkSize);
    RomStream.WriteBuffer(datachunk, chunksize);
    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  //A read from a Start address stops at the end of the chip, as in
  //ReadFlash25.  By Dreg
  if BytesRead <> integer(ChipSize - StartAddress) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure ReadFlash45(var RomStream: TMemoryStream; StartAddress, PageSize, ChipSize: cardinal);
var
  ChunkSize: Word;
  BytesRead: integer;
  DataChunk: array[0..2047] of byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := PageSize;
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_READING_FLASH);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  RomStream.Clear;

  while Address < ChipSize div ChunkSize do
  begin
    if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    BytesRead := BytesRead + UsbAsp45_Read(Address, datachunk, ChunkSize);
    RomStream.WriteBuffer(datachunk, chunksize);
    Inc(Address, 1);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if BytesRead <> ChipSize then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure ReadFlashKB(var RomStream: TMemoryStream; StartAddress, ChipSize: cardinal);
var
  ChunkSize: byte;
  BytesRead: integer;
  DataChunk: byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := SizeOf(DataChunk);
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_READING_FLASH);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  UsbAspMulti_EnableEDI();

  RomStream.Clear;

  while Address < ChipSize do
  begin
    if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    BytesRead := BytesRead + UsbAspMulti_Read(Address, datachunk);
    RomStream.WriteBuffer(datachunk, chunksize);
    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if BytesRead <> ChipSize then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;


procedure VerifyFlash25(var RomStream: TMemoryStream; StartAddress, DataSize: cardinal);
const
  FLASH_SIZE_128MBIT = 16777216;
var
  ChunkSize: Word;
  BytesRead, Got, i: integer;
  DataChunk: array[0..16786] of byte;
  DataChunkFile: array[0..16786] of byte;
  Address: cardinal;
begin
  if (DataSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if ASProgrammer.Current_HW = CHW_FT232H then
    ChunkSize := SizeOf(DataChunk)
  else
  if ASProgrammer.Current_HW = CHW_BUZZPIRAT then
    ChunkSize := BP_MAX_BULK
  else
  if ASProgrammer.Current_HW = CHW_BUSPIRATE5 then
    ChunkSize := BusPirate5Dev.MaxRead
  else
    ChunkSize := 2048;

  if ChunkSize > DataSize then ChunkSize := DataSize;

  LogPrint(STR_VERIFY);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := DataSize div ChunkSize;

  //As in WriteFlash25: four byte mode depends on the highest address this pass
  //touches, not on how many bytes it moves.
  if (StartAddress + DataSize) > FLASH_SIZE_128MBIT then
    if not EnterFourByteMode then Exit;
try
  while (Address-StartAddress) < DataSize do
  begin
    if ChunkSize > (DataSize - (Address-StartAddress)) then ChunkSize := DataSize - (Address-StartAddress);

    if (StartAddress + DataSize) > FLASH_SIZE_128MBIT then
        Got := UsbAsp25_Read32bitAddr($03, Address, datachunk, ChunkSize)
      else
        Got := UsbAsp25_Read($03, Address, datachunk, ChunkSize);

    //Comparing a stale buffer would report a mismatch at the wrong address, or
    //none at all.
    if Got <> ChunkSize then
    begin
      LogPrint(STR_WRONG_BYTES_READ + ' @ 0x' + IntToHex(Address, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;
    Inc(BytesRead, Got);

    RomStream.ReadBuffer(DataChunkFile, ChunkSize);

    for i := 0 to ChunkSize -1 do
    if DataChunk[i] <> DataChunkFile[i] then
    begin
      LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;

    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;
finally
  //Both early Exits above leave the loop, so the four byte mode has to be
  //undone here or the chip stays latched in it for every later operation.
  if (StartAddress + DataSize) > FLASH_SIZE_128MBIT then UsbAsp25_EX4B();
end;

  if (BytesRead <> integer(DataSize)) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure VerifyFlash95(var RomStream: TMemoryStream; StartAddress, DataSize, ChipSize: cardinal);
var
  ChunkSize: Word;
  BytesRead, i: integer;
  DataChunk: array[0..2047] of byte;
  DataChunkFile: array[0..2047] of byte;
  Address: cardinal;
begin
  if (DataSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := SizeOf(DataChunk);
  if ChunkSize > DataSize then ChunkSize := DataSize;

  LogPrint(STR_VERIFY);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := DataSize div ChunkSize;

  while (Address-StartAddress) < DataSize do
  begin
    if ChunkSize > (DataSize - (Address-StartAddress)) then ChunkSize := DataSize - (Address-StartAddress);

    BytesRead := BytesRead + UsbAsp95_Read(ChipSize, Address, datachunk, ChunkSize);
    RomStream.ReadBuffer(DataChunkFile, ChunkSize);

    for i := 0 to ChunkSize -1 do
    if DataChunk[i] <> DataChunkFile[i] then
    begin
      LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;

    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if (BytesRead <> DataSize) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure VerifyFlash45(var RomStream: TMemoryStream; StartAddress, PageSize, ChipSize: cardinal);
var
  ChunkSize: Word;
  BytesRead, i: integer;
  DataChunk: array[0..2047] of byte;
  DataChunkFile: array[0..2047] of byte;
  PageAddress: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := PageSize;
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_VERIFY);
  BytesRead := 0;
  PageAddress := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  while PageAddress < ChipSize div ChunkSize do
  begin
    //if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    BytesRead := BytesRead + UsbAsp45_Read(PageAddress, datachunk, ChunkSize);
    RomStream.ReadBuffer(DataChunkFile, ChunkSize);

    for i := 0 to ChunkSize -1 do
    if DataChunk[i] <> DataChunkFile[i] then
    begin
      LogPrint(STR_VERIFY_ERROR+IntToHex((PageAddress*ChunkSize)+i, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;

    Inc(PageAddress, 1);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if (BytesRead <> ChipSize) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure VerifyFlashMW(var RomStream: TMemoryStream; AddrBitLen: byte; StartAddress, ChipSize: cardinal);
var
  ChunkSize: Word;
  BytesRead, i: integer;
  DataChunk: array[0..2047] of byte;
  DataChunkFile: array[0..2047] of byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := 2;
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_VERIFY);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  while Address < ChipSize div 2 do
  begin
    BytesRead := BytesRead + UsbAspMW_Read(AddrBitLen, Address, datachunk, ChunkSize);
    RomStream.ReadBuffer(DataChunkFile, ChunkSize);

    for i := 0 to ChunkSize -1 do
    if DataChunk[i] <> DataChunkFile[i] then
    begin
      LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;

    Inc(Address, ChunkSize div 2);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 2;
    Application.ProcessMessages;
    if UserCancel then Break;
  end;

  if (BytesRead <> ChipSize) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure VerifyFlashKB(var RomStream: TMemoryStream; StartAddress, ChipSize: cardinal);
var
  ChunkSize: byte;
  BytesRead: integer;
  DataChunk: byte;
  DataChunkFile: byte;
  Address: cardinal;
begin
  if (StartAddress >= ChipSize) or (ChipSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  ChunkSize := SizeOf(DataChunk);
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_VERIFY);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  UsbAspMulti_EnableEDI();
  UsbAspMulti_WriteReg($FEAD, $08); //en flash

  //RomStream.Clear;

  while Address < ChipSize do
  begin
    if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    BytesRead := BytesRead + UsbAspMulti_Read(Address, datachunk);
    RomStream.ReadBuffer(DataChunkFile, ChunkSize);

    if DataChunk <> DataChunkFile then
    begin
      LogPrint(STR_VERIFY_ERROR+IntToHex(Address, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;

    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  if BytesRead <> ChipSize then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure ReadFlashI2C(var RomStream: TMemoryStream; StartAddress, ChipSize: cardinal; ChunkSize: Word; DevAddr: byte);
var
  BytesRead, Got: integer;
  DataChunk: array[0..255] of byte;
  Address: cardinal;
begin
  if ChipSize = 0 then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  if ChunkSize > SizeOf(DataChunk) then ChunkSize := SizeOf(DataChunk);
  if ChunkSize < 1 then ChunkSize := 1;
  if ChunkSize > ChipSize then ChunkSize := ChipSize;

  LogPrint(STR_READING_FLASH);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := ChipSize div ChunkSize;

  RomStream.Clear;

  while Address < ChipSize do
  begin
    if ChunkSize > (ChipSize - Address) then ChunkSize := ChipSize - Address;

    Got := UsbAspI2C_Read(DevAddr, MainForm.ComboAddrType.ItemIndex, Address, datachunk, ChunkSize);

    //Never let a failed chunk into the image: DataChunk still holds the
    //previous one and the duplicate would be indistinguishable from real data.
    if Got <> ChunkSize then
    begin
      LogPrint(STR_WRONG_BYTES_READ + ' @ 0x' + IntToHex(Address, 8));
      Break;
    end;

    Inc(BytesRead, Got);
    RomStream.WriteBuffer(DataChunk, ChunkSize);
    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then Break;
  end;

  //The loop covers StartAddress..ChipSize, so a complete read produces
  //ChipSize - StartAddress bytes.
  if BytesRead <> integer(ChipSize - StartAddress) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

//False when it stopped: a cancel, a chip that stayed busy, or nothing to
//write. Pages that failed do not stop it.  By Dreg
function WriteFlashI2C(var RomStream: TMemoryStream; StartAddress, WriteSize: cardinal; PageSize: word; DevAddr: byte): boolean;
var
  DataChunk: array[0..2047] of byte;
  Address, BytesWrite: cardinal;
  PageSizeTemp: word;
  BusyDeadline: QWord;
  PageAddr, FirstFailed: cardinal;
  Written, Pages, Failed: integer;
  Stopped: boolean;
begin
  result := false;
  Stopped := false;
  if {(StartAddress >= WriteSize) or} (WriteSize = 0) {or (PageSize > WriteSize)} then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  PageSizeTemp := PageSize;
  LogPrint(STR_WRITING_FLASH);
  BytesWrite := 0;
  Pages := 0;
  Failed := 0;
  FirstFailed := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := WriteSize div PageSize;

  while (Address-StartAddress) < WriteSize do
  begin
    //The first chunk stops at the next page boundary and every chunk after it
    //is a whole page, so no page write rolls over a page boundary.
    if (Address = StartAddress) and (PageSizeTemp > 1) then
      PageSize := PageSizeTemp - (StartAddress mod PageSizeTemp)
    else
      PageSize := PageSizeTemp;

    if (WriteSize - (Address-StartAddress)) < PageSize then PageSize := (WriteSize - (Address-StartAddress));

    RomStream.ReadBuffer(DataChunk, PageSize);
    //Keep the address of the page being written: Address moves on before the
    //wait below, whose timeout names this page.  By Dreg
    PageAddr := Address;
    Written := UsbAspI2C_Write(DevAddr, MainForm.ComboAddrType.ItemIndex, Address, datachunk, PageSize);
    Inc(Pages);
    //A programmer returns the page size for a page it sent and a negative
    //number for a transfer that failed. Only the two Bus Pirate back ends are
    //known to fail a page whose data the chip refused: FT232H, USBasp,
    //AVRISP-MKII and Arduino never look at that acknowledge, and CH341 and
    //CH347 fail only when their DLL call fails. A failed page is counted and
    //the write goes on: a chip can protect only part of itself (an SPD EEPROM
    //can protect 00h-7Fh and still take 80h-FFh).  By Dreg
    if Written < PageSize then
    begin
      if Failed = 0 then FirstFailed := PageAddr;
      Inc(Failed);
    end
    else
      BytesWrite := BytesWrite + cardinal(Written);
    Inc(Address, PageSize);

    //Acknowledge polling: the chip stops answering while it programs a page.
    //A transport failure looks exactly like a busy chip from here, so the wait
    //is bounded: an EEPROM page write is milliseconds, and without the bound a
    //broken link spins in this loop until the user notices and cancels.
    BusyDeadline := GetTickCount64 + 5000;
    while UsbAspI2C_BUSY(DevAddr) do
    begin
      Application.ProcessMessages;
      if UserCancel then
      begin
        Stopped := true;
        Break;
      end;
      if GetTickCount64 > BusyDeadline then
      begin
        LogPrint(STR_I2C_NO_ANSWER + ' @ 0x' + IntToHex(PageAddr, 8));
        Stopped := true;
        Break;
      end;
    end;
    if Stopped then Break;

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then
    begin
      Stopped := true;
      Break;
    end;
  end;

  //A stop has logged its reason. The pages that failed before it still get
  //their line, and no byte count is compared.  By Dreg
  if Failed > 0 then
    LogPrint(Format(STR_DM_I2C_PAGES_FAILED, [Failed, Pages, IntToHex(FirstFailed, 8)]))
  else if not Stopped then
  begin
    if BytesWrite <> WriteSize then
      LogPrint(STR_WRONG_BYTES_WRITE)
    else
      LogPrint(STR_DONE);
  end;

  MainForm.ProgressBar.Position := 0;
  result := not Stopped;
end;

//True when every page was erased, which is when it logs Done. PartlyRefused
//when it ran to the end and the chip refused some pages but not all, as an SPD
//EEPROM that protects 00h-7Fh does.  By Dreg
function EraseFlashI2C(StartAddress, WriteSize: cardinal; PageSize: word; DevAddr: byte;
  out PartlyRefused: boolean): boolean;
var
  DataChunk: array[0..2047] of byte;
  Address, BytesWrite, PageAddr, FirstFailed: cardinal;
  BusyDeadline: QWord;
  Written, Pages, Failed: integer;
  Stopped: boolean;
begin
  result := false;
  PartlyRefused := false;
  Stopped := false;
  if (StartAddress >= WriteSize) or (WriteSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  LogPrint(STR_ERASING_FLASH);
  BytesWrite := 0;
  Pages := 0;
  Failed := 0;
  FirstFailed := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := WriteSize div PageSize;

  while Address < WriteSize do
  begin
    if (WriteSize - Address) < PageSize then PageSize := (WriteSize - Address);
    FillByte(DataChunk, PageSize, $FF);
    PageAddr := Address;
    Written := UsbAspI2C_Write(DevAddr, MainForm.ComboAddrType.ItemIndex, Address, datachunk, PageSize);
    Inc(Pages);
    //Counted as in the write loop: a failed page does not stop the erase.
    if Written < PageSize then
    begin
      if Failed = 0 then FirstFailed := PageAddr;
      Inc(Failed);
    end
    else
      BytesWrite := BytesWrite + cardinal(Written);
    Inc(Address, PageSize);

    //Bounded as in the write loop: a link that has died looks exactly like a
    //chip that is still programming.
    BusyDeadline := GetTickCount64 + 5000;
    while UsbAspI2C_BUSY(DevAddr) do
    begin
      Application.ProcessMessages;
      if UserCancel then
      begin
        Stopped := true;
        Break;
      end;
      if GetTickCount64 > BusyDeadline then
      begin
        LogPrint(STR_I2C_NO_ANSWER + ' @ 0x' + IntToHex(PageAddr, 8));
        Stopped := true;
        Break;
      end;
    end;
    if Stopped then Break;

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then
    begin
      Stopped := true;
      Break;
    end;
  end;

  //As in the write loop.  By Dreg
  if Failed > 0 then
    LogPrint(Format(STR_DM_I2C_PAGES_FAILED, [Failed, Pages, IntToHex(FirstFailed, 8)]))
  else if not Stopped then
  begin
    if BytesWrite <> WriteSize then
      LogPrint(STR_WRONG_BYTES_WRITE)
    else
    begin
      LogPrint(STR_DONE);
      result := true;
    end;
  end;
  PartlyRefused := (Failed > 0) and (Failed < Pages) and not Stopped;

  MainForm.ProgressBar.Position := 0;
end;

procedure VerifyFlashI2C(var RomStream: TMemoryStream; StartAddress, DataSize: cardinal; ChunkSize: Word; DevAddr: byte);
var
  BytesRead, Got, i: integer;
  DataChunk: array[0..2047] of byte;
  DataChunkFile: array[0..2047] of byte;
  Address: cardinal;
begin
  if (DataSize = 0) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    exit;
  end;

  //The caller passes 65535 unless the user asked for byte at a time reads, so
  //without a limit from the programmer itself this asks for up to the whole
  //2048 byte buffer. A Bus Pirate v5 or newer reads at most 512 bytes per
  //request, and its back end splits anything larger into several, so its own
  //limit is the chunk that costs one round trip, as in VerifyFlash25.  By Dreg
  if (ASProgrammer.Current_HW = CHW_BUSPIRATE5) and (BusPirate5Dev <> nil) then
    if ChunkSize > BusPirate5Dev.MaxRead then ChunkSize := BusPirate5Dev.MaxRead;

  if ChunkSize > SizeOf(DataChunk) then ChunkSize := SizeOf(DataChunk);
  if ChunkSize < 1 then ChunkSize := 1;
  if ChunkSize > DataSize then ChunkSize := DataSize;

  LogPrint(STR_VERIFY);
  BytesRead := 0;
  Address := StartAddress;
  MainForm.ProgressBar.Max := DataSize div ChunkSize;

  while (Address-StartAddress) < DataSize do
  begin
    if ChunkSize > (DataSize - (Address - StartAddress)) then ChunkSize := DataSize -(Address - StartAddress) ;

    Got := UsbAspI2C_Read(DevAddr, MainForm.ComboAddrType.ItemIndex, Address, datachunk, ChunkSize);

    //After a short read DataChunk is stale: comparing it would report a
    //mismatch at the wrong address, or none at all.
    if Got <> ChunkSize then
    begin
      LogPrint(STR_WRONG_BYTES_READ + ' @ 0x' + IntToHex(Address, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;
    Inc(BytesRead, Got);

    RomStream.ReadBuffer(DataChunkFile, ChunkSize);

    for i := 0 to ChunkSize -1 do
    if DataChunk[i] <> DataChunkFile[i] then
    begin
      LogPrint(STR_VERIFY_ERROR+IntToHex(Address+i, 8));
      MainForm.ProgressBar.Position := 0;
      Exit;
    end;

    Inc(Address, ChunkSize);

    MainForm.ProgressBar.Position := MainForm.ProgressBar.Position + 1;
    Application.ProcessMessages;
    if UserCancel then Break;
  end;

  if (BytesRead <> integer(DataSize)) then
    LogPrint(STR_WRONG_BYTES_READ)
  else
    LogPrint(STR_DONE);

  MainForm.ProgressBar.Position := 0;
end;

procedure SelectHW(programmer: THardwareList);
begin
  //Release every Bus Pirate back end but the incoming one, and only when the
  //selection really changes: this is also called while the saved settings are
  //applied at startup. Each driver holds its own serial handle, the I2C scan
  //and Device info of both menus, and Show pin labels, open one whatever
  //programmer is selected, and on a v5 or newer the two menus can point at
  //ports of the same physical device, so a session left open makes the other
  //driver fail with an access denied that reads like a driver fault.
  //Disconnecting also parks the pins and drops the target supply, which is
  //what should happen when the user changes programmer.  By Dreg
  if programmer <> AsProgrammer.Current_HW then
  begin
    if (programmer <> CHW_BUZZPIRAT) and (BuzzpiratDev <> nil) then
      BuzzpiratDev.Disconnect;
    if (programmer <> CHW_BUSPIRATE5) and (BusPirate5Dev <> nil) then
      BusPirate5Dev.Disconnect;
  end;

  if programmer = CHW_USBASP then
  begin
    MainForm.MenuSPIClock.Visible:= true;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuFT232SPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= true;
    AsProgrammer.Current_HW := CHW_USBASP;
  end;

  if programmer = CHW_CH341 then
  begin
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuFT232SPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_CH341;
  end;

  if programmer = CHW_CH347 then
  begin
    MainForm.MenuCH347SPIClock.Visible:= true;
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuFT232SPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_CH347;
  end;

  if programmer = CHW_AVRISP then
  begin
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= true;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuFT232SPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_AVRISP;
  end;

  if programmer = CHW_ARDUINO then
  begin
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= true;
    MainForm.MenuFT232SPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_ARDUINO;
  end;

  if programmer = CHW_BUZZPIRAT then
  begin
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuFT232SPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_BUZZPIRAT;
  end;

  if programmer = CHW_BUSPIRATE5 then
  begin
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuFT232SPIClock.Visible:= false;
    //BPIO2 has no Microwire: its 3-wire handlers are not wired into the
    //firmware's dispatch table and DataRequest is byte granular anyway.
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_BUSPIRATE5;
  end;

  if programmer = CHW_FT232H then
  begin
    MainForm.MenuFT232SPIClock.Visible:= true;
    MainForm.MenuCH347SPIClock.Visible:= false;
    MainForm.MenuSPIClock.Visible:= false;
    MainForm.MenuAVRISPSPIClock.Visible:= false;
    MainForm.MenuArduinoSPIClock.Visible:= false;
    MainForm.MenuMicrowire.Enabled:= false;
    AsProgrammer.Current_HW := CHW_FT232H;
  end;

end;

//Tag of whichever child of a submenu is checked, and its inverse. The
//BusPirateV5+ clock and supply menus carry their value in Tag, so they need no
//if-ladder to save or restore.
function MenuCheckedTag(Parent: TMenuItem; Default: PtrInt): PtrInt;
var
  i: integer;
begin
  result := Default;
  if Parent = nil then Exit;
  for i := 0 to Parent.Count - 1 do
    if Parent.Items[i].Checked then Exit(Parent.Items[i].Tag);
end;

procedure MenuCheckByTag(Parent: TMenuItem; Value: PtrInt);
var
  i: integer;
begin
  if Parent = nil then Exit;
  for i := 0 to Parent.Count - 1 do
    if Parent.Items[i].Tag = Value then
    begin
      Parent.Items[i].Checked := true;
      Exit;
    end;
end;

//Waits for the chip to finish an erase, a page program or a status register
//write. False means the operation has to stop: the user cancelled, which
//UserCancel has already logged, or the chip stopped answering, logged here.
function WaitChipReady: boolean;
var
  linkLost: boolean;
begin
  result := UsbAsp25_WaitReady(linkLost);
  if linkLost then
  begin
    LogPrint('The chip stopped answering while waiting for it to finish - aborted');
    //As UserCancel does: every caller leaves on false, and a chip erase runs
    //the bar in marquee mode.  By Dreg
    MainForm.ProgressBar.Style := pbstNormal;
    MainForm.ProgressBar.Position := 0;
  end;
end;

//Everything that can reach the device or the buffer. The flash loops pump the
//message queue with Application.ProcessMessages, so without this a menu click
//lands in the middle of a transfer: Disconnect closes the port under a running
//read, the I2C scanner re-enters the driver, changing the COM port drops the
//session, and the random fill rewrites the stream the write loop is reading.
procedure SetOperationMenusEnabled(OnOff: boolean);
begin
  MainForm.MenuChip.Enabled := OnOff;
  MainForm.MenuOptions.Enabled := OnOff;
  MainForm.MenuItemHardware.Enabled := OnOff;
  MainForm.MenuBuzzpirat.Enabled := OnOff;
  MainForm.MenuBP5.Enabled := OnOff;
  MainForm.MenuHexEditor.Enabled := OnOff;
  MainForm.ScriptsMenuItem.Enabled := OnOff;

  //Also the bus radios: their change handlers reset the chip size, the page
  //size and the address type, which the running transfer still reads.  By Dreg
  MainForm.RadioSPI.Enabled := OnOff;
  MainForm.RadioI2C.Enabled := OnOff;
  MainForm.RadioMw.Enabled := OnOff;

  //The status register editor and the script editor are modeless, so they stay
  //clickable while an operation runs. A click on the editor's Read in the
  //middle of an 8 MB write opens the device, does its own traffic and closes
  //it again underneath the write, which then fails. With
  //"Reset device on every operation" or "Reconnect on every operation"
  //ticked it also drops the supply mid page program.  By Dreg
  if sregedit.sregeditForm <> nil then sregedit.sregeditForm.Enabled := OnOff;
  if ScriptEditForm <> nil then ScriptEditForm.Enabled := OnOff;
  //Find IC stays on top and selecting a chip there sets the bus radios, the
  //chip size and the page size, and re-enables Erase, all while the transfer
  //still reads them.  By Dreg
  if ChipSearchForm <> nil then ChipSearchForm.Enabled := OnOff;
end;

var
  //True from LockControl to UnlockControl, while an operation uses the
  //programmer. The window still processes messages then, so it can be closed:
  //FormCloseQuery reads this.  By Dreg
  ControlLocked: boolean = false;

procedure LockControl;
begin
  ControlLocked := true;
  SetOperationMenusEnabled(false);
  MainForm.ButtonRead.Enabled := False;
  MainForm.ButtonWrite.Enabled := False;
  MainForm.ButtonVerify.Enabled := False;
  MainForm.ButtonReadID.Enabled := False;
  MainForm.ButtonBlock.Enabled := False;
  MainForm.ButtonErase.Enabled := False;
  MainForm.ButtonOpenHex.Enabled := False;
  MainForm.ButtonSaveHex.Enabled := False;

  MainForm.GroupChipSettings.Enabled := false;
  MainForm.MPHexEditorEx.Enabled := false;
end;

procedure UnlockControl;
begin
  ControlLocked := false;
  SetOperationMenusEnabled(true);
  MainForm.MPHexEditorEx.Enabled := true;
  MainForm.GroupChipSettings.Enabled := true;
  MainForm.ButtonRead.Enabled := True;
  MainForm.ButtonWrite.Enabled := True;
  MainForm.ButtonVerify.Enabled := True;
  MainForm.ButtonOpenHex.Enabled := True;
  MainForm.ButtonSaveHex.Enabled := True;
  MainForm.ButtonErase.Enabled := True;

  if MainForm.RadioSPI.Checked then
  begin
    MainForm.ButtonReadID.Enabled := True;
    if MainForm.ComboSPICMD.ItemIndex = SPI_CMD_KB then
      MainForm.ButtonBlock.Enabled := False
    else
      MainForm.ButtonBlock.Enabled := True;
  end;
end;

procedure TMainForm.ChipClick(Sender: TObject);
begin
  if Sender is TMenuItem then
    findchip.SelectChip(chiplistfile, TMenuItem(Sender).Caption);
end;

procedure TMainForm.MPHexEditorExChange(Sender: TObject);
begin
  StatusBar.Panels.Items[0].Text := STR_SIZE+IntToStr(MPHexEditorEx.DataSize);
  if MPHexEditorEx.Modified then
    StatusBar.Panels.Items[1].Text := STR_CHANGED
  else
    StatusBar.Panels.Items[1].Text := '';
end;

procedure TMainForm.ComboItem1Click(Sender: TObject);
var
  CheckTemp: Boolean;
begin
  if MessageDlg('AsProgrammer', STR_COMBO_WARN, mtConfirmation, [mbYes, mbNo], 0)
    <> mrYes then Exit;

  if ButtonBlock.Enabled then
  begin
    ButtonBlockClick(Sender);
    //A cancel during Unprotect stops the command too: the erase below would
    //clear it.  By Dreg
    if ButtonCancel.Tag <> 0 then Exit;
  end;
  if ButtonErase.Enabled then
    if ComboSPICMD.ItemIndex <> SPI_CMD_45 then  //Сами стирают страницу
    begin
      ButtonEraseClick(Sender);
      //The command stops after a cancel and after an erase that did not end
      //well, as the same fault would meet the write. It goes on when an I2C
      //EEPROM refused only some pages, so the write programs the pages the
      //chip does not protect.  By Dreg
      if not FEraseOK then Exit;
    end;

  CheckTemp := MenuAutoCheck.Checked;
  MenuAutoCheck.Checked := True;
  //Verify is the user's again however the write ends.  By Dreg
  try
    ButtonWriteClick(Sender);
  finally
    MenuAutoCheck.Checked := CheckTemp;
  end;
end;

procedure TMainForm.MenuArduinoCOMPortClick(Sender: TObject);
begin
  Arduino_COMPort := InputBox('Arduino COMPort','',Arduino_COMPort);
  MainForm.MenuArduinoCOMPort.Caption := 'Arduino COMPort: '+Arduino_COMPort;
end;

procedure TMainForm.RefreshCOMPortMenu;
var
  ports: TStringList;
  i, wanted: integer;
  item: TMenuItem;
  sig, cur: string;
begin
  if MenuBuzzpiratCOMPort = nil then Exit;

  ports := TStringList.Create;
  try
    //Only the ports present right now: one that is not there cannot be opened.
    BPGetSerialPorts(ports);
    cur := Trim(Buzzpirat_COMPort);

    sig := ports.CommaText + '|' + cur;
    if sig = FCOMPortMenuSig then Exit;
    FCOMPortMenuSig := sig;

    //One disabled placeholder when there is nothing to offer.
    wanted := ports.Count;
    if wanted = 0 then wanted := 1;

    //Never destroy an item from the timer. A submenu that is open while
    //this fires is walking the very list being freed, and the surplus is
    //at most a few entries, so hide it instead. Growing is safe: an item
    //that appears is not one the menu is already pointing at.  By Dreg
    while MenuBuzzpiratCOMPort.Count < wanted do
    begin
      item := TMenuItem.Create(Self);
      item.RadioItem := true;
      item.AutoCheck := false;
      MenuBuzzpiratCOMPort.Add(item);
    end;

    for i := 0 to MenuBuzzpiratCOMPort.Count - 1 do
      MenuBuzzpiratCOMPort.Items[i].Visible := i < wanted;

    if ports.Count = 0 then
    begin
      item := MenuBuzzpiratCOMPort.Items[0];
      item.Caption := STR_DM_NO_SERIAL_PORTS;
      item.Hint := '';
      item.Checked := false;
      item.Enabled := false;
      item.OnClick := nil;
    end
    else
      for i := 0 to ports.Count - 1 do
      begin
        item := MenuBuzzpiratCOMPort.Items[i];
        item.Caption := ports[i];
        //The plain port name lives here, so the caption stays free to explain.
        item.Hint := ports[i];
        item.Enabled := true;
        item.Checked := SameText(ports[i], cur);
        item.OnClick := @BuzzpiratCOMPortItemClick;
      end;

    if cur = '' then
      MenuBuzzpiratCOMPort.Caption := STR_DM_COMPORT_NONE
    else
      MenuBuzzpiratCOMPort.Caption := STR_DM_COMPORT_PREFIX + cur;
  finally
    ports.Free;
  end;
end;

procedure TMainForm.BuzzpiratCOMPortItemClick(Sender: TObject);
var
  p: string;
begin
  p := Trim(TMenuItem(Sender).Hint);
  if p = '' then Exit;
  if SameText(p, Trim(Buzzpirat_COMPort)) then Exit;

  //Whatever session is open belongs to the port being left behind.
  if BuzzpiratDev <> nil then BuzzpiratDev.Disconnect;

  Buzzpirat_COMPort := p;
  LogPrint('Buzzpirat: COM port set to ' + p);
  RefreshCOMPortMenu;
end;

procedure TMainForm.ComPortTimerTimer(Sender: TObject);
begin
  //Cheap: registry reads on Windows, and a menu is only rebuilt when what it
  //shows would change.
  RefreshCOMPortMenu;
  RefreshBP5PortMenu;
end;

procedure TMainForm.MenuBuzzpiratDisconnectClick(Sender: TObject);
begin
  if BuzzpiratDev = nil then Exit;
  case BuzzpiratDev.Disconnect of
    bpdReset:
      LogPrint('Buzzpirat: disconnected, device reset to its user terminal');
    bpdKeptBinmode:
      LogPrint('Buzzpirat: disconnected. A Bus Pirate v5 or newer stays in its ' +
               'legacy binary mode until it restarts');
    bpdNoSession:
      LogPrint('Buzzpirat: not connected');
  end;
end;

//Bus Pirate v5+
//By Dreg
//https://github.com/therealdreg/asprogrammer-dregmod
//The BusPirateV5+ menu, for the BPIO2 back end in buspirate5hw.pas.

procedure TMainForm.RefreshBP5PortMenu;
var
  devs: TBP5DeviceArray;
  ports: TStringList;
  i, wanted: integer;
  item: TMenuItem;
  sig, cur, note: string;
  isData, isTerm: boolean;
begin
  if MenuBP5COMPort = nil then Exit;

  ports := TStringList.Create;
  try
    //Every serial port the system has right now, as in the v3.x menu.
    //BP5EnumerateDevices only labels them, so a machine where that lookup finds
    //nothing still gets a complete list.
    BP5GetSerialPorts(ports);
    devs := BP5EnumerateDevices;

    cur := Trim(BusPirate5_COMPort);

    //The captions show the note, so another Bus Pirate on the same port
    //numbers has to change the signature too.  By Dreg
    sig := cur + '|';
    for i := 0 to ports.Count - 1 do
    begin
      note := BP5DescribePort(devs, ports[i], isData, isTerm);
      sig := sig + ports[i] + ':' + IntToStr(Ord(isData)) + IntToStr(Ord(isTerm)) +
             ':' + note + ',';
    end;

    if sig = FBP5PortMenuSig then Exit;
    FBP5PortMenuSig := sig;

    wanted := ports.Count;
    if wanted = 0 then wanted := 1;

    //As in RefreshCOMPortMenu: surplus items are hidden, never freed.  By Dreg
    while MenuBP5COMPort.Count < wanted do
    begin
      item := TMenuItem.Create(Self);
      item.RadioItem := true;
      item.AutoCheck := false;
      MenuBP5COMPort.Add(item);
    end;

    for i := 0 to MenuBP5COMPort.Count - 1 do
      MenuBP5COMPort.Items[i].Visible := i < wanted;

    if ports.Count = 0 then
    begin
      item := MenuBP5COMPort.Items[0];
      item.Caption := STR_DM_NO_SERIAL_PORTS;
      item.Hint := '';
      item.Checked := false;
      item.Enabled := false;
      item.OnClick := nil;
    end
    else
      for i := 0 to ports.Count - 1 do
      begin
        item := MenuBP5COMPort.Items[i];
        note := BP5DescribePort(devs, ports[i], isData, isTerm);

        item.Caption := ports[i];
        if note <> '' then item.Caption := item.Caption + '   (' + note + ')';
        //The terminal interface gives no BPIO2 answer, so a handshake there
        //only times out.
        if isTerm then item.Caption := item.Caption + STR_DM_NOT_THIS_ONE;

        item.Hint := ports[i];
        item.Enabled := true;
        item.Checked := SameText(ports[i], cur);
        item.OnClick := @BP5COMPortItemClick;
      end;

    if cur = '' then
      MenuBP5COMPort.Caption := STR_DM_COMPORT_NONE
    else
      MenuBP5COMPort.Caption := STR_DM_COMPORT_PREFIX + cur;
  finally
    ports.Free;
  end;
end;

procedure TMainForm.BP5COMPortItemClick(Sender: TObject);
var
  p: string;
begin
  p := Trim(TMenuItem(Sender).Hint);
  if p = '' then Exit;
  if SameText(p, Trim(BusPirate5_COMPort)) then Exit;

  if BusPirate5Dev <> nil then BusPirate5Dev.Disconnect;
  BusPirate5_COMPort := p;
  LogPrint('BusPirateV5+: COM port set to ' + p);
  RefreshBP5PortMenu;
end;

procedure TMainForm.MenuBP5DisconnectClick(Sender: TObject);
begin
  if BusPirate5Dev = nil then Exit;
  //A failed park has already logged why the target may still be powered.
  case BusPirate5Dev.Disconnect of
    bp5pkParked:
      LogPrint('BusPirateV5+: disconnected, device left in HiZ with the supply off');
    bp5pkFailed:
      LogPrint('BusPirateV5+: disconnected');
    bp5pkNoSession:
      if BusPirate5Dev.SupplyMayBeOn then
        LogPrint('BusPirateV5+: not connected. The last session ended with the target ' +
                 'supply on, so the target may still be powered: unplug the Bus Pirate to be sure')
      else
        LogPrint('BusPirateV5+: not connected');
  end;
end;

//Shows where each wire goes on the Bus Pirate's own screen, for the bus picked
//in the window, with the supply and the pull-ups off.  By Dreg
procedure TMainForm.MenuBP5LabelsClick(Sender: TObject);
var
  err, bus: string;
  ok: boolean;
begin
  if BusPirate5Dev = nil then Exit;
  if RadioMw.Checked then
  begin
    LogPrint('BusPirateV5+: Show pin labels works for SPI and I2C only: pick one of them in the window');
    Exit;
  end;
  if RadioI2C.Checked then bus := 'I2C' else bus := 'SPI';

  Screen.Cursor := crHourGlass;
  try
    ok := BusPirate5Dev.ShowPinLabels(err);
  finally
    Screen.Cursor := crDefault;
  end;

  if ok then
    LogPrint('BusPirateV5+: the screen of the Bus Pirate shows where each ' + bus + ' wire goes. ' +
             'The supply and the pull-ups are off; the next operation sets them as the menu says')
  else
    LogPrint('BusPirateV5+: could not show the ' + bus + ' pin labels: ' + err);
end;

procedure TMainForm.MenuBP5InfoClick(Sender: TObject);
var
  report: string;
begin
  if BusPirate5Dev = nil then Exit;

  Screen.Cursor := crHourGlass;
  try
    report := BusPirate5Dev.DeviceReport;
  finally
    Screen.Cursor := crDefault;
  end;

  LogPrint(report);
  ShowMonospaceReport('Bus Pirate v5+', report);
end;

procedure TMainForm.MenuBP5HelpClick(Sender: TObject);
begin
  //By Dreg
  ExecuteProcess('cmd.exe', '/c start https://docs.buspirate.com/docs/software/asprogrammer-dregmod/', []);
end;

procedure TMainForm.MenuBP5I2CScanClick(Sender: TObject);
var
  found: TBytes;
  err: string;
  ok: boolean;
  i: integer;
  lines: TStringList;
begin
  if BusPirate5Dev = nil then Exit;

  Screen.Cursor := crHourGlass;
  try
    ok := BusPirate5Dev.ScanI2CBus(found, err);
  finally
    Screen.Cursor := crDefault;
  end;

  if not ok then
  begin
    LogPrint('I2C scan failed: ' + err);
    MessageDlg(STR_DM_I2C_SCAN_TITLE, STR_DM_I2C_SCAN_NO_RUN + LineEnding + LineEnding +
               err, mtError, [mbOK], 0);
    Exit;
  end;

  lines := TStringList.Create;
  try
    for i := 0 to High(found) do
      lines.Add(BusPirate5Dev.I2CDeviceLine(found[i]));
    ShowI2CScanResult(found, Trim(BusPirate5_COMPort),
                      BusPirate5Dev.I2CBusDescription, lines, I2C_EMPTY_HINTS_V5);
  finally
    lines.Free;
  end;
end;

procedure TMainForm.MenuBuzzpiratI2CScanClick(Sender: TObject);
var
  found: TBytes;
  err: string;
  ok: boolean;
  i: integer;
  lines: TStringList;
begin
  if BuzzpiratDev = nil then Exit;

  Screen.Cursor := crHourGlass;
  try
    ok := BuzzpiratDev.ScanI2CBus(found, err);
  finally
    Screen.Cursor := crDefault;
  end;

  if not ok then
  begin
    LogPrint('I2C scan failed: ' + err);
    MessageDlg(STR_DM_I2C_SCAN_TITLE, STR_DM_I2C_SCAN_NO_RUN + LineEnding + LineEnding +
               err, mtError, [mbOK], 0);
    Exit;
  end;

  lines := TStringList.Create;
  try
    for i := 0 to High(found) do
      lines.Add(BuzzpiratDev.I2CDeviceLine(found[i]));
    ShowI2CScanResult(found, Trim(Buzzpirat_COMPort),
                      BuzzpiratDev.I2CBusDescription, lines, I2C_EMPTY_HINTS_V3);
  finally
    lines.Free;
  end;
end;

procedure TMainForm.MenuHexEditorRandomClick(Sender: TObject);
const
  CHUNK = 65536;
var
  size, done, take, i: integer;
  bound: int64;
  buf: array[0..CHUNK - 1] of byte;
begin
  size := MPHexEditorEx.DataSize;
  //Nothing loaded yet: fill what a Write would accept, the chip size minus the
  //start address (the bound ButtonWriteClick checks), so the result can go
  //straight to the Write button.
  if size <= 0 then
  begin
    if StartAddressFromUI < 0 then
    begin
      ShowMessage(STR_CHECK_SETTINGS);
      Exit;
    end;
    bound := StrToInt64Def(ComboChipSize.Text, 0) - StartAddressFromUI;
    if (bound > 0) and (bound <= High(integer)) then size := integer(bound) else size := 0;
  end;
  if size <= 0 then
  begin
    ShowMessage(STR_DM_FILL_NO_SIZE);
    Exit;
  end;

  if MessageDlg(STR_DM_FILL_TITLE,
       Format(STR_DM_FILL_ASK, [size]) + LineEnding + LineEnding +
       Format(STR_DM_FILL_UNTOUCHED, [ButtonWrite.Hint]),
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  Screen.Cursor := crHourGlass;
  try
    RomF.Clear;
    RomF.Size := size;
    RomF.Position := 0;
    done := 0;
    while done < size do
    begin
      take := size - done;
      if take > CHUNK then take := CHUNK;
      for i := 0 to take - 1 do buf[i] := byte(Random(256));
      RomF.WriteBuffer(buf[0], take);
      Inc(done, take);
    end;
    RomF.Position := 0;
    MPHexEditorEx.LoadFromStream(RomF);
    RomF.Position := 0;
  finally
    Screen.Cursor := crDefault;
  end;

  LogPrint(Format('Hexeditor filled with %d random bytes - write it, read it back and verify.', [size]));
end;

procedure TMainForm.MenuCopyToClipClick(Sender: TObject);
begin
    MainForm.MPHexEditorEx.CBCopy;
end;

procedure TMainForm.MenuFindChipClick(Sender: TObject);
begin
  ChipSearchForm.EditSearch.Text:= '';
  ChipSearchForm.ListBoxChips.Items.Clear;
  ChipSearchForm.Show;
  ChipSearchForm.EditSearch.SetFocus;
end;

procedure TMainForm.MenuFindClick(Sender: TObject);
begin
  Search.SearchForm.Show;
end;

procedure TMainForm.MenuGotoOffsetClick(Sender: TObject);
var
  s : string;
  addr: integer;
begin
  s := InputBox(STR_GOTO_ADDR,'','');
  s := Trim(s);
  if IsNumber('$'+s)  then
  begin
    addr := StrToInt('$' + s);
    MainForm.MPHexEditorEx.SelStart := addr;
    MainForm.MPHexEditorEx.SelEnd := addr;
  end;
end;

procedure TMainForm.MenuHWCH341AClick(Sender: TObject);
begin
  SelectHW(CHW_CH341);
end;

procedure TMainForm.MenuHWCH347Click(Sender: TObject);
begin
  SelectHW(CHW_CH347);
end;

procedure TMainForm.MenuHWFT232HClick(Sender: TObject);
begin
  SelectHW(CHW_FT232H);
end;

procedure TMainForm.MenuHWUSBASPClick(Sender: TObject);
begin
  SelectHW(CHW_USBASP);
end;

procedure TMainForm.MenuHWAVRISPClick(Sender: TObject);
begin
  SelectHW(CHW_AVRISP);
end;

procedure TMainForm.MenuHWARDUINOClick(Sender: TObject);
begin
  SelectHW(CHW_ARDUINO);
end;

procedure TMainForm.MenuHWBUZZPIRATClick(Sender: TObject);
begin
  SelectHW(CHW_BUZZPIRAT);
end;

procedure TMainForm.MenuHWBUSPIRATE5Click(Sender: TObject);
begin
  SelectHW(CHW_BUSPIRATE5);
end;

procedure TMainForm.MenuItemBenchmarkClick(Sender: TObject);
var
  buffer: array[0..2047] of byte;
  i, cycles: integer;
  t: TDateTime;
  timeval: integer;
  ms, sec, d: word;
begin
  ButtonCancel.Tag := 0;
  if not OpenDevice() then exit;
  EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);
  LockControl();
try
  if (AsProgrammer.Current_HW = CHW_CH341) or (AsProgrammer.Current_HW = CHW_AVRISP) or (AsProgrammer.Current_HW = CHW_CH347)
    or (AsProgrammer.Current_HW = CHW_FT232H) then
    cycles := 256
  else
    cycles := 32;

  LogPrint('Benchmark read '+ IntToStr(SizeOf(buffer))+' bytes * '+ IntToStr(cycles) +' cycles');
  Application.ProcessMessages();
  TimeCounter := Time();

  for i:=1 to cycles do
  begin
    UsbAsp25_Read(0, 0, buffer, sizeof(buffer));
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  t :=  Time() - TimeCounter;
  DecodeDateTime(t, d, d, d, d, d, sec, ms);

  timeval := (sec * 1000) + ms;
  if timeval = 0 then timeval := 1;

  LogPrint(STR_TIME + TimeToStr(t)+' '+
    IntToStr( Trunc(((cycles*sizeof(buffer)) / timeval) * 1000)) +' bytes/s');

  LogPrint('Benchmark write '+ IntToStr(SizeOf(buffer))+' bytes * '+ IntToStr(cycles) +' cycles');
  Application.ProcessMessages();
  TimeCounter := Time();

  for i:=1 to cycles do
  begin
    UsbAsp25_Write(0, 0, buffer, sizeof(buffer));
    Application.ProcessMessages;

    if UserCancel then Break;
  end;

  t :=  Time() - TimeCounter;
  DecodeDateTime(t, d, d, d, d, d, sec, ms);

  timeval := (sec * 1000) + ms;
  if timeval = 0 then timeval := 1;

  LogPrint(STR_TIME + TimeToStr(t)+' '+
    IntToStr( Trunc(((cycles*sizeof(buffer)) / timeval) * 1000)) +' bytes/s');
finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;
end;

procedure TMainForm.MenuItemEditSregClick(Sender: TObject);
begin
  if MainForm.ComboSPICMD.ItemIndex = SPI_CMD_25 then
    sregedit.sregeditForm.Show;
end;

procedure TMainForm.MenuItemLockFlashClick(Sender: TObject);
var
  sreg: byte;
begin
  try
  ButtonCancel.Tag := 0;
  if not OpenDevice() then exit;
  sreg:= 0;
  LockControl();
  EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);

  if ComboSPICMD.ItemIndex = SPI_CMD_25 then
  begin
    UsbAsp25_ReadSR(sreg); //Читаем регистр
    LogPrint(STR_OLD_SREG+IntToBin(sreg, 8));

    sreg := %10011100; //
    UsbAsp25_WREN(); //Включаем разрешение записи
    UsbAsp25_WriteSR(sreg); //Устанавливаем регистр

    //Пока отлипнет ромка
    if not WaitChipReady then Exit;

    LogPrint(STR_NEW_SREG+IntToBin(sreg, 8));
  end;

  if ComboSPICMD.ItemIndex = SPI_CMD_95 then
  begin
    UsbAsp95_ReadSR(sreg); //Читаем регистр
    LogPrint(STR_OLD_SREG+IntToBin(sreg, 8));

    sreg := %10011100; //
    UsbAsp95_WREN(); //Включаем разрешение записи
    UsbAsp95_WriteSR(sreg); //Устанавливаем регистр

    //Пока отлипнет ромка
    if not WaitChipReady then Exit;

    LogPrint(STR_NEW_SREG+IntToBin(sreg, 8));
  end;


finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;

end;

procedure TMainForm.MenuItemReadSregClick(Sender: TObject);
var
  sreg, sreg2, sreg3: byte;
begin
  try
  ButtonCancel.Tag := 0;
  if not OpenDevice() then exit;
  sreg:= 0;
  LockControl();
  EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);

  if ComboSPICMD.ItemIndex = SPI_CMD_25 then
  begin
    //Every read is checked: the ReadSR functions return the byte count, and a
    //failed read leaves a value the chip never sent (zero here, the opcode
    //in the 95 and 45 functions).  By Dreg
    sreg2 := 0;
    sreg3 := 0;
    if (UsbAsp25_ReadSR(sreg) < 1) or (UsbAsp25_ReadSR(sreg2, $35) < 1) or
       (UsbAsp25_ReadSR(sreg3, $15) < 1) then
      LogPrint(STR_DM_SREG_NO_ANSWER)
    else
      LogPrint('Sreg: '+IntToBin(sreg, 8)+'(0x'+(IntToHex(sreg, 2)+'), ')
                                           +IntToBin(sreg2, 8)+'(0x'+(IntToHex(sreg2, 2)+'), ')
                                           +IntToBin(sreg3, 8)+'(0x'+(IntToHex(sreg3, 2)+')'));
  end;

  if ComboSPICMD.ItemIndex = SPI_CMD_95 then
  begin
    if UsbAsp95_ReadSR(sreg) < 1 then //Читаем регистр
      LogPrint(STR_DM_SREG_NO_ANSWER)
    else
      LogPrint('Sreg: '+IntToBin(sreg, 8));
  end;

  if ComboSPICMD.ItemIndex = SPI_CMD_45 then
  begin
    if UsbAsp45_ReadSR(sreg) < 1 then //Читаем регистр
      LogPrint(STR_DM_SREG_NO_ANSWER)
    else
      LogPrint('Sreg: '+IntToBin(sreg, 8));
  end;

finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;

end;

procedure TMainForm.RadioI2CChange(Sender: TObject);
begin
  Label1.Visible              := True;
  Label4.Visible              := True;
  ComboAddrType.Visible       := True;
  ComboPageSize.Visible       := True;
  Label5.Visible              := False;
  LabelSPICMD.Visible         := False;
  ButtonReadID.Enabled        := False;
  ButtonBlock.Enabled         := False;
  ButtonErase.Enabled         := True;
  ComboMWBitLen.Visible       := False;
  ComboSPICMD.Visible         := False;
  Panel_I2C_DevAddr.Visible   := True;

  ComboMWBitLen.Text:= 'MW addr len';
  ComboAddrType.Text:= '';
  ComboPageSize.Text:= 'Page size';
  ComboChipSize.Text:= 'Chip size';
end;

procedure TMainForm.RadioMwChange(Sender: TObject);
begin
  Label1.Visible              := False;
  ComboPageSize.Visible       := False;
  ComboAddrType.Visible       := False;
  ComboSPICMD.Visible         := False;
  ButtonReadID.Enabled        := False;
  ButtonBlock.Enabled         := False;
  Label4.Visible              := False;
  LabelSPICMD.Visible         := False;
  Panel_I2C_DevAddr.Visible   := False;
  Label5.Visible              := True;
  ButtonErase.Enabled         := True;
  ComboMWBitLen.Visible       := True;


  ComboMWBitLen.Text:= 'MW addr len';
  ComboAddrType.Text:= '';
  ComboPageSize.Text:= 'Page size';
  ComboChipSize.Text:= 'Chip size';
end;

procedure TMainForm.RadioSPIChange(Sender: TObject);
begin
  Label1.Visible              := True;
  LabelSPICMD.Visible         := True;
  ComboPageSize.Visible       := True;
  ComboSPICMD.Visible         := True;

  ButtonErase.Enabled         := True;
  ButtonReadID.Enabled        := True;

  ButtonBlock.Enabled := ComboSPICMD.ItemIndex <> SPI_CMD_KB;
  UpdateSkipFFCaption;

  ComboMWBitLen.Visible       := False;
  Label4.Visible              := False;
  Label5.Visible              := False;
  ComboAddrType.Visible       := False;

  Panel_I2C_DevAddr.Visible  := False;

  ComboMWBitLen.Text:= 'MW addr len';
  ComboAddrType.Text:= '';
  ComboPageSize.Text:= 'Page size';
  ComboChipSize.Text:= 'Chip size';
end;

procedure TMainForm.ButtonWriteClick(Sender: TObject);
var
  PageSize: word;
  WriteType: byte;
  I2C_DevAddr: byte;
  I2C_ChunkSize: Word = 65535;
  WasProtected: boolean = false;
begin
try
  ButtonCancel.Tag := 0;
  //Ask before opening the device, as Erase does: on a Bus Pirate with Power ON
  //ticked, opening switches the target supply on.  By Dreg
  if Sender <> ComboItem1 then
    if MessageDlg('AsProgrammer', STR_START_WRITE, mtConfirmation, [mbYes, mbNo], 0)
      <> mrYes then Exit;
  if not OpenDevice() then exit;
  LockControl();

  if RunScriptFromFile(CurrentICParam.Script, 'write') then Exit;

  LogPrint(TimeToStr(Time()));

  if (not IsNumber(ComboChipSize.Text)) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    Exit;
  end;

  if StartAddressFromUI < 0 then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    Exit;
  end;
  if MPHexEditorEx.DataSize > StrToInt64(ComboChipSize.Text) - StartAddressFromUI then
  begin
    LogPrint(STR_WRONG_FILE_SIZE);
    Exit;
  end;

  //SPI
  if RadioSPI.Checked then
  begin
    EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);
    //Kept for the warning at the end: a protected chip takes an erase and a
    //program without any complaint and keeps what it had, so the run would end
    //on "Done" having written nothing. Measured on an SST25VF080B, which powers
    //up with every block protected.  By Dreg
    if ComboSPICMD.ItemIndex <> SPI_CMD_KB then
      WasProtected := IsLockBitsEnabled;
    if (not IsNumber(ComboPageSize.Text)) and (UpperCase(ComboPageSize.Text)<>'SSTB') and (UpperCase(ComboPageSize.Text)<>'SSTW') then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;
    TimeCounter := Time();

    RomF.Position := 0;
    MPHexEditorEx.SaveToStream(RomF);
    RomF.Position := 0;

    if UpperCase(ComboPageSize.Text)='SSTB' then
    begin
      PageSize := 1;
      WriteType := WT_SSTB;
    end;

    if UpperCase(ComboPageSize.Text)='SSTW' then
    begin
      PageSize := 2;
      WriteType := WT_SSTW;
    end;

    if IsNumber(ComboPageSize.Text) then
    begin
      PageSize := PageSizeFromUI;
      WriteType := WT_PAGE;
    end;

    if ComboSPICMD.ItemIndex = SPI_CMD_25 then
      WriteFlash25(RomF, Hex2Dec('$'+StartAddressEdit.Text), MPHexEditorEx.DataSize, PageSize, WriteType);
    if ComboSPICMD.ItemIndex = SPI_CMD_95 then
      WriteFlash95(RomF, Hex2Dec('$'+StartAddressEdit.Text), MPHexEditorEx.DataSize, PageSize, StrToInt(ComboChipSize.Text));
    if ComboSPICMD.ItemIndex = SPI_CMD_45 then
      WriteFlash45(RomF, 0, MPHexEditorEx.DataSize, PageSize, WriteType);
    if ComboSPICMD.ItemIndex = SPI_CMD_KB then
      WriteFlashKB(RomF, 0, MPHexEditorEx.DataSize, PageSize);

    if (MenuAutoCheck.Checked) and (WriteType <> WT_PAGE) then
    begin
      LogPrint(STR_TIME + TimeToStr(Time() - TimeCounter));
      TimeCounter := Time();
      RomF.Position :=0;
      MPHexEditorEx.SaveToStream(RomF);
      RomF.Position :=0;
      if ComboSPICMD.ItemIndex <> SPI_CMD_KB then
        VerifyFlash25(RomF, Hex2Dec('$'+StartAddressEdit.Text), MPHexEditorEx.DataSize)
      else
        VerifyFlashKB(RomF, 0, MPHexEditorEx.DataSize);
    end;

  end;
  //I2C
  if RadioI2C.Checked then
  begin
    if ( (ComboAddrType.ItemIndex < 0) or (not IsNumber(ComboPageSize.Text)) ) then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    EnterProgModeI2C();

    //Адрес микросхемы по чекбоксам
    I2C_DevAddr := SetI2CDevAddr();

    if CheckBox_I2C_ByteRead.Checked then I2C_ChunkSize := 1;

    if UsbAspI2C_BUSY(I2C_DevAddr) then
    begin
      LogPrint(STR_I2C_NO_ANSWER);
      exit;
    end;
    TimeCounter := Time();

    RomF.Position := 0;
    MPHexEditorEx.SaveToStream(RomF);
    RomF.Position := 0;

    //No verify after a cancel or a chip that stayed busy.  By Dreg
    if WriteFlashI2C(RomF, Hex2Dec('$'+StartAddressEdit.Text), MPHexEditorEx.DataSize, PageSizeFromUI, I2C_DevAddr) and
       MenuAutoCheck.Checked then
    begin
      if UsbAspI2C_BUSY(I2C_DevAddr) then
      begin
        LogPrint(STR_I2C_NO_ANSWER);
        exit;
      end;
      LogPrint(STR_TIME + TimeToStr(Time() - TimeCounter));

      TimeCounter := Time();

      RomF.Position :=0;
      MPHexEditorEx.SaveToStream(RomF);
      RomF.Position :=0;
      VerifyFlashI2C(RomF, Hex2Dec('$'+StartAddressEdit.Text), RomF.Size, I2C_ChunkSize, I2C_DevAddr);
    end;

  end;
  //Microwire
  if RadioMW.Checked then
  begin
    if (not IsNumber(ComboMWBitLen.Text)) then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    if not AsProgrammer.Programmer.MWInit(SetSPISpeed(0)) then
    begin
      //Several programmers fail it without a word of their own, but the Bus
      //Pirates log why.  By Dreg
      if not AsProgrammer.Programmer.ErrorWasLogged then
        LogPrint(STR_DM_MW_INIT_FAILED);
      Exit;
    end;
    TimeCounter := Time();

    RomF.Position := 0;
    MPHexEditorEx.SaveToStream(RomF);
    RomF.Position := 0;

    WriteFlashMW(RomF, StrToInt(ComboMWBitLen.Text), 0, MPHexEditorEx.DataSize);

    if MenuAutoCheck.Checked then
    begin
      TimeCounter := Time();
      RomF.Position :=0;
      MPHexEditorEx.SaveToStream(RomF);
      RomF.Position :=0;
      VerifyFlashMW(RomF, StrToInt(ComboMWBitLen.Text), 0, StrToInt(ComboChipSize.Text));
    end;

  end;

  LogPrint(STR_TIME + TimeToStr(Time() - TimeCounter));

  //Last thing the reader sees, not buried among the settings at the top.
  if WasProtected then LogPrint(STR_DM_MAYBE_PROTECTED);

finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;
end;

procedure TMainForm.ButtonVerifyClick(Sender: TObject);
begin
  VerifyFlash(false);
end;

procedure TMainForm.VerifyFlash(BlankCheck: boolean = false);
var
  I2C_DevAddr: byte;
  I2C_ChunkSize: Word = 65535;
  i: Longword;
  BlankByte: byte;
  blankSize: int64;
begin
try
  ButtonCancel.Tag := 0;
  if not OpenDevice() then exit;
  LockControl();

  if RunScriptFromFile(CurrentICParam.Script, 'verify') then Exit;

  LogPrint(TimeToStr(Time()));

  if not IsNumber(ComboChipSize.Text) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    Exit;
  end;

  if StartAddressFromUI < 0 then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    Exit;
  end;
  if (MPHexEditorEx.DataSize > StrToInt64(ComboChipSize.Text) - StartAddressFromUI) and (not BlankCheck) then
  begin
    LogPrint(STR_WRONG_FILE_SIZE);
    Exit;
  end;

  //SPI
  if RadioSPI.Checked then
  begin
    EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);
    TimeCounter := Time();

    RomF.Clear;
    if BlankCheck then
    begin
      if ComboSPICMD.ItemIndex = SPI_CMD_KB then
        BlankByte := $00
      else
        BlankByte := $FF;

      //25 and 95 verify from the Start address, so the blank image runs from
      //there to the end of the chip: a whole chip's worth would run past the
      //end, and on a 16 MB part ask for four byte addressing.  By Dreg
      blankSize := StrToInt64(ComboChipSize.Text);
      if (ComboSPICMD.ItemIndex = SPI_CMD_25) or (ComboSPICMD.ItemIndex = SPI_CMD_95) then
        blankSize := blankSize - StartAddressFromUI;
      if blankSize <= 0 then
      begin
        LogPrint(STR_CHECK_SETTINGS);
        Exit;
      end;
      while RomF.Size < blankSize do
        RomF.WriteByte(BlankByte);
    end
    else
      MPHexEditorEx.SaveToStream(RomF);
    RomF.Position :=0;

    if ComboSPICMD.ItemIndex = SPI_CMD_KB then
      VerifyFlashKB(RomF, 0, RomF.Size);

    if ComboSPICMD.ItemIndex = SPI_CMD_25 then
      VerifyFlash25(RomF, Hex2Dec('$'+StartAddressEdit.Text), RomF.Size);

    if ComboSPICMD.ItemIndex = SPI_CMD_95 then
      VerifyFlash95(RomF, Hex2Dec('$'+StartAddressEdit.Text), RomF.Size, StrToInt(ComboChipSize.Text));

    if ComboSPICMD.ItemIndex = SPI_CMD_45 then
     begin
      if (not IsNumber(ComboPageSize.Text)) then
      begin
        LogPrint(STR_CHECK_SETTINGS);
        Exit;
      end;
      VerifyFlash45(RomF, 0, PageSizeFromUI, RomF.Size);
    end;


  end;
  //I2C
  if RadioI2C.Checked then
  begin
    if ComboAddrType.ItemIndex < 0 then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    EnterProgModeI2C();

    //Адрес микросхемы по чекбоксам
    I2C_DevAddr := SetI2CDevAddr();

    if CheckBox_I2C_ByteRead.Checked then I2C_ChunkSize := 1;

    if UsbAspI2C_BUSY(I2C_DevAddr) then
    begin
      LogPrint(STR_I2C_NO_ANSWER);
      exit;
    end;
    TimeCounter := Time();

    RomF.Clear;
    if BlankCheck then
    begin
      //From the Start address to the end, as for SPI 25 and 95 above.  By Dreg
      blankSize := StrToInt64(ComboChipSize.Text) - StartAddressFromUI;
      if blankSize <= 0 then
      begin
        LogPrint(STR_CHECK_SETTINGS);
        Exit;
      end;
      while RomF.Size < blankSize do
        RomF.WriteByte($FF);
    end
    else
      MPHexEditorEx.SaveToStream(RomF);
    RomF.Position :=0;

    VerifyFlashI2C(RomF, Hex2Dec('$'+StartAddressEdit.Text), RomF.Size, I2C_ChunkSize, I2C_DevAddr);
  end;

  //Microwire
  if RadioMW.Checked then
  begin
    if (not IsNumber(ComboMWBitLen.Text)) then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    if not AsProgrammer.Programmer.MWInit(SetSPISpeed(0)) then
    begin
      //By Dreg
      if not AsProgrammer.Programmer.ErrorWasLogged then
        LogPrint(STR_DM_MW_INIT_FAILED);
      Exit;
    end;
    TimeCounter := Time();

    RomF.Clear;
    if BlankCheck then
    begin
      for i:=1 to StrToInt(ComboChipSize.Text) do
        RomF.WriteByte($FF);
    end
    else
      MPHexEditorEx.SaveToStream(RomF);
    RomF.Position :=0;

    VerifyFlashMW(RomF, StrToInt(ComboMWBitLen.Text), 0, RomF.Size);
  end;

  LogPrint(STR_TIME + TimeToStr(Time() - TimeCounter));

finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;
end;

procedure TMainForm.ButtonBlockClick(Sender: TObject);
var
  sreg: byte;
  i: integer;
  s: string;
  SLreg: array[0..31] of byte;
begin
try
  ButtonCancel.Tag := 0;
  if not OpenDevice() then exit;
  sreg := 0;
  LockControl();

  if RunScriptFromFile(CurrentICParam.Script, 'unlock') then Exit;

  EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);

  if ComboSPICMD.ItemIndex = SPI_CMD_25 then
  begin
    UsbAsp25_ReadSR(sreg); //Читаем регистр
    LogPrint(STR_OLD_SREG+IntToBin(sreg, 8)+'(0x'+(IntToHex(sreg, 2)+')'));

    sreg := 0;

    UsbAsp25_WREN(); //Включаем разрешение записи
    UsbAsp25_WriteSR(sreg); //Сбрасываем регистр

    //Пока отлипнет ромка
    if not WaitChipReady then Exit;

    UsbAsp25_ReadSR(sreg); //Читаем регистр
    LogPrint(STR_NEW_SREG+IntToBin(sreg, 8)+'(0x'+(IntToHex(sreg, 2)+')'));
  end;

  if ComboSPICMD.ItemIndex = SPI_CMD_95 then
  begin
    UsbAsp95_ReadSR(sreg); //Читаем регистр
    LogPrint(STR_OLD_SREG+IntToBin(sreg, 8));

    sreg := 0; //
    UsbAsp95_WREN(); //Включаем разрешение записи
    UsbAsp95_WriteSR(sreg); //Сбрасываем регистр

    //Пока отлипнет ромка
    if not WaitChipReady then Exit;

    UsbAsp95_ReadSR(sreg); //Читаем регистр
    LogPrint(STR_NEW_SREG+IntToBin(sreg, 8));
  end;

  if ComboSPICMD.ItemIndex = SPI_CMD_45 then
  begin
    UsbAsp45_DisableSP();
    UsbAsp45_ReadSR(sreg); //Читаем регистр
    LogPrint('Sreg: '+IntToBin(sreg, 8));

    UsbAsp45_ReadSectorLockdown(SLreg); //Читаем Lockdown регистр

    s := '';
    for i:=0 to 31 do
    begin
      s := s + IntToHex(SLreg[i], 2);
    end;
    LogPrint('Sector Lockdown register: 0x'+s);
    if UsbAsp45_isPagePowerOfTwo() then LogPrint(STR_45PAGE_POWEROF2)
      else LogPrint(STR_45PAGE_STD);

  end;


finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;

end;

procedure TMainForm.ButtonReadIDClick(Sender: TObject);
var
  XMLfile: TXMLDocument;
  ID: MEMORY_ID;
  IDstr9FH: string[6];
  IDstr90H: string[4];
  IDstrABH: string[6];
  IDstr15H: string[4];
begin
  try
    if not OpenDevice() then exit;
    LockControl();

    FillByte(ID.ID9FH, 3, $FF);
    FillByte(ID.ID90H, 2, $FF);
    FillByte(ID.IDABH, 1, $FF);
    FillByte(ID.ID15H, 2, $FF);

    EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);

    if ComboSPICMD.ItemIndex = SPI_CMD_KB then
    begin
      UsbAspMulti_EnableEDI();
      UsbAspMulti_EnableEDI();
      UsbAspMulti_ReadReg($FF00, ID.IDABH); //read EC hardware version
      LogPrint('KB9012 EC Hardware version: '+IntToHex(ID.IDABH, 2));
      UsbAspMulti_ReadReg($FF24, ID.IDABH); //read EDI version
      LogPrint('KB9012 EDI version: '+IntToHex(ID.IDABH, 2));
      ExitProgMode25;
      //As the path below does: the finally only unlocks.  By Dreg
      AsProgrammer.Programmer.DevClose;
      Exit;
    end;

    UsbAsp25_ReadID(ID);
    ExitProgMode25;

    AsProgrammer.Programmer.DevClose;

    IDstr9FH := Upcase(IntToHex(ID.ID9FH[0], 2)+IntToHex(ID.ID9FH[1], 2)+IntToHex(ID.ID9FH[2], 2));
    IDstr90H := Upcase(IntToHex(ID.ID90H[0], 2)+IntToHex(ID.ID90H[1], 2));
    IDstrABH := Upcase(IntToHex(ID.IDABH, 2));
    IDstr15H := Upcase(IntToHex(ID.ID15H[0], 2)+IntToHex(ID.ID15H[1], 2));

    if FileExists(ChipListFileName) then
    begin

      try
        ReadXMLFile(XMLfile, ChipListFileName);
      except
        on E: EXMLReadError do
        begin
          ShowMessage(E.Message);
        end;
      end;

      ChipSearchForm.ListBoxChips.Clear;
      ChipSearchForm.EditSearch.Text:= '';

      FindChip.FindChip(XMLfile, '', IDstr9FH);
      if ChipSearchForm.ListBoxChips.Items.Capacity = 0 then FindChip.FindChip(XMLfile, '', IDstr90H);
      if ChipSearchForm.ListBoxChips.Items.Capacity = 0 then FindChip.FindChip(XMLfile, '', IDstrABH);
      if ChipSearchForm.ListBoxChips.Items.Capacity = 0 then FindChip.FindChip(XMLfile, '', IDstr15H);

      XMLfile.Free;
    end;

      if ChipSearchForm.ListBoxChips.Items.Capacity > 0 then
      begin
        ChipSearchForm.Show;
        LogPrint('ID(9F): '+ IDstr9FH);
        LogPrint('ID(90): '+ IDstr90H);
        LogPrint('ID(AB): '+ IDstrABH);
        LogPrint('ID(15): '+ IDstr15H);
      end
      else
      begin
        LogPrint('ID(9F): '+ IDstr9FH +STR_ID_UNKNOWN);
        LogPrint('ID(90): '+ IDstr90H +STR_ID_UNKNOWN);
        LogPrint('ID(AB): '+ IDstrABH +STR_ID_UNKNOWN);
        LogPrint('ID(15): '+ IDstr15H +STR_ID_UNKNOWN);
      end;

  finally
    UnlockControl();
  end;

end;

procedure TMainForm.ButtonOpenHexClick(Sender: TObject);
begin
  if OpenDialog.Execute then
  begin
   MPHexEditorEx.LoadFromFile(OpenDialog.FileName);
   StatusBar.Panels.Items[2].Text := OpenDialog.FileName;
  end;
end;

procedure TMainForm.ButtonSaveHexClick(Sender: TObject);
begin
  if SaveDialog.Execute then
  begin
    MPHexEditorEx.SaveToFile(SaveDialog.FileName);
    StatusBar.Panels.Items[2].Text := SaveDialog.FileName;
  end;
end;

procedure TMainForm.ButtonCancelClick(Sender: TObject);
begin
  ButtonCancel.Tag:= 1;
  ScriptEngine.Stop:= true;
end;

procedure TMainForm.I2C_DevAddrChange(Sender: TObject);
begin
  if TToggleBox(Sender).State = cbUnchecked then
  TToggleBox(Sender).Caption:= '0';
  if TToggleBox(Sender).State = cbChecked then
  TToggleBox(Sender).Caption:= '1';
end;

procedure TMainForm.ScriptsMenuItemClick(Sender: TObject);
begin
  ScriptEditForm.Show;
end;

procedure TMainForm.DebugconsoleMenuItemClick(Sender: TObject);
var
  report: string;
begin
  if BuzzpiratDev = nil then Exit;

  Screen.Cursor := crHourGlass;
  try
    report := BuzzpiratDev.DeviceReport;
  finally
    Screen.Cursor := crDefault;
  end;

  LogPrint(report);
  ShowMonospaceReport('Buzzpirat / Bus Pirate', report);
end;

//The run time report windows have no form file, so their controls share these
//two handlers and find their partner controls through the parent chain.
procedure TMainForm.ReportCopyClick(Sender: TObject);
var
  dlg: TWinControl;
  i: integer;
begin
  dlg := TControl(Sender).Parent;
  if dlg = nil then Exit;
  dlg := dlg.Parent;
  if dlg = nil then Exit;

  for i := 0 to dlg.ControlCount - 1 do
    if dlg.Controls[i] is TMemo then
    begin
      TMemo(dlg.Controls[i]).SelectAll;
      TMemo(dlg.Controls[i]).CopyToClipboard;
      Exit;
    end;
end;

procedure TMainForm.ReportListDblClick(Sender: TObject);
var
  dlg: TWinControl;
begin
  if TListBox(Sender).ItemIndex < 0 then Exit;
  dlg := TControl(Sender).Parent;
  if dlg is TCustomForm then TCustomForm(dlg).ModalResult := mrOk;
end;

procedure ShowMonospaceReport(const ATitle, AText: string);
var
  dlg: TForm;
  memo: TMemo;
  bar: TPanel;
  btnCopy, btnClose: TButton;
begin
  dlg := TForm.CreateNew(nil);
  try
    dlg.Caption := ATitle;
    dlg.Position := poMainFormCenter;
    dlg.BorderStyle := bsSizeable;
    dlg.Width := 560;
    dlg.Height := 420;
    dlg.Constraints.MinWidth := 380;
    dlg.Constraints.MinHeight := 220;

    bar := TPanel.Create(dlg);
    bar.Parent := dlg;
    bar.Align := alBottom;
    bar.Height := 44;
    bar.BevelOuter := bvNone;

    //alRight stacks right to left in creation order: Close ends up outermost.
    btnClose := TButton.Create(dlg);
    btnClose.Parent := bar;
    btnClose.Caption := STR_DM_BTN_CLOSE;
    btnClose.ModalResult := mrOk;
    btnClose.Default := true;
    btnClose.Cancel := true;
    btnClose.Width := 90;
    btnClose.Align := alRight;
    btnClose.BorderSpacing.Around := 8;

    btnCopy := TButton.Create(dlg);
    btnCopy.Parent := bar;
    btnCopy.Caption := STR_DM_BTN_COPY;
    btnCopy.Width := 90;
    btnCopy.Align := alRight;
    btnCopy.BorderSpacing.Around := 8;
    btnCopy.OnClick := @MainForm.ReportCopyClick;

    memo := TMemo.Create(dlg);
    memo.Parent := dlg;
    memo.Align := alClient;
    memo.ReadOnly := true;
    memo.ScrollBars := ssAutoBoth;
    memo.WordWrap := false;
    memo.ParentFont := false;
    memo.Font.Name := 'Courier New';
    memo.Font.Size := 9;
    memo.Text := AText;

    dlg.ShowModal;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.ApplyI2CAddress(Addr: byte);
var
  wr: byte;
begin
  //SetI2CDevAddr() rebuilds the write address out of these toggles: bits 1..3
  //are A0..A2, bits 4..7 the device type nibble, bit 0 is the R/W flag.
  wr := (Addr shl 1) and $FF;
  CheckBox_I2C_A0.Checked    := (wr and $02) <> 0;
  CheckBox_I2C_A1.Checked    := (wr and $04) <> 0;
  CheckBox_I2C_A2.Checked    := (wr and $08) <> 0;
  CheckBox_I2C_DevA4.Checked := (wr and $10) <> 0;
  CheckBox_I2C_DevA5.Checked := (wr and $20) <> 0;
  CheckBox_I2C_DevA6.Checked := (wr and $40) <> 0;
  CheckBox_I2C_DevA7.Checked := (wr and $80) <> 0;

  LogPrint(Format('I2C device address set to 7-bit 0x%.2x (write 0x%.2x, read 0x%.2x)',
                  [Addr, wr, wr or 1]));
end;

procedure TMainForm.ShowI2CScanResult(const Found: TBytes; const APort,
  ABusDesc: string; ALines: TStrings; const AEmptyHints: string);
var
  dlg: TForm;
  memo: TMemo;
  list: TListBox;
  bar: TPanel;
  btnUse, btnCopy, btnClose: TButton;
  report: string;
  i: integer;
begin
  report := STR_DM_I2C_SCAN_ON + APort + LineEnding +
            ABusDesc + LineEnding + LineEnding +
            BPFormatI2CGrid(Found) + LineEnding;

  if Length(Found) = 0 then
    report := report +
      'Nothing answered.' + LineEnding + LineEnding +
      'Worth checking:' + LineEnding + AEmptyHints
  else
  begin
    report := report + Format(STR_DM_I2C_SCAN_COUNT, [Length(Found)]) + LineEnding;
    report := report + LineEnding +
      'Addresses 0x00-0x07 and 0x78-0x7f are reserved by the I2C' + LineEnding +
      'specification and are never probed. The descriptions below are' + LineEnding +
      'guesses: I2C addresses are not registered anywhere.';
  end;

  LogPrint(report);

  dlg := TForm.CreateNew(nil);
  try
    dlg.Caption := STR_DM_I2C_SCAN_TITLE;
    dlg.Position := poMainFormCenter;
    dlg.BorderStyle := bsSizeable;
    dlg.Width := 660;
    dlg.Height := 520;
    dlg.Constraints.MinWidth := 480;
    dlg.Constraints.MinHeight := 320;

    bar := TPanel.Create(dlg);
    bar.Parent := dlg;
    bar.Align := alBottom;
    bar.Height := 44;
    bar.BevelOuter := bvNone;

    btnClose := TButton.Create(dlg);
    btnClose.Parent := bar;
    btnClose.Caption := STR_DM_BTN_CLOSE;
    btnClose.ModalResult := mrCancel;
    btnClose.Cancel := true;
    btnClose.Width := 90;
    btnClose.Align := alRight;
    btnClose.BorderSpacing.Around := 8;

    btnCopy := TButton.Create(dlg);
    btnCopy.Parent := bar;
    btnCopy.Caption := STR_DM_BTN_COPY;
    btnCopy.Width := 90;
    btnCopy.Align := alRight;
    btnCopy.BorderSpacing.Around := 8;
    btnCopy.OnClick := @ReportCopyClick;

    list := nil;
    if Length(Found) > 0 then
    begin
      btnUse := TButton.Create(dlg);
      btnUse.Parent := bar;
      btnUse.Caption := STR_DM_I2C_USE_ADDRESS;
      btnUse.ModalResult := mrOk;
      btnUse.Default := true;
      btnUse.Width := 150;
      btnUse.Align := alLeft;
      btnUse.BorderSpacing.Around := 8;

      list := TListBox.Create(dlg);
      list.Parent := dlg;
      list.Align := alBottom;
      list.Height := 120;
      list.ParentFont := false;
      list.Font.Name := 'Courier New';
      list.Font.Size := 9;
      list.OnDblClick := @ReportListDblClick;
      for i := 0 to High(Found) do
        if i < ALines.Count then list.Items.Add(ALines[i]);
      list.ItemIndex := 0;
    end;

    memo := TMemo.Create(dlg);
    memo.Parent := dlg;
    memo.Align := alClient;
    memo.ReadOnly := true;
    memo.ScrollBars := ssAutoBoth;
    memo.WordWrap := false;
    memo.ParentFont := false;
    memo.Font.Name := 'Courier New';
    memo.Font.Size := 9;
    memo.Text := report;

    if (dlg.ShowModal = mrOk) and (list <> nil) and (list.ItemIndex >= 0) then
    begin
      ApplyI2CAddress(Found[list.ItemIndex]);
      if not RadioI2C.Checked then
        ShowMessage(STR_DM_I2C_ADDR_STORED);
    end;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.BzHelpMenuItemClick(Sender: TObject);
begin
     ExecuteProcess('cmd.exe', '/c start https://github.com/therealdreg/asprogrammer-dregmod', []);
end;

procedure TMainForm.CreditsMenuItemClick(Sender: TObject);
var
  credits: string;
begin
  credits := 'nofeletru https://github.com/nofeletru, Dreg @therealdreg https://github.com/therealdreg';
  LogPrint(credits);
  ShowMessage(credits);
end;

//Runs a chip script as an operation like any other: the interface is locked
//while it works, so no second operation starts on top of it, and the device
//is closed afterwards whatever happens.  By Dreg
procedure TMainForm.SpeedButton1Click(Sender: TObject);
begin
  if ComboBox_chip_scriptrun.Items.Capacity < 1 then Exit;
  if not OpenDevice() then Exit;
  try
    LockControl();
    RunScriptFromFile(CurrentICParam.Script, ComboBox_chip_scriptrun.Text);
  finally
    ExitProgMode25;
    AsProgrammer.Programmer.DevClose;
    UnlockControl();
  end;
end;

procedure TMainForm.StartAddressEditChange(Sender: TObject);
begin
  if StartAddressEdit.Text = '' then StartAddressEdit.Text := '0';
  //StartAddressFromUI rather than Hex2Dec, which raises on pasted text that is
  //not hex and is negative from 80000000 up.  By Dreg
  if StartAddressFromUI > 0 then
     StartAddressEdit.Color:= clYellow
  else
     StartAddressEdit.Color:= clDefault;
end;

procedure TMainForm.StartAddressEditKeyPress(Sender: TObject; var Key: char);
begin
  Key := UpCase(Key);
  if not(Key in['A'..'F', '0'..'9', Char(VK_BACK)]) then Key := Char('');
end;

procedure LoadChipList(XMLfile: TXMLDocument);
var
  Node: TDOMNode;
  j, i: integer;
begin
  if XMLfile <> nil then
  begin

    Node := XMLfile.DocumentElement.FirstChild;

    while Assigned(Node) do
    begin

     if (LowerCase(Node.NodeName) = 'options') or (LowerCase(Node.NodeName) = 'locale') then
     begin
       Node := Node.NextSibling;
       continue;
     end;

     MainForm.MenuChip.Add(NewItem(UTF16ToUTF8(Node.NodeName), 0, False, True, nil, 0, '')); //Раздел(SPI, I2C...)

     // Используем свойство ChildNodes
     with Node.ChildNodes do
     try
       for j := 0 to (Count - 1) do
       begin
         MainForm.MenuChip.Find(UTF16ToUTF8(Node.NodeName)).Add(NewItem(UTF16ToUTF8(Item[j].NodeName) ,0, False, True, nil, 0, '')); //Раздел Фирма

         for i := 0 to (Item[j].ChildNodes.Count - 1) do
           MainForm.MenuChip.Find(UTF16ToUTF8(Node.NodeName)).
             Find(UTF16ToUTF8(Item[j].NodeName)).
               Add(NewItem(UTF16ToUTF8(Item[j].ChildNodes.Item[i].NodeName), 0, False, True, @MainForm.ChipClick, 0, '' )); //Чип
       end;
     finally
       Free;
     end;
     Node := Node.NextSibling;
    end;
  end;

end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  //Without this the random fill gives the same bytes on every run, and a write
  //and read back test needs different ones each time.
  Randomize;

  //Lets spi25 cancel a long busy wait.
  UsbAsp25_OnCancel := @UserCancel;

  AsProgrammer := TAsProgrammer.Create;
  AsProgrammer.AddHW(TUsbAspHardware.Create);
  AsProgrammer.AddHW(TCH341Hardware.Create);
  AsProgrammer.AddHW(TAvrispHardware.Create);
  AsProgrammer.AddHW(TArduinoHardware.Create);
  BuzzpiratDev := TBuzzpiratHardware.Create;
  AsProgrammer.AddHW(BuzzpiratDev);
  BusPirate5Dev := TBusPirate5Hardware.Create;
  AsProgrammer.AddHW(BusPirate5Dev);
  AsProgrammer.AddHW(TFT232HHardware.Create);
  AsProgrammer.AddHW(TCH347Hardware.Create);

  //This fork is built around the Bus Pirate, so a new install starts on
  //BusPirateV5+, the Bus Pirate v5 and newer over BPIO2. A settings.xml that
  //names a programmer overrides it further down.  By Dreg
  SelectHW(CHW_BUSPIRATE5);

  LoadChipList(ChipListFile);
  RomF := TMemoryStream.Create;
  ScriptEngine := TPasCalc.Create;
  ScriptEngine.IncludeDir := ScriptsPath;  //By Dreg
  ScriptsFunc.SetScriptFunctions(ScriptEngine);

  MPHexEditorEx.NoSizeChange := true;
  MPHexEditorEx.InsertMode := false;
  LoadOptions(SettingsFile);
  LoadLangList();

  //Fill the COM port menus once now; the timer keeps them in step with
  //whatever gets plugged in or unplugged afterwards.
  RefreshCOMPortMenu;
  RefreshBP5PortMenu;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  //The timer walks the menu tree; stop it before any of that is freed.
  ComPortTimer.Enabled := false;

  AsProgrammer.Free;
  //Owned by the list AsProgrammer just freed.
  BuzzpiratDev := nil;
  BusPirate5Dev := nil;
  MainForm.MPHexEditorEx.Free;
  RomF.Free;
  //Saved here when FormCloseQuery did not: an end that never asked it, an
  //operation still running at the close, or a save that failed, tried again
  //with nobody left to tell.  By Dreg
  if not FSettingsSaved then SaveOptions(SettingsFile);
  ChipListFile.Free;
  SettingsFile.Free;
  ScriptEngine.Free;
end;

procedure TMainForm.ButtonReadClick(Sender: TObject);
var
  I2C_DevAddr: byte;
  I2C_ChunkSize: word = 65535;
  CRC32: Cardinal;
begin
try
  ButtonCancel.Tag := 0;
  if not OpenDevice() then exit;
  LockControl();

  if RunScriptFromFile(CurrentICParam.Script, 'read') then Exit;

  LogPrint(TimeToStr(Time()));

  if (not IsNumber(ComboChipSize.Text)) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    Exit;
  end;

  //The Start address box has to hold a hex number below the chip size, as for
  //Write. StartAddressFromUI gives -1 for text that is not hex, and RomF is
  //cleared only after this check, so a refused address leaves the editor as
  //it was.  By Dreg
  if (StartAddressFromUI < 0) or
     (StartAddressFromUI >= StrToInt64(ComboChipSize.Text)) then
  begin
    LogPrint(STR_CHECK_SETTINGS);
    Exit;
  end;
  RomF.Clear;

  //SPI
  if RadioSPI.Checked then
  begin
    EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);
    TimeCounter := Time();

    if  ComboSPICMD.ItemIndex = SPI_CMD_KB then
    begin
      ReadFlashKB(RomF, 0, StrToInt(ComboChipSize.Text));
    end;

    if  ComboSPICMD.ItemIndex = SPI_CMD_25 then
      ReadFlash25(RomF, cardinal(StartAddressFromUI), StrToInt(ComboChipSize.Text));
    if  ComboSPICMD.ItemIndex = SPI_CMD_45 then
    begin
      if (not IsNumber(ComboPageSize.Text)) then
      begin
        LogPrint(STR_CHECK_SETTINGS);
        Exit;
      end;
      ReadFlash45(RomF, 0, PageSizeFromUI, StrToInt(ComboChipSize.Text));
    end;

    if  ComboSPICMD.ItemIndex = SPI_CMD_95 then
      ReadFlash95(RomF, cardinal(StartAddressFromUI), StrToInt(ComboChipSize.Text));

    RomF.Position := 0;
    MPHexEditorEx.LoadFromStream(RomF);
    StatusBar.Panels.Items[2].Text := LabelChipName.Caption;
  end;
  //I2C
  if RadioI2C.Checked then
  begin
    if ComboAddrType.ItemIndex < 0 then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    EnterProgModeI2c();

    //Адрес микросхемы по чекбоксам
    I2C_DevAddr := SetI2CDevAddr();

    if CheckBox_I2C_ByteRead.Checked then I2C_ChunkSize := 1;

    if UsbAspI2C_BUSY(I2C_DevAddr) then
    begin
      LogPrint(STR_I2C_NO_ANSWER);
      exit;
    end;
    TimeCounter := Time();
    ReadFlashI2C(RomF, cardinal(StartAddressFromUI), StrToInt(ComboChipSize.Text), I2C_ChunkSize, I2C_DevAddr);

    RomF.Position := 0;
    MPHexEditorEx.LoadFromStream(RomF);
    StatusBar.Panels.Items[2].Text := LabelChipName.Caption;
  end;
  //Microwire
  if RadioMw.Checked then
  begin
    if (not IsNumber(ComboMWBitLen.Text)) then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    if not AsProgrammer.Programmer.MWInit(SetSPISpeed(0)) then
    begin
      //By Dreg
      if not AsProgrammer.Programmer.ErrorWasLogged then
        LogPrint(STR_DM_MW_INIT_FAILED);
      Exit;
    end;
    TimeCounter := Time();
    ReadFlashMW(RomF, StrToInt(ComboMWBitLen.Text), 0, StrToInt(ComboChipSize.Text));

    RomF.Position := 0;
    MPHexEditorEx.LoadFromStream(RomF);
    StatusBar.Panels.Items[2].Text := LabelChipName.Caption;
  end;

  LogPrint(STR_TIME + TimeToStr(Time() - TimeCounter));

  //A read stopped before its first byte, as when EN4B could not be sent, has
  //no image to sum.  By Dreg
  if RomF.Size > 0 then
  begin
    CRC32 := UpdateCRC32($FFFFFFFF, Romf.Memory, Romf.Size);
    LogPrint('CRC32 = 0x'+IntToHex(CRC32, 8));
  end;

finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;
end;

procedure TMainForm.ClearLogMenuItemClick(Sender: TObject);
begin
  Log.Lines.Clear;
end;

procedure TMainForm.ComboSPICMDChange(Sender: TObject);
begin
  RadioSPI.OnChange(Sender);
end;

procedure TMainForm.CopyLogMenuItemClick(Sender: TObject);
begin
  Log.CopyToClipboard;
end;

procedure TMainForm.AllowInsertItemClick(Sender: TObject);
begin
  MPHexEditorEx.NoSizeChange := not AllowInsertItem.Checked;
  MPHexEditorEx.InsertMode := AllowInsertItem.Checked;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: boolean);
var
  err: string;
begin
  ButtonCancel.Tag := 1;
  ScriptEditForm.FormCloseQuery(Sender, CanClose);
  //Park the Bus Pirate v5+ now, while a dialog can still say that it failed:
  //Destroy would do it later, with the log gone. An operation still running
  //keeps the device, and Destroy parks it once the operation ends.  By Dreg
  if CanClose and (BusPirate5Dev <> nil) and (not ControlLocked) then
  begin
    BusPirate5Dev.Disconnect;
    if BusPirate5Dev.SupplyMayBeOn then
      MessageDlg('BusPirateV5+', STR_DM_BP5_SUPPLY_LEFT_ON, mtWarning, [mbOK], 0);
  end;
  //The settings too, for the same reason: a dialog shown from Destroy does not
  //appear and the program hangs, and without one a folder the user cannot
  //write to loses them without a word. Not while an operation still runs: it
  //may hold a setting of its own (the combined command ticks Verify), and
  //Destroy saves them once it ends.  By Dreg
  if CanClose and (not ControlLocked) then
  begin
    err := SaveOptions(SettingsFile);
    FSettingsSaved := err = '';
    if err <> '' then
      MessageDlg('AsProgrammer', Format(STR_DM_SETTINGS_NOT_SAVED, [err]), mtWarning, [mbOK], 0);
  end;
end;

procedure TMainForm.ButtonEraseClick(Sender: TObject);
var
  I2C_DevAddr: byte;
  WasProtected: boolean = false;
  erased: boolean = false;
  partly: boolean = false;
begin
try
  ButtonCancel.Tag := 0;
  FEraseOK := false;
  //Ask before opening the device: opening configures the programmer, and a
  //Bus Pirate with Power ON ticked switches the target supply on. The finally
  //copes with a device never opened, as when OpenDevice fails.  By Dreg
  if Sender <> ComboItem1 then
    if MessageDlg('AsProgrammer', STR_START_ERASE, mtConfirmation, [mbYes, mbNo], 0)
      <> mrYes then Exit;
  if not OpenDevice() then exit;
  LockControl();

  //A chip's own erase script reports for itself: the combined command goes on
  //after it unless it stopped on an error or a cancel.  By Dreg
  if RunScriptFromFile(CurrentICParam.Script, 'erase') then
  begin
    FEraseOK := (ScriptEngine.ErrCode = 0) and (ButtonCancel.Tag = 0);
    Exit;
  end;

  LogPrint(TimeToStr(Time()));

  //SPI
  if RadioSPI.Checked then
  begin
    EnterProgMode25(SetSPISpeed(0), MainForm.MenuSendAB.Checked);
    if ComboSPICMD.ItemIndex <> SPI_CMD_KB then
      WasProtected := IsLockBitsEnabled;
    TimeCounter := Time();

    LogPrint(STR_ERASING_FLASH);

    if ComboSPICMD.ItemIndex = SPI_CMD_KB then
    begin

      if (not IsNumber(ComboChipSize.Text)) then
      begin
        LogPrint(STR_CHECK_SETTINGS);
        Exit;
      end;

      if (not IsNumber(ComboPageSize.Text)) then
      begin
        LogPrint(STR_CHECK_SETTINGS);
        Exit;
      end;

      if not EraseFlashKB(StrToInt(ComboChipSize.Text), PageSizeFromUI) then Exit;
      LogPrint(STR_DONE);
      erased := true;
    end;

    if ComboSPICMD.ItemIndex = SPI_CMD_25 then
    begin
      //A programmer that refuses writes still reads, so without this the busy
      //wait below would pass and log Done.  By Dreg
      if (UsbAsp25_WREN() < 1) or (UsbAsp25_ChipErase() < 1) then
      begin
        if not AsProgrammer.Programmer.ErrorWasLogged then
          LogPrint(STR_DM_ERASE_NOT_SENT);
        Exit;
      end;

      ProgressBar.Style:= pbstMarquee;
      ProgressBar.Max:= 1;
      ProgressBar.Position:= 1;

      LogPrint(STR_ERASE_NOTICE);

      if not WaitChipReady then Exit;

      ProgressBar.Style:= pbstNormal;
      ProgressBar.Position:= 0;
      LogPrint(STR_DONE);
      erased := true;
    end;

    if ComboSPICMD.ItemIndex = SPI_CMD_95 then
      begin
        if ( (not IsNumber(ComboChipSize.Text)) or (not IsNumber(ComboPageSize.Text))) then
        begin
          LogPrint(STR_CHECK_SETTINGS);
          Exit;
        end;

      erased := EraseEEPROM25(0, StrToInt(ComboChipSize.Text), PageSizeFromUI, StrToInt(ComboChipSize.Text));
    end;

    if ComboSPICMD.ItemIndex = SPI_CMD_45 then
    begin
      //As for the 25 series.  By Dreg
      if UsbAsp45_ChipErase() < 1 then
      begin
        if not AsProgrammer.Programmer.ErrorWasLogged then
          LogPrint(STR_DM_ERASE_NOT_SENT);
        Exit;
      end;

      while UsbAsp45_Busy() do
      begin
        Application.ProcessMessages;
        if UserCancel then Exit;
      end;
      LogPrint(STR_DONE);
      erased := true;
    end;

  end;

  //I2C
  if RadioI2C.Checked then
  begin
  if ( (ComboAddrType.ItemIndex < 0) or (not IsNumber(ComboPageSize.Text)) ) then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    EnterProgModeI2C();

    //Адрес микросхемы по чекбоксам
    I2C_DevAddr := SetI2CDevAddr();

    if UsbAspI2C_BUSY(I2C_DevAddr) then
    begin
      LogPrint(STR_I2C_NO_ANSWER);
      exit;
    end;

    TimeCounter := Time();

    erased := EraseFlashI2C(0, StrToInt(ComboChipSize.Text), PageSizeFromUI, I2C_DevAddr, partly);
  end;

  //Microwire
  if RadioMW.Checked then
  begin
    if (not IsNumber(ComboMWBitLen.Text)) then
    begin
      LogPrint(STR_CHECK_SETTINGS);
      Exit;
    end;

    if not AsProgrammer.Programmer.MWInit(SetSPISpeed(0)) then
    begin
      //By Dreg
      if not AsProgrammer.Programmer.ErrorWasLogged then
        LogPrint(STR_DM_MW_INIT_FAILED);
      Exit;
    end;
    TimeCounter := Time();
    LogPrint(STR_ERASING_FLASH);
    //As for the 25 series: the busy reads of the UsbAsp, Arduino and AVRISP
    //report a chip that is not busy when they fail, so Done needs both
    //commands sent.  By Dreg
    if (UsbAspMW_Ewen(StrToInt(ComboMWBitLen.Text)) < 1) or
       (UsbAspMW_ChipErase(StrToInt(ComboMWBitLen.Text)) < 1) then
    begin
      if not AsProgrammer.Programmer.ErrorWasLogged then
        LogPrint(STR_DM_ERASE_NOT_SENT);
      Exit;
    end;

     while UsbAspMW_Busy do
     begin
       Application.ProcessMessages;
       if UserCancel then Exit;
     end;
     LogPrint(STR_DONE);
     erased := true;

  end;

  //Each branch logs Done once its erase has ended well: the SPI 95 and I2C
  //routines log their own result, the other branches log it above.  By Dreg
  LogPrint(STR_TIME + TimeToStr(Time() - TimeCounter));
  //A cancel seen after the last page still stops the combined command.
  //By Dreg
  FEraseOK := (erased or partly) and (ButtonCancel.Tag = 0);

  //Last thing the reader sees, not buried among the settings at the top.
  if WasProtected then LogPrint(STR_DM_MAYBE_PROTECTED);

finally
  ExitProgMode25;
  AsProgrammer.Programmer.DevClose;
  UnlockControl();
end;
end;

procedure TMainForm.BlankCheckMenuItemClick(Sender: TObject);
begin
  VerifyFlash(true);
end;

function SaveOptions(XMLfile: TXMLDocument): string;
var
  Node, ParentNode: TDOMNode;
begin
  result := '';
  if XMLfile <> nil then
  begin
    //Удаляем старую запись
    Node := XMLfile.DocumentElement.FindNode('locale');
    if (Node <> nil) then XMLfile.DocumentElement.RemoveChild(Node);
    //Создаем новую
    Node:= XMLfile.DocumentElement;
    ParentNode := XMLfile.CreateElement('locale');
    TDOMElement(ParentNode).SetAttribute('lang', CurrentLang);
    Node.Appendchild(parentNode);

    //Удаляем старую запись
    Node := XMLfile.DocumentElement.FindNode('options');
    if (Node <> nil) then XMLfile.DocumentElement.RemoveChild(Node);

    Node:= XMLfile.DocumentElement;
    ParentNode := XMLfile.CreateElement('options');

    if MainForm.MenuAutoCheck.Checked then
      TDOMElement(ParentNode).SetAttribute('verify', '1') else
        TDOMElement(ParentNode).SetAttribute('verify', '0');

    if MainForm.MenuSkipFF.Checked then
      TDOMElement(ParentNode).SetAttribute('skipff', '1') else
        TDOMElement(ParentNode).SetAttribute('skipff', '0');

    if MainForm.MenuSendAB.Checked then
      TDOMElement(ParentNode).SetAttribute('sendab', '1') else
        TDOMElement(ParentNode).SetAttribute('sendab', '0');

    if MainForm.Menu3Mhz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '3Mhz');
    if MainForm.Menu1_5Mhz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '1_5Mhz');
    if MainForm.Menu750Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '750Khz');
    if MainForm.Menu375Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '375Khz');
    if MainForm.Menu187_5Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '187_5Khz');
    if MainForm.Menu93_75Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '93_75Khz');
    if MainForm.Menu32Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('spi_speed', '32Khz');

    if MainForm.MenuCH347SPIClock60MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '60Mhz');
    if MainForm.MenuCH347SPIClock30MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '30Mhz');
    if MainForm.MenuCH347SPIClock15MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '15Mhz');
    if MainForm.MenuCH347SPIClock7_5MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '7_5Mhz');
    if MainForm.MenuCH347SPIClock3_75MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '3_75Mhz');
    if MainForm.MenuCH347SPIClock1_875MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '1_875MHz');
    if MainForm.MenuCH347SPIClock937_5KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '937_5KHz');
    if MainForm.MenuCH347SPIClock468_75KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('ch347_spi_speed', '468_75KHz');

    if MainForm.MenuMW32Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('mw_speed', '32Khz');
    if MainForm.MenuMW16Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('mw_speed', '16Khz');
    if MainForm.MenuMW8Khz.Checked then
      TDOMElement(ParentNode).SetAttribute('mw_speed', '8Khz');

    if MainForm.MenuHWUSBASP.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'usbasp');
    if MainForm.MenuHWCH341A.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'ch341a');
    if MainForm.MenuHWCH347.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'ch347');
    if MainForm.MenuHWAVRISP.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'avrisp');
    if MainForm.MenuHWARDUINO.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'arduino');
    if MainForm.MenuHWBUZZPIRAT.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'buzzpirat');
    if MainForm.MenuHWBUSPIRATE5.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'buspirate5');
    if MainForm.MenuHWFT232H.Checked then
      TDOMElement(ParentNode).SetAttribute('hw', 'ft232h');

    TDOMElement(ParentNode).SetAttribute('arduino_comport', Arduino_COMPort);
    TDOMElement(ParentNode).SetAttribute('arduino_baudrate', IntToStr(Arduino_BaudRate));

    TDOMElement(ParentNode).SetAttribute('buzzpirat_comport', Buzzpirat_COMPort);

    if MainForm.MenuBuzzpiratSerial2M.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_serial_speed', '2000000');
    if MainForm.MenuBuzzpiratSerial1M.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_serial_speed', '1000000');
    if MainForm.MenuBuzzpiratSerial250000.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_serial_speed', '250000');
    if MainForm.MenuBuzzpiratSerial230400.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_serial_speed', '230400');
    if MainForm.MenuBuzzpiratSerial115200.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_serial_speed', '115200');

    TDOMElement(ParentNode).SetAttribute('buspirate5_comport', BusPirate5_COMPort);
    TDOMElement(ParentNode).SetAttribute('buspirate5_spi_hz',
      IntToStr(MenuCheckedTag(MainForm.MenuBP5SPIClock, 125000)));
    TDOMElement(ParentNode).SetAttribute('buspirate5_i2c_hz',
      IntToStr(MenuCheckedTag(MainForm.MenuBP5I2CClock, 50000)));
    TDOMElement(ParentNode).SetAttribute('buspirate5_mv',
      IntToStr(MenuCheckedTag(MainForm.MenuBP5Voltage, 3300)));
    TDOMElement(ParentNode).SetAttribute('buspirate5_ma',
      IntToStr(MenuCheckedTag(MainForm.MenuBP5Current, 300)));
    if MainForm.MenuBP5Power.Checked then
      TDOMElement(ParentNode).SetAttribute('buspirate5_power', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buspirate5_power', '0');
    if MainForm.MenuBP5Pullups.Checked then
      TDOMElement(ParentNode).SetAttribute('buspirate5_pullups', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buspirate5_pullups', '0');
    if MainForm.MenuBP5Verbose.Checked then
      TDOMElement(ParentNode).SetAttribute('buspirate5_verbose', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buspirate5_verbose', '0');
    if MainForm.MenuBP5ResetEach.Checked then
      TDOMElement(ParentNode).SetAttribute('buspirate5_reseteach', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buspirate5_reseteach', '0');

    if MainForm.MenuBuzzpiratSPI8MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '8Mhz');
    if MainForm.MenuBuzzpiratSPI4MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '4Mhz');
    if MainForm.MenuBuzzpiratSPI2P6MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '2_6Mhz');
    if MainForm.MenuBuzzpiratSPI2MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '2Mhz');
    if MainForm.MenuBuzzpiratSPI1MHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '1Mhz');
    if MainForm.MenuBuzzpiratSPI250KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '250Khz');
    if MainForm.MenuBuzzpiratSPI125KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '125Khz');
    if MainForm.MenuBuzzpiratSPI30KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_spi_speed', '30Khz');

    if MainForm.MenuBuzzpiratI2C400KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_i2c_speed', '400Khz');
    if MainForm.MenuBuzzpiratI2C100KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_i2c_speed', '100Khz');
    if MainForm.MenuBuzzpiratI2C50KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_i2c_speed', '50Khz');
    if MainForm.MenuBuzzpiratI2C5KHz.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_i2c_speed', '5Khz');

    if MainForm.MenuBuzzpiratSPINormal.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_output', '3v3')
    else
      TDOMElement(ParentNode).SetAttribute('buzzpirat_output', 'hiz');

    if MainForm.MenuBuzzpiratPower.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_power', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buzzpirat_power', '0');

    if MainForm.MenuBuzzpiratPullups.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_pullups', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buzzpirat_pullups', '0');

    if MainForm.MenuBuzzpiratResetEach.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_reset_each', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buzzpirat_reset_each', '0');

    if MainForm.MenuBuzzpiratVerbose.Checked then
      TDOMElement(ParentNode).SetAttribute('buzzpirat_verbose', '1')
    else
      TDOMElement(ParentNode).SetAttribute('buzzpirat_verbose', '0');

    Node.Appendchild(parentNode);

    //The program's folder can be one the user cannot write to, as under
    //Program Files.  By Dreg
    try
      WriteXMLFile(XMLfile, SettingsFileName);
    except
      on E: Exception do result := E.Message;
    end;
  end;

end;

procedure LoadOptions(XMLfile: TXMLDocument);
var
    Node: TDOMNode;
    OptVal: string;
begin
  if XMLfile <> nil then
  begin
    Node := XMLfile.DocumentElement.FindNode('options');

    if (Node <> nil) then
    if (Node.HasAttributes) then
    begin

      if  Node.Attributes.GetNamedItem('verify') <> nil then
      begin
        if Node.Attributes.GetNamedItem('verify').NodeValue = '1' then
          MainForm.MenuAutoCheck.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('sendab') <> nil then
      begin
        if Node.Attributes.GetNamedItem('sendab').NodeValue = '1' then
          MainForm.MenuSendAB.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('skipff') <> nil then
      begin
        if Node.Attributes.GetNamedItem('skipff').NodeValue = '1' then
          MainForm.MenuSkipFF.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('spi_speed') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('spi_speed').NodeValue);

        if OptVal = '3Mhz' then MainForm.Menu3Mhz.Checked := true;
        if OptVal = '1_5Mhz' then MainForm.Menu1_5Mhz.Checked := true;
        if OptVal = '750Khz' then MainForm.Menu750Khz.Checked := true;
        if OptVal = '375Khz' then MainForm.Menu375Khz.Checked := true;
        if OptVal = '187_5Khz' then MainForm.Menu187_5Khz.Checked := true;
        if OptVal = '93_75Khz' then MainForm.Menu93_75Khz.Checked := true;
        if OptVal = '32Khz' then MainForm.Menu32Khz.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('ch347_spi_speed') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('ch347_spi_speed').NodeValue);

        if OptVal = '60Mhz' then MainForm.MenuCH347SPIClock60MHz.Checked := true;
        if OptVal = '30Mhz' then MainForm.MenuCH347SPIClock30MHz.Checked := true;
        if OptVal = '15Mhz' then MainForm.MenuCH347SPIClock15MHz.Checked := true;
        if OptVal = '7_5Mhz' then MainForm.MenuCH347SPIClock7_5MHz.Checked := true;
        if OptVal = '3_75Mhz' then MainForm.MenuCH347SPIClock3_75MHz.Checked := true;
        if OptVal = '1_875MHz' then MainForm.MenuCH347SPIClock1_875MHz.Checked := true;
        if OptVal = '937_5KHz' then MainForm.MenuCH347SPIClock937_5KHz.Checked := true;
        if OptVal = '468_75KHz' then MainForm.MenuCH347SPIClock468_75KHz.Checked := true;
      end;


      if  Node.Attributes.GetNamedItem('mw_speed') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('mw_speed').NodeValue);

        if OptVal = '32Khz' then MainForm.MenuMW32Khz.Checked := true;
        if OptVal = '16Khz' then MainForm.MenuMW16Khz.Checked := true;
        if OptVal = '8Khz' then MainForm.MenuMW8Khz.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('hw') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('hw').NodeValue);

        if OptVal = 'usbasp' then
        begin
          MainForm.MenuHWUSBASP.Checked := true;
          SelectHW(CHW_USBASP);
        end;

        if OptVal = 'ch341a' then
        begin
          MainForm.MenuHWCH341A.Checked := true;
          SelectHW(CHW_CH341);
        end;

        if OptVal = 'ch347' then
        begin
          MainForm.MenuHWCH347.Checked := true;
          SelectHW(CHW_CH347);
        end;

        if OptVal = 'avrisp' then
        begin
          MainForm.MenuHWAVRISP.Checked := true;
          SelectHW(CHW_AVRISP);
        end;

        if OptVal = 'arduino' then
        begin
          MainForm.MenuHWArduino.Checked := true;
          SelectHW(CHW_ARDUINO);
        end;

        if OptVal = 'buzzpirat' then
        begin
          MainForm.MenuHWBuzzpirat.Checked := true;
          SelectHW(CHW_BUZZPIRAT);
        end;

        if OptVal = 'buspirate5' then
        begin
          MainForm.MenuHWBUSPIRATE5.Checked := true;
          SelectHW(CHW_BUSPIRATE5);
        end;

        if OptVal = 'ft232h' then
        begin
          MainForm.MenuHWFT232H.Checked := true;
          SelectHW(CHW_FT232H);
        end;


      end;

      if  Node.Attributes.GetNamedItem('arduino_comport') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('arduino_comport').NodeValue);

        Arduino_COMPort := OptVal;
        MainForm.MenuArduinoCOMPort.Caption := 'Arduino COMPort: '+ Arduino_COMPort;
      end;

      if  Node.Attributes.GetNamedItem('buzzpirat_comport') <> nil then
      begin
        Buzzpirat_COMPort := Trim(UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_comport').NodeValue));
        MainForm.RefreshCOMPortMenu;
      end;

      if  Node.Attributes.GetNamedItem('buzzpirat_serial_speed') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_serial_speed').NodeValue);
        if OptVal = '2000000' then MainForm.MenuBuzzpiratSerial2M.Checked := true;
        if OptVal = '1000000' then MainForm.MenuBuzzpiratSerial1M.Checked := true;
        if OptVal = '250000' then MainForm.MenuBuzzpiratSerial250000.Checked := true;
        if OptVal = '230400' then MainForm.MenuBuzzpiratSerial230400.Checked := true;
        if OptVal = '115200' then MainForm.MenuBuzzpiratSerial115200.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('buspirate5_comport') <> nil then
      begin
        BusPirate5_COMPort := Trim(UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_comport').NodeValue));
        MainForm.RefreshBP5PortMenu;
      end;
      if  Node.Attributes.GetNamedItem('buspirate5_spi_hz') <> nil then
        MenuCheckByTag(MainForm.MenuBP5SPIClock,
          StrToIntDef(UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_spi_hz').NodeValue), 125000));
      if  Node.Attributes.GetNamedItem('buspirate5_i2c_hz') <> nil then
        MenuCheckByTag(MainForm.MenuBP5I2CClock,
          StrToIntDef(UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_i2c_hz').NodeValue), 50000));
      if  Node.Attributes.GetNamedItem('buspirate5_mv') <> nil then
        MenuCheckByTag(MainForm.MenuBP5Voltage,
          StrToIntDef(UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_mv').NodeValue), 3300));
      if  Node.Attributes.GetNamedItem('buspirate5_ma') <> nil then
        MenuCheckByTag(MainForm.MenuBP5Current,
          StrToIntDef(UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_ma').NodeValue), 300));
      if  Node.Attributes.GetNamedItem('buspirate5_power') <> nil then
        MainForm.MenuBP5Power.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_power').NodeValue) = '1';
      if  Node.Attributes.GetNamedItem('buspirate5_pullups') <> nil then
        MainForm.MenuBP5Pullups.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_pullups').NodeValue) = '1';
      if  Node.Attributes.GetNamedItem('buspirate5_verbose') <> nil then
        MainForm.MenuBP5Verbose.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_verbose').NodeValue) = '1';
      if  Node.Attributes.GetNamedItem('buspirate5_reseteach') <> nil then
        MainForm.MenuBP5ResetEach.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buspirate5_reseteach').NodeValue) = '1';

      if  Node.Attributes.GetNamedItem('buzzpirat_spi_speed') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_spi_speed').NodeValue);

        if OptVal = '8Mhz' then MainForm.MenuBuzzpiratSPI8MHz.Checked := true;
        //Dropped from the menu: fall back to the nearest clock still offered.
        if OptVal = '5_3Mhz' then MainForm.MenuBuzzpiratSPI4MHz.Checked := true;
        if OptVal = '4Mhz' then MainForm.MenuBuzzpiratSPI4MHz.Checked := true;
        if OptVal = '3_2Mhz' then MainForm.MenuBuzzpiratSPI2P6MHz.Checked := true;
        if OptVal = '2_6Mhz' then MainForm.MenuBuzzpiratSPI2P6MHz.Checked := true;
        if OptVal = '2Mhz' then MainForm.MenuBuzzpiratSPI2MHz.Checked := true;
        if OptVal = '1_3Mhz' then MainForm.MenuBuzzpiratSPI1MHz.Checked := true;
        if OptVal = '1Mhz' then MainForm.MenuBuzzpiratSPI1MHz.Checked := true;
        if OptVal = '250Khz' then MainForm.MenuBuzzpiratSPI250KHz.Checked := true;
        if OptVal = '125Khz' then MainForm.MenuBuzzpiratSPI125KHz.Checked := true;
        if OptVal = '50Khz' then MainForm.MenuBuzzpiratSPI30KHz.Checked := true;
        if OptVal = '30Khz' then MainForm.MenuBuzzpiratSPI30KHz.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('buzzpirat_i2c_speed') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_i2c_speed').NodeValue);

        if OptVal = '400Khz' then MainForm.MenuBuzzpiratI2C400KHz.Checked := true;
        if OptVal = '100Khz' then MainForm.MenuBuzzpiratI2C100KHz.Checked := true;
        if OptVal = '50Khz' then MainForm.MenuBuzzpiratI2C50KHz.Checked := true;
        if OptVal = '5Khz' then MainForm.MenuBuzzpiratI2C5KHz.Checked := true;
      end;

      if  Node.Attributes.GetNamedItem('buzzpirat_output') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_output').NodeValue);

        MainForm.MenuBuzzpiratSPINormal.Checked := OptVal = '3v3';
        MainForm.MenuBuzzpiratSPIHiz.Checked := OptVal <> '3v3';
      end;

      if  Node.Attributes.GetNamedItem('buzzpirat_power') <> nil then
        MainForm.MenuBuzzpiratPower.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_power').NodeValue) = '1';

      if  Node.Attributes.GetNamedItem('buzzpirat_pullups') <> nil then
        MainForm.MenuBuzzpiratPullups.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_pullups').NodeValue) = '1';

      if  Node.Attributes.GetNamedItem('buzzpirat_reset_each') <> nil then
        MainForm.MenuBuzzpiratResetEach.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_reset_each').NodeValue) = '1';

      if  Node.Attributes.GetNamedItem('buzzpirat_verbose') <> nil then
        MainForm.MenuBuzzpiratVerbose.Checked :=
          UTF16ToUTF8(Node.Attributes.GetNamedItem('buzzpirat_verbose').NodeValue) = '1';

      if  Node.Attributes.GetNamedItem('arduino_baudrate') <> nil then
      begin
        OptVal := UTF16ToUTF8(Node.Attributes.GetNamedItem('arduino_baudrate').NodeValue);

        Arduino_BaudRate := StrToInt(OptVal);
      end;

    end;
  end;

end;


end.
