unit buspirate5hw;

{
  Bus Pirate v5 / v6 / v7 (BPIO2) programmer back end for AsProgrammer.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  This is a completely separate driver from buzzpirathw.pas. The v3.x speaks
  BBIO, a stream of raw opcodes; the v5 and later speak BPIO2, which is
  FlatBuffers packets inside COBS frames on a second USB serial port. The two
  share nothing but the TBaseHardware contract, and both back ends can hold
  their own port open at the same time.

  Everything lives in this one unit, in three layers:

    TBP5Port            serial transport over Synapse's TBlockSerial, plus the
                        one thing BBIO never needed: read a COBS frame.

    TBusPirate5         the BPIO2 protocol engine - COBS, a hand written
                        FlatBuffers encoder and a generic decoder, the status
                        handshake, SPI and I2C.

    TBusPirate5Hardware the TBaseHardware implementation AsProgrammer talks to,
                        plus the reading of the BusPirateV5+ menu settings.

  Reference material:
    - https://docs.buspirate.com/docs/binmode-reference/protocol-bpio2/
    - the BPIO2 schema, bpio.fbs
    - firmware: src/binmode/bpio.c, bpio_spi.c, bpio_i2c.c

  Design notes worth knowing before touching this unit:

  * There is no FlatBuffers runtime for Free Pascal here and we are not porting
    one. Requests are fixed byte templates with the variable fields patched in
    place - the layouts below were built by hand and verified byte for byte
    against a real Bus Pirate 6. Responses cannot use templates, because the
    firmware's flatcc emitter lays buffers out differently from anything we
    emit, so the decoder is a fully generic vtable walker. It has to cope with
    negative soffsets (flatcc puts vtables after their tables), truncated
    vtables (trailing empty slots are dropped) and elided fields (anything
    equal to its schema default is simply absent).

  * Three limits are firmware constants, not suggestions:
      - bytes_read must never exceed 512. The firmware detects the overrun but
        its error path jumps past the start of the response table, so flatcc
        builds a malformed packet or none at all, and the damage carries into
        later responses. Never probe this one.
      - data_write is not checked by the firmware at all; the real ceiling is
        the 643 byte frame buffer, so keep it to 512.
      - contents_type must be 1, 2 or 3. Zero indexes a NULL handler and reboots
        the device, so it is hardcoded in every template.

  * An I2C read that asks for a start must carry at least one write byte: the
    firmware reads data_write[0] to build the read address without checking
    whether the vector is there.

  * The device only speaks BPIO2 when BPIO2 is the selected binmode. The
    factory default is the SUMP logic analyser, which answers on the same port,
    so a failed handshake means "wrong binmode", not "wrong port" - and it is
    reported that way, once, rather than retried on every operation.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Synaser, basehw;

const
  //--- firmware constants (bpio.c) -------------------------------------------
  BP5_MAX_PACKET   = 640;
  BP5_MAX_WRITE    = 512;
  BP5_MAX_READ     = 512;
  //640 + ceil(640/254) of COBS overhead, the firmware's own frame buffer.
  BP5_MAX_COBS     = 643;

  //Nominal only: this is USB CDC, so the rate is a formality the host driver
  //records and the device ignores. Throughput is set by USB and by the SPI
  //clock, never by this, which is why it is not offered as a setting.
  BP5_BAUD_DEFAULT = 3000000;

  BP5_USB_ID       = 'VID_1209&PID_7331';

  //--- union tags ------------------------------------------------------------
  BP5_REQ_STATUS   = 1;
  BP5_REQ_CONFIG   = 2;
  BP5_REQ_DATA     = 3;

  BP5_RSP_STATUS   = 1;
  BP5_RSP_CONFIG   = 2;
  BP5_RSP_DATA     = 3;

  //--- ResponsePacket slots --------------------------------------------------
  BP5_RP_ERROR         = 0;
  BP5_RP_CONTENTS_TYPE = 1;
  BP5_RP_CONTENTS      = 2;

  //--- DataResponse slots ----------------------------------------------------
  BP5_DR_ERROR     = 0;
  BP5_DR_DATA_READ = 1;
  BP5_DR_IS_ASYNC  = 2;

  //--- ConfigurationResponse slots -------------------------------------------
  BP5_CR_ERROR     = 0;

  //--- StatusResponse slots --------------------------------------------------
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

  //Clocks offered in the menu. The firmware does no validation on the BPIO
  //path, so the host clamps instead.
  BP5_SPI_MIN_HZ   = 1000;
  BP5_SPI_MAX_HZ   = 16000000;
  //I2C speed is divided by 1000 on the device; below 1 kHz that divides by zero.
  BP5_I2C_MIN_HZ   = 1000;
  BP5_I2C_MAX_HZ   = 1000000;

type

{ TBP5Port }

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
public
  constructor Create;
  destructor Destroy; override;

  function Open(const APortName: string; ABaudRate: LongWord): boolean;
  procedure Close;
  function IsOpen: boolean;

  function WriteAll(const Buffer; Count: integer): boolean;
  //Reads until the first 0x00 and returns the frame without that delimiter.
  //TimeoutMs restarts on every byte that arrives.
  function ReadFrame(out Frame: TBytes; TimeoutMs: integer): boolean;

  procedure Purge;
  function Drain(IdleMs, MaxMs: integer): integer;
  function BytesWaiting: integer;

  property LastError: string read FLastError;
  property PortName: string read FPortName;
end;

//--- COBS ---------------------------------------------------------------------
//Consistent Overhead Byte Stuffing. The encoded form never contains a zero, so
//a zero delimits a frame.
function BP5CobsEncode(const Src: TBytes): TBytes;
function BP5CobsDecode(const Src: TBytes; out Dst: TBytes): boolean;

//--- device enumeration -------------------------------------------------------
type
  TBP5Device = record
    DataPort: string;    //MI_02, the BPIO2 interface
    TermPort: string;    //MI_00, the user terminal
    Name: string;        //USB serial string: 5buspirate, 6buspirate, ...
    Present: boolean;    //still plugged in
  end;
  TBP5DeviceArray = array of TBP5Device;

//Every serial port the system currently has, sorted the way a human reads COM
//numbers. This is the list the menu is built from: it works on any machine,
//whatever the driver stack, exactly like the v3.x back end's port list.
procedure BP5GetSerialPorts(AList: TStrings);

//Best effort identification of Bus Pirate v5+ units from the USB registry, to
//annotate that list. Never the sole source of the menu: a machine where this
//finds nothing must still be able to pick a port by hand.
function BP5EnumerateDevices: TBP5DeviceArray;

//What a given COM port is, for the menu caption: '' when nothing is known,
//otherwise something like 'Bus Pirate 6, BPIO2' or 'Bus Pirate 6, terminal'.
function BP5DescribePort(const Devices: TBP5DeviceArray; const APort: string;
                         out IsData, IsTerminal: boolean): string;

type
  TBP5Mode = (bp5Closed, bp5Unknown, bp5HiZ, bp5SPI, bp5I2C);

  TBP5LogLevel = (bp5lError, bp5lInfo, bp5lDebug);
  TBP5LogEvent = procedure(Level: TBP5LogLevel; const Msg: string) of object;

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
    ClockPolarity: boolean;   //CPOL
    ClockPhase: boolean;      //CPHA
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

{ TBusPirate5 }

TBusPirate5 = class
private
  FPort: TBP5Port;
  FMode: TBP5Mode;
  FStatus: TBP5Status;
  FLastError: string;
  FOnLog: TBP5LogEvent;
  FVerbose: boolean;

  //Set when a reply was lost or could not be parsed. Nothing else goes out
  //until Resync has proved the link is back in step.
  FDesynced: boolean;
  FRecovering: boolean;

  //Deferred CS-low write bytes, so a write/read pair costs one round trip.
  FPending: TBytes;
  FPendingLen: integer;
  FCSAsserted: boolean;
  //I2CReadByte(false) has to emit a stop to produce the NACK, so the I2CStop
  //that follows would be a second one.
  FStopAlreadySent: boolean;

  FSPI: TBP5SPISettings;
  FI2C: TBP5I2CSettings;

  procedure Log(Level: TBP5LogLevel; const Msg: string);
  function SetError(const Msg: string): boolean;
  procedure MarkDesynced(const Why: string);

  //One request, one response. Returns the decoded response body.
  function Transact(const Request: TBytes; WantType: byte;
                    out Response: TBytes; out BodyPos: integer;
                    TimeoutMs: integer): boolean;

  function EncodeStatus(VersionAndModeOnly: boolean): TBytes;
  function EncodeConfig(const AMode: string; SpeedHz: LongWord;
                        DataBits: byte; ClockStretch, ClockPolarity,
                        ClockPhase, ChipSelectIdle: boolean;
                        SetBitorderMsb: boolean;
                        PsuEnable: boolean; PsuMv: LongWord; PsuMa: word;
                        Pullups: boolean): TBytes;
  function EncodeData(StartMain, StopMain: boolean; BytesRead: word;
                      WritePtr: Pointer; WriteCount: integer): TBytes;

  function ReadStatus(VersionAndModeOnly: boolean): boolean;
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

  //Cheap liveness check and the thing that proves BPIO2 is really active.
  function Ping: boolean;
  //Drains whatever is in flight and re-establishes the link and the mode.
  function Resync: boolean;
  //Refreshes the whole status block, for the device info window.
  function RefreshStatus: boolean;

  function EnterSPI(const Settings: TBP5SPISettings): boolean;
  function EnterI2C(const Settings: TBP5I2CSettings): boolean;
  function EnterHiZ: boolean;

  //--- SPI -------------------------------------------------------------------
  function SPIQueueWrite(Data: Pointer; Count: integer): boolean;
  function SPIFlushQueued: boolean;
  function SPITransfer(WritePtr: Pointer; WriteCount: integer;
                       ReadPtr: Pointer; ReadCount: integer;
                       Deassert: boolean): boolean;
  function SPIReleaseCS: boolean;
  procedure SPIDropQueued;

  //--- I2C -------------------------------------------------------------------
  function I2CStart: boolean;
  function I2CStop: boolean;
  function I2CWriteByte(Data: byte; out Acked: boolean): boolean;
  function I2CReadByte(out Data: byte; SendAck: boolean): boolean;
  function I2CWriteRead(DevAddr: byte; WritePtr: Pointer; WriteCount: integer;
                        ReadPtr: Pointer; ReadCount: integer): boolean;
  function I2CScan(FirstAddr, LastAddr: integer; out Found: TBytes): boolean;

  property LastError: string read FLastError;
  property Mode: TBP5Mode read FMode;
  property Status: TBP5Status read FStatus;
  property Desynced: boolean read FDesynced;
  property OnLog: TBP5LogEvent read FOnLog write FOnLog;
  property Verbose: boolean read FVerbose write FVerbose;
  property Port: TBP5Port read FPort;
end;

{ TBusPirate5Hardware }

TBusPirate5Hardware = class(TBaseHardware)
private
  FBP: TBusPirate5;
  FDevOpened: boolean;
  FStrError: string;
  FOpenPort: string;
  FAppliedConfig: string;

  procedure HandleLog(Level: TBP5LogLevel; const Msg: string);
  function Complain(const Msg: string): boolean;

  function WantI2C: boolean;
  function SelectedSPIHz: LongWord;
  function SelectedI2CHz: LongWord;
  function SelectedPsuMv: LongWord;
  function SelectedPsuMa: LongWord;
  function SPISettings: TBP5SPISettings;
  function I2CSettings: TBP5I2CSettings;
  function ConfigSignature: string;

  function Connect(const APort: string): boolean;
public
  constructor Create;
  destructor Destroy; override;

  function GetLastError: string; override;
  function DevOpen: boolean; override;
  procedure DevClose; override;

  //spi
  function SPIRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer; override;
  function SPIWrite(CS: byte; BufferLen: integer; buffer: array of byte): integer; override;
  function SPIInit(speed: integer): boolean; override;
  procedure SPIDeinit; override;

  //I2C
  procedure I2CInit; override;
  procedure I2CDeinit; override;
  function I2CReadWrite(DevAddr: byte;
                        WBufferLen: integer; WBuffer: array of byte;
                        RBufferLen: integer; var RBuffer: array of byte): integer; override;
  procedure I2CStart; override;
  procedure I2CStop; override;
  function I2CReadByte(ack: boolean): byte; override;
  function I2CWriteByte(data: byte): boolean; override; //return ack

  //MICROWIRE - not reachable over BPIO2, see the note in MWInit.
  function MWInit(speed: integer): boolean; override;
  procedure MWDeinit; override;
  function MWRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer; override;
  function MWWrite(CS: byte; BitsWrite: byte; buffer: array of byte): integer; override;
  function MWIsBusy: boolean; override;

  //Extras driven from the BusPirateV5+ menu.
  procedure Disconnect;
  //HiZ with the supply off, recovering the link first if it needs it.
  function SafePowerDown: boolean;
  function DeviceReport: string;
  function ScanI2CBus(out Found: TBytes; out ErrMsg: string): boolean;
  function I2CDeviceLine(Addr: byte): string;
  function I2CBusDescription: string;
  //Largest read the device will accept, for the chunk size ladders in main.pas.
  function MaxRead: integer;
end;

implementation

uses Registry, Menus, main;

//============================================================================
//  Serial transport
//============================================================================

const
  BPSER_DEADLOCK_MS = 15000;
  BPSER_RX_BUFFER   = 65536;

constructor TBP5Port.Create;
begin
  inherited Create;
  FSerial := TBlockSerial.Create;
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

function TBP5Port.Open(const APortName: string; ABaudRate: LongWord): boolean;
begin
  FLastError := '';
  Close;
  FPortName := APortName;

  FSerial.Connect(APortName);
  if FSerial.LastError <> 0 then Exit(Fail('cannot open ' + APortName));

  //USB CDC: the line settings are cosmetic, but they still have to be applied
  //or the driver may refuse the handle.
  if ABaudRate = 0 then ABaudRate := BP5_BAUD_DEFAULT;
  FSerial.Config(ABaudRate, 8, 'N', SB1, false, false);
  if FSerial.LastError <> 0 then
  begin
    Fail('cannot configure ' + APortName);
    FSerial.CloseSocket;
    Exit(false);
  end;

  //Must come after Config: the setter re-applies the DCB.
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

  //The deadline above restarts on every byte, on purpose, so a device that
  //trickles a long answer is not cut off half way. On its own that bounds
  //nothing: a stuck-low line or a break condition delivers a continuous stream
  //of 0x00, every byte of which is thrown away below as a leading delimiter
  //without ever growing the frame, and refreshes the window again. This runs on
  //the GUI thread with no message pump and no cancel, so it is a hard freeze,
  //and it is reachable by choosing any port that is not a Bus Pirate. Keep a
  //second deadline that nothing is allowed to touch, and a cap on how many
  //delimiters may be discarded before calling it what it is.  By Dreg
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
    //every single response pay the whole inter-byte timeout after its last
    //byte - which turned a 7 ms round trip into 47 ms.
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
        //Leading delimiters from a previous frame are just noise, but a stream
        //of nothing else is not noise, it is the wrong port or a broken line.
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
  //actually start the next request clean.
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

//============================================================================
//  COBS
//============================================================================

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

//============================================================================
//  FlatBuffers - little endian helpers and the generic decoder
//============================================================================

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

//Position of a field inside a table, or 0 when the field is absent - which in
//FlatBuffers means "equal to its schema default", never "not reported".
function FieldPos(const B: TBytes; Table, Slot: integer): integer;
var
  soff: longint;
  vt, vtsize: integer;
  vs, vo: word;
begin
  result := 0;
  if (Table < 0) or (Length(B) < 4) or (Table > Length(B) - 4) then Exit;
  //Signed: flatcc emits vtables AFTER their tables, so this is often negative.
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
  //Unsigned comparison against the space that is actually left. GetU32
  //succeeding already proves sp + 4 <= Length(B), so this cannot wrap.
  //A signed cast here made the guard pass for any length above $7FFFFFFF.
  if (n = 0) or (n > LongWord(Length(B) - sp - 4)) or (n > BP5_MAX_PACKET) then Exit;
  SetLength(result, n);
  for i := 1 to integer(n) do
    result[i] := Chr(B[sp + 3 + i]);
end;

//Vector of strings, joined with a separator - the GUI never needs them apart.
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
  //A vector of strings is four bytes per element, so this is what fits.
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

//Vector of ubyte. Count is returned so an empty vector can be told from absent.
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
  //Same rule, and this one guards a Move.
  if (n > LongWord(Length(B) - sp - 4)) or (n > BP5_MAX_PACKET) then Exit(false);
  SetLength(Data, n);
  if n > 0 then Move(B[sp + 4], Data[0], n);
  result := true;
end;

//============================================================================
//  Request templates
//============================================================================

//StatusRequest with an empty query table, which the firmware reads as "all".
const
  TPL_STATUS_ALL: array[0..35] of byte = (
    $14, $00, $00, $00, $0C, $00, $0C, $00, $04, $00, $06, $00, $05, $00, $08, $00,
    $04, $00, $04, $00, $10, $00, $00, $00, $02, $01, $00, $00, $04, $00, $00, $00,
    $10, $00, $00, $00);

//StatusRequest([Version, Mode]) - the connect probe. Its answer is ~470 bytes,
//comfortably inside the device's 643 byte frame buffer, where the "all" form
//comes back at 562 and leaves very little headroom.
  TPL_STATUS_VM: array[0..51] of byte = (
    $18, $00, $00, $00, $0C, $00, $0C, $00, $04, $00, $06, $00, $05, $00, $08, $00,
    $06, $00, $08, $00, $04, $00, $00, $00, $14, $00, $00, $00, $02, $01, $00, $00,
    $04, $00, $00, $00, $14, $00, $00, $00, $04, $00, $00, $00, $02, $00, $00, $00,
    $01, $02, $00, $00);

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
//   88 psu_set_mv (u32)   92 psu_set_ma (u16)   94 bitorder_msb  95 bitorder_lsb
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

//============================================================================
//  TBusPirate5
//============================================================================

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
  Log(bp5lError, Msg);
  result := false;
end;

procedure TBusPirate5.MarkDesynced(const Why: string);
begin
  if FDesynced or FRecovering then Exit;
  FDesynced := true;
  FPendingLen := 0;
  Log(bp5lInfo, 'BusPirateV5+: link out of sync (' + Why +
                '), it will be re-armed before the next operation');
end;

function TBusPirate5.IsOpen: boolean;
begin
  result := FPort.IsOpen and (FMode <> bp5Closed);
end;

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

  if FDesynced and (not FRecovering) then
    Exit(SetError('the link is out of sync after a failed transfer; it must be re-armed first'));

  frame := BP5CobsEncode(Request);
  SetLength(frame, Length(frame) + 1);
  frame[High(frame)] := 0;              //the delimiter

  FPort.Purge;
  if not FPort.WriteAll(frame[0], Length(frame)) then
    Exit(SetError(FPort.LastError));

  //A frame that cannot be the answer to THIS request has to be thrown away
  //rather than reported, or one stray packet desynchronises every operation
  //that follows. Our requests are built from verified templates and guarded,
  //so a framing or validation complaint from the device is by definition about
  //something else - another program on the port, line noise, or the tail of a
  //session that died. Keep reading until the deadline.
  deadline := GetTickCount64 + QWord(TimeoutMs);
  staleErr := '';
  skipped := 0;

  repeat
    //The budget is the budget. Without this the loop bought itself a fresh
    //window for every frame it discarded and could run for ever on the GUI
    //thread, with no way out.
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
      //Almost always this IS the answer: the firmware reports version and
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
      //without writing an error line: a 112 address bus scan used to leave 110
      //of them in the log. Framing, timeout and desync failures still go
      //through SetError and are still logged.  By Dreg
      FLastError := innerErr;
      Exit(false);
    end;

    if skipped > 0 then
      Log(bp5lInfo, 'BusPirateV5+: link resynchronised after ' + IntToStr(skipped) +
                    ' stray frame(s)');
    Response := raw;
    Exit(true);
  until false;
end;

function TBusPirate5.EncodeStatus(VersionAndModeOnly: boolean): TBytes;
begin
  if VersionAndModeOnly then
  begin
    SetLength(result, Length(TPL_STATUS_VM));
    Move(TPL_STATUS_VM[0], result[0], Length(result));
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

  //Guards for the three firmware landmines. These are internal errors, not
  //user errors: nothing must ever construct such a packet.
  if BytesRead > BP5_MAX_READ then
    raise Exception.CreateFmt('BPIO2: bytes_read %d exceeds %d', [BytesRead, BP5_MAX_READ]);
  if WriteCount > BP5_MAX_WRITE then
    raise Exception.CreateFmt('BPIO2: data_write %d exceeds %d', [WriteCount, BP5_MAX_WRITE]);
  //A read that opens with a start makes the firmware read data_write[0] to
  //build the read address, without checking that the vector is there.
  if StartMain and (BytesRead > 0) and (WriteCount < 1) then
    raise Exception.Create('BPIO2: a read with a start needs at least one write byte');

  //Prefix, then the vector, padded to a multiple of four.
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
  PsuEnable: boolean; PsuMv: LongWord; PsuMa: word; Pullups: boolean): TBytes;
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
  if SetBitorderMsb then result[94] := 1;      //bitorder_lsb stays 0
  if PsuEnable then result[97] := 1 else result[96] := 1;
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

