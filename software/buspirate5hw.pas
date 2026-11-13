unit buspirate5hw;

{
  Bus Pirate v5 / v6 / v7 (BPIO2) programmer back end for AsProgrammer.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  This driver is separate from buzzpirathw.pas. The v3.x speaks BBIO, a stream
  of raw opcodes; the v5 and later speak BPIO2, which is FlatBuffers packets
  inside COBS frames on a second USB serial port. The two share nothing but
  the TBaseHardware contract, and both back ends can hold their own port open
  at the same time.

  Everything lives in this one unit, in three layers:

    TBP5Port            serial transport over Synapse's TBlockSerial, plus
                        reading a COBS frame.

    TBusPirate5         the BPIO2 protocol engine: COBS, a hand written
                        FlatBuffers encoder and a generic decoder, the status
                        handshake, SPI and I2C.

    TBusPirate5Hardware the TBaseHardware implementation AsProgrammer talks to,
                        plus the reading of the BusPirateV5+ menu settings.

  Reference material:
    - https://docs.buspirate.com/docs/binmode-reference/protocol-bpio2/
    - the BPIO2 schema, bpio.fbs
    - firmware: src/binmode/bpio.c, bpio_spi.c, bpio_i2c.c

  Design notes:

  * There is no FlatBuffers runtime for Free Pascal here. Requests are fixed
    byte templates with the variable fields patched in place; the layouts
    below were built by hand and verified byte for byte against a real
    Bus Pirate 6. Responses cannot use templates, because the firmware's
    flatcc emitter lays them out its own way, so the decoder is a generic
    vtable walker. It has to cope with negative soffsets (flatcc puts vtables
    after their tables), truncated vtables (trailing empty slots are dropped)
    and elided fields (a field equal to its schema default is absent).

  * Three firmware limits the host has to keep:
      - bytes_read must never exceed 512. The firmware detects the overrun but
        its error path jumps past the start of the response table, so flatcc
        builds a malformed packet or none at all, and the damage carries into
        later responses. Never probe this one.
      - data_write is not checked by the firmware; the real ceiling is the 643
        byte frame buffer, so keep it to 512.
      - contents_type must be 1, 2 or 3. Zero indexes a NULL handler and reboots
        the device, so it is hardcoded in every template.

  * An I2C read that asks for a start must carry at least one write byte: the
    firmware reads data_write[0] to build the read address without checking
    whether the vector is there.

  * The device only speaks BPIO2 when BPIO2 is the selected binmode. The
    factory default is the SUMP logic analyser, which uses the same port, so a
    failed handshake means "wrong binmode", not "wrong port". Open reports it
    that way after one request, without retrying.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Synaser, basehw;

const
  //Firmware constants (bpio.c)
  BP5_MAX_PACKET   = 640;
  BP5_MAX_WRITE    = 512;
  BP5_MAX_READ     = 512;
  //640 + ceil(640/254) of COBS overhead, the firmware's own frame buffer.
  BP5_MAX_COBS     = 643;
  //The error of a DataRequest whose mode handler failed.
  BP5_REQUEST_FAILED = 'Protocol request failed';

  //Nominal: on USB CDC the host driver records the rate and the device ignores
  //it. USB and the SPI clock set the throughput, so the menu does not offer it.
  BP5_BAUD_DEFAULT = 3000000;

  BP5_USB_ID       = 'VID_1209&PID_7331';

  //Union tags
  BP5_REQ_STATUS   = 1;
  BP5_REQ_CONFIG   = 2;
  BP5_REQ_DATA     = 3;

  BP5_RSP_STATUS   = 1;
  BP5_RSP_CONFIG   = 2;
  BP5_RSP_DATA     = 3;

  //ResponsePacket slots
  BP5_RP_ERROR         = 0;
  BP5_RP_CONTENTS_TYPE = 1;
  BP5_RP_CONTENTS      = 2;

  //DataResponse slots
  BP5_DR_ERROR     = 0;
  BP5_DR_DATA_READ = 1;
  BP5_DR_IS_ASYNC  = 2;

  //ConfigurationResponse slots
  BP5_CR_ERROR     = 0;

  //StatusResponse slots
  BP5_SR_ERROR          = 0;
  BP5_SR_FB_MAJOR       = 1;
  BP5_SR_FB_MINOR       = 2;
  BP5_SR_HW_MAJOR       = 3;
  BP5_SR_HW_MINOR       = 4;
  BP5_SR_GIT_HASH       = 7;
  BP5_SR_FW_DATE        = 8;
  BP5_SR_MODES          = 9;
  BP5_SR_MODE_CURRENT   = 10;
  BP5_SR_MAX_PACKET     = 13;
  BP5_SR_MAX_WRITE      = 14;
  BP5_SR_MAX_READ       = 15;
  BP5_SR_PSU_ENABLED    = 16;
  BP5_SR_PSU_SET_MV     = 17;
  BP5_SR_PSU_SET_MA     = 18;
  BP5_SR_PSU_MEAS_MV    = 19;
  BP5_SR_PSU_MEAS_MA    = 20;
  BP5_SR_PSU_ERROR      = 21;
  BP5_SR_PULLUP_ENABLED = 22;

  //Bounds the host clamps the clock to: the firmware does no validation on the
  //BPIO path.
  BP5_SPI_MIN_HZ   = 1000;
  BP5_SPI_MAX_HZ   = 16000000;
  //The firmware divides by speed div 1000, so below 1 kHz it divides by zero.
  BP5_I2C_MIN_HZ   = 1000;
  BP5_I2C_MAX_HZ   = 1000000;

  //The status reports the voltage and current limit psu_set_v and psu_set_i
  //last worked out, which can be well off the request (a DAC board clamps
  //5.0 V to 4896 mV), so a session compares later reads with its first read
  //after switching the supply on. A set voltage that moves more than this was
  //set by someone else.
  BP5_PSU_MV_SLACK = 10;
  //VOUT under this share of the set voltage is a fault: the firmware's own
  //default undervoltage limit (W command, 10 %), which BPIO2 switches off.
  BP5_PSU_MIN_PERCENT = 90;
  //psu_enable waits 10 ms, and this much more with a current limit (psu.c).
  //VOUT read low right after a configuration is read again after this wait,
  //so a supply with no limit gets as long to settle.
  BP5_PSU_SETTLE_MS = 500;

type

TBP5Port = class
private
  FSerial: TBlockSerial;
  FPortName: string;
  FLastError: string;
  //Whatever followed a frame delimiter inside the same read. RecvBufferEx has
  //already taken those bytes out of the driver, so without this they would be
  //lost and the frame after them beheaded.
  FResidual: TBytes;
  function Fail(const Where: string): boolean;
  function GetWriteTimeout: integer;
  procedure SetWriteTimeout(Ms: integer);
public
  constructor Create;
  destructor Destroy; override;

  function Open(const APortName: string; ABaudRate: LongWord): boolean;
  procedure Close;
  function IsOpen: boolean;

  function WriteAll(const Buffer; Count: integer): boolean;
  //Reads the next frame, without its 0x00 delimiter, into Frame; zeros before
  //it are skipped. TimeoutMs restarts on every byte that arrives.
  function ReadFrame(out Frame: TBytes; TimeoutMs: integer): boolean;

  procedure Purge;
  function Drain(IdleMs, MaxMs: integer): integer;
  function BytesWaiting: integer;

  property LastError: string read FLastError;
  property PortName: string read FPortName;
  //How long one write may wait for the driver to take the bytes (synaser's
  //DeadlockTimeout). A device whose firmware hung with USB still up takes none.
  //It bounds a pending read too, but this unit only reads bytes already there.
  property WriteTimeoutMs: integer read GetWriteTimeout write SetWriteTimeout;
end;

//COBS, Consistent Overhead Byte Stuffing: the encoded form never contains a
//zero, so a zero delimits a frame.
function BP5CobsEncode(const Src: TBytes): TBytes;
function BP5CobsDecode(const Src: TBytes; out Dst: TBytes): boolean;

//Device enumeration
type
  TBP5Device = record
    DataPort: string;    //MI_02, the BPIO2 interface
    TermPort: string;    //MI_00, the user terminal
    Name: string;        //USB serial string: chip ID in hex, or 5buspirate, ...
    Present: boolean;    //still plugged in
  end;
  TBP5DeviceArray = array of TBP5Device;

//Every serial port the system has now, sorted by COM number. The menu lists
//these, as the v3.x menu does, so it works whatever the driver stack.
procedure BP5GetSerialPorts(AList: TStrings);

//Finds Bus Pirate v5+ units in the USB registry, best effort, to label the
//ports of that list as BPIO2 or terminal. The menu does not depend on it: on a
//machine where this finds nothing, the user still picks a port by hand.
function BP5EnumerateDevices: TBP5DeviceArray;

//What a COM port is, for the menu caption: '' when nothing is known, else
//the Name or 'Bus Pirate' and the interface, as in '6buspirate, terminal'.
function BP5DescribePort(const Devices: TBP5DeviceArray; const APort: string;
                         out IsData, IsTerminal: boolean): string;

type
  TBP5Mode = (bp5Closed, bp5Unknown, bp5HiZ, bp5SPI, bp5I2C);

  TBP5LogLevel = (bp5lError, bp5lInfo, bp5lDebug);
  TBP5LogEvent = procedure(Level: TBP5LogLevel; const Msg: string) of object;

  //What a configuration request does to the target supply. The firmware's
  //psu_enable switches the supply off and on again, then waits 10 ms, and
  //500 ms more with a current limit, so On goes out only when the request
  //changes or FPsuKnown is false. Leave sends neither flag.
  TBP5PsuAction = (bp5psuLeave, bp5psuOn, bp5psuOff);

  //How Disconnect ended.
  TBP5Park = (bp5pkNoSession, bp5pkParked, bp5pkFailed);

  TBP5Status = record
    Valid: boolean;
    FbMajor: byte;
    FbMinor: word;
    HwMajor: byte;
    HwMinor: byte;
    GitHash: string;
    FwDate: string;
    ModeCurrent: string;
    Modes: string;
    MaxPacket: LongWord;
    MaxWrite: LongWord;
    MaxRead: LongWord;
    PsuEnabled: boolean;
    PsuSetMv: LongWord;
    PsuSetMa: LongWord;
    PsuMeasMv: LongWord;
    PsuMeasMa: LongWord;
    PsuError: boolean;
    PullupEnabled: boolean;
  end;

  TBP5SPISettings = record
    SpeedHz: LongWord;
    ClockPolarity: boolean;
    ClockPhase: boolean;
    ChipSelectIdleHigh: boolean;
    Power: boolean;
    PsuMv: LongWord;
    PsuMa: LongWord;
    Pullups: boolean;
  end;

  TBP5I2CSettings = record
    SpeedHz: LongWord;
    Power: boolean;
    PsuMv: LongWord;
    PsuMa: LongWord;
    Pullups: boolean;
  end;

TBusPirate5 = class
private
  FPort: TBP5Port;
  FMode: TBP5Mode;
  FStatus: TBP5Status;
  FLastError: string;
  FOnLog: TBP5LogEvent;
  FVerbose: boolean;

  //Set when a request or its reply was lost, or a reply could not be parsed.
  //Nothing else goes out until Resync has proved the link is back in step.
  FDesynced: boolean;
  FRecovering: boolean;
  //The guard's refusal is logged once per out of sync episode.
  FRefusalLogged: boolean;
  //Whether FLastError went to the log (SetError) or was only kept: a device's
  //own refusal is the expected answer of an I2C probe and stays quiet.
  FLastErrorLogged: boolean;

  //Deferred CS-low write bytes, so a write/read pair costs one round trip.
  FPending: TBytes;
  FPendingLen: integer;
  FCSAsserted: boolean;
  //I2CReadByte(false) has to emit a stop to produce the NACK, so the I2CStop
  //that follows would be a second one.
  FStopAlreadySent: boolean;

  FSPI: TBP5SPISettings;
  FI2C: TBP5I2CSettings;

  //The supply request the device last accepted. While it is known and the
  //same, a new configuration leaves the supply alone instead of power cycling
  //the target. Forgotten on Open, on Close, after a failed configuration that
  //carried a supply flag, and whenever a status read finds the supply no
  //longer as set.
  FPsuKnown: boolean;
  FPsuOn: boolean;
  FPsuMv: LongWord;
  FPsuMa: LongWord;
  //What the first status read after switching the supply on reported.
  FPsuRefKnown: boolean;
  FPsuRefMv: LongWord;
  FPsuRefMa: LongWord;
  //A status read found the supply in another state than the one this session
  //set: the current limit tripped, VOUT sagged, or someone used the terminal.
  FPsuChanged: boolean;
  FPsuChangeWhy: string;
  //The only problem found is VOUT under BP5_PSU_MIN_PERCENT: the supply is
  //still as set, so FPsuKnown stays and RecheckSag can read VOUT again.
  FPsuSagging: boolean;
  //The device may still be powering the target. Survives Close, so a session
  //that ended without parking the device is not taken for one switched off.
  FSupplyMayBeOn: boolean;

  procedure Log(Level: TBP5LogLevel; const Msg: string);
  function SetError(const Msg: string): boolean;
  procedure MarkDesynced(const Why: string);
  function PsuActionFor(Power: boolean; Mv, Ma: LongWord): TBP5PsuAction;
  procedure NotePsuApplied(Action: TBP5PsuAction; Power: boolean; Mv, Ma: LongWord);
  procedure CheckPsu;
  function GetPsuOn: boolean;

  //One request, one response: Response is the whole decoded packet and
  //BodyPos the position of its contents table.
  function Transact(const Request: TBytes; WantType: byte;
                    out Response: TBytes; out BodyPos: integer;
                    TimeoutMs: integer): boolean;

  function EncodeStatus(Quick: boolean): TBytes;
  function EncodeConfig(const AMode: string; SpeedHz: LongWord;
                        DataBits: byte; ClockStretch, ClockPolarity,
                        ClockPhase, ChipSelectIdle: boolean;
                        SetBitorderMsb: boolean;
                        Psu: TBP5PsuAction; PsuMv: LongWord; PsuMa: word;
                        Pullups: boolean): TBytes;
  function EncodeData(StartMain, StopMain: boolean; BytesRead: word;
                      WritePtr: Pointer; WriteCount: integer): TBytes;

  //Quick: version and supply only, for the probe and the liveness check.
  function ReadStatus(Quick: boolean): boolean;
  function SendConfig(const Request: TBytes; const What: string): boolean;

  function PendingAdd(const Buffer; Count: integer): boolean;
  function DataExchange(StartMain, StopMain: boolean; BytesRead: word;
                        WritePtr: Pointer; WriteCount: integer;
                        ReadPtr: Pointer): boolean;
public
  constructor Create;
  destructor Destroy; override;

  function Open(const APortName: string; ABaudRate: LongWord = 0): boolean;
  procedure Close;
  function IsOpen: boolean;

  //Liveness check: a quick status read proves BPIO2 is active and reads the
  //supply state too, so check PsuChanged afterwards.
  function Ping: boolean;
  //Drains whatever is in flight and proves the link again, like Ping. It
  //leaves the mode and the supply alone: re-entering the mode can switch the
  //supply on again, and the power down path runs this too.
  function Resync: boolean;
  procedure ClearPsuChanged;
  //Refreshes the whole status block, for the device info window.
  function RefreshStatus: boolean;

  function EnterSPI(const Settings: TBP5SPISettings): boolean;
  function EnterI2C(const Settings: TBP5I2CSettings): boolean;
  function EnterHiZ: boolean;

  function SPIQueueWrite(Data: Pointer; Count: integer): boolean;
  function SPIFlushQueued: boolean;
  function SPITransfer(WritePtr: Pointer; WriteCount: integer;
                       ReadPtr: Pointer; ReadCount: integer;
                       Deassert: boolean): boolean;
  function SPIReleaseCS: boolean;
  procedure SPIDropQueued;

  function I2CStart: boolean;
  function I2CStop: boolean;
  function I2CWriteByte(Data: byte; out Acked: boolean): boolean;
  function I2CReadByte(out Data: byte; SendAck: boolean): boolean;
  function I2CWriteRead(DevAddr: byte; WritePtr: Pointer; WriteCount: integer;
                        ReadPtr: Pointer; ReadCount: integer): boolean;
  function I2CScan(FirstAddr, LastAddr: integer; out Found: TBytes): boolean;

  property LastError: string read FLastError;
  property LastErrorLogged: boolean read FLastErrorLogged;
  property Mode: TBP5Mode read FMode;
  property Status: TBP5Status read FStatus;
  property Desynced: boolean read FDesynced;
  //The supply is on as this session set it, and no read since says otherwise.
  property PsuOn: boolean read GetPsuOn;
  property PsuChanged: boolean read FPsuChanged;
  property PsuChangeWhy: string read FPsuChangeWhy;
  property PsuSagging: boolean read FPsuSagging;
  property SupplyMayBeOn: boolean read FSupplyMayBeOn;
  property OnLog: TBP5LogEvent read FOnLog write FOnLog;
  property Verbose: boolean read FVerbose write FVerbose;
  property Port: TBP5Port read FPort;
end;

TBusPirate5Hardware = class(TBaseHardware)
private
  FBP: TBusPirate5;
  FDevOpened: boolean;
  FStrError: string;
  //Whether FStrError reached the log (Complain) or was only kept.
  FErrorLogged: boolean;
  FOpenPort: string;
  FAppliedConfig: string;

  procedure HandleLog(Level: TBP5LogLevel; const Msg: string);
  function Complain(const Msg: string): boolean;
  function TakeSupplyChange: string;
  function SupplyChanged: boolean;
  function RecheckSag: boolean;

  function WantI2C: boolean;
  function SelectedSPIHz: LongWord;
  function SelectedI2CHz: LongWord;
  function SelectedPsuMv: LongWord;
  function SelectedPsuMa: LongWord;
  function SPISettings: TBP5SPISettings;
  function I2CSettings: TBP5I2CSettings;
  function ConfigSignature: string;

  function Connect(const APort: string): boolean;
  function ReadyLink(const APort: string): boolean;
public
  constructor Create;
  destructor Destroy; override;

  function GetLastError: string; override;
  function ErrorWasLogged: boolean; override;
  function DevOpen: boolean; override;
  procedure DevClose; override;

  function SPIRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer; override;
  function SPIWrite(CS: byte; BufferLen: integer; buffer: array of byte): integer; override;
  function SPIInit(speed: integer): boolean; override;
  procedure SPIDeinit; override;

  procedure I2CInit; override;
  procedure I2CDeinit; override;
  function I2CReadWrite(DevAddr: byte;
                        WBufferLen: integer; WBuffer: array of byte;
                        RBufferLen: integer; var RBuffer: array of byte): integer; override;
  procedure I2CStart; override;
  procedure I2CStop; override;
  function I2CReadByte(ack: boolean): byte; override;
  function I2CWriteByte(data: byte): boolean; override; //return ack

  //Microwire is not reachable over BPIO2: MWInit, MWRead and MWWrite fail.
  function MWInit(speed: integer): boolean; override;
  procedure MWDeinit; override;
  function MWRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer; override;
  function MWWrite(CS: byte; BitsWrite: byte; buffer: array of byte): integer; override;
  function MWIsBusy: boolean; override;

  //Extras driven from the BusPirateV5+ menu.
  function Disconnect: TBP5Park;
  //HiZ with the supply off, recovering the link first if it needs it.
  function SafePowerDown: boolean;
  //No session is open, and the last one may have left the target powered.
  function SupplyMayBeOn: boolean;
  function DeviceReport: string;
  function ScanI2CBus(out Found: TBytes; out ErrMsg: string): boolean;
  //The bus picked in the window, SPI or I2C, labelled on the device's screen
  //with the supply and the pull-ups off.
  function ShowPinLabels(out ErrMsg: string): boolean;
  function I2CDeviceLine(Addr: byte): string;
  function I2CBusDescription: string;
  //Largest read the device will accept, for the chunk size ladders in main.pas.
  function MaxRead: integer;
end;

implementation

uses Registry, Menus, main;

//Serial transport

const
  BPSER_DEADLOCK_MS = 15000;
  BPSER_RX_BUFFER   = 65536;
  //Write timeout while parking, for Resync's delimiter and for the first
  //request of Open: those requests are at most about 130 bytes on the wire,
  //which a live device takes at once, and each write would otherwise wait the
  //full deadlock timeout on a hung one, or on one left in SUMP.
  BPSER_PARK_WRITE_MS = 1000;

type
  //A Bus Pirate whose active binmode is SUMP starts its logic analyser when
  //DTR rises: with the port opened with DTR high, a Bus Pirate 5 put 3.3 V on
  //VOUT, and the bytes of a BPIO2 request armed the analyser and hung the
  //firmware. synaser raises DTR in Connect and in Config, so this class turns
  //every DTR write into DTR off. BPIO2 reads requests whatever DTR says.
  //By Dreg
  TBP5Serial = class(TBlockSerial)
  protected
    procedure SetDTRF(Value: Boolean); override;
  end;

{$push}{$hints off}
procedure TBP5Serial.SetDTRF(Value: Boolean);
begin
  inherited SetDTRF(false);
end;
{$pop}

constructor TBP5Port.Create;
begin
  inherited Create;
  FSerial := TBP5Serial.Create;
  FSerial.RaiseExcept := false;
  FSerial.DeadlockTimeout := BPSER_DEADLOCK_MS;
  //No handshake lines are wired; never gate I/O on them.
  FSerial.TestDSR := false;
  FSerial.TestCTS := false;
  FSerial.LinuxLock := false;
  FLastError := '';
end;

destructor TBP5Port.Destroy;
begin
  Close;
  FSerial.Free;
  inherited Destroy;
end;

function TBP5Port.Fail(const Where: string): boolean;
begin
  if FSerial.LastError <> 0 then
    FLastError := Where + ': ' + FSerial.LastErrorDesc + ' (' + IntToStr(FSerial.LastError) + ')'
  else
    FLastError := Where;
  result := false;
end;

function TBP5Port.GetWriteTimeout: integer;
begin
  result := FSerial.DeadlockTimeout;
end;

procedure TBP5Port.SetWriteTimeout(Ms: integer);
begin
  FSerial.DeadlockTimeout := Ms;
end;

function TBP5Port.Open(const APortName: string; ABaudRate: LongWord): boolean;
begin
  FLastError := '';
  Close;
  FPortName := APortName;

  FSerial.Connect(APortName);
  if FSerial.LastError <> 0 then Exit(Fail('cannot open ' + APortName));

  //USB CDC: the line settings are cosmetic, but they still have to be applied
  //or the driver may refuse the handle. They are set as synaser's Config sets
  //them, except DTR: Config writes a DCB that raises it, and TBP5Serial above
  //only stops the DTR property, so the DCB is written here with DTR off.
  //By Dreg
  if ABaudRate = 0 then ABaudRate := BP5_BAUD_DEFAULT;
  FSerial.GetCommState;
  FSerial.DCB.DCBlength := SizeOf(FSerial.DCB);
  FSerial.DCB.BaudRate := ABaudRate;
  FSerial.DCB.ByteSize := 8;
  FSerial.DCB.Parity := 0;
  FSerial.DCB.StopBits := SB1;
  FSerial.DCB.XonChar := #17;
  FSerial.DCB.XoffChar := #19;
  FSerial.DCB.Flags := dcb_Binary or dcb_RtsControlEnable;
  FSerial.SetCommState;
  if FSerial.LastError <> 0 then
  begin
    Fail('cannot configure ' + APortName);
    FSerial.CloseSocket;
    Exit(false);
  end;

  //Must come after the line settings: the setter writes the DCB again, with
  //DTR as it finds it.
  FSerial.SizeRecvBuffer := BPSER_RX_BUFFER;
  FSerial.Purge;
  result := true;
end;

procedure TBP5Port.Close;
begin
  if FSerial.InstanceActive then FSerial.CloseSocket;
end;

function TBP5Port.IsOpen: boolean;
begin
  result := FSerial.InstanceActive;
end;

function TBP5Port.WriteAll(const Buffer; Count: integer): boolean;
var
  sent, written: integer;
  base: PtrUInt;
begin
  if Count <= 0 then Exit(true);
  if not IsOpen then
  begin
    FLastError := 'port not open';
    Exit(false);
  end;

  base := PtrUInt(@Buffer);
  sent := 0;
  while sent < Count do
  begin
    written := FSerial.SendBuffer(Pointer(base + PtrUInt(sent)), Count - sent);
    //Bytes out is the only measure of success: synaser folds ClearCommError's
    //mask, which carries receive side conditions too, into LastError.
    if written > 0 then
    begin
      Inc(sent, written);
      Continue;
    end;
    if FSerial.LastError <> 0 then Exit(Fail('write failed'));
    Exit(Fail('write timed out after ' + IntToStr(sent) + '/' + IntToStr(Count) + ' bytes'));
  end;
  result := true;
end;

function TBP5Port.ReadFrame(out Frame: TBytes; TimeoutMs: integer): boolean;
var
  buf: array[0..1023] of byte;
  got, avail, i, len, skipped: integer;
  deadline, hardDeadline: QWord;
begin
  SetLength(Frame, 0);
  len := 0;
  if not IsOpen then
  begin
    FLastError := 'port not open';
    Exit(false);
  end;
  if TimeoutMs < 50 then TimeoutMs := 50;

  deadline := GetTickCount64 + QWord(TimeoutMs);

  //The deadline above restarts on every byte, so a device that trickles a long
  //answer is not cut off half way. On its own that bounds nothing: a stuck-low
  //line or a break condition delivers a continuous stream of 0x00, which keeps
  //restarting it, and every byte is thrown away below as a leading delimiter
  //without growing the frame. This runs on the GUI thread with no message pump
  //and no cancel, so that is a hard freeze, reachable by choosing any port that
  //is not a Bus Pirate. A second deadline that nothing restarts, and a cap on
  //the delimiters thrown away, end the read.  By Dreg
  hardDeadline := GetTickCount64 + QWord(TimeoutMs) * 4 + 2000;
  skipped := 0;

  while (GetTickCount64 < deadline) and (GetTickCount64 < hardDeadline) do
  begin
    //Anything left over from the previous frame comes first.
    if Length(FResidual) > 0 then
    begin
      got := Length(FResidual);
      if got > SizeOf(buf) then got := SizeOf(buf);
      Move(FResidual[0], buf[0], got);
      if got < Length(FResidual) then
      begin
        Move(FResidual[got], FResidual[0], Length(FResidual) - got);
        SetLength(FResidual, Length(FResidual) - got);
      end
      else
        SetLength(FResidual, 0);
    end
    else
    begin
    //Read what has actually arrived, never a fixed block. RecvBufferEx waits
    //for the full count it is given, so asking for a buffer-sized chunk makes
    //every response pay the whole inter-byte timeout after its last byte: a
    //7 ms round trip takes 47 ms.
    avail := FSerial.WaitingDataEx;
    if avail > SizeOf(buf) then avail := SizeOf(buf);
    if avail > 0 then
      got := FSerial.RecvBufferEx(@buf[0], avail, 50)
    else
      //Nothing yet: block on the first byte only, so the wait is the device's
      //latency and not a timeout.
      got := FSerial.RecvBufferEx(@buf[0], 1, 20);
    end;
    if got <= 0 then Continue;

    deadline := GetTickCount64 + QWord(TimeoutMs);
    for i := 0 to got - 1 do
    begin
      if buf[i] = 0 then
      begin
        //Leading delimiters from a previous frame are noise, but a stream of
        //nothing else means the wrong port or a broken line.
        if len = 0 then
        begin
          Inc(skipped);
          if skipped > BP5_MAX_COBS then
            Exit(Fail('the port is sending a continuous stream of frame ' +
                      'delimiters and nothing else, which is not a Bus Pirate ' +
                      'in BPIO2 mode'));
          Continue;
        end;
        //Anything after the delimiter belongs to the next frame and has to be
        //kept: these bytes are already out of the serial driver.
        if i < got - 1 then
        begin
          SetLength(FResidual, got - 1 - i);
          Move(buf[i + 1], FResidual[0], got - 1 - i);
        end;
        SetLength(Frame, len);
        Exit(true);
      end;
      if len >= BP5_MAX_COBS then
        Exit(Fail('COBS frame longer than ' + IntToStr(BP5_MAX_COBS) + ' bytes'));
      if len >= Length(Frame) then SetLength(Frame, len + 512);
      Frame[len] := buf[i];
      Inc(len);
    end;
  end;

  SetLength(Frame, 0);
  result := Fail('no answer within ' + IntToStr(TimeoutMs) + ' ms (' +
                 IntToStr(len) + ' bytes seen, no frame delimiter)');
end;

procedure TBP5Port.Purge;
begin
  //The residual belongs to the bytes being discarded, or a purge would not
  //start the next request clean.
  SetLength(FResidual, 0);
  if IsOpen then FSerial.Purge;
end;

function TBP5Port.BytesWaiting: integer;
begin
  if IsOpen then
    result := FSerial.WaitingDataEx
  else
    result := 0;
end;

function TBP5Port.Drain(IdleMs, MaxMs: integer): integer;
var
  buf: array[0..1023] of byte;
  got: integer;
  deadline, quiet: QWord;
begin
  result := 0;
  if not IsOpen then Exit;

  deadline := GetTickCount64 + QWord(MaxMs);
  quiet := GetTickCount64 + QWord(IdleMs);
  while (GetTickCount64 < deadline) and (GetTickCount64 < quiet) do
  begin
    got := FSerial.RecvBufferEx(@buf[0], SizeOf(buf), 20);
    if got > 0 then
    begin
      Inc(result, got);
      quiet := GetTickCount64 + QWord(IdleMs);
    end;
  end;
end;

//COBS

function BP5CobsEncode(const Src: TBytes): TBytes;
var
  i, codePos, code, outLen: integer;

  procedure Put(B: byte);
  begin
    if outLen >= Length(result) then SetLength(result, outLen + 256);
    result[outLen] := B;
    Inc(outLen);
  end;

begin
  SetLength(result, Length(Src) + Length(Src) div 254 + 2);
  outLen := 0;
  codePos := 0;
  Put(0);             //placeholder for the first code byte
  code := 1;

  for i := 0 to High(Src) do
  begin
    if Src[i] <> 0 then
    begin
      Put(Src[i]);
      Inc(code);
      if code < 255 then Continue;
    end;
    //Either a zero, which the code byte stands in for, or a full 254 byte run.
    result[codePos] := byte(code);
    codePos := outLen;
    Put(0);
    code := 1;
  end;

  result[codePos] := byte(code);
  SetLength(result, outLen);
end;

function BP5CobsDecode(const Src: TBytes; out Dst: TBytes): boolean;
var
  i, k, n, outLen, code: integer;
begin
  SetLength(Dst, Length(Src));
  outLen := 0;
  i := 0;
  while i < Length(Src) do
  begin
    code := Src[i];
    //A zero inside a frame is impossible: it is the delimiter.
    if code = 0 then
    begin
      SetLength(Dst, 0);
      Exit(false);
    end;
    Inc(i);
    n := code - 1;
    if i + n > Length(Src) then
    begin
      SetLength(Dst, 0);
      Exit(false);
    end;
    if n > 0 then
    begin
      //Wire data is untrusted. A zero inside a block cannot come from a COBS
      //encoder, so the framing is broken and the frame must be refused rather
      //than silently turned into something plausible.
      for k := 0 to n - 1 do
        if Src[i + k] = 0 then
        begin
          SetLength(Dst, 0);
          Exit(false);
        end;
      Move(Src[i], Dst[outLen], n);
      Inc(outLen, n);
      Inc(i, n);
    end;
    //A code of 255 means a full run with no implied zero after it, and a code
    //that ends the frame has no zero after it either.
    if (code < 255) and (i < Length(Src)) then
    begin
      Dst[outLen] := 0;
      Inc(outLen);
    end;
  end;
  SetLength(Dst, outLen);
  result := true;
end;

//FlatBuffers: little endian helpers and the generic decoder

//Bounds checks throughout this decoder subtract from the buffer length and
//never add to a wire-supplied offset: the offsets come from untrusted data,
//and on a release build with overflow checking off, "Pos + 3 < Length(B)"
//wraps to a passing comparison for a large Pos and then reads wild memory.
function GetU8(const B: TBytes; Pos: integer; out V: byte): boolean;
begin
  result := (Pos >= 0) and (Pos < Length(B));
  if result then V := B[Pos] else V := 0;
end;

function GetU16(const B: TBytes; Pos: integer; out V: word): boolean;
begin
  result := (Pos >= 0) and (Length(B) >= 2) and (Pos <= Length(B) - 2);
  if result then V := B[Pos] or (word(B[Pos + 1]) shl 8) else V := 0;
end;

function GetU32(const B: TBytes; Pos: integer; out V: LongWord): boolean;
begin
  result := (Pos >= 0) and (Length(B) >= 4) and (Pos <= Length(B) - 4);
  if result then
    V := LongWord(B[Pos]) or (LongWord(B[Pos + 1]) shl 8) or
         (LongWord(B[Pos + 2]) shl 16) or (LongWord(B[Pos + 3]) shl 24)
  else
    V := 0;
end;

function GetI32(const B: TBytes; Pos: integer; out V: longint): boolean;
var
  u: LongWord;
begin
  result := GetU32(B, Pos, u);
  V := longint(u);
end;

procedure PutU16(var B: TBytes; Pos: integer; V: word);
begin
  B[Pos] := V and $FF;
  B[Pos + 1] := (V shr 8) and $FF;
end;

procedure PutU32(var B: TBytes; Pos: integer; V: LongWord);
begin
  B[Pos] := V and $FF;
  B[Pos + 1] := (V shr 8) and $FF;
  B[Pos + 2] := (V shr 16) and $FF;
  B[Pos + 3] := (V shr 24) and $FF;
end;

//Position of a field inside a table, or 0 when the field is absent, which in
//FlatBuffers means "equal to its schema default", never "not reported".
function FieldPos(const B: TBytes; Table, Slot: integer): integer;
var
  soff: longint;
  vt, vtsize: integer;
  vs, vo: word;
begin
  result := 0;
  if (Table < 0) or (Length(B) < 4) or (Table > Length(B) - 4) then Exit;
  //Signed: flatcc emits vtables after their tables, so this is often negative.
  if not GetI32(B, Table, soff) then Exit;
  vt := Table - soff;
  if (vt < 0) or (vt > Length(B) - 4) then Exit;
  if not GetU16(B, vt, vs) then Exit;
  vtsize := vs;
  //Trailing empty slots are dropped from the vtable entirely.
  if (4 + 2 * Slot) >= vtsize then Exit;
  if not GetU16(B, vt + 4 + 2 * Slot, vo) then Exit;
  if vo = 0 then Exit;
  result := Table + vo;
  if (result < 0) or (result >= Length(B)) then result := 0;
end;

//Follows a uoffset at Pos and returns what it points at.
function Deref(const B: TBytes; Pos: integer): integer;
var
  u: LongWord;
begin
  result := 0;
  if Pos <= 0 then Exit;
  if not GetU32(B, Pos, u) then Exit;
  result := Pos + integer(u);
  if (result < 0) or (result >= Length(B)) then result := 0;
end;

function FieldU8(const B: TBytes; Table, Slot: integer; Default: byte = 0): byte;
var
  p: integer;
begin
  p := FieldPos(B, Table, Slot);
  if (p = 0) or (not GetU8(B, p, result)) then result := Default;
end;

function FieldBool(const B: TBytes; Table, Slot: integer; Default: boolean = false): boolean;
var
  p: integer;
  v: byte;
begin
  p := FieldPos(B, Table, Slot);
  if (p = 0) or (not GetU8(B, p, v)) then Exit(Default);
  result := v <> 0;
end;

function FieldU16(const B: TBytes; Table, Slot: integer; Default: word = 0): word;
var
  p: integer;
begin
  p := FieldPos(B, Table, Slot);
  if (p = 0) or (not GetU16(B, p, result)) then result := Default;
end;

function FieldU32(const B: TBytes; Table, Slot: integer; Default: LongWord = 0): LongWord;
var
  p: integer;
begin
  p := FieldPos(B, Table, Slot);
  if (p = 0) or (not GetU32(B, p, result)) then result := Default;
end;

function FieldStr(const B: TBytes; Table, Slot: integer): string;
var
  p, sp, i: integer;
  n: LongWord;
begin
  result := '';
  p := FieldPos(B, Table, Slot);
  if p = 0 then Exit;
  sp := Deref(B, p);
  if sp = 0 then Exit;
  if not GetU32(B, sp, n) then Exit;
  //Unsigned comparison against the space that is left. GetU32 succeeding
  //already proves sp + 4 <= Length(B), so this cannot wrap. A signed cast here
  //would let any length above $7FFFFFFF through.
  if (n = 0) or (n > LongWord(Length(B) - sp - 4)) or (n > BP5_MAX_PACKET) then Exit;
  SetLength(result, n);
  for i := 1 to integer(n) do
    result[i] := Chr(B[sp + 3 + i]);
end;

//Vector of strings, joined with a separator: the GUI never needs them apart.
function FieldStrList(const B: TBytes; Table, Slot: integer; const Sep: string): string;
var
  p, sp, i, ep, strp, j: integer;
  n, sn: LongWord;
  s: string;
begin
  result := '';
  p := FieldPos(B, Table, Slot);
  if p = 0 then Exit;
  sp := Deref(B, p);
  if sp = 0 then Exit;
  if not GetU32(B, sp, n) then Exit;
  //Each element is a four byte offset to its string, so this is what fits.
  if n > LongWord((Length(B) - sp - 4) div 4) then Exit;
  if n > 64 then n := 64;
  for i := 0 to integer(n) - 1 do
  begin
    ep := sp + 4 + i * 4;
    strp := Deref(B, ep);
    if strp = 0 then Continue;
    if not GetU32(B, strp, sn) then Continue;
    if (sn = 0) or (sn > LongWord(Length(B) - strp - 4)) or (sn > BP5_MAX_PACKET) then Continue;
    SetLength(s, sn);
    for j := 1 to integer(sn) do
      s[j] := Chr(B[strp + 3 + j]);
    if result = '' then result := s else result := result + Sep + s;
  end;
end;

//Vector of ubyte. The result tells an empty vector (true) from an absent one.
function FieldBytes(const B: TBytes; Table, Slot: integer; out Data: TBytes): boolean;
var
  p, sp: integer;
  n: LongWord;
begin
  SetLength(Data, 0);
  p := FieldPos(B, Table, Slot);
  if p = 0 then Exit(false);
  sp := Deref(B, p);
  if sp = 0 then Exit(false);
  if not GetU32(B, sp, n) then Exit(false);
  //The same unsigned check as in FieldStr, and here it guards a Move.
  if (n > LongWord(Length(B) - sp - 4)) or (n > BP5_MAX_PACKET) then Exit(false);
  SetLength(Data, n);
  if n > 0 then Move(B[sp + 4], Data[0], n);
  result := true;
end;

//Request templates

//StatusRequest with no query vector, which the firmware reads as "all".
const
  TPL_STATUS_ALL: array[0..35] of byte = (
    $14, $00, $00, $00, $0C, $00, $0C, $00, $04, $00, $06, $00, $05, $00, $08, $00,
    $04, $00, $04, $00, $10, $00, $00, $00, $02, $01, $00, $00, $04, $00, $00, $00,
    $10, $00, $00, $00);

//StatusRequest([Version, PSU]): the connect probe and the liveness check.
//It leaves out the mode list, which is most of the "all" answer and grows
//with every mode the firmware gains. It brings back the supply state, so a
//current limit that tripped mid-session shows at the next check. Byte 49 is
//the second query: 4 = PSU.
  TPL_STATUS_VP: array[0..51] of byte = (
    $18, $00, $00, $00, $0C, $00, $0C, $00, $04, $00, $06, $00, $05, $00, $08, $00,
    $06, $00, $08, $00, $04, $00, $00, $00, $14, $00, $00, $00, $02, $01, $00, $00,
    $04, $00, $00, $00, $14, $00, $00, $00, $04, $00, $00, $00, $02, $00, $00, $00,
    $01, $04, $00, $00);

//DataRequest, fixed 64 byte prefix; the write vector is appended.
//  48 start_main   49 start_alt   50 stop_main   51 stop_alt
//  52 bytes_read (u16)            60 vector count (u32)
  TPL_DATA: array[0..63] of byte = (
    $20, $00, $00, $00,
    $0C, $00, $0C, $00, $04, $00, $06, $00, $05, $00, $08, $00,
    $10, $00, $10, $00, $04, $00, $05, $00, $0C, $00, $08, $00, $06, $00, $07, $00,
    $1C, $00, $00, $00,
    $02, $03, $00, $00,
    $04, $00, $00, $00,
    $1C, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $04, $00, $00, $00,
    $00, $00, $00, $00);

//ConfigurationRequest + nested ModeConfiguration, 116 byte prefix; the mode
//name is appended as a length prefixed, NUL terminated string.
//   88 psu_set_mv (u32)   92 psu_set_ma (u16)  94 bitorder_msb  95 bitorder_lsb
//   96 psu_disable  97 psu_enable  98 pullup_disable  99 pullup_enable
//  104 speed (u32)  108 data_bits  109 clock_stretch  110 cpol  111 cpha
//  112 chip_select_idle
  TPL_CONFIG: array[0..115] of byte = (
    $40, $00, $00, $00,
    $0C, $00, $0C, $00, $04, $00, $06, $00, $05, $00, $08, $00,
    $18, $00, $18, $00, $04, $00, $08, $00, $12, $00, $13, $00,
    $14, $00, $15, $00, $0C, $00, $10, $00, $16, $00, $17, $00,
    $18, $00, $10, $00, $04, $00, $08, $00, $00, $00, $00, $00,
    $00, $00, $00, $00, $09, $00, $0A, $00, $0B, $00, $0C, $00,
    $3C, $00, $00, $00,
    $02, $02, $00, $00,
    $04, $00, $00, $00,
    $3C, $00, $00, $00,
    $24, $00, $00, $00,
    $10, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $3C, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00);

//TBusPirate5

constructor TBusPirate5.Create;
begin
  inherited Create;
  FPort := TBP5Port.Create;
  FMode := bp5Closed;
  SetLength(FPending, 8192);
  FPendingLen := 0;
end;

destructor TBusPirate5.Destroy;
begin
  Close;
  FPort.Free;
  inherited Destroy;
end;

procedure TBusPirate5.Log(Level: TBP5LogLevel; const Msg: string);
begin
  if (Level = bp5lDebug) and (not FVerbose) then Exit;
  if Assigned(FOnLog) then FOnLog(Level, Msg);
end;

function TBusPirate5.SetError(const Msg: string): boolean;
begin
  FLastError := Msg;
  FLastErrorLogged := true;
  Log(bp5lError, 'BusPirateV5+: ' + Msg);
  result := false;
end;

procedure TBusPirate5.MarkDesynced(const Why: string);
begin
  if FDesynced or FRecovering then Exit;
  FDesynced := true;
  FRefusalLogged := false;
  FPendingLen := 0;
  //The log line does not say when the link is re-armed: DevOpen and ReadyLink
  //do it in the same call when their own status read is the request that
  //failed.
  Log(bp5lInfo, 'BusPirateV5+: link out of sync (' + Why + ')');
end;

//The firmware's psu_enable switches the supply off and on again, then waits
//10 ms, and 500 ms more with a current limit (psu.c), so every request with
//psu_enable restarts the target. Off costs nothing and is always sent.
function TBusPirate5.PsuActionFor(Power: boolean; Mv, Ma: LongWord): TBP5PsuAction;
begin
  if not Power then
    result := bp5psuOff
  else if FPsuKnown and FPsuOn and (FPsuMv = Mv) and (FPsuMa = Ma) then
    result := bp5psuLeave
  else
    result := bp5psuOn;
end;

procedure TBusPirate5.NotePsuApplied(Action: TBP5PsuAction; Power: boolean;
  Mv, Ma: LongWord);
begin
  if Action = bp5psuLeave then Exit;
  FPsuKnown := true;
  FPsuOn := Power;
  FPsuMv := Mv;
  FPsuMa := Ma;
  //The next status read records what the device made of the request.
  FPsuRefKnown := false;
  FPsuChanged := false;
  FSupplyMayBeOn := Power;
end;

//Every status read asks for the supply, and this compares it with what this
//session set: the firmware cuts the supply when the current limit trips, and
//the terminal port stays usable while BPIO2 runs. VOUT is checked here
//because BPIO2 asks for no undervoltage check (100 %, bpio.c).
procedure TBusPirate5.CheckPsu;
begin
  FSupplyMayBeOn := FStatus.PsuEnabled;
  if not FPsuKnown then Exit;
  if not FPsuOn then
  begin
    if not FStatus.PsuEnabled then Exit;
    FPsuChangeWhy := 'the target supply was switched on outside this program';
  end
  else if FStatus.PsuError then
    FPsuChangeWhy := 'the current limit tripped and the Bus Pirate cut the target supply'
  else if not FStatus.PsuEnabled then
    FPsuChangeWhy := 'the target supply was switched off outside this program'
  else
  begin
    if not FPsuRefKnown then
    begin
      FPsuRefKnown := true;
      FPsuRefMv := FStatus.PsuSetMv;
      FPsuRefMa := FStatus.PsuSetMa;
    end;
    if (Abs(int64(FStatus.PsuSetMv) - int64(FPsuRefMv)) > BP5_PSU_MV_SLACK) or
       (FStatus.PsuSetMa <> FPsuRefMa) then
      FPsuChangeWhy := Format('the target supply was set to %d mV, %d mA outside this program',
                              [FStatus.PsuSetMv, FStatus.PsuSetMa])
    else if int64(FStatus.PsuMeasMv) * 100 < int64(FStatus.PsuSetMv) * BP5_PSU_MIN_PERCENT then
    begin
      FPsuChangeWhy := Format('the target supply measures %d mV, under %d %% of the %d mV ' +
                              'set (a short or a heavy load)',
                              [FStatus.PsuMeasMv, BP5_PSU_MIN_PERCENT, FStatus.PsuSetMv]);
      FPsuChanged := true;
      FPsuSagging := true;
      Exit;
    end
    else
      Exit;
  end;
  FPsuChanged := true;
  FPsuSagging := false;
  FPsuKnown := false;
end;

function TBusPirate5.GetPsuOn: boolean;
begin
  result := FPsuKnown and FPsuOn;
end;

procedure TBusPirate5.ClearPsuChanged;
begin
  FPsuChanged := false;
  FPsuSagging := false;
  FPsuChangeWhy := '';
end;

function TBusPirate5.IsOpen: boolean;
begin
  result := FPort.IsOpen and (FMode <> bp5Closed);
end;

const
  BP5_REFUSED_MSG = 'the link is out of sync after a failed transfer; it must be re-armed first';

function TBusPirate5.Transact(const Request: TBytes; WantType: byte;
  out Response: TBytes; out BodyPos: integer; TimeoutMs: integer): boolean;
var
  frame, raw: TBytes;
  root: LongWord;
  rp, ct, skipped, left: integer;
  deadline: QWord;
  outerErr, innerErr, staleErr: string;
begin
  SetLength(Response, 0);
  BodyPos := 0;

  //The refusal is logged once per out of sync episode: an I2C busy poll asks
  //again with no pause for 5 s, and every answer would be the same line.
  if FDesynced and (not FRecovering) then
  begin
    if FRefusalLogged then
    begin
      FLastError := BP5_REFUSED_MSG;
      FLastErrorLogged := true;
      Exit(false);
    end;
    FRefusalLogged := true;
    Exit(SetError(BP5_REFUSED_MSG));
  end;

  frame := BP5CobsEncode(Request);
  SetLength(frame, Length(frame) + 1);
  frame[High(frame)] := 0;              //the delimiter

  FPort.Purge;
  if not FPort.WriteAll(frame[0], Length(frame)) then
  begin
    SetError(FPort.LastError);
    //Part of the frame may have gone out, and the port of a Bus Pirate that
    //was unplugged and plugged back in fails every write: either way the link
    //has to be re-armed, or the port opened again, before the next request.
    MarkDesynced('write failed');
    Exit(false);
  end;

  //A frame that cannot be the answer to this request is thrown away, or one
  //stray packet desynchronises every operation that follows. The device may
  //still be answering another program, line noise or the tail of a session
  //that died. Keep reading until the deadline.
  deadline := GetTickCount64 + QWord(TimeoutMs);
  staleErr := '';
  skipped := 0;

  repeat
    //One deadline for the whole call: a fresh window for every discarded
    //frame would hold the GUI thread far past the timeout, with no way out.
    left := integer(int64(deadline) - int64(GetTickCount64));
    if (left <= 0) or (skipped > 8) then
    begin
      if staleErr <> '' then
        //The device did answer, and the stream is in step; this is its error,
        //not a lost frame, so the link must not be marked desynchronised.
        Exit(SetError('device refused the request: ' + staleErr));
      MarkDesynced('no matching response within the timeout');
      Exit(SetError('the device did not answer this request'));
    end;

    if not FPort.ReadFrame(frame, left) then
    begin
      if staleErr <> '' then
        Exit(SetError('device refused the request: ' + staleErr));
      MarkDesynced('no response frame');
      Exit(SetError(FPort.LastError));
    end;

    if not BP5CobsDecode(frame, raw) then
    begin
      MarkDesynced('COBS decode failed');
      Exit(SetError('malformed COBS frame from the device'));
    end;

    if not GetU32(raw, 0, root) then
    begin
      MarkDesynced('response too short');
      Exit(SetError('truncated response packet'));
    end;
    rp := integer(root);
    if (rp <= 0) or (rp >= Length(raw)) then
    begin
      MarkDesynced('bad root offset');
      Exit(SetError('response packet has a bad root offset'));
    end;

    //Two independent error channels; both have to be checked.
    outerErr := FieldStr(raw, rp, BP5_RP_ERROR);
    ct := FieldU8(raw, rp, BP5_RP_CONTENTS_TYPE, 0);

    if outerErr <> '' then
    begin
      //Almost always this is the answer: the firmware reports version and
      //validation problems this way. It is only worth looking past it once,
      //in case it belongs to something that was already in the pipe, and the
      //grace window for that is short.
      if staleErr <> '' then
        Exit(SetError('device refused the request: ' + outerErr));
      staleErr := outerErr;
      Inc(skipped);
      if deadline > GetTickCount64 + 400 then deadline := GetTickCount64 + 400;
      Log(bp5lDebug, 'BusPirateV5+: device error frame ("' + outerErr +
                     '"), checking briefly for a later answer');
      Continue;
    end;

    if ct <> WantType then
    begin
      Inc(skipped);
      Log(bp5lInfo, 'BusPirateV5+: discarding a stale response of type ' + IntToStr(ct) +
                    ' while waiting for type ' + IntToStr(WantType));
      Continue;
    end;

    BodyPos := Deref(raw, FieldPos(raw, rp, BP5_RP_CONTENTS));
    if BodyPos = 0 then
      Exit(SetError('response has no contents table'));

    //Unsolicited data the device pushed on its own is never an answer.
    if (WantType = BP5_RSP_DATA) and FieldBool(raw, BodyPos, BP5_DR_IS_ASYNC) then
    begin
      Inc(skipped);
      Log(bp5lInfo, 'BusPirateV5+: discarding an unsolicited data packet');
      Continue;
    end;

    //Every response table happens to carry its own error in slot 0.
    innerErr := FieldStr(raw, BodyPos, 0);
    if innerErr <> '' then
    begin
      //The device refusing a request is not a transport failure, and for an
      //I2C probe or an acknowledge poll it is the expected answer. Record it
      //without writing an error line, or a 112 address bus scan leaves 110 of
      //them in the log. Framing, timeout and desync failures go through
      //SetError and are logged.  By Dreg
      FLastError := innerErr;
      FLastErrorLogged := false;
      Exit(false);
    end;

    if skipped > 0 then
      Log(bp5lInfo, 'BusPirateV5+: link resynchronised after ' + IntToStr(skipped) +
                    ' stray frame(s)');
    Response := raw;
    Exit(true);
  until false;
end;

function TBusPirate5.EncodeStatus(Quick: boolean): TBytes;
begin
  if Quick then
  begin
    SetLength(result, Length(TPL_STATUS_VP));
    Move(TPL_STATUS_VP[0], result[0], Length(result));
  end
  else
  begin
    SetLength(result, Length(TPL_STATUS_ALL));
    Move(TPL_STATUS_ALL[0], result[0], Length(result));
  end;
end;

function TBusPirate5.EncodeData(StartMain, StopMain: boolean; BytesRead: word;
  WritePtr: Pointer; WriteCount: integer): TBytes;
var
  total: integer;
begin
  SetLength(result, 0);
  if WriteCount < 0 then WriteCount := 0;

  //Guards against three requests the firmware mishandles. These are internal
  //errors, not user errors: nothing must ever construct such a packet.
  if BytesRead > BP5_MAX_READ then
    raise Exception.CreateFmt('BPIO2: bytes_read %d exceeds %d', [BytesRead, BP5_MAX_READ]);
  if WriteCount > BP5_MAX_WRITE then
    raise Exception.CreateFmt('BPIO2: data_write %d exceeds %d', [WriteCount, BP5_MAX_WRITE]);
  //An I2C read that opens with a start makes the firmware read data_write[0]
  //to build the read address, without checking that the vector is there. It
  //is refused in every mode.
  if StartMain and (BytesRead > 0) and (WriteCount < 1) then
    raise Exception.Create('BPIO2: a read with a start needs at least one write byte');

  total := Length(TPL_DATA) + WriteCount;
  while (total mod 4) <> 0 do Inc(total);
  SetLength(result, total);
  FillChar(result[0], total, 0);
  Move(TPL_DATA[0], result[0], Length(TPL_DATA));

  if StartMain then result[48] := 1;
  if StopMain then result[50] := 1;
  PutU16(result, 52, BytesRead);
  PutU32(result, 60, LongWord(WriteCount));
  if (WriteCount > 0) and (WritePtr <> nil) then
    Move(PByte(WritePtr)^, result[64], WriteCount);
end;

function TBusPirate5.EncodeConfig(const AMode: string; SpeedHz: LongWord;
  DataBits: byte; ClockStretch, ClockPolarity, ClockPhase,
  ChipSelectIdle: boolean; SetBitorderMsb: boolean;
  Psu: TBP5PsuAction; PsuMv: LongWord; PsuMa: word; Pullups: boolean): TBytes;
var
  total, n, i: integer;
begin
  n := Length(AMode);
  //4 byte length, the chars, a NUL the firmware's strcasecmp needs, then pad.
  total := Length(TPL_CONFIG) + 4 + n + 1;
  while (total mod 4) <> 0 do Inc(total);
  SetLength(result, total);
  FillChar(result[0], total, 0);
  Move(TPL_CONFIG[0], result[0], Length(TPL_CONFIG));

  PutU32(result, 88, PsuMv);
  PutU16(result, 92, PsuMa);
  if SetBitorderMsb then result[94] := 1;
  //The firmware reads mV and mA only with psu_enable, and with neither flag
  //it leaves the supply as it is.
  case Psu of
    bp5psuOn:    result[97] := 1;
    bp5psuOff:   result[96] := 1;
    bp5psuLeave: ;
  end;
  if Pullups then result[99] := 1 else result[98] := 1;

  PutU32(result, 104, SpeedHz);
  result[108] := DataBits;
  if ClockStretch then result[109] := 1;
  if ClockPolarity then result[110] := 1;
  if ClockPhase then result[111] := 1;
  if ChipSelectIdle then result[112] := 1;

  PutU32(result, 116, LongWord(n));
  for i := 1 to n do
    result[119 + i] := byte(Ord(AMode[i]));
end;

function TBusPirate5.ReadStatus(Quick: boolean): boolean;
var
  raw: TBytes;
  body: integer;
begin
  FStatus.Valid := false;
  if not Transact(EncodeStatus(Quick), BP5_RSP_STATUS, raw, body, 2500) then
    Exit(false);

  FStatus.FbMajor := FieldU8(raw, body, BP5_SR_FB_MAJOR);
  FStatus.FbMinor := FieldU16(raw, body, BP5_SR_FB_MINOR);
  FStatus.HwMajor := FieldU8(raw, body, BP5_SR_HW_MAJOR);
  FStatus.HwMinor := FieldU8(raw, body, BP5_SR_HW_MINOR);
  FStatus.PsuEnabled := FieldBool(raw, body, BP5_SR_PSU_ENABLED);
  FStatus.PsuSetMv := FieldU32(raw, body, BP5_SR_PSU_SET_MV);
  FStatus.PsuSetMa := FieldU32(raw, body, BP5_SR_PSU_SET_MA);
  FStatus.PsuMeasMv := FieldU32(raw, body, BP5_SR_PSU_MEAS_MV);
  FStatus.PsuMeasMa := FieldU32(raw, body, BP5_SR_PSU_MEAS_MA);
  FStatus.PsuError := FieldBool(raw, body, BP5_SR_PSU_ERROR);

  //The quick read leaves the rest as the last full read found it.
  if not Quick then
  begin
    FStatus.ModeCurrent := FieldStr(raw, body, BP5_SR_MODE_CURRENT);
    FStatus.GitHash := FieldStr(raw, body, BP5_SR_GIT_HASH);
    FStatus.FwDate := FieldStr(raw, body, BP5_SR_FW_DATE);
    FStatus.Modes := FieldStrList(raw, body, BP5_SR_MODES, ', ');
    FStatus.MaxPacket := FieldU32(raw, body, BP5_SR_MAX_PACKET);
    FStatus.MaxWrite := FieldU32(raw, body, BP5_SR_MAX_WRITE);
    FStatus.MaxRead := FieldU32(raw, body, BP5_SR_MAX_READ);
    FStatus.PullupEnabled := FieldBool(raw, body, BP5_SR_PULLUP_ENABLED);
    //Absent means the schema default, which is 0, and 0 is not a usable
    //limit, so fall back to the built-in copies of the firmware's constants.
    if FStatus.MaxPacket = 0 then FStatus.MaxPacket := BP5_MAX_PACKET;
    if FStatus.MaxWrite = 0 then FStatus.MaxWrite := BP5_MAX_WRITE;
    if FStatus.MaxRead = 0 then FStatus.MaxRead := BP5_MAX_READ;
  end;

  CheckPsu;
  FStatus.Valid := true;
  result := true;
end;

function TBusPirate5.Open(const APortName: string; ABaudRate: LongWord): boolean;
var
  saved: integer;
  ok: boolean;
begin
  Close;
  if ABaudRate = 0 then ABaudRate := BP5_BAUD_DEFAULT;
  if not FPort.Open(APortName, ABaudRate) then Exit(SetError(FPort.LastError));

  //Anything left over from a previous session, or from whatever binmode was
  //running before, has to go before the first request.
  FPort.Drain(60, 400);
  FPort.Purge;

  FMode := bp5Unknown;
  FDesynced := false;

  //A device that is not in BPIO2 binmode either says nothing or answers with
  //something that is not a ResponsePacket. Either way it is not a port problem.
  //This first write gets the short timeout of the park writes: a Bus Pirate
  //left in SUMP takes no more bytes after one request, and the default write
  //timeout would hold the program for 15 s before this message.  By Dreg
  saved := FPort.WriteTimeoutMs;
  FPort.WriteTimeoutMs := BPSER_PARK_WRITE_MS;
  try
    ok := ReadStatus(true);
  finally
    FPort.WriteTimeoutMs := saved;
  end;
  if not ok then
  begin
    FPort.Close;
    FMode := bp5Closed;
    //With the port closed there is no link to re-arm: the next DevOpen
    //connects again, and must not say a transfer failed.
    FDesynced := false;
    Exit(SetError('no BPIO2 answer on ' + APortName + '. ' +
      'On the Bus Pirate terminal port run "binmode", choose "BPIO2 flatbuffer ' +
      'interface" and answer y to "Save setting?". The factory default is the ' +
      'SUMP logic analyser, which uses the same port and will not answer here.'));
  end;

  //The full status, the limits included. The probe already answered, so a
  //failure here is not fatal, but it is logged: the limits then fall back to
  //the built-in ones.
  if not ReadStatus(false) then
  begin
    Log(bp5lInfo, 'BusPirateV5+: full status read failed (' + FLastError +
                  '), using the built-in limits');

    //FDesynced must not stay set. The probe proved the link, and this read is
    //the larger one (it has the mode list), so it is the one that times out on
    //a slow or noisy link. Left set, FDesynced makes Open return true and the
    //guard refuse the next request, and nothing re-arms the link: DevOpen and
    //ReadyLink run Resync only before Connect.  By Dreg
    FPort.Purge;
    FDesynced := false;
    FPendingLen := 0;
  end;

  Log(bp5lInfo, Format('BusPirateV5+: Bus Pirate %d REV%d on %s, firmware %s',
      [FStatus.HwMajor, FStatus.HwMinor, APortName, FStatus.FwDate]));
  result := true;
end;

procedure TBusPirate5.Close;
begin
  if FPort.IsOpen then FPort.Close;
  FMode := bp5Closed;
  FPendingLen := 0;
  FCSAsserted := false;
  FStopAlreadySent := false;
  FDesynced := false;
  FRecovering := false;
  FRefusalLogged := false;
  //The next session does not know what the supply was set to, so its first
  //configuration sets it again: Off, or On, which restarts the target.
  //FSupplyMayBeOn stays: nothing here switched the supply off.
  FPsuKnown := false;
  ClearPsuChanged;
  //Finalize first: the record holds four AnsiStrings, and zeroing their
  //pointers without dropping the references orphans the heap blocks.
  Finalize(FStatus);
  FillChar(FStatus, SizeOf(FStatus), 0);
end;

function TBusPirate5.Ping: boolean;
begin
  if not FPort.IsOpen then Exit(false);
  if FDesynced then Exit(false);
  if FPendingLen > 0 then Exit(false);
  result := ReadStatus(true);
end;

function TBusPirate5.Resync: boolean;
var
  junk, saved: integer;
  ok: boolean;
  delim: byte;
begin
  //Always runs, even when nothing has been flagged: the caller may know the
  //link is dirty for a reason this object never saw.
  if not FPort.IsOpen then Exit(false);

  FRecovering := true;
  try
    //First close whatever half a frame the device may still be accumulating.
    //On an idle device a lone delimiter does no harm: the drain that follows
    //throws away any answer. The firmware drops an unfinished frame 500 ms
    //after its first byte (bpio.c), and until then it appends a new request to
    //the broken frame and rejects both.
    delim := 0;
    //One byte needs no more than the park timeout: a device that takes no
    //bytes would hold it for the whole default write timeout.
    saved := FPort.WriteTimeoutMs;
    FPort.WriteTimeoutMs := BPSER_PARK_WRITE_MS;
    try
      ok := FPort.WriteAll(delim, 1);
    finally
      FPort.WriteTimeoutMs := saved;
    end;
    if not ok then
    begin
      //A port that takes no byte at all cannot be re-armed: the device behind
      //it went away (a Bus Pirate unplugged and plugged back in, which only
      //opening the port again reaches) or stopped reading. The drain would
      //only wait, and a status write would fail the same way: both only delay
      //the reopen.  By Dreg
      FLastError := 'the port takes no writes: ' + FPort.LastError;
      FLastErrorLogged := false;
    end
    else
    begin
      //Then wait for it to finish answering (any error for that broken frame,
      //or a reply Transact gave up on) and throw all of it away. The reply to a
      //512 byte read can still be on its way.
      junk := FPort.Drain(300, 5000);
      FPort.Purge;
      if junk > 0 then
        Log(bp5lInfo, 'BusPirateV5+: discarded ' + IntToStr(junk) +
                      ' late byte(s) from the aborted transfer');
      FPendingLen := 0;
      FCSAsserted := false;
      FStopAlreadySent := false;

      ok := ReadStatus(true);

      //A transfer cut half way can leave chip select low or an I2C transaction
      //open, and not every caller changes the mode after this. A bare stop ends
      //both (bpio_spi.c, bpio_i2c.c) and leaves the supply alone. A refusal, a
      //stuck I2C bus say, keeps the link in step, so a failed stop is followed
      //by a second status read, and that read decides.
      if ok and (FMode in [bp5SPI, bp5I2C]) then
        if not DataExchange(false, true, 0, nil, 0, nil) then
          ok := ReadStatus(true);
    end;
  finally
    FRecovering := false;
  end;

  FDesynced := not ok;
  if ok then
    Log(bp5lInfo, 'BusPirateV5+: link re-armed')
  else if FLastErrorLogged then
    //The log has the reason on the line before.
    Log(bp5lError, 'BusPirateV5+: could not re-arm the link')
  else
  begin
    Log(bp5lError, 'BusPirateV5+: could not re-arm the link: ' + FLastError);
    FLastErrorLogged := true;
  end;
  result := ok;
end;

function TBusPirate5.RefreshStatus: boolean;
begin
  result := ReadStatus(false);
end;

function TBusPirate5.SendConfig(const Request: TBytes; const What: string): boolean;
var
  raw: TBytes;
  body: integer;
begin
  if not Transact(Request, BP5_RSP_CONFIG, raw, body, 3000) then
    Exit(SetError(What + ': ' + FLastError));
  result := true;
end;

function TBusPirate5.EnterSPI(const Settings: TBP5SPISettings): boolean;
var
  hz: LongWord;
  psu: TBP5PsuAction;
begin
  hz := Settings.SpeedHz;
  if hz < BP5_SPI_MIN_HZ then hz := BP5_SPI_MIN_HZ;
  if hz > BP5_SPI_MAX_HZ then hz := BP5_SPI_MAX_HZ;

  psu := PsuActionFor(Settings.Power, Settings.PsuMv, Settings.PsuMa);
  //Before sending: a reply that is lost does not mean the supply stayed off.
  if psu = bp5psuOn then FSupplyMayBeOn := true;
  FPendingLen := 0;
  if not SendConfig(EncodeConfig('SPI', hz, 8, false,
                                 Settings.ClockPolarity, Settings.ClockPhase,
                                 Settings.ChipSelectIdleHigh, true,
                                 psu, Settings.PsuMv,
                                 word(Settings.PsuMa), Settings.Pullups),
                    'SPI configuration') then
  begin
    //The device changes the mode first and the supply after it, so a request
    //that failed with psu flags may have done either. One without them left
    //the supply alone (bpio.c), and the next status read checks it anyway.
    if psu <> bp5psuLeave then FPsuKnown := false;
    Exit(false);
  end;
  NotePsuApplied(psu, Settings.Power, Settings.PsuMv, Settings.PsuMa);

  FMode := bp5SPI;
  FSPI := Settings;
  FSPI.SpeedHz := hz;
  //A mode change ends with the chip deselected on the device side.
  FCSAsserted := false;

  Log(bp5lInfo, 'BusPirateV5+: SPI ready, ' + IntToStr(hz div 1000) + ' kHz, ' +
      'power ' + BoolToStr(Settings.Power, 'on', 'off'));
  result := true;
end;

function TBusPirate5.EnterI2C(const Settings: TBP5I2CSettings): boolean;
var
  hz: LongWord;
  psu: TBP5PsuAction;
begin
  hz := Settings.SpeedHz;
  if hz < BP5_I2C_MIN_HZ then hz := BP5_I2C_MIN_HZ;
  if hz > BP5_I2C_MAX_HZ then hz := BP5_I2C_MAX_HZ;

  psu := PsuActionFor(Settings.Power, Settings.PsuMv, Settings.PsuMa);
  //The same supply rules as EnterSPI.
  if psu = bp5psuOn then FSupplyMayBeOn := true;
  FPendingLen := 0;
  if not SendConfig(EncodeConfig('I2C', hz, 8, false, false, false, true, true,
                                 psu, Settings.PsuMv,
                                 word(Settings.PsuMa), Settings.Pullups),
                    'I2C configuration') then
  begin
    if psu <> bp5psuLeave then FPsuKnown := false;
    Exit(false);
  end;
  NotePsuApplied(psu, Settings.Power, Settings.PsuMv, Settings.PsuMa);

  FMode := bp5I2C;
  FI2C := Settings;
  FI2C.SpeedHz := hz;
  FStopAlreadySent := false;

  Log(bp5lInfo, 'BusPirateV5+: I2C ready, ' + IntToStr(hz div 1000) + ' kHz');
  result := true;
end;

function TBusPirate5.EnterHiZ: boolean;
begin
  //Everything off: this is the safe state to leave the device in. The HiZ
  //mode change itself releases the pins and switches the supply and the
  //pull-ups off (hiz_setup_exec); the flags say the same.
  if not SendConfig(EncodeConfig('HiZ', 20000, 8, false, false, false, true,
                                 false, bp5psuOff, 0, 0, false),
                    'HiZ configuration') then
  begin
    FPsuKnown := false;
    Exit(false);
  end;
  NotePsuApplied(bp5psuOff, false, 0, 0);
  FMode := bp5HiZ;
  FCSAsserted := false;
  FPendingLen := 0;
  result := true;
end;

//Transfers

function TBusPirate5.DataExchange(StartMain, StopMain: boolean; BytesRead: word;
  WritePtr: Pointer; WriteCount: integer; ReadPtr: Pointer): boolean;
var
  raw, got: TBytes;
  body: integer;
  timeout: integer;
begin
  //Protocol overhead plus the bus time, generously rounded.
  timeout := 3000 + (WriteCount + BytesRead) * 2;

  if not Transact(EncodeData(StartMain, StopMain, BytesRead, WritePtr, WriteCount),
                  BP5_RSP_DATA, raw, body, timeout) then Exit(false);

  if BytesRead > 0 then
  begin
    if not FieldBytes(raw, body, BP5_DR_DATA_READ, got) then
      Exit(SetError('the device answered without the data it was asked for'));
    if Length(got) <> BytesRead then
      Exit(SetError(Format('asked for %d bytes, got %d', [BytesRead, Length(got)])));
    if ReadPtr <> nil then Move(got[0], PByte(ReadPtr)^, BytesRead);
  end;
  result := true;
end;

function TBusPirate5.PendingAdd(const Buffer; Count: integer): boolean;
begin
  if Count <= 0 then Exit(true);
  if FPendingLen + Count > Length(FPending) then
    SetLength(FPending, FPendingLen + Count + 4096);
  Move(Buffer, FPending[FPendingLen], Count);
  Inc(FPendingLen, Count);
  result := true;
end;

function TBusPirate5.SPIQueueWrite(Data: Pointer; Count: integer): boolean;
begin
  if FMode <> bp5SPI then Exit(SetError('not in SPI mode'));
  if (Count <= 0) or (Data = nil) then Exit(true);
  //Bounded so a script that only ever queues cannot eat the heap.
  if FPendingLen + Count > 65536 then
    if not SPIFlushQueued then Exit(false);
  result := PendingAdd(PByte(Data)^, Count);
end;

function TBusPirate5.SPIFlushQueued: boolean;
begin
  if FPendingLen = 0 then Exit(true);
  result := SPITransfer(nil, 0, nil, 0, false);
end;

procedure TBusPirate5.SPIDropQueued;
begin
  if FPendingLen > 0 then
    Log(bp5lInfo, 'BusPirateV5+: dropping ' + IntToStr(FPendingLen) +
                  ' queued byte(s) from an abandoned transfer');
  FPendingLen := 0;
end;

function TBusPirate5.SPITransfer(WritePtr: Pointer; WriteCount: integer;
  ReadPtr: Pointer; ReadCount: integer; Deassert: boolean): boolean;
var
  total, offset, readDone, wslice, rslice: integer;
  startMain, stopMain, last: boolean;
  src: Pointer;
begin
  if FMode <> bp5SPI then Exit(SetError('not in SPI mode'));
  if WriteCount < 0 then WriteCount := 0;
  if ReadCount < 0 then ReadCount := 0;

  if (WriteCount > 0) and (WritePtr <> nil) then
    if not PendingAdd(PByte(WritePtr)^, WriteCount) then Exit(false);

  //From here the queue is this transfer's write stream. Drop the claim on it
  //straight away so an error cannot make stale bytes reappear later.
  total := FPendingLen;
  FPendingLen := 0;
  offset := 0;

  //Everything that does not fit alongside the read goes out first with CS held.
  while (total - offset) > BP5_MAX_WRITE do
  begin
    startMain := not FCSAsserted;
    if not DataExchange(startMain, false, 0, @FPending[offset], BP5_MAX_WRITE, nil) then
      Exit(false);
    if startMain then FCSAsserted := true;
    Inc(offset, BP5_MAX_WRITE);
  end;

  readDone := 0;
  repeat
    wslice := total - offset;
    rslice := ReadCount - readDone;
    if rslice > BP5_MAX_READ then rslice := BP5_MAX_READ;
    last := (readDone + rslice) >= ReadCount;

    stopMain := Deassert and last;
    startMain := not FCSAsserted;

    //EncodeData refuses a read that opens with a start and writes nothing:
    //assert CS on its own first.
    if startMain and (rslice > 0) and (wslice = 0) then
    begin
      if not DataExchange(true, false, 0, nil, 0, nil) then Exit(false);
      FCSAsserted := true;
      startMain := false;
    end;

    if wslice > 0 then src := @FPending[offset] else src := nil;

    if not DataExchange(startMain, stopMain, word(rslice), src, wslice,
                        Pointer(PtrUInt(ReadPtr) + PtrUInt(readDone))) then Exit(false);

    if startMain then FCSAsserted := true;
    if stopMain then FCSAsserted := false;

    offset := total;          //the write stream is spent after the first slice
    Inc(readDone, rslice);
  until last;

  result := true;
end;

function TBusPirate5.SPIReleaseCS: boolean;
begin
  if FMode <> bp5SPI then Exit(true);
  //Queued bytes here belong to an abandoned transfer. Flushing them would turn
  //a command fragment into a complete, CS framed transaction against the chip.
  SPIDropQueued;
  if not FCSAsserted then Exit(true);
  if not DataExchange(false, true, 0, nil, 0, nil) then Exit(false);
  FCSAsserted := false;
  result := true;
end;

//I2C

function TBusPirate5.I2CStart: boolean;
begin
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));
  FStopAlreadySent := false;
  result := DataExchange(true, false, 0, nil, 0, nil);