function TBusPirate5.ReadStatus(VersionAndModeOnly: boolean): boolean;
var
  raw: TBytes;
  body: integer;
begin
  FStatus.Valid := false;
  if not Transact(EncodeStatus(VersionAndModeOnly), BP5_RSP_STATUS, raw, body, 2500) then
    Exit(false);

  FStatus.FbMajor := FieldU8(raw, body, BP5_SR_FB_MAJOR);
  FStatus.FbMinor := FieldU16(raw, body, BP5_SR_FB_MINOR);
  FStatus.HwMajor := FieldU8(raw, body, BP5_SR_HW_MAJOR);
  FStatus.HwMinor := FieldU8(raw, body, BP5_SR_HW_MINOR);
  FStatus.ModeCurrent := FieldStr(raw, body, BP5_SR_MODE_CURRENT);

  if not VersionAndModeOnly then
  begin
    FStatus.GitHash := FieldStr(raw, body, BP5_SR_GIT_HASH);
    FStatus.FwDate := FieldStr(raw, body, BP5_SR_FW_DATE);
    FStatus.Modes := FieldStrList(raw, body, BP5_SR_MODES, ', ');
    FStatus.MaxPacket := FieldU32(raw, body, BP5_SR_MAX_PACKET);
    FStatus.MaxWrite := FieldU32(raw, body, BP5_SR_MAX_WRITE);
    FStatus.MaxRead := FieldU32(raw, body, BP5_SR_MAX_READ);
    FStatus.PsuEnabled := FieldBool(raw, body, BP5_SR_PSU_ENABLED);
    FStatus.PsuSetMv := FieldU32(raw, body, BP5_SR_PSU_SET_MV);
    FStatus.PsuSetMa := FieldU32(raw, body, BP5_SR_PSU_SET_MA);
    FStatus.PsuMeasMv := FieldU32(raw, body, BP5_SR_PSU_MEAS_MV);
    FStatus.PsuMeasMa := FieldU32(raw, body, BP5_SR_PSU_MEAS_MA);
    FStatus.PsuError := FieldBool(raw, body, BP5_SR_PSU_ERROR);
    FStatus.PullupEnabled := FieldBool(raw, body, BP5_SR_PULLUP_ENABLED);
    //Absent means the schema default, which is 0 - and 0 is not a usable
    //limit, so fall back to the firmware's compiled-in constants.
    if FStatus.MaxPacket = 0 then FStatus.MaxPacket := BP5_MAX_PACKET;
    if FStatus.MaxWrite = 0 then FStatus.MaxWrite := BP5_MAX_WRITE;
    if FStatus.MaxRead = 0 then FStatus.MaxRead := BP5_MAX_READ;
  end;

  FStatus.Valid := true;
  result := true;
end;

function TBusPirate5.Open(const APortName: string; ABaudRate: LongWord): boolean;
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
  if not ReadStatus(true) then
  begin
    FPort.Close;
    FMode := bp5Closed;
    Exit(SetError('no BPIO2 answer on ' + APortName + '. ' +
      'On the Bus Pirate terminal port run "binmode", choose "BPIO2 flatbuffer ' +
      'interface" and answer y to "Save setting?". The factory default is the ' +
      'SUMP logic analyser, which uses the same port and will not answer here.'));
  end;

  //Now that the link is proven, get the full picture including the limits. A
  //failure here is not fatal - the probe already answered - but it must not be
  //silently swallowed, because the limits fall back to the compiled defaults.
  if not ReadStatus(false) then
  begin
    Log(bp5lInfo, 'BusPirateV5+: full status read failed (' + FLastError +
                  '), using the built-in limits');

    //Not fatal, but it must not survive as a desync flag. ReadStatus(true)
    //already proved the link, and this second read is the larger one: it
    //carries the mode name vector and the firmware strings, so it is the one
    //that times out on a slow or noisy link. Leaving FDesynced set here makes
    //Open return true and then have the very next EnterSPI refused by the
    //guard, with nothing in the path to re-arm it, because DevOpen's Resync
    //branch already ran before Connect.  By Dreg
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
  junk: integer;
  wanted: TBP5Mode;
  ok: boolean;
  delim: byte;