end;

function TBusPirate5.I2CStop: boolean;
begin
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));
  //I2CReadByte(false) had to emit a stop to produce its NACK, so this one
  //would be a second stop on an idle bus.
  if FStopAlreadySent then
  begin
    FStopAlreadySent := false;
    Exit(true);
  end;
  result := DataExchange(false, true, 0, nil, 0, nil);
end;

function TBusPirate5.I2CWriteByte(Data: byte; out Acked: boolean): boolean;
var
  b: byte;
begin
  Acked := false;
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));
  b := Data;
  //No start flag, so the firmware sends the byte verbatim instead of masking
  //bit 0 as it would for an address.
  result := DataExchange(false, false, 0, @b, 1, nil);
  //A NACK and a bus timeout are the same string on the wire, so Acked means
  //the whole request succeeded. A NACK is a normal answer (acknowledge polling
  //gets one per attempt), so the call still succeeds and nothing is logged.
  Acked := result;
  if not result and (not FDesynced) then
  begin
    FLastError := 'I2C write not acknowledged (NACK or bus timeout)';
    FLastErrorLogged := false;
    result := true;
  end;
end;

function TBusPirate5.I2CReadByte(out Data: byte; SendAck: boolean): boolean;
begin
  Data := 0;
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));

  if SendAck then
    result := DataExchange(false, false, 1, nil, 0, @Data)
  else
  begin
    //The only way to make the firmware NACK is to ask it to stop, so the stop
    //comes out as a side effect and the next I2CStop must not repeat it.
    result := DataExchange(false, true, 1, nil, 0, @Data);
    if result then FStopAlreadySent := true;
  end;