begin
  //Always runs, even when nothing has been flagged: the caller may know the
  //link is dirty for a reason this object never saw.
  if not FPort.IsOpen then Exit(false);

  wanted := FMode;
  FRecovering := true;
  try
    //First close whatever half a frame the device may still be accumulating.
    //A lone delimiter costs nothing when the device is idle, and it is the
    //only way out when it is not: without it the device would splice the next
    //request onto the tail of the broken one and reject both. This is the
    //BPIO2 counterpart of walking the v3.x terminal back into bitbang.
    delim := 0;
    FPort.WriteAll(delim, 1);

    //Then wait for it to finish answering - the error for that broken frame,
    //or a reply we gave up on - and throw all of it away. A 512 byte read is
    //562 framed bytes and can still be on its way.
    junk := FPort.Drain(300, 5000);
    FPort.Purge;
    if junk > 0 then
      Log(bp5lInfo, 'BusPirateV5+: discarded ' + IntToStr(junk) +
                    ' late byte(s) from the aborted transfer');
    FPendingLen := 0;
    FCSAsserted := false;
    FStopAlreadySent := false;

    ok := ReadStatus(true);
    if ok then
      case wanted of
        bp5SPI: ok := EnterSPI(FSPI);
        bp5I2C: ok := EnterI2C(FI2C);
      end;
  finally
    FRecovering := false;
  end;

  FDesynced := not ok;
  if ok then
    Log(bp5lInfo, 'BusPirateV5+: link re-armed')
  else
    Log(bp5lError, 'BusPirateV5+: could not re-arm the link: ' + FLastError);
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
begin
  hz := Settings.SpeedHz;
  if hz < BP5_SPI_MIN_HZ then hz := BP5_SPI_MIN_HZ;
  if hz > BP5_SPI_MAX_HZ then hz := BP5_SPI_MAX_HZ;

  FPendingLen := 0;
  if not SendConfig(EncodeConfig('SPI', hz, 8, false,
                                 Settings.ClockPolarity, Settings.ClockPhase,
                                 Settings.ChipSelectIdleHigh, true,
                                 Settings.Power, Settings.PsuMv,
                                 word(Settings.PsuMa), Settings.Pullups),
                    'SPI configuration') then Exit(false);

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
begin
  hz := Settings.SpeedHz;
  //The firmware divides this by 1000 and then divides by the result; below
  //1 kHz that is a division by zero on the device.
  if hz < BP5_I2C_MIN_HZ then hz := BP5_I2C_MIN_HZ;
  if hz > BP5_I2C_MAX_HZ then hz := BP5_I2C_MAX_HZ;

  FPendingLen := 0;
  if not SendConfig(EncodeConfig('I2C', hz, 8, false, false, false, true, true,
                                 Settings.Power, Settings.PsuMv,
                                 word(Settings.PsuMa), Settings.Pullups),
                    'I2C configuration') then Exit(false);

  FMode := bp5I2C;
  FI2C := Settings;
  FI2C.SpeedHz := hz;
  FStopAlreadySent := false;

  Log(bp5lInfo, 'BusPirateV5+: I2C ready, ' + IntToStr(hz div 1000) + ' kHz');
  result := true;