end;

function TBusPirate5.I2CWriteRead(DevAddr: byte; WritePtr: Pointer;
  WriteCount: integer; ReadPtr: Pointer; ReadCount: integer): boolean;
var
  buf: TBytes;
  first, chunk, done: integer;
  last, readStarted, refused, acked, msgLogged: boolean;
  dst: Pointer;
  probe: byte;
  msg: string;
  tries: integer;
begin
  readStarted := false;
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));
  if WriteCount < 0 then WriteCount := 0;
  if ReadCount < 0 then ReadCount := 0;
  //A request carries at most BP5_MAX_WRITE bytes out and BP5_MAX_READ back,
  //so more goes as several requests on one transaction: a start only on the
  //first, a stop only on the last, and every byte read before that one
  //acknowledged (bpio_i2c.c). The repeated start of a write then read only
  //happens inside one request, so the write half of one has to fit.
  if (WriteCount + 1 > BP5_MAX_WRITE) and (ReadCount > 0) then
    Exit(SetError('I2C write of ' + IntToStr(WriteCount) + ' bytes before a read ' +
                  'exceeds ' + IntToStr(BP5_MAX_WRITE - 1)));

  //The address byte leads the write vector; the firmware masks bit 0 for the
  //write phase and sets it for the read phase after its own repeated start.
  SetLength(buf, WriteCount + 1);
  buf[0] := DevAddr;
  if (WriteCount > 0) and (WritePtr <> nil) then
    Move(PByte(WritePtr)^, buf[1], WriteCount);

  if ReadCount = 0 then
  begin
    done := 0;
    repeat
      chunk := Length(buf) - done;
      if chunk > BP5_MAX_WRITE then chunk := BP5_MAX_WRITE;
      last := done + chunk >= Length(buf);
      result := DataExchange(done = 0, last, 0, @buf[done], chunk, nil);
      Inc(done, chunk);
    until (not result) or last;
  end
  else
  begin
    first := ReadCount;
    if first > BP5_MAX_READ then first := BP5_MAX_READ;
    result := DataExchange(true, first = ReadCount, word(first), @buf[0], Length(buf), ReadPtr);
    readStarted := result;
    done := first;
    while result and (done < ReadCount) do
    begin
      chunk := ReadCount - done;
      if chunk > BP5_MAX_READ then chunk := BP5_MAX_READ;
      if ReadPtr <> nil then dst := PByte(ReadPtr) + done else dst := nil;
      result := DataExchange(false, done + chunk >= ReadCount, word(chunk), nil, 0, dst);
      Inc(done, chunk);
    end;
  end;
  if not result then
  begin
    //A refusal the I2C handler answered with, before any byte was read: the
    //firmware gives a NACK of the address, a NACK of a data byte and a bus
    //timeout the same "Protocol request failed" (bpio.c). Its other errors,
    //such as no handler for the mode, keep their own text.  By Dreg
    refused := (not FDesynced) and (not FLastErrorLogged) and (not readStarted) and
               (FLastError = BP5_REQUEST_FAILED);

    //Name the device and keep the reason. A reason SetError has logged already
    //gets a line of its own naming the device, so the reason is not logged
    //twice.  By Dreg
    msg := 'device $' + IntToHex(DevAddr, 2) + ': ' + FLastError;
    msgLogged := FLastErrorLogged;
    if msgLogged then
      Log(bp5lError, 'BusPirateV5+: the I2C transfer to device $' +
                     IntToHex(DevAddr, 2) + ' failed');

    //Every firmware error path returns before its cleanup label, so a failed
    //transfer leaves the bus held. Release it. After a read piece that went
    //through, the device is still sending with its last byte acknowledged,
    //so read one more and NACK it before the stop.
    if not FDesynced then
      if readStarted then
        DataExchange(false, true, 1, nil, 0, nil)
      else
        DataExchange(false, true, 0, nil, 0, nil);

    //As on the v3: when bytes followed the address, the address goes out again
    //alone. A device that takes it now refused what came after (its WP pin
    //high, a protected area), unless it was only busy the first time.  By Dreg
    if refused and (not FDesynced) then
    begin
      acked := false;
      if WriteCount > 0 then
      begin
        //Bytes it took before the NACK start an EEPROM's write cycle at the
        //stop above, and the chip ignores its address until that ends, 5 ms
        //at most on Microchip's AT24C256C. So the probe goes up to 8 times, two
        //requests each: a timer would not do, GetTickCount64 moves in 15 or
        //16 ms steps.
        probe := DevAddr and $FE;
        for tries := 1 to 8 do
        begin
          acked := DataExchange(true, true, 0, @probe, 1, nil);
          if acked or FDesynced then Break;
          DataExchange(false, true, 0, nil, 0, nil);
          if FDesynced then Break;
        end;
      end;
      if acked then
        msg := 'device $' + IntToHex(DevAddr, 2) +
               ' acknowledged its address but refused the data after it'
      else
        msg := 'no I2C answer from device $' + IntToHex(DevAddr, 2);
    end;

    //A release or a probe that lost the link logged its own reason, and that
    //reason is what the caller gets.
    if not FDesynced then
    begin
      FLastError := msg;
      FLastErrorLogged := msgLogged;
    end;
  end;