end;

function TBusPirate5.EnterHiZ: boolean;
begin
  //Everything off: this is the safe state to leave the device in.
  if not SendConfig(EncodeConfig('HiZ', 20000, 8, false, false, false, true,
                                 false, false, 0, 0, false),
                    'HiZ configuration') then Exit(false);
  FMode := bp5HiZ;
  FCSAsserted := false;
  FPendingLen := 0;
  result := true;
end;

//--- transfers ----------------------------------------------------------------

function TBusPirate5.DataExchange(StartMain, StopMain: boolean; BytesRead: word;
  WritePtr: Pointer; WriteCount: integer; ReadPtr: Pointer): boolean;
var
  raw, got: TBytes;
  body: integer;
  timeout: integer;
begin
  //Roughly 0.7 ms of protocol overhead plus the bus time, generously rounded.
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

    //A read that opens the transaction must carry the command bytes with it.
    if startMain and (rslice > 0) and (wslice = 0) then
    begin
      //Nothing to write but CS is idle: assert it on its own first, so the
      //firmware never has to invent a read address out of an empty vector.
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

//--- I2C ----------------------------------------------------------------------

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
  //A NACK and a bus timeout are the same string on the wire, so the honest
  //answer is "acknowledged only if the whole request succeeded". A NACK is a
  //normal answer though - acknowledge polling produces one per attempt - so
  //the call itself still counts as having worked, and nothing is logged.
  Acked := result;
  if not result and (not FDesynced) then
  begin
    FLastError := 'I2C write not acknowledged (NACK or bus timeout)';
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
begin
  if FMode <> bp5I2C then Exit(SetError('not in I2C mode'));
  if WriteCount < 0 then WriteCount := 0;
  if ReadCount < 0 then ReadCount := 0;
  if ReadCount > BP5_MAX_READ then
    Exit(SetError('I2C read of ' + IntToStr(ReadCount) + ' bytes exceeds ' +
                  IntToStr(BP5_MAX_READ)));
  if WriteCount + 1 > BP5_MAX_WRITE then
    Exit(SetError('I2C write of ' + IntToStr(WriteCount) + ' bytes exceeds ' +
                  IntToStr(BP5_MAX_WRITE - 1)));

  //The address byte leads the write vector; the firmware masks bit 0 for the
  //write phase and sets it for the read phase after its own repeated start.
  SetLength(buf, WriteCount + 1);
  buf[0] := DevAddr;
  if (WriteCount > 0) and (WritePtr <> nil) then
    Move(PByte(WritePtr)^, buf[1], WriteCount);

  result := DataExchange(true, true, word(ReadCount), @buf[0], Length(buf), ReadPtr);
  if not result then
  begin
    //Say which device did not answer, but never at the cost of the reason. This
    //used to overwrite the real message unconditionally, which turned a plain
    //"read of 2048 bytes exceeds 512" into "no I2C answer from device $A0" and
    //sent the reader looking at their wiring.  By Dreg
    if FLastError = '' then
      FLastError := 'no I2C answer from device $' + IntToHex(DevAddr, 2)
    else
      FLastError := 'device $' + IntToHex(DevAddr, 2) + ': ' + FLastError;

    //Every firmware error path returns before its cleanup label, so a failed
    //transfer leaves the bus held. Release it.
    if not FDesynced then DataExchange(false, true, 0, nil, 0, nil);
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

  SetLength(Found, count);
  result := true;