end;

function TBusPirate5.I2CScan(FirstAddr, LastAddr: integer; out Found: TBytes): boolean;
var
  addr, count: integer;
  probe: byte;
begin
  SetLength(Found, 0);
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));
  if FirstAddr < 0 then FirstAddr := 0;
  if LastAddr > 127 then LastAddr := 127;
  if LastAddr < FirstAddr then Exit(true);

  count := 0;
  SetLength(Found, LastAddr - FirstAddr + 1);

  for addr := FirstAddr to LastAddr do
  begin
    probe := byte((addr shl 1) and $FF);
    //Address only, no data: START, address, STOP. A device that acknowledges
    //makes the whole request succeed.
    if DataExchange(true, true, 0, @probe, 1, nil) then
    begin
      Found[count] := byte(addr);
      Inc(count);
    end
    else
    begin
      if FDesynced then Exit(false);
      //The firmware bailed out before its own stop, so release the bus.
      DataExchange(false, true, 0, nil, 0, nil);
    end;
  end;

  //Every address answering means SDA reads low: the acknowledge is the SDA
  //level sampled after the address, and on a Bus Pirate 7 the pull-ups off
  //means 1M pull-downs on every line (p_pullups.c). Same guard as the v3.x
  //scanner.  By Dreg
  if (count > 0) and (count = LastAddr - FirstAddr + 1) then
  begin
    SetLength(Found, 0);
    Exit(SetError('every address answered, which means SDA reads low rather than ' +
                  'a busy bus: switch the pull-ups on, or check the wiring'));
  end;

  SetLength(Found, count);
  result := true;