end;

//============================================================================
//  Device enumeration
//============================================================================

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

      //Find every composite interface of the Bus Pirate rather than assuming a
      //fixed instance suffix: the child key names differ between machines and
      //between Windows versions, and hardcoding one is how this breaks on
      //somebody else's PC.
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
      //It lives under the base key, whose children carry a ParentIdPrefix that
      //matches the group. Best effort only - a build without the manufacturing
      //test mode ships a hex serial instead.
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
      //port list, never from the registry.
      for n := 0 to High(result) do
        result[n].Present := (result[n].DataPort <> '') and
                             (present.IndexOf(result[n].DataPort) >= 0);
    except
      //A locked or ACL-denied key must degrade to "no annotation", never to a
      //crash: the menu still lists every port from BP5GetSerialPorts.
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

//============================================================================
//  TBusPirate5Hardware
//============================================================================

//Address of the first element, or nil for an empty slice. Callers pass buffers
//that are almost always larger than Count, and sometimes a bare byte variable,
//so Count is what decides and never Length().
function SlicePtr(const Buffer: array of byte; Count: integer): Pointer;
begin
  if (Count > 0) and (Length(Buffer) > 0) then
    result := @Buffer[0]
  else
    result := nil;
end;

//Tag of whichever child of a submenu is checked.
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