end;

//Device enumeration

procedure BP5GetSerialPorts(AList: TStrings);

  //COM2 belongs before COM10, which is not what a plain string sort does.
  function PortRank(const S: string): integer;
  var
    i: integer;
    digits: string;
  begin
    digits := '';
    for i := 1 to Length(S) do
      if (S[i] >= '0') and (S[i] <= '9') then digits := digits + S[i];
    if digits = '' then Exit(MaxInt);
    result := StrToIntDef(digits, MaxInt);
  end;

var
  raw, item: string;
  i, j: integer;
  parts: TStringList;
begin
  AList.Clear;
  raw := GetSerialPortNames;
  if raw = '' then Exit;

  parts := TStringList.Create;
  try
    raw := StringReplace(raw, ';', ',', [rfReplaceAll]);
    parts.Delimiter := ',';
    parts.StrictDelimiter := true;
    parts.DelimitedText := raw;

    for i := 0 to parts.Count - 1 do
    begin
      item := Trim(parts[i]);
      if item = '' then Continue;
      if AList.IndexOf(item) >= 0 then Continue;

      j := 0;
      while (j < AList.Count) and (PortRank(AList[j]) <= PortRank(item)) do Inc(j);
      AList.Insert(j, item);
    end;
  finally
    parts.Free;
  end;
end;

function BP5EnumerateDevices: TBP5DeviceArray;
var
  reg: TRegistry;
  present: TStringList;
  ifaceKeys, children, groups: TStringList;
  i, k, n, ifnum, idx: integer;
  enumBase, keyName, child, group, port, serial: string;

  //Strips the trailing '&nnnn' instance suffix, leaving the per-device prefix
  //that all interfaces of one physical unit share.
  function GroupOf(const AChild: string): string;
  var
    p: integer;
  begin
    result := AChild;
    p := LastDelimiter('&', result);
    if p > 1 then SetLength(result, p - 1);
  end;

  function ReadPortName(const AKey: string): string;
  begin
    result := '';
    if reg.OpenKeyReadOnly(AKey + '\Device Parameters') then
    begin
      if reg.ValueExists('PortName') then result := Trim(reg.ReadString('PortName'));
      reg.CloseKey;
    end;
  end;

begin
  SetLength(result, 0);
  reg := TRegistry.Create;
  present := TStringList.Create;
  ifaceKeys := TStringList.Create;
  children := TStringList.Create;
  groups := TStringList.Create;
  try
    try
      BP5GetSerialPorts(present);

      reg.RootKey := HKEY_LOCAL_MACHINE;
      enumBase := 'SYSTEM\CurrentControlSet\Enum\USB';
      if not reg.OpenKeyReadOnly(enumBase) then Exit;
      reg.GetKeyNames(ifaceKeys);
      reg.CloseKey;

      //The loop reads every interface key of the Bus Pirate and every child
      //under it, with no fixed instance suffix: the child key names differ
      //between machines and between Windows versions.
      for i := 0 to ifaceKeys.Count - 1 do
      begin
        keyName := ifaceKeys[i];
        if Pos(UpperCase(BP5_USB_ID) + '&MI_', UpperCase(keyName)) <> 1 then Continue;

        ifnum := StrToIntDef('$' + Copy(keyName, Length(keyName) - 1, 2), -1);
        if ifnum < 0 then Continue;

        children.Clear;
        if not reg.OpenKeyReadOnly(enumBase + '\' + keyName) then Continue;
        reg.GetKeyNames(children);
        reg.CloseKey;

        for k := 0 to children.Count - 1 do
        begin
          child := children[k];
          port := ReadPortName(enumBase + '\' + keyName + '\' + child);
          if port = '' then Continue;

          group := GroupOf(child);
          idx := groups.IndexOf(group);
          if idx < 0 then
          begin
            idx := groups.Add(group);
            SetLength(result, Length(result) + 1);
            result[High(result)].Name := '';
            result[High(result)].DataPort := '';
            result[High(result)].TermPort := '';
            result[High(result)].Present := false;
          end;

          //Interface 0 is the user terminal, interface 2 the BPIO2 channel.
          //Anything else on the device (mass storage) has no COM port.
          if ifnum = 0 then result[idx].TermPort := port
          else if ifnum = 2 then result[idx].DataPort := port;
        end;
      end;

      //The USB serial string names the generation: 5buspirate, 6buspirate...
      //It is the name of a child key of BP5_USB_ID, whose ParentIdPrefix value
      //matches the group. Best effort only: outside the manufacturing test mode
      //the serial is the chip ID in hex by default.
      children.Clear;
      if reg.OpenKeyReadOnly(enumBase + '\' + BP5_USB_ID) then
      begin
        reg.GetKeyNames(children);
        reg.CloseKey;
        for k := 0 to children.Count - 1 do
        begin
          serial := children[k];
          if not reg.OpenKeyReadOnly(enumBase + '\' + BP5_USB_ID + '\' + serial) then Continue;
          group := '';
          if reg.ValueExists('ParentIdPrefix') then group := Trim(reg.ReadString('ParentIdPrefix'));
          reg.CloseKey;
          if group = '' then Continue;
          idx := groups.IndexOf(group);
          if idx >= 0 then result[idx].Name := serial;
        end;
      end;

      //Enum\USB keeps stale entries for ever, so presence comes from the live
      //port list, never from those keys.
      for n := 0 to High(result) do
        result[n].Present := (result[n].DataPort <> '') and
                             (present.IndexOf(result[n].DataPort) >= 0);
    except
      //An exception from the registry must degrade to "no annotation", never
      //to a crash: the menu still lists every port from BP5GetSerialPorts.
      on E: Exception do SetLength(result, 0);
    end;
  finally
    groups.Free;
    children.Free;
    ifaceKeys.Free;
    present.Free;
    reg.Free;
  end;
end;

function BP5DescribePort(const Devices: TBP5DeviceArray; const APort: string;
  out IsData, IsTerminal: boolean): string;
var
  i: integer;
  gen: string;
begin
  result := '';
  IsData := false;
  IsTerminal := false;
  if APort = '' then Exit;

  for i := 0 to High(Devices) do
  begin
    gen := Devices[i].Name;
    if gen = '' then gen := 'Bus Pirate';

    if SameText(Devices[i].DataPort, APort) then
    begin
      IsData := true;
      Exit(gen + ', BPIO2');
    end;
    if SameText(Devices[i].TermPort, APort) then
    begin
      IsTerminal := true;
      Exit(gen + ', terminal');
    end;
  end;
end;

//TBusPirate5Hardware

//Address of the first element, or nil when Count is under 1 or the buffer is
//empty. The slice is Count bytes long, never Length(): callers pass buffers
//that are almost always larger than Count, and sometimes a bare byte variable.
function SlicePtr(const Buffer: array of byte; Count: integer): Pointer;
begin
  if (Count > 0) and (Length(Buffer) > 0) then
    result := @Buffer[0]
  else
    result := nil;
end;

function CheckedTag(Parent: TMenuItem; Default: PtrInt): PtrInt;
var
  i: integer;
begin
  result := Default;
  if Parent = nil then Exit;
  for i := 0 to Parent.Count - 1 do
    if Parent.Items[i].Checked then Exit(Parent.Items[i].Tag);
end;

constructor TBusPirate5Hardware.Create;
begin
  FHardwareName := 'BusPirateV5+';
  FHardwareID := CHW_BUSPIRATE5;
  FBP := TBusPirate5.Create;
  FBP.OnLog := @HandleLog;
  FDevOpened := false;
  FStrError := '';
  FErrorLogged := false;
  FOpenPort := '';
  FAppliedConfig := '';
end;

destructor TBusPirate5Hardware.Destroy;
begin
  //Never leave a target powered or a chip selected because the program closed.
  if FBP.IsOpen then
  begin
    try
      SafePowerDown;
    except
      //Shutdown must not throw.
    end;
    FBP.Close;
  end;
  FBP.Free;
  inherited Destroy;
end;

//Puts the pins high impedance and the supply off, also when the link is out of
//step and refuses every request. Resync only proves the link, so nothing
//switches the supply on again on the way, and the HiZ mode change releases
//chip select itself (spi_cleanup). A dead device costs one timeout and one
//Resync, about 6 s, also at exit; the short write timeout keeps a hung one
//that takes no bytes at about 2 s.
function TBusPirate5Hardware.SafePowerDown: boolean;
var
  saved: integer;
begin
  result := false;
  if not FBP.IsOpen then Exit;

  saved := FBP.Port.WriteTimeoutMs;
  FBP.Port.WriteTimeoutMs := BPSER_PARK_WRITE_MS;
  try
    if (not FBP.Desynced) or FBP.Resync then
    begin
      if FBP.EnterHiZ then Exit(true);
      //One more go once the line is clean, whatever the first failure was.
      if FBP.Resync and FBP.EnterHiZ then Exit(true);
    end;
  finally
    FBP.Port.WriteTimeoutMs := saved;
  end;

  LogPrint('BusPirateV5+: could not switch to HiZ (' + FBP.LastError +
           '), the target may still be powered: unplug the Bus Pirate to be sure');
end;

procedure TBusPirate5Hardware.HandleLog(Level: TBP5LogLevel; const Msg: string);
begin
  LogPrint(Msg);
end;

function TBusPirate5Hardware.Complain(const Msg: string): boolean;
begin
  FStrError := Msg;
  FErrorLogged := true;
  //Anything that went wrong makes the session suspect, so the next DevOpen
  //configures the device again instead of taking the fast path.
  FAppliedConfig := '';
  //The engine's own error was logged where it happened, unless it was one it
  //keeps quiet (a device's refusal), which is said here.
  if (Msg <> FBP.LastError) or (not FBP.LastErrorLogged) then
    LogPrint('BusPirateV5+: ' + Msg);
  result := false;
end;

//Why a status read found the supply in another state than the one this
//session set, with the flag cleared. A supply that is still on goes off first,
//as the firmware does with its own faults: with no current limit nothing else
//would stop it feeding a short.
function TBusPirate5Hardware.TakeSupplyChange: string;
begin
  result := FBP.PsuChangeWhy;
  FBP.ClearPsuChanged;
  //HiZ is not the mode the next operation wants, and the supply has to be set
  //again in any case.
  FAppliedConfig := '';
  if FBP.Status.PsuEnabled and FBP.EnterHiZ then
    result := result + '. The supply is off now';
end;

//Fail the operation and say why. Nothing switches the supply on again until
//the next operation or I2C scan applies the menu settings.
function TBusPirate5Hardware.SupplyChanged: boolean;
begin
  result := Complain(TakeSupplyChange + '. Check the target, then run the ' +
                     'operation again: it applies the BusPirateV5+ menu settings');
end;

//VOUT read low right after a configuration. With no current limit psu_enable
//lets the supply settle for 10 ms only (psu.c), so a target with a lot of
//capacitance can still be charging: read once more after the wait psu_enable
//uses with a limit. False only when the device stopped answering.
function TBusPirate5Hardware.RecheckSag: boolean;
begin
  FBP.ClearPsuChanged;
  Sleep(BP5_PSU_SETTLE_MS);
  result := FBP.Ping;
end;

function TBusPirate5Hardware.GetLastError: string;
begin
  result := FStrError;
end;

function TBusPirate5Hardware.ErrorWasLogged: boolean;
begin
  result := FErrorLogged;
end;

function TBusPirate5Hardware.MaxRead: integer;
begin
  if FBP.Status.Valid and (FBP.Status.MaxRead > 0) then
    result := integer(FBP.Status.MaxRead)
  else
    result := BP5_MAX_READ;
  //This number comes off the wire and feeds a Word chunk size and fixed stack
  //buffers in main.pas, so it gets the same ceiling everything else does.
  if result > BP5_MAX_READ then result := BP5_MAX_READ;
  if result < 16 then result := BP5_MAX_READ;
end;

function TBusPirate5Hardware.WantI2C: boolean;
begin
  result := MainForm.RadioI2C.Checked;
end;

function TBusPirate5Hardware.SelectedSPIHz: LongWord;
begin
  //Same default as the v3.x back end: slow enough to work on any wiring. The
  //menu goes up to 16 MHz.
  result := LongWord(CheckedTag(MainForm.MenuBP5SPIClock, 125000));
  if result < BP5_SPI_MIN_HZ then result := 125000;
end;

function TBusPirate5Hardware.SelectedI2CHz: LongWord;
begin
  result := LongWord(CheckedTag(MainForm.MenuBP5I2CClock, 50000));
  if result < BP5_I2C_MIN_HZ then result := 50000;
end;

function TBusPirate5Hardware.SelectedPsuMv: LongWord;
begin
  result := LongWord(CheckedTag(MainForm.MenuBP5Voltage, 3300));
  if (result < 800) or (result > 5000) then result := 3300;
end;

function TBusPirate5Hardware.SelectedPsuMa: LongWord;
begin
  //Tag 0 means unlimited, which the firmware accepts because the template
  //always emits the field.
  result := LongWord(CheckedTag(MainForm.MenuBP5Current, 300));
  if result > 500 then result := 500;
end;

function TBusPirate5Hardware.SPISettings: TBP5SPISettings;
begin
  FillChar(result, SizeOf(result), 0);
  result.SpeedHz := SelectedSPIHz;
  //Mode 0, which is what 25-series SPI flash expects.
  result.ClockPolarity := false;
  result.ClockPhase := false;
  result.ChipSelectIdleHigh := true;
  result.Power := MainForm.MenuBP5Power.Checked;
  result.PsuMv := SelectedPsuMv;
  result.PsuMa := SelectedPsuMa;
  result.Pullups := MainForm.MenuBP5Pullups.Checked;
end;

function TBusPirate5Hardware.I2CSettings: TBP5I2CSettings;
begin
  FillChar(result, SizeOf(result), 0);
  result.SpeedHz := SelectedI2CHz;
  result.Power := MainForm.MenuBP5Power.Checked;
  result.PsuMv := SelectedPsuMv;
  result.PsuMa := SelectedPsuMa;
  //I2C needs pull-ups, and these follow the menu. They are fed from VOUT, so
  //they do nothing without a supply there, the Bus Pirate's or the target's.
  result.Pullups := MainForm.MenuBP5Pullups.Checked;
end;

//DevOpen configures the device again when any of these values changes.
function TBusPirate5Hardware.ConfigSignature: string;
begin
  if WantI2C then
    result := Format('i2c|%d|%d|%d|%d%d', [SelectedI2CHz, SelectedPsuMv, SelectedPsuMa,
                Ord(MainForm.MenuBP5Power.Checked),
                Ord(MainForm.MenuBP5Pullups.Checked)])
  else
    result := Format('spi|%d|%d|%d|%d%d', [SelectedSPIHz, SelectedPsuMv, SelectedPsuMa,
                Ord(MainForm.MenuBP5Power.Checked),
                Ord(MainForm.MenuBP5Pullups.Checked)]);
end;

function TBusPirate5Hardware.Connect(const APort: string): boolean;
begin
  FBP.Verbose := MainForm.MenuBP5Verbose.Checked;
  FAppliedConfig := '';
  FOpenPort := '';

  if not FBP.Open(APort) then
  begin
    Complain(FBP.LastError);
    //A session that died with the supply on is gone now, and nothing will
    //switch it off.
    if FBP.SupplyMayBeOn then
      LogPrint('BusPirateV5+: the last session ended with the target supply on, ' +
               'so the target may still be powered: unplug the Bus Pirate to be sure');
    Exit(false);
  end;
  //Open has logged the hardware, the port and the firmware date.

  FOpenPort := APort;
  result := true;
end;

//The session of a menu command that runs outside an operation (Show pin
//labels, the I2C scan, Device info): opened when there is none, re-armed when
//it is out of sync, and otherwise checked with a status read, as DevOpen does.
//The port of a Bus Pirate unplugged and plugged back in fails every write, so a
//failed read opens it again, and a supply change since the last operation
//shows in PsuChanged. False with the reason logged and in FBP.LastError.
//By Dreg
function TBusPirate5Hardware.ReadyLink(const APort: string): boolean;
var
  needConnect: boolean;
begin
  needConnect := (not FBP.IsOpen) or (APort <> FOpenPort);
  if not needConnect then
  begin
    if FBP.Desynced then
    begin
      FAppliedConfig := '';
      needConnect := not FBP.Resync;
    end
    else
    begin
      FBP.SPIDropQueued;
      if not FBP.Ping then
      begin
        LogPrint('BusPirateV5+: device stopped answering, reconnecting');
        FAppliedConfig := '';
        needConnect := not (FBP.Desynced and FBP.Resync);
      end;
    end;
  end;
  result := (not needConnect) or Connect(APort);
end;

function TBusPirate5Hardware.DevOpen: boolean;
var
  port, signature: string;
  needConnect, lostPing, armed: boolean;
begin
  FStrError := '';
  FErrorLogged := false;
  FDevOpened := false;
  lostPing := false;
  armed := false;
  FBP.Verbose := MainForm.MenuBP5Verbose.Checked;

  port := Trim(main.BusPirate5_COMPort);
  if port = '' then Exit(Complain('no COM port selected (BusPirateV5+ menu -> COM port)'));

  signature := ConfigSignature;

  //A failed transfer can leave the device mid-answer. Get the stream back in
  //step before anything else.
  if FBP.Desynced then
  begin
    LogPrint('BusPirateV5+: the last transfer failed, re-arming the link');
    FAppliedConfig := '';
    if not FBP.Resync then
      if not Connect(port) then Exit(false);
    //Resync and Open have both just read the status.
    armed := true;
  end;

  //Fast path: same port, same settings, device still answering.
  if FBP.IsOpen and (port = FOpenPort) and (signature = FAppliedConfig) and
     (not MainForm.MenuBP5ResetEach.Checked) then
  begin
    //Bytes still queued belong to an abandoned transfer. Ping refuses to run
    //with them there, and that reads as "stopped answering" and costs a
    //reconnect.
    FBP.SPIDropQueued;
    if FBP.Ping then
    begin
      //An operation cancelled mid transaction can leave CS asserted. Releasing
      //it is a transaction of its own, which can fail and desync the link, so a
      //failure falls through to the reconnect.  By Dreg
      if (FBP.Mode <> bp5SPI) or FBP.SPIReleaseCS then
      begin
        if FBP.PsuChanged then Exit(SupplyChanged);
        FDevOpened := true;
        Exit(true);
      end;
      LogPrint('BusPirateV5+: could not release chip select, reconnecting');
      lostPing := true;
    end
    else
    LogPrint('BusPirateV5+: device stopped answering, reconnecting');
    //A failed Ping desynchronises the link, and the guard refuses every later
    //request. With lostPing set, DevOpen re-arms the link or reconnects below.
    lostPing := true;
  end;

  needConnect := MainForm.MenuBP5ResetEach.Checked or lostPing or
                 (not FBP.IsOpen) or (port <> FOpenPort);

  //An open session the fast path did not check (new settings, an operation
  //that failed, Show pin labels, the I2C scan) is checked the same way: the
  //port of a Bus Pirate unplugged and plugged back in fails every write until
  //it is opened again, and a supply change since the last operation has to be
  //said before the configuration below switches the supply on again.  By Dreg
  if (not needConnect) and (not armed) then
  begin
    FBP.SPIDropQueued;
    if not FBP.Ping then
    begin
      LogPrint('BusPirateV5+: device stopped answering, reconnecting');
      lostPing := true;
      needConnect := true;
    end;
  end;

  if needConnect then
  begin
    //One cheap attempt to re-arm what is already open before tearing the port
    //down and running the whole handshake again.
    if lostPing and FBP.Desynced and FBP.Resync then
      LogPrint('BusPirateV5+: link re-armed without reopening the port')
    else
      if not Connect(port) then Exit(false);
  end;

  //Resync and Ping read the supply as well.
  if FBP.PsuChanged then Exit(SupplyChanged);

  //Drop the claim before touching the device: a mode change that dies half way
  //must not leave a signature the next DevOpen would fast path on.
  FAppliedConfig := '';

  if WantI2C then
  begin
    if not FBP.EnterI2C(I2CSettings) then Exit(Complain(FBP.LastError));
  end
  else
    if not FBP.EnterSPI(SPISettings) then Exit(Complain(FBP.LastError));

  //The configuration's answer carries no supply state, and under BPIO2 the
  //firmware does not check VOUT (bpio.c), so read the supply now.
  if FBP.PsuOn then
  begin
    if not FBP.Ping then Exit(Complain(FBP.LastError));
    if FBP.PsuSagging and (not RecheckSag) then Exit(Complain(FBP.LastError));
    if FBP.PsuChanged then Exit(SupplyChanged);
  end;

  FAppliedConfig := signature;
  FDevOpened := true;
  result := true;
end;

procedure TBusPirate5Hardware.DevClose;
begin
  FDevOpened := false;
  if not FBP.IsOpen then Exit;

  //Leave CS idle so the chip is never left selected between operations.
  if FBP.Mode = bp5SPI then FBP.SPIReleaseCS;

  //An operation that lost its supply half way still ends with "Done", so look
  //once more. The next DevOpen applies the menu settings again.
  if FBP.PsuOn and FBP.Ping and FBP.PsuChanged then
  begin
    LogPrint('BusPirateV5+: ' + TakeSupplyChange +
             '. The result of this operation cannot be trusted');
    FAppliedConfig := '';
  end;

  //Only tear the link down when the user asked for it. An open link lets the
  //next operation skip the handshake.
  if MainForm.MenuBP5ResetEach.Checked then
  begin
    SafePowerDown;
    FBP.Close;
    FOpenPort := '';
    FAppliedConfig := '';
  end;
end;

function TBusPirate5Hardware.Disconnect: TBP5Park;
begin
  FDevOpened := false;
  if not FBP.IsOpen then
    result := bp5pkNoSession
  else if SafePowerDown then
    result := bp5pkParked
  else
    result := bp5pkFailed;
  FBP.Close;
  FOpenPort := '';
  FAppliedConfig := '';
end;

function TBusPirate5Hardware.SupplyMayBeOn: boolean;
begin
  result := (not FBP.IsOpen) and FBP.SupplyMayBeOn;
end;

//SPI

function TBusPirate5Hardware.SPIInit(speed: integer): boolean;
begin
  //The clock comes from the menu and DevOpen has already sent it; the argument
  //is an opaque menu tag, not Hz.
  result := FDevOpened and (FBP.Mode = bp5SPI);
  if not result then
  begin
    FStrError := 'SPI mode is not active';
    FErrorLogged := false;
  end;
end;

procedure TBusPirate5Hardware.SPIDeinit;
begin
  if not FDevOpened then Exit;
  if FBP.Mode <> bp5SPI then Exit;
  FBP.SPIReleaseCS;
end;

function TBusPirate5Hardware.SPIRead(CS: byte; BufferLen: integer;
  var buffer: array of byte): integer;
begin
  if not FDevOpened then Exit(-1);

  if not FBP.SPITransfer(nil, 0, SlicePtr(buffer, BufferLen), BufferLen, CS = 1) then
  begin
    Complain(FBP.LastError);
    Exit(-1);
  end;
  result := BufferLen;
end;

function TBusPirate5Hardware.SPIWrite(CS: byte; BufferLen: integer;
  buffer: array of byte): integer;
begin
  if not FDevOpened then Exit(-1);

  if CS = 1 then
  begin
    //Closing half of a transaction: push everything and release CS.
    if not FBP.SPITransfer(SlicePtr(buffer, BufferLen), BufferLen, nil, 0, true) then
    begin
      Complain(FBP.LastError);
      Exit(-1);
    end;
  end
  else
    //Opening half: hold the bytes back so they travel with the next call as a
    //single request instead of two round trips.
    if not FBP.SPIQueueWrite(SlicePtr(buffer, BufferLen), BufferLen) then
    begin
      Complain(FBP.LastError);
      Exit(-1);
    end;

  result := BufferLen;
end;

//I2C

procedure TBusPirate5Hardware.I2CInit;
begin
  //Configured by DevOpen.
end;

procedure TBusPirate5Hardware.I2CDeinit;
begin
  //Nothing to undo: the mode stays valid until the link is closed.
end;

procedure TBusPirate5Hardware.I2CStart;
begin
  if not FDevOpened then Exit;
  if not FBP.I2CStart then Complain(FBP.LastError);
end;

procedure TBusPirate5Hardware.I2CStop;
begin
  if not FDevOpened then Exit;
  if not FBP.I2CStop then Complain(FBP.LastError);
end;

function TBusPirate5Hardware.I2CReadByte(ack: boolean): byte;
begin
  result := $FF;
  if not FDevOpened then Exit;
  if not FBP.I2CReadByte(result, ack) then
  begin
    Complain(FBP.LastError);
    result := $FF;
  end;
end;

function TBusPirate5Hardware.I2CWriteByte(data: byte): boolean;
var
  acked: boolean;
begin
  result := false;
  if not FDevOpened then Exit;
  if not FBP.I2CWriteByte(data, acked) then
  begin
    Complain(FBP.LastError);
    Exit;
  end;
  result := acked;
end;

function TBusPirate5Hardware.I2CReadWrite(DevAddr: byte;
  WBufferLen: integer; WBuffer: array of byte;
  RBufferLen: integer; var RBuffer: array of byte): integer;
begin
  if not FDevOpened then Exit(-1);

  if not FBP.I2CWriteRead(DevAddr,
                          SlicePtr(WBuffer, WBufferLen), WBufferLen,
                          SlicePtr(RBuffer, RBufferLen), RBufferLen) then
  begin
    Complain(FBP.LastError);
    Exit(-1);
  end;
  result := WBufferLen + RBufferLen;
end;

//Microwire

//BPIO2 cannot do Microwire, for three independent reasons: the firmware's
//3WIRE handlers are compiled but not wired into its BPIO dispatch table, the
//DataRequest schema is byte granular where Microwire needs odd bit counts, and
//the only way to sample the busy pin would be a USB round trip per bit.
const
  MW_UNSUPPORTED = 'Microwire is not available on the Bus Pirate v5+ (BPIO2). ' +
                   'Use a CH341a, CH347T, UsbAsp, AVRISP-MKII, Arduino or ' +
                   'FT232H for Microwire parts.';

function TBusPirate5Hardware.MWInit(speed: integer): boolean;
begin
  result := Complain(MW_UNSUPPORTED);
end;

procedure TBusPirate5Hardware.MWDeinit;
begin
end;

function TBusPirate5Hardware.MWRead(CS: byte; BufferLen: integer;
  var buffer: array of byte): integer;
begin
  FStrError := MW_UNSUPPORTED;
  FErrorLogged := false;
  result := -1;
end;

function TBusPirate5Hardware.MWWrite(CS: byte; BitsWrite: byte;
  buffer: array of byte): integer;
begin
  FStrError := MW_UNSUPPORTED;
  FErrorLogged := false;
  result := -1;
end;

function TBusPirate5Hardware.MWIsBusy: boolean;
begin
  result := false;
end;

//Extras

function TBusPirate5Hardware.DeviceReport: string;
var
  check, port: string;
  wasOn: boolean;
begin
  port := Trim(main.BusPirate5_COMPort);
  if port = '' then Exit('No COM port selected');
  //Otherwise a failed transfer, or a Bus Pirate plugged back in, would leave
  //this menu command dead for the rest of the session.
  if not ReadyLink(port) then
    Exit('Cannot reach the device: ' + FBP.LastError);

  if not FBP.RefreshStatus then
    Exit('Cannot read the device status: ' + FBP.LastError);

  //Act on a supply change now, as the next operation would: a short fed with
  //no current limit should not wait for it. Then show the supply as it is.
  check := '';
  if FBP.PsuChanged then
  begin
    wasOn := FBP.Status.PsuEnabled;
    check := TakeSupplyChange;
    if wasOn then FBP.RefreshStatus;
  end;

  result :=
    'Port          : ' + FBP.Port.PortName + LineEnding +
    'Hardware      : Bus Pirate ' + IntToStr(FBP.Status.HwMajor) +
                    ' REV' + IntToStr(FBP.Status.HwMinor) + LineEnding +
    'Firmware date : ' + FBP.Status.FwDate + LineEnding +
    'Firmware hash : ' + FBP.Status.GitHash + LineEnding +
    'FlatBuffers   : ' + IntToStr(FBP.Status.FbMajor) + '.' +
                         IntToStr(FBP.Status.FbMinor) + LineEnding +
    'Current mode  : ' + FBP.Status.ModeCurrent + LineEnding +
    'Modes         : ' + FBP.Status.Modes + LineEnding +
    'Limits        : packet ' + IntToStr(FBP.Status.MaxPacket) +
                    ', write ' + IntToStr(FBP.Status.MaxWrite) +
                    ', read ' + IntToStr(FBP.Status.MaxRead) + LineEnding +
    'Power supply  : ' + BoolToStr(FBP.Status.PsuEnabled, 'on', 'off') +
                    ', set ' + IntToStr(FBP.Status.PsuSetMv) + ' mV / ' +
                    IntToStr(FBP.Status.PsuSetMa) + ' mA' + LineEnding +
    'Measured      : ' + IntToStr(FBP.Status.PsuMeasMv) + ' mV, ' +
                         IntToStr(FBP.Status.PsuMeasMa) + ' mA' + LineEnding +
    'Supply fault  : ' + BoolToStr(FBP.Status.PsuError, 'YES - check the target!', 'no') + LineEnding +
    'Pull-ups      : ' + BoolToStr(FBP.Status.PullupEnabled, 'on', 'off') + LineEnding;

  if check <> '' then
    result := result + 'Supply check  : ' + check + LineEnding;

  //The firmware's own version fields are hardcoded to 0, so they are not shown.
end;

function TBusPirate5Hardware.ScanI2CBus(out Found: TBytes; out ErrMsg: string): boolean;
var
  port: string;
begin
  SetLength(Found, 0);
  ErrMsg := '';
  result := false;
  FBP.Verbose := MainForm.MenuBP5Verbose.Checked;

  port := Trim(main.BusPirate5_COMPort);
  if port = '' then
  begin
    ErrMsg := 'No COM port selected. Pick one in the BusPirateV5+ menu.';
    Exit;
  end;

  //A previous failure, or a Bus Pirate plugged back in, must not make the
  //scanner unavailable, and a supply change since the last operation is said
  //below before the scan configures anything.
  if not ReadyLink(port) then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;

  //The scan runs whatever the SPI/I2C radio says, so leave the session dirty:
  //the next operation applies the user's own settings again.
  FAppliedConfig := '';

  //The same supply checks as DevOpen, before and after the configuration.
  if not FBP.PsuChanged then
  begin
    if not FBP.EnterI2C(I2CSettings) then
    begin
      ErrMsg := FBP.LastError;
      Exit;
    end;
    if FBP.PsuOn then
      if (not FBP.Ping) or (FBP.PsuSagging and (not RecheckSag)) then
      begin
        ErrMsg := FBP.LastError;
        Exit;
      end;
  end;
  if FBP.PsuChanged then
  begin
    ErrMsg := TakeSupplyChange + '. Check the target, then scan again: the scan ' +
              'applies the BusPirateV5+ menu settings';
    Exit;
  end;

  if not FBP.I2CScan(8, 119, Found) then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;

  //A supply that went off half way hides the devices after that point, and a
  //Bus Pirate that no longer answers cannot say whether that happened.
  if FBP.PsuOn then
  begin
    if not FBP.Ping then
    begin
      SetLength(Found, 0);
      ErrMsg := FBP.LastError;
      Exit;
    end;
    if FBP.PsuChanged then
    begin
      SetLength(Found, 0);
      ErrMsg := 'The scan result cannot be trusted: ' + TakeSupplyChange +
                '. Check the target, then scan again';
      Exit;
    end;
  end;
  result := true;
end;

//The device's screen labels each pin with what the mode uses it for. This
//sets the mode of the bus picked in the window, SPI or I2C, with the supply
//and the pull-ups off in the same request, so the labels show where each wire
//goes with the Bus Pirate's supply off. A target with its own supply on VOUT
//still gets the mode's outputs (SPI drives CS, CLK and MOSI). The next
//operation sets the device up again as the menu says.
//By Dreg
function TBusPirate5Hardware.ShowPinLabels(out ErrMsg: string): boolean;
var
  port: string;
  spi: TBP5SPISettings;
  i2c: TBP5I2CSettings;
begin
  ErrMsg := '';
  result := false;
  FBP.Verbose := MainForm.MenuBP5Verbose.Checked;

  port := Trim(main.BusPirate5_COMPort);
  if port = '' then
  begin
    ErrMsg := 'No COM port selected. Pick one in the BusPirateV5+ menu.';
    Exit;
  end;

  //A session the last operation left open has not read the status since, so a
  //tripped current limit or a supply changed on the device's own terminal is
  //still unknown, and switching the supply off below would hide it.
  if not ReadyLink(port) then
  begin
    ErrMsg := 'see the log above';
    Exit;
  end;

  //Not the operation's setup: the next operation configures the device again.
  FAppliedConfig := '';

  if FBP.PsuChanged then
  begin
    LogPrint('BusPirateV5+: ' + FBP.PsuChangeWhy + '. Check the target: the next ' +
             'operation switches the supply on again as the menu says');
    FBP.ClearPsuChanged;
  end;

  if WantI2C then
  begin
    i2c := I2CSettings;
    i2c.Power := false;
    i2c.Pullups := false;
    result := FBP.EnterI2C(i2c);
  end
  else
  begin
    spi := SPISettings;
    spi.Power := false;
    spi.Pullups := false;
    result := FBP.EnterSPI(spi);
  end;
  if not result then
  begin
    //A reason the engine has logged already is not said twice.
    if FBP.LastErrorLogged then ErrMsg := 'see the log above' else ErrMsg := FBP.LastError;
    //The request may have changed the mode and left the supply on, and the
    //next thing the user does is touch the wires.
    if SafePowerDown then
      ErrMsg := ErrMsg + '. The Bus Pirate is in HiZ with the supply off';
  end;
end;

function TBusPirate5Hardware.I2CDeviceLine(Addr: byte): string;
begin
  result := Format('0x%.2x    0x%.2x    0x%.2x',
                   [Addr, (Addr shl 1) and $FF, ((Addr shl 1) or 1) and $FF]);
end;

function TBusPirate5Hardware.I2CBusDescription: string;
begin
  result := Format('%d kHz, pull-ups %s, target power %s',
    [SelectedI2CHz div 1000,
     BoolToStr(MainForm.MenuBP5Pullups.Checked, 'on', 'off'),
     BoolToStr(MainForm.MenuBP5Power.Checked, 'on', 'off')]);
end;

end.