//Puts the pins high impedance and the supply off, even when the link is out of
//step - which is exactly when it matters, because a desynchronised link
//refuses every request and would otherwise leave the target powered.
function TBusPirate5Hardware.SafePowerDown: boolean;
begin
  result := false;
  if not FBP.IsOpen then Exit;

  if FBP.Desynced then
    if not FBP.Resync then
    begin
      LogPrint('BusPirateV5+: could not re-arm the link, so the target may ' +
               'still be powered - unplug the Bus Pirate to be sure');
      Exit;
    end;

  if FBP.Mode = bp5SPI then FBP.SPIReleaseCS;
  result := FBP.EnterHiZ;
  if not result then
    LogPrint('BusPirateV5+: could not switch to HiZ (' + FBP.LastError +
             '), the target may still be powered');
end;

procedure TBusPirate5Hardware.HandleLog(Level: TBP5LogLevel; const Msg: string);
begin
  LogPrint(Msg);
end;

function TBusPirate5Hardware.Complain(const Msg: string): boolean;
begin
  FStrError := Msg;
  //Anything that went wrong makes the session suspect, so the next DevOpen
  //re-arms the device instead of trusting a liveness check.
  FAppliedConfig := '';
  LogPrint('BusPirateV5+: ' + Msg);
  result := false;
end;

function TBusPirate5Hardware.GetLastError: string;
begin
  result := FStrError;
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
  //Same default as the v3.x back end: slow enough to work on any wiring.
  //The menu goes to 16 MHz for anyone who wants it.
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
  //I2C without pull-ups is not a bus, so they follow the menu but the pull-up
  //bank is referenced to VOUT and needs the supply on to do anything.
  result.Pullups := MainForm.MenuBP5Pullups.Checked;
end;

//Anything in here changing means the device has to be reconfigured.
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

  if not FBP.Open(APort) then Exit(Complain(FBP.LastError));

  LogPrint(Format('BusPirateV5+: Bus Pirate %d REV%d, firmware %s',
    [FBP.Status.HwMajor, FBP.Status.HwMinor, FBP.Status.FwDate]));

  FOpenPort := APort;
  result := true;
end;

function TBusPirate5Hardware.DevOpen: boolean;
var
  port, signature: string;
  needConnect, lostPing: boolean;
begin
  FStrError := '';
  FDevOpened := false;
  lostPing := false;
  FBP.Verbose := MainForm.MenuBP5Verbose.Checked;

  port := Trim(main.BusPirate5_COMPort);
  if port = '' then Exit(Complain('no COM port selected (BusPirateV5+ menu -> COM port)'));

  signature := ConfigSignature;

  //A transfer that died left the device mid-answer. Get the stream back in
  //step before anything else is considered.
  if FBP.Desynced then
  begin
    LogPrint('BusPirateV5+: the last transfer failed, re-arming the link');
    FAppliedConfig := '';
    if not FBP.Resync then
      if not Connect(port) then Exit(false);
  end;

  //Fast path: same port, same settings, device still answering.
  if FBP.IsOpen and (port = FOpenPort) and (signature = FAppliedConfig) and
     (not MainForm.MenuBP5ResetEach.Checked) then
  begin
    if FBP.Ping then
    begin
      //An operation cancelled mid transaction can leave CS asserted. Releasing
      //it is a transaction of its own, so it can fail and desync the link. Fall
      //through to the reconnect when it does, rather than returning a link this
      //function already knows is broken.  By Dreg
      if (FBP.Mode <> bp5SPI) or FBP.SPIReleaseCS then
      begin
        FDevOpened := true;
        Exit(true);
      end;
      LogPrint('BusPirateV5+: could not release chip select, reconnecting');
      lostPing := true;
    end
    else
    LogPrint('BusPirateV5+: device stopped answering, reconnecting');
    //A failed Ping desynchronises the link, so every later request would be
    //refused. Say so here, or the reconnect this line promises never happens
    //and the operation dies on the guard instead.
    lostPing := true;
  end;

  needConnect := MainForm.MenuBP5ResetEach.Checked or lostPing or
                 (not FBP.IsOpen) or (port <> FOpenPort);

  if needConnect then
  begin
    //One cheap attempt to re-arm what is already open before tearing the port
    //down and running the whole handshake again.
    if lostPing and FBP.Desynced and FBP.Resync then
      LogPrint('BusPirateV5+: link re-armed without reopening the port')
    else
      if not Connect(port) then Exit(false);
  end;

  //Drop the claim before touching the device: a mode change that dies half way
  //must not leave a signature the next DevOpen would fast path on.
  FAppliedConfig := '';

  if WantI2C then
  begin
    if not FBP.EnterI2C(I2CSettings) then Exit(Complain(FBP.LastError));
  end
  else
    if not FBP.EnterSPI(SPISettings) then Exit(Complain(FBP.LastError));

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

  //Only tear the link down when the user asked for it. Keeping it up is what
  //makes the next operation start instantly.
  if MainForm.MenuBP5ResetEach.Checked then
  begin
    SafePowerDown;
    FBP.Close;
    FOpenPort := '';
    FAppliedConfig := '';
  end;
end;

procedure TBusPirate5Hardware.Disconnect;
begin
  FDevOpened := false;
  if FBP.IsOpen then SafePowerDown;
  FBP.Close;
  FOpenPort := '';
  FAppliedConfig := '';
end;

//--- SPI ----------------------------------------------------------------------

function TBusPirate5Hardware.SPIInit(speed: integer): boolean;
begin
  //The clock comes from the menu and DevOpen has already sent it; the argument
  //is an opaque menu tag, not Hz.
  result := FDevOpened and (FBP.Mode = bp5SPI);
  if not result then FStrError := 'SPI mode is not active';
end;

procedure TBusPirate5Hardware.SPIDeinit;
begin
  if not FDevOpened then Exit;
  if FBP.Mode <> bp5SPI then Exit;
  //Teardown: drop anything queued rather than clocking an abandoned fragment
  //onto the chip as a complete CS framed transaction.
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

//--- I2C ----------------------------------------------------------------------

procedure TBusPirate5Hardware.I2CInit;
begin
  //Configured by DevOpen.
end;

procedure TBusPirate5Hardware.I2CDeinit;
begin
  //Nothing to undo, the mode stays valid until the link is closed.
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

//--- MICROWIRE ----------------------------------------------------------------

//BPIO2 cannot do Microwire, for three independent reasons: the firmware's
//3WIRE handlers are compiled but not wired into its BPIO dispatch table, the
//DataRequest schema is byte granular where Microwire needs odd bit counts, and
//the only way to sample the busy pin would be a USB round trip per bit.
const
  MW_UNSUPPORTED = 'Microwire is not available on the Bus Pirate v5+ (BPIO2). ' +
                   'Use a Bus Pirate v3.x for Microwire parts.';

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
  result := -1;
end;

function TBusPirate5Hardware.MWWrite(CS: byte; BitsWrite: byte;
  buffer: array of byte): integer;
begin
  FStrError := MW_UNSUPPORTED;
  result := -1;
end;

function TBusPirate5Hardware.MWIsBusy: boolean;
begin
  result := false;
end;

//--- extras -------------------------------------------------------------------

function TBusPirate5Hardware.DeviceReport: string;
begin
  if not FBP.IsOpen then
  begin
    if Trim(main.BusPirate5_COMPort) = '' then Exit('No COM port selected');
    if not Connect(Trim(main.BusPirate5_COMPort)) then
      Exit('Cannot reach the device: ' + FBP.LastError);
  end
  else
    //Otherwise a single failed transfer would leave this menu command dead
    //for the rest of the session.
    if FBP.Desynced then
    begin
      FAppliedConfig := '';
      if not FBP.Resync then
        if not Connect(Trim(main.BusPirate5_COMPort)) then
          Exit('Cannot reach the device: ' + FBP.LastError);
    end;

  if not FBP.RefreshStatus then
    Exit('Cannot read the device status: ' + FBP.LastError);

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

  //The firmware hardcodes its version fields to zero, so they are never shown.
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

  if (not FBP.IsOpen) or (port <> FOpenPort) then
  begin
    if not Connect(port) then
    begin
      ErrMsg := FBP.LastError;
      Exit;
    end;
  end
  else
    //A previous failure must not make the scanner permanently unavailable.
    if FBP.Desynced then
      if not FBP.Resync then
        if not Connect(port) then
        begin
          ErrMsg := FBP.LastError;
          Exit;
        end;

  //The scan runs whatever the SPI/I2C radio says, so leave the session dirty
  //on purpose: the next real operation re-arms the user's own settings.
  FAppliedConfig := '';

  if not FBP.EnterI2C(I2CSettings) then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;

  if not FBP.I2CScan(8, 119, Found) then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;
  result := true;
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
