unit buzzpirathw;

{
  Buzzpirat / Bus Pirate v3.x programmer back end for AsProgrammer.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  Originally based on arduinohw. Rewritten so the device is driven straight
  from Pascal: the old buzzpirathlp.dll is gone, together with its log file,
  its tail.exe console and its busy-wait loops.

  Everything lives in this one unit, in three layers:

    TBPSerialPort         serial transport, a thin deterministic wrapper over
                          Synapse's TBlockSerial (synaser.pas, already part of
                          this project and used by arduinohw.pas). No OS API is
                          called directly anywhere in here.

    TBusPirate            the binary (BBIO) protocol engine: mode entry, SPI,
                          I2C and the Buzzpirat specific "buzz" commands.

    TBuzzpiratHardware    the TBaseHardware implementation AsProgrammer talks
                          to, plus the reading of the Buzzpirat menu settings.

  Reference material:
    - http://buzzpirat.com/docs/binaryio/  (BBIO command reference)
    - buzzpirat firmware: binary_io.c, spi.c, i2c.c, buzz.c, proc_menu.c
    - flashrom programmers/buspirate_spi.c

  Design notes worth knowing before touching this unit:

  * Entering bitbang mode: the firmware answers every 0x00 with "BBIO1".
    Blasting 20 of them back to back overruns the PIC UART and can leave the
    firmware in an endless BBIO1 loop that only a USB re-plug clears. So one
    0x00 goes out at a time and the answer is checked before the next one.

  * Bulk transfers are capped at 4096 bytes each way (the firmware's
    terminal_input buffer). Going over that makes the firmware answer 0x00 and
    drop straight back to its command loop *without* consuming the payload,
    which then gets executed as commands. Never let a slice exceed BP_MAX_BULK.

  * A whole transaction is assembled into one buffer and written in a single
    call, then all the replies are read back together. Round trips, not
    bandwidth, are what cost time here: an FT232R sits on a 16 ms latency timer
    by default, so four round trips per flash page is the difference between
    two minutes and half an hour.

  * Session handling: AsProgrammer calls DevOpen/DevClose around every single
    operation. Re-running the whole handshake each time costs seconds, so the
    connection is kept alive between operations and DevOpen only verifies it
    with a four byte round trip. It falls back to a full re-init whenever that
    check fails or the user changed a setting.

  * The link starts at 115200 baud, which is where the device comes up and
    where it returns after every hardware reset. A faster rate is negotiated
    through the firmware's own "b" terminal menu, and only ever from the
    terminal - never blind. Every step of that is checked, the driver asks the
    serial driver whether it can even produce the rate before telling the
    device to move, and any failure falls straight back to 115200. The device
    divides 4 MHz by (BRG+1), so 250000, 1M and 2M are exact; 230400 is not
    reachable at all and the nearest divisor is 2.1% off.

  * Never send a command while the firmware may be bit-banging. In binary mode
    user_serial_read_byte() (base.c) is a blocking poll on the raw PIC UART:
    there is no interrupt ring buffer, only the four byte hardware FIFO. More
    than four bytes of backlog latches OERR, and OERR is only cleared back in
    the user terminal (proc_menu.c), so the device goes deaf until it is
    unplugged. Everything here is therefore strictly request/response, and a
    command is only ever concatenated with another when the firmware is known
    to consume both without touching the bus in between:
      - the bulk SPI/I2C commands read their entire payload into terminal_input
        before a single clock edge is generated (streaming is #undef'd in the
        firmware's configuration.h), so a 4096 byte payload is safe;
      - at most one trailing byte (CS high) may follow a bulk command, and one
        byte always fits in the FIFO however long the transfer takes.
    Anything more ambitious - batching several bus transactions into one write
    - would overrun the FIFO at low bus speeds and is deliberately not done.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Dialogs, Synaser, basehw;

//============================================================================
//  Serial transport
//============================================================================

const
  //Windows queues only 4096 bytes by default (synaser), too tight for a
  //4096 byte bulk read at 2 Mbaud.
  BPSER_RX_BUFFER   = 65536;

  //Upper bound for a single SendBuffer/RecvBuffer to complete.
  BPSER_DEADLOCK_MS = 15000;

type

{ TBPSerialPort }

TBPSerialPort = class
private
  FSerial: TBlockSerial;
  FPortName: string;
  FBaudRate: LongWord;
  FLastError: string;
  FRxCount: int64;
  function Fail(const Where: string): boolean;
  function ApplyBaudRate(Baud: LongWord): boolean;
public
  constructor Create;
  destructor Destroy; override;

  function Open(const APortName: string; ABaudRate: LongWord): boolean;
  procedure Close;
  function IsOpen: boolean;

  //Changes the line rate of the host side only.
  function SetBaudRate(ABaudRate: LongWord): boolean;
  //Tries a rate and puts the old one back; tells whether the driver accepts it.
  function SupportsBaudRate(ABaudRate: LongWord): boolean;

  function WriteAll(const Buffer; Count: integer): boolean;
  function WriteByteValue(Value: byte): boolean;

  //Reads exactly Count bytes. TimeoutMs is an inter-packet timeout: the clock
  //restarts whenever something arrives, so slow devices are fine but silent
  //ones are not.
  function ReadAll(var Buffer; Count: integer; TimeoutMs: integer): boolean;
  function ReadByteValue(out Value: byte; TimeoutMs: integer): boolean;

  procedure Purge;
  //Reads and discards until the line stays quiet for IdleMs, MaxMs at most.
  function Drain(IdleMs, MaxMs: integer): integer;
  function BytesWaiting: integer;
  //Blocks until everything queued has physically left the port.
  procedure WaitSent;

  property LastError: string read FLastError;
  property PortName: string read FPortName;
  property BaudRate: LongWord read FBaudRate;
  //Total bytes ever received on this port, for liveness decisions.
  property RxCount: int64 read FRxCount;
end;

//Comma separated list of the serial ports the system knows about.
function BPSerialPortList: string;
//The same list, split, trimmed and sorted the way a human reads COM numbers.
procedure BPGetSerialPorts(AList: TStrings);

//============================================================================
//  Bus Pirate binary protocol engine
//============================================================================

const
  //--- raw bitbang (BBIO) ----------------------------------------------------
  BBIO_RESET_BITBANG     = $00;   // -> "BBIO1"
  BBIO_ENTER_SPI         = $01;   // -> "SPI1"
  BBIO_ENTER_I2C         = $02;   // -> "I2C1"
  BBIO_ENTER_BUZZ        = $0A;   // -> 0x01
  BBIO_RESET_DEVICE      = $0F;   // -> 0x01, then hardware reset + banner

  //--- common to every binary protocol mode ---------------------------------
  BPCMD_MODE_ID          = $01;   // -> mode identifier string
  BPCMD_PERIPHERALS      = $40;   // or wxyz: w=power x=pullups y=aux z=cs
  BPCMD_BUZZ             = $FE;   // -> 0x01, then one buzz sub command

  BP_PERIPH_CS           = $01;
  BP_PERIPH_AUX          = $02;
  BP_PERIPH_PULLUPS      = $04;
  BP_PERIPH_POWER        = $08;

  //--- raw SPI ---------------------------------------------------------------
  SPICMD_CS_LOW          = $02;
  SPICMD_CS_HIGH         = $03;
  SPICMD_WRITE_READ_CS   = $04;   // firmware drives CS around the transfer
  SPICMD_WRITE_READ_NOCS = $05;
  SPICMD_SPEED           = $60;   // or 0..7
  SPICMD_CONFIG          = $80;   // or wxyz: w=3v3 x=ckp y=cke z=smp

  SPI_CFG_OUT_3V3        = $08;   // 0 = HiZ / open drain
  SPI_CFG_CKP_IDLE_HIGH  = $04;
  SPI_CFG_CKE_ACT2IDLE   = $02;
  SPI_CFG_SMP_END        = $01;

  //--- raw I2C ---------------------------------------------------------------
  I2CCMD_START           = $02;
  I2CCMD_STOP            = $03;
  I2CCMD_READ_BYTE       = $04;
  I2CCMD_ACK             = $06;
  I2CCMD_NACK            = $07;
  I2CCMD_WRITE_READ      = $08;
  I2CCMD_BULK_WRITE      = $10;   // or (n-1), 1..16 bytes
  I2CCMD_SPEED           = $60;   // or 0..3

  //--- buzz mode sub commands ------------------------------------------------
  BUZZ_VOLTAGES          = $00;   // 12 bytes of ADC, then 0x01
  BUZZ_TP0_INPUT_LOW     = $01;
  BUZZ_TP0_OUTPUT_LOW    = $02;
  BUZZ_TP0_READ          = $03;
  BUZZ_PSU_CHECK         = $10;   // 0x01 = rails healthy, 0x00 = shorted/low
  BUZZ_PROBE_VOLTAGE     = $14;
  BUZZ_NOP               = $69;
  BUZZ_IS_BPV3_BUILD     = $96;

  BP_ACK                 = $01;
  BP_NAK                 = $00;

  //Firmware side buffer for one bulk transfer (BP_TERMINAL_BUFFER_SIZE).
  BP_MAX_BULK            = 4096;

  //The one and only line rate. The device boots at it, returns to it after
  //every hardware reset, and this driver never asks it to change.
  BP_DEFAULT_BAUD        = 115200;

  //Highest amount of queued CS-low write bytes before they get pushed out.
  BP_PENDING_LIMIT       = 65536;

  BP_SPI_SPEED_HZ: array[0..11] of LongWord =
    (30000, 125000, 250000, 1000000, 50000, 1300000, 2000000, 2600000,
     3200000, 4000000, 5300000, 8000000);

  //The eight clocks the BBIO documentation defines, in the order it defines
  //them. This is the table the Bus Pirate v5/v6/v7 legacy emulation decodes,
  //and it is not a prefix of the PIC's own table above: they diverge from index
  //4 upwards.  By Dreg
  BP_SPI_SPEED_DOC_HZ: array[0..7] of LongWord =
    (30000, 125000, 250000, 1000000, 2000000, 2600000, 4000000, 8000000);

  BP_I2C_SPEED_HZ: array[0..3] of LongWord =
    (5000, 50000, 100000, 400000);

  //Rates the firmware's raw BRG entry can reach on a 16 MIPS PIC24. The PIC
  //divides 4 MHz by (BRG+1), so 250000, 1M and 2M are exact; 230400 is not
  //reachable at all (the nearest divisor gives 235294, 2.1% off).
  BP_SERIAL_SPEEDS: array[0..4] of LongWord =
    (115200, 230400, 250000, 1000000, 2000000);

  //Range i2cdetect probes by default. 0x00..0x07 and 0x78..0x7F are reserved
  //by the I2C specification (general call, CBUS, 10-bit addressing) and
  //poking them can reset or confuse perfectly innocent devices.
  BP_I2C_SCAN_FIRST      = $08;
  BP_I2C_SCAN_LAST       = $77;

type
  TBPMode = (bpmClosed, bpmTerminal, bpmBitbang, bpmSPI, bpmI2C);

  TBPLogLevel = (bplError, bplInfo, bplDebug);
  TBPLogEvent = procedure(Level: TBPLogLevel; const Msg: string) of object;

  TBPSPISettings = record
    Speed: byte;                  // index into BP_SPI_SPEED_HZ
    PushPull: boolean;            // true = 3.3V push-pull, false = HiZ open drain
    ClockIdleHigh: boolean;
    ClockEdgeActiveToIdle: boolean;
    SampleAtEnd: boolean;
    Pullups: boolean;
    Power: boolean;
    AuxHigh: boolean;
  end;

  TBPI2CSettings = record
    Speed: byte;                  // index into BP_I2C_SPEED_HZ
    Pullups: boolean;
    Power: boolean;
    AuxHigh: boolean;
  end;

  TBPVoltages = record
    V50, V33, V25, V18, VPullup, VProbe: double;
  end;

{ TBusPirate }

TBusPirate = class
private
  FPort: TBPSerialPort;
  FMode: TBPMode;
  FLastError: string;
  FOnLog: TBPLogEvent;
  FVerbose: boolean;

  FTx: array of byte;
  FTxLen: integer;

  //Bytes handed over with CS asked to stay low. They are held back so they can
  //ride along with the next transfer as a single command.
  FPending: array of byte;
  FPendingLen: integer;

  FCSLow: boolean;
  FBusHz: LongWord;
  //Set right after a hardware reset, when the firmware's NUL counter is known
  //to be zero and 19 of them can go out in one burst without any answer.
  FTerminalFresh: boolean;
  FDesynced: boolean;
  FRecovering: boolean;

  FSPI: TBPSPISettings;
  FI2C: TBPI2CSettings;

  FBanner: string;
  FHardware: string;
  FFirmware: string;
  FHwMajor, FHwMinor: integer;
  FFwMajor, FFwMinor: integer;
  FIsBuzzpirat: boolean;

  procedure Log(Level: TBPLogLevel; const Msg: string);
  function SetError(const Msg: string): boolean;
  //Records that a reply was left in flight, so nothing may be read until the
  //link has been put back on its feet.
  procedure MarkDesynced(const Why: string);

  procedure TxReset;
  procedure TxNeed(Extra: integer);
  procedure TxAddByte(Value: byte);
  procedure TxAddBuffer(const Buffer; Count: integer);
  function TxSend: boolean;

  function RxBuffer(var Buffer; Count, TimeoutMs: integer): boolean;
  function RxByte(out Value: byte; TimeoutMs: integer): boolean;
  function ExpectAck(const What: string; TimeoutMs: integer): boolean;

  //Reads until Text has been seen or the deadline passes.
  function WaitText(const Text: string; TimeoutMs: integer): boolean;

  function BusTimeout(BusBytes, WireBytes: integer): integer;
  function CommandWithAck(Command: byte; const What: string): boolean;

  function ProbeCurrentMode(out Detected: TBPMode; TimeoutMs: integer): boolean;
  function SendPeripherals(Power, Pullups, AuxHigh, CSHigh: boolean): boolean;
  //Everything a protocol mode needs after the mode identifier has come back.
  //Separate from EnterSPI/EnterI2C because the buzz power supply check has to
  //re-run it: it leaves the regulator off, and in open drain mode it also
  //leaves CS as an input until spi_setup() runs again.
  function ApplySPISettings: boolean;
  function ApplyI2CSettings: boolean;
  //Re-enters a protocol mode from bitbang with the settings already stored.
  function ApplyModeAgain(Wanted: TBPMode): boolean;
  function ReadBanner(TimeoutMs: integer): boolean;
  procedure ParseBanner;
  function SendTerminalLine(const Line: string): boolean;

  function PendingAdd(const Buffer; Count: integer): boolean;
  function SPIExecSlice(WriteOffset, WriteCount: integer;
                        ReadPtr: Pointer; ReadCount: integer;
                        Deassert: boolean): boolean;
public
  constructor Create;
  destructor Destroy; override;

  //Opens the port and gets the device into raw bitbang mode, retrying at the
  //other plausible line rates if a previous run left the device fast.
  function Open(const APortName: string): boolean;
  procedure Close(ResetDevice: boolean);
  function IsOpen: boolean;

  //Cheap liveness check: asks the current mode to name itself.
  function Ping: boolean;

  //Waits for the device to finish whatever it was answering, throws the answer
  //away and re-arms the mode it was in. The only way out of a desynchronised
  //link, and the only thing that clears Desynced.
  function Resync: boolean;

  function EnterBitbang: boolean;
  //0x0F: acknowledges, resets the hardware and prints the version banner.
  //Leaves the device sitting at its user terminal at BP_DEFAULT_BAUD.
  function ResetToTerminal: boolean;
  //Talks the terminal's "b" menu into a raw BRG value, then follows on the
  //host side. Only call while in terminal mode. A refusal is not fatal: the
  //link simply stays at 115200.
  function SetHighSpeedSerial(Baud: LongWord): boolean;
  //What this device can actually run at, from the versions in its own banner,
  //using flashrom's rules unchanged. Reason explains any downgrade.
  function UsableSerialSpeed(Wanted: LongWord; out Reason: string): LongWord;
  //True when the firmware is too old for binary SPI at all (flashrom: < 2.4).
  function SupportsBinarySPI: boolean;
  function UsesDocumentedSpeedTable: boolean;
  function SPISpeedHz(Index: byte): LongWord;

  function EnterSPI(const Settings: TBPSPISettings): boolean;
  function EnterI2C(const Settings: TBPI2CSettings): boolean;

  //--- SPI -------------------------------------------------------------------
  //Queues bytes to be written with CS held low (nothing hits the wire yet).
  function SPIQueueWrite(Data: Pointer; Count: integer): boolean;
  //Pushes anything queued out, leaving CS low.
  function SPIFlushQueued: boolean;
  //Writes Count bytes then reads ReadCount, splitting into firmware sized
  //slices. Deassert raises CS when the last slice is done.
  function SPITransfer(WritePtr: Pointer; WriteCount: integer;
                       ReadPtr: Pointer; ReadCount: integer;
                       Deassert: boolean): boolean;
  function SPISetCS(Low: boolean): boolean;

  //--- I2C -------------------------------------------------------------------
  function I2CWriteRead(DevAddr: byte; WritePtr: Pointer; WriteCount: integer;
                        ReadPtr: Pointer; ReadCount: integer): boolean;
  function I2CStart: boolean;
  function I2CStop: boolean;
  function I2CWriteByte(Data: byte; out Acked: boolean): boolean;
  function I2CReadByte(out Data: byte; SendAck: boolean): boolean;
  //Probes every 7-bit address in [FirstAddr..LastAddr] and returns the ones
  //that acknowledged.
  function I2CScan(FirstAddr, LastAddr: integer; out Found: TBytes): boolean;

  //--- buzz extensions (Buzzpirat firmware only) -----------------------------
  function ReadVoltages(out Volts: TBPVoltages): boolean;
  function CheckPowerSupplies(out Healthy: boolean): boolean;

  property LastError: string read FLastError;
  //True once a read failed: the device is still talking and its bytes would be
  //mistaken for the next command's answer. Nothing goes out until Resync ran.
  property Desynced: boolean read FDesynced;
  property Mode: TBPMode read FMode;
  property Banner: string read FBanner;
  property Hardware: string read FHardware;
  property Firmware: string read FFirmware;
  property HwMajor: integer read FHwMajor;
  property HwMinor: integer read FHwMinor;
  property FwMajor: integer read FFwMajor;
  property FwMinor: integer read FFwMinor;
  property IsBuzzpirat: boolean read FIsBuzzpirat;
  property OnLog: TBPLogEvent read FOnLog write FOnLog;
  property Verbose: boolean read FVerbose write FVerbose;
  property Port: TBPSerialPort read FPort;
end;

function BPSPISpeedIndexFromKHz(KHz: integer): integer;
function BPI2CSpeedIndexFromKHz(KHz: integer): integer;

//What is commonly found at a 7-bit I2C address, '' when nothing is known.
//Only ever a hint: I2C addresses are not registered anywhere.
function BPI2CAddressHint(Addr: byte): string;
//i2cdetect style 16 x 8 address map of a scan result. Needs a fixed pitch font.
function BPFormatI2CGrid(const Found: TBytes): string;

//============================================================================
//  AsProgrammer hardware back end
//============================================================================

type

{ TBuzzpiratHardware }

TBuzzpiratHardware = class(TBaseHardware)
private
  FBP: TBusPirate;
  FDevOpened: boolean;
  FStrError: string;
  FOpenPort: string;
  FAppliedConfig: string;
  //What the menu asked for, not what the link achieved: a device that refuses
  //to go fast must not make every later DevOpen reconnect trying again.
  FAppliedSerial: LongWord;

  procedure HandleLog(Level: TBPLogLevel; const Msg: string);
  function Complain(const Msg: string): boolean;

  function WantI2C: boolean;
  function SelectedSPISpeed: byte;
  function SelectedI2CSpeed: byte;
  function SelectedSerialSpeed: LongWord;
  function SPISettings: TBPSPISettings;
  function I2CSettings: TBPI2CSettings;
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

  //MICROWIRE
  function MWInit(speed: integer): boolean; override;
  procedure MWDeinit; override;
  function MWRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer; override;
  function MWWrite(CS: byte; BitsWrite: byte; buffer: array of byte): integer; override;
  function MWIsBusy: boolean; override;

  //Extras driven from the Buzzpirat menu, none of them needed by TBaseHardware.
  procedure Disconnect;

  //Read only, for the clock test in software/tests. It sends every entry of
  //the SPI clock menu to real hardware and has to be able to say which index
  //went out and which of the two tables it came from. Nothing in the program
  //itself reads these.  By Dreg
  function SPIClockIndex: byte;
  function UsesDocumentedTable: boolean;
  function BannerSummary: string;
  function DeviceReport: string;
  //Connects if needed, arms I2C and scans the bus. Leaves the session marked
  //dirty so the next real operation re-applies the user's own settings.
  function ScanI2CBus(out Found: TBytes; out ErrMsg: string): boolean;
  //Human readable line for one scan hit.
  function I2CDeviceLine(Addr: byte): string;
  //Bus settings the scan ran with, for the report header.
  function I2CBusDescription: string;
end;

implementation

uses main;


//============================================================================
//  Serial transport
//============================================================================

function BPSerialPortList: string;
begin
  result := GetSerialPortNames;
end;

procedure BPGetSerialPorts(AList: TStrings);

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
    //synaser hands back a comma separated list; be forgiving about separators.
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

constructor TBPSerialPort.Create;
begin
  inherited Create;
  FSerial := TBlockSerial.Create;
  FSerial.RaiseExcept := false;
  FSerial.DeadlockTimeout := BPSER_DEADLOCK_MS;
  //The Bus Pirate has no handshake lines wired, never gate I/O on them.
  FSerial.TestDSR := false;
  FSerial.TestCTS := false;
  FSerial.LinuxLock := false;
  FLastError := '';
end;

destructor TBPSerialPort.Destroy;
begin
  Close;
  FSerial.Free;
  inherited Destroy;
end;

function TBPSerialPort.Fail(const Where: string): boolean;
begin
  if FSerial.LastError <> 0 then
    FLastError := Where + ': ' + FSerial.LastErrorDesc + ' (' + IntToStr(FSerial.LastError) + ')'
  else
    FLastError := Where;
  result := false;
end;

function TBPSerialPort.IsOpen: boolean;
begin
  result := FSerial.InstanceActive;
end;

function TBPSerialPort.ApplyBaudRate(Baud: LongWord): boolean;
begin
  FSerial.Config(Baud, 8, 'N', SB1, false, false);
  if FSerial.LastError <> 0 then Exit(Fail('cannot set ' + IntToStr(Baud) + ' baud'));
  FBaudRate := Baud;
  result := true;
end;

function TBPSerialPort.Open(const APortName: string; ABaudRate: LongWord): boolean;
begin
  Close;

  FLastError := '';
  FPortName := Trim(APortName);
  if FPortName = '' then
  begin
    FLastError := 'no COM port selected';
    Exit(false);
  end;

  FSerial.Connect(FPortName);
  if FSerial.LastError <> 0 then Exit(Fail('cannot open ' + FPortName));

  if not ApplyBaudRate(ABaudRate) then
  begin
    Close;
    Exit(false);
  end;

  //Must come after Config: the setter re-applies the DCB.
  FSerial.SizeRecvBuffer := BPSER_RX_BUFFER;

  FSerial.Purge;
  result := true;
end;

procedure TBPSerialPort.Close;
begin
  if FSerial.InstanceActive then FSerial.CloseSocket;
end;

function TBPSerialPort.SetBaudRate(ABaudRate: LongWord): boolean;
begin
  if not IsOpen then
  begin
    FLastError := 'port not open';
    Exit(false);
  end;
  if ABaudRate = FBaudRate then Exit(true);

  WaitSent;
  result := ApplyBaudRate(ABaudRate);
  if result then FSerial.Purge;
end;

function TBPSerialPort.SupportsBaudRate(ABaudRate: LongWord): boolean;
var
  previous: LongWord;
begin
  if not IsOpen then Exit(false);
  if ABaudRate = FBaudRate then Exit(true);

  previous := FBaudRate;
  result := ApplyBaudRate(ABaudRate);
  //Put the old rate back either way; the caller only wanted to know.
  ApplyBaudRate(previous);
  FLastError := '';
end;

function TBPSerialPort.WriteAll(const Buffer; Count: integer): boolean;
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

    //Bytes out is the only thing that says whether the write worked. synaser
    //folds ClearCommError's mask into LastError at the end of every send, and
    //that mask carries *receive* side conditions too - a host RX overrun right
    //after a perfectly good write would otherwise be reported as a write
    //failure. If bytes really were lost the reply read fails next, and that is
    //what marks the link out of sync.
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

function TBPSerialPort.WriteByteValue(Value: byte): boolean;
begin
  result := WriteAll(Value, 1);
end;

function TBPSerialPort.ReadAll(var Buffer; Count: integer; TimeoutMs: integer): boolean;
var
  got: integer;
begin
  if Count <= 0 then Exit(true);
  if not IsOpen then
  begin
    FLastError := 'port not open';
    Exit(false);
  end;
  if TimeoutMs < 50 then TimeoutMs := 50;

  got := FSerial.RecvBufferEx(@Buffer, Count, TimeoutMs);
  Inc(FRxCount, got);
  if got = Count then Exit(true);

  result := Fail('read timed out, got ' + IntToStr(got) + ' of ' + IntToStr(Count) + ' bytes');
end;

function TBPSerialPort.ReadByteValue(out Value: byte; TimeoutMs: integer): boolean;
begin
  Value := 0;
  result := ReadAll(Value, 1, TimeoutMs);
end;

procedure TBPSerialPort.Purge;
begin
  if IsOpen then FSerial.Purge;
end;

procedure TBPSerialPort.WaitSent;
begin
  if IsOpen then FSerial.Flush;
end;

function TBPSerialPort.BytesWaiting: integer;
begin
  if IsOpen then
    result := FSerial.WaitingDataEx
  else
    result := 0;
end;

function TBPSerialPort.Drain(IdleMs, MaxMs: integer): integer;
var
  chunk: AnsiString;
  started: QWord;
begin
  result := 0;
  if not IsOpen then Exit;
  if IdleMs < 1 then IdleMs := 1;

  started := GetTickCount64;
  repeat
    chunk := FSerial.RecvPacket(IdleMs);
    Inc(result, Length(chunk));
    Inc(FRxCount, Length(chunk));
    if chunk = '' then Break;
  until GetTickCount64 - started > QWord(MaxMs);

  FLastError := '';
end;


//============================================================================
//  Bus Pirate binary protocol engine
//============================================================================

function BPSPISpeedIndexFromKHz(KHz: integer): integer;
var
  i: integer;
begin
  for i := 0 to High(BP_SPI_SPEED_HZ) do
    if BP_SPI_SPEED_HZ[i] = LongWord(KHz) * 1000 then Exit(i);
  result := 1; //125 kHz, the historic default of this program
end;

function BPI2CSpeedIndexFromKHz(KHz: integer): integer;
var
  i: integer;
begin
  for i := 0 to High(BP_I2C_SPEED_HZ) do
    if BP_I2C_SPEED_HZ[i] = LongWord(KHz) * 1000 then Exit(i);
  result := 1; //50 kHz
end;

function BPI2CAddressHint(Addr: byte): string;
begin
  //Nothing on I2C is registered, so every one of these is a guess. The serial
  //EEPROM block is the one that matters here: it is what this program writes.
  case Addr of
    $50..$57: result := 'serial EEPROM (24Cxx / 24LCxx), A2..A0 = ' +
                        IntToStr((Addr shr 2) and 1) + IntToStr((Addr shr 1) and 1) +
                        IntToStr(Addr and 1);
    $18, $19: result := 'accelerometer (LIS3DH / LSM303)';
    $1E:      result := 'magnetometer (HMC5883L / LSM303)';
    $20..$27: result := 'I/O expander (PCF8574 / MCP23008 / MCP23017)';
    $28..$2F: result := 'I/O expander or capacitive touch';
    $38..$3B: result := 'I/O expander (PCF8574A)';
    $3C, $3D: result := 'OLED display (SSD1306 / SH1106)';
    $40..$47: result := 'current / humidity sensor (INA219, HTU21D, PCA9685)';
    $48..$4B: result := 'ADC or temperature sensor (ADS1115 / LM75 / PCF8591)';
    $4C..$4F: result := 'temperature sensor (LM75 family)';
    $5A:      result := 'touch or gas sensor (MPR121 / CCS811 / MLX90614)';
    $60..$67: result := 'DAC or clock generator (MCP4725 / Si5351)';
    $68, $69: result := 'RTC or IMU (DS1307 / DS3231 / MPU6050)';
    $6A, $6B: result := 'gyroscope (L3GD20 / LSM9DS1)';
    $70..$77: result := 'I2C multiplexer (TCA9548A) or pressure sensor (BMP/BME280)';
  else
    result := '';
  end;
end;

function BPFormatI2CGrid(const Found: TBytes): string;
var
  hit: array[0..127] of boolean;
  i, row, col, addr: integer;
  line: string;
begin
  FillChar(hit, SizeOf(hit), 0);
  for i := 0 to High(Found) do
    if Found[i] < 128 then hit[Found[i]] := true;

  result := '     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f' + LineEnding;
  for row := 0 to 7 do
  begin
    line := IntToHex(row * 16, 2) + ':';
    for col := 0 to 15 do
    begin
      addr := row * 16 + col;
      if (addr < BP_I2C_SCAN_FIRST) or (addr > BP_I2C_SCAN_LAST) then
        //Reserved by the I2C spec, deliberately never probed.
        line := line + '   '
      else
        if hit[addr] then line := line + ' ' + IntToHex(addr, 2)
        else line := line + ' --';
    end;
    result := result + LowerCase(line) + LineEnding;
  end;
end;

constructor TBusPirate.Create;
begin
  inherited Create;
  FPort := TBPSerialPort.Create;
  FMode := bpmClosed;
  FBusHz := 125000;
  SetLength(FTx, 8192);
  SetLength(FPending, 4096);
end;

destructor TBusPirate.Destroy;
begin
  Close(false);
  FPort.Free;
  inherited Destroy;
end;

procedure TBusPirate.Log(Level: TBPLogLevel; const Msg: string);
begin
  if (Level = bplDebug) and (not FVerbose) then Exit;
  if Assigned(FOnLog) then FOnLog(Level, Msg);
end;

function TBusPirate.SetError(const Msg: string): boolean;
begin
  FLastError := Msg;
  Log(bplError, 'Buzzpirat: ' + Msg);
  result := false;
end;

//--- raw transport helpers ----------------------------------------------------

procedure TBusPirate.TxReset;
begin
  FTxLen := 0;
end;

procedure TBusPirate.TxNeed(Extra: integer);
begin
  if FTxLen + Extra > Length(FTx) then
    SetLength(FTx, FTxLen + Extra + 1024);
end;

procedure TBusPirate.TxAddByte(Value: byte);
begin
  TxNeed(1);
  FTx[FTxLen] := Value;
  Inc(FTxLen);
end;

procedure TBusPirate.TxAddBuffer(const Buffer; Count: integer);
begin
  if Count <= 0 then Exit;
  TxNeed(Count);
  Move(Buffer, FTx[FTxLen], Count);
  Inc(FTxLen, Count);
end;

function TBusPirate.TxSend: boolean;
begin
  if FTxLen <= 0 then Exit(true);
  //One gate for every command in the unit: while the stream is out of step,
  //sending anything only makes the confusion worse.
  if FDesynced and (not FRecovering) then
    Exit(SetError('the link is out of sync after a failed transfer; it must be re-armed first'));
  if FPort.WriteAll(FTx[0], FTxLen) then Exit(true);
  result := SetError(FPort.LastError);
end;

procedure TBusPirate.MarkDesynced(const Why: string);
begin
  if FDesynced or FRecovering then Exit;
  FDesynced := true;
  //Whatever was queued belonged to the transfer that just died.
  FPendingLen := 0;
  Log(bplInfo, 'Buzzpirat: link out of sync (' + Why +
               '), it will be re-armed before the next operation');
end;

function TBusPirate.RxBuffer(var Buffer; Count, TimeoutMs: integer): boolean;
begin
  if FPort.ReadAll(Buffer, Count, TimeoutMs) then Exit(true);

  //A short read does not mean the device stopped: it is still executing the
  //command and will send the rest, seconds later for a slow bulk transfer.
  //Those bytes would be read as the next command's acknowledgement.
  MarkDesynced('incomplete reply');
  result := SetError(FPort.LastError);
end;

function TBusPirate.RxByte(out Value: byte; TimeoutMs: integer): boolean;
begin
  result := RxBuffer(Value, 1, TimeoutMs);
end;

function TBusPirate.ExpectAck(const What: string; TimeoutMs: integer): boolean;
var
  status: byte;
begin
  if not RxByte(status, TimeoutMs) then Exit(false);
  if status = BP_ACK then Exit(true);

  //A wrong status byte means the device and this driver disagree about where
  //the stream is. Draining here on a fixed timer cannot work - a bulk reply
  //can legitimately start a second later - so hand it to Resync, which waits
  //for real silence and then re-arms the mode.
  MarkDesynced(What + ' answered $' + IntToHex(status, 2));
  result := SetError(What + ': device answered $' + IntToHex(status, 2) + ' instead of $01');
end;

function TBusPirate.WaitText(const Text: string; TimeoutMs: integer): boolean;
var
  window: string;
  b: byte;
  deadline: QWord;
  n: integer;
begin
  n := Length(Text);
  if n = 0 then Exit(true);
  window := '';
  deadline := GetTickCount64 + QWord(TimeoutMs);

  while GetTickCount64 < deadline do
  begin
    if not FPort.ReadAll(b, 1, 100) then
    begin
      //A read can come back without having waited, so pace the retry by hand.
      if not FPort.IsOpen then Exit(false);
      Sleep(10);
      Continue;
    end;
    window := window + Chr(b);
    if Length(window) > n then Delete(window, 1, Length(window) - n);
    if window = Text then Exit(true);
  end;

  result := false;
end;

function TBusPirate.BusTimeout(BusBytes, WireBytes: integer): integer;
var
  wire, bus: int64;
  baud: LongWord;
  hz: LongWord;
begin
  baud := FPort.BaudRate;
  if baud < 9600 then baud := BP_DEFAULT_BAUD;
  hz := FBusHz;
  if hz < 1000 then hz := 1000;

  //10 bits per character on the wire, 9 clocks per byte on the bus (SPI needs
  //8, I2C needs 9 with the ack) - round up on purpose, this is a safety net
  //and not a schedule.
  wire := (int64(WireBytes) * 12000) div baud;
  bus := (int64(BusBytes) * 9000) div hz;

  result := 3000 + integer(wire) + integer(bus) * 2;
  if result > 120000 then result := 120000;
end;

function TBusPirate.CommandWithAck(Command: byte; const What: string): boolean;
begin
  TxReset;
  TxAddByte(Command);
  if not TxSend then Exit(false);
  result := ExpectAck(What, BusTimeout(0, 4));
end;

//--- mode handling ------------------------------------------------------------

function TBusPirate.IsOpen: boolean;
begin
  result := FPort.IsOpen and (FMode <> bpmClosed);
end;

function TBusPirate.ProbeCurrentMode(out Detected: TBPMode; TimeoutMs: integer): boolean;
var
  got: string;
  deadline: QWord;
  b: byte;
begin
  Detected := bpmClosed;

  //0x01 names the current mode in every binary mode and does nothing harmful
  //at the user terminal, so it is a safe way to find out where we are.
  if FPort.BytesWaiting > 0 then FPort.Drain(30, 300);
  TxReset;
  TxAddByte(BPCMD_MODE_ID);
  if not TxSend then Exit(false);

  got := '';
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while (GetTickCount64 < deadline) and (Length(got) < 24) do
  begin
    if not FPort.ReadAll(b, 1, 80) then
    begin
      //80 ms is the pacing of one poll, not the budget. Breaking here made the
      //caller's timeout meaningless: a device that answers a little late was
      //declared dead. The while condition holds the real deadline.
      if not FPort.IsOpen then Break;
      Continue;
    end;
    got := got + Chr(b);

    //Stop on the first identifier so the common case costs four bytes and no
    //waiting at all.
    if Pos('SPI1', got) > 0 then begin Detected := bpmSPI; Break; end;
    if Pos('I2C1', got) > 0 then begin Detected := bpmI2C; Break; end;
    if Pos('BBIO1', got) > 0 then begin Detected := bpmBitbang; Break; end;
  end;

  result := Detected <> bpmClosed;
end;

function TBusPirate.EnterBitbang: boolean;
var
  attempt: integer;
begin
  FCSLow := false;
  FPendingLen := 0;
  if not FTerminalFresh then FPort.Purge;

  //The terminal counts NULs and only reacts to the twentieth, so right after a
  //reset the first nineteen provoke no answer at all and can go out together.
  if FTerminalFresh then
  begin
    FTerminalFresh := false;
    TxReset;
    for attempt := 1 to 19 do TxAddByte(BBIO_RESET_BITBANG);
    if not TxSend then Exit(false);
    Sleep(30);
    TxReset;
    TxAddByte(BBIO_RESET_BITBANG);
    if not TxSend then Exit(false);
    if WaitText('BBIO1', 1500) then
    begin
      FPort.Drain(60, 400);
      FMode := bpmBitbang;
      Exit(true);
    end;
  end;

  //Otherwise walk the terminal into bitbang mode. It takes 20 NULs, and they
  //have to go one at a time: a burst overruns the PIC UART and can wedge the
  //firmware in an endless BBIO1 loop that only a USB re-plug clears.
  for attempt := 1 to 25 do
  begin
    TxReset;
    TxAddByte(BBIO_RESET_BITBANG);
    if not TxSend then Exit(false);
    if WaitText('BBIO1', 60) then
    begin
      FPort.Drain(60, 400);
      FMode := bpmBitbang;
      Exit(true);
    end;
  end;

  //Last resort: the terminal may be stuck inside a configuration submenu.
  //Newlines finish whatever it is waiting for, '#' resets the device.
  //Strictly one byte at a time, and wait for the line to go quiet in between.
  //The terminal echoes and reprints a prompt for every character it takes, and
  //it is not reading the UART while it does that - a burst overruns the four
  //byte FIFO and latches OERR, which the submenu readers never clear. That
  //would wedge the device for good in exactly the state this code exists for.
  Log(bplInfo, 'Buzzpirat: terminal looks stuck, trying to reset it');

  //A space first, before any carriage return. If a baud change was interrupted
  //the firmware is inside set_baud_rate(), which drains its transmitter,
  //reprograms U1BRG and then loops forever until it reads exactly 0x20. NUL and
  //'#' only make it ring the bell, and a CR makes it worse: the number prompt
  //accepts the default and drops straight into that wait. At an ordinary HiZ>
  //prompt a space is just a harmless character on the command line, which the
  //carriage returns below then submit as an empty command.  By Dreg
  TxReset;
  TxAddByte(Ord(' '));
  if not TxSend then Exit(false);
  FPort.Drain(80, 800);

  //A space after every carriage return, not just one before them all. The
  //leading space frees a device already blocked in set_baud_rate, but a CR sent
  //at the baud menu's number prompt puts it INTO that block: getnumber takes
  //the CR as the end of an empty answer, returns the default, and set_baud_rate
  //then loops until it reads 0x20 and nothing else. So the very first CR here
  //used to undo the space and swallow everything that followed, including the
  //'#' that resets the device. Still strictly one byte at a time with a drain
  //in between, because the PIC is not reading its UART while it echoes.
  //By Dreg
  for attempt := 1 to 6 do
  begin
    TxReset;
    TxAddByte(13);
    if not TxSend then Exit(false);
    FPort.Drain(80, 800);

    TxReset;
    TxAddByte(Ord(' '));
    if not TxSend then Exit(false);
    FPort.Drain(80, 800);
  end;

  TxReset;
  TxAddByte(Ord('#'));
  if not TxSend then Exit(false);
  FPort.Drain(80, 800);

  TxReset;
  TxAddByte(13);
  if not TxSend then Exit(false);
  FPort.Drain(200, 3000);

  for attempt := 1 to 25 do
  begin
    TxReset;
    TxAddByte(BBIO_RESET_BITBANG);
    if not TxSend then Exit(false);
    if WaitText('BBIO1', 150) then
    begin
      FPort.Drain(60, 400);
      FMode := bpmBitbang;
      Exit(true);
    end;
  end;

  FMode := bpmClosed;
  result := SetError('no answer from the device on ' + FPort.PortName +
                     ' at ' + IntToStr(FPort.BaudRate) + ' baud');
end;

function TBusPirate.Resync: boolean;
var
  wasMode: TBPMode;
  ok: boolean;
  junk: integer;
begin
  if not FDesynced then Exit(true);
  if not FPort.IsOpen then Exit(false);

  wasMode := FMode;
  FRecovering := true;
  try
    //Wait for the device to actually finish. A 4096 byte bulk reply at the
    //slowest clock takes over a second to even start, so the only safe test is
    //real silence - not a fixed delay, and not the short drain an error path
    //can afford.
    junk := FPort.Drain(400, 20000);
    FPort.Purge;
    if junk > 0 then
      Log(bplInfo, 'Buzzpirat: discarded ' + IntToStr(junk) + ' late byte(s) from the aborted transfer');

    ok := EnterBitbang;
    if ok then
      case wasMode of
        bpmSPI: ok := ApplyModeAgain(bpmSPI);
        bpmI2C: ok := ApplyModeAgain(bpmI2C);
      end;
  finally
    FRecovering := false;
  end;

  FDesynced := not ok;
  if ok then
    Log(bplInfo, 'Buzzpirat: link re-armed')
  else
    Log(bplError, 'Buzzpirat: could not re-arm the link: ' + FLastError);
  result := ok;
end;

function TBusPirate.ApplyModeAgain(Wanted: TBPMode): boolean;
begin
  case Wanted of
    bpmSPI: result := EnterSPI(FSPI);
    bpmI2C: result := EnterI2C(FI2C);
  else
    result := true;
  end;
end;

function TBusPirate.ReadBanner(TimeoutMs: integer): boolean;
var
  b: byte;
  deadline: QWord;
begin
  FBanner := '';
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while GetTickCount64 < deadline do
  begin
    if not FPort.ReadAll(b, 1, 150) then
    begin
      //Nothing more coming and we already have the prompt: done.
      if Pos('HiZ>', FBanner) > 0 then Break;
      if not FPort.IsOpen then Break;
      Sleep(10);
      Continue;
    end;
    if Length(FBanner) < 8192 then FBanner := FBanner + Chr(b);
    if (Length(FBanner) >= 4) and (Copy(FBanner, Length(FBanner) - 3, 4) = 'HiZ>') then Break;
  end;
  result := Pos('HiZ>', FBanner) > 0;
end;

procedure TBusPirate.ParseBanner;

  //Case insensitive, because the banner is whatever survived the wire. The
  //first characters of it are routinely lost: the device starts printing as
  //soon as it resets, before the host has finished setting the port up, so a
  //real Bus Pirate 6 in legacy mode hands us "us Pirate v2.5" and an anchor on
  //"Bus Pirate v" then finds nothing. That is not cosmetic. The hardware
  //version decides whether the link may leave 115200 and which SPI clock table
  //the device indexes, so losing one character used to silently turn both of
  //those rules off. Callers pass the longest marker first and shorter suffixes
  //after it.  By Dreg
  function TokenAfter(const Marker: string): string;
  var
    p, i: integer;
  begin
    result := '';
    p := Pos(LowerCase(Marker), LowerCase(FBanner));
    if p = 0 then Exit;
    i := p + Length(Marker);
    while (i <= Length(FBanner)) and (not (FBanner[i] in [#0, #9, #10, #13, ' '])) do
    begin
      result := result + FBanner[i];
      Inc(i);
    end;
  end;

  procedure SplitVersion(const S: string; out Major, Minor: integer);
  var
    dot: integer;
  begin
    Major := 0;
    Minor := 0;
    dot := Pos('.', S);
    if dot = 0 then
    begin
      Major := StrToIntDef(S, 0);
      Exit;
    end;
    Major := StrToIntDef(Copy(S, 1, dot - 1), 0);
    Minor := StrToIntDef(Copy(S, dot + 1, Length(S)), 0);
  end;

begin
  //"Bus Pirate v3.6" / "Community Firmware v7.1 - buzzpirat.com By Dreg ..."
  FHardware := TokenAfter('Bus Pirate v');
  if FHardware = '' then FHardware := TokenAfter('Pirate v');
  if FHardware = '' then FHardware := TokenAfter('irate v');
  FFirmware := TokenAfter('Firmware v');
  if FFirmware = '' then FFirmware := TokenAfter('irmware v');
  SplitVersion(FHardware, FHwMajor, FHwMinor);
  SplitVersion(FFirmware, FFwMajor, FFwMinor);
  FIsBuzzpirat := Pos('buzzpirat', LowerCase(FBanner)) > 0;
end;

function TBusPirate.ResetToTerminal: boolean;
var
  status: byte;
begin
  if FMode = bpmClosed then Exit(SetError('device is not open'));

  //A hardware reset is the strongest resynchronisation there is, so it runs
  //even when the stream is out of step - and clears the flag on its way.
  FRecovering := true;
  try
  if FMode <> bpmBitbang then
    if not EnterBitbang then Exit(false);

  //Nothing about the previous identity may survive a reset: if the banner does
  //not come back this time, "unknown" is the honest answer, not last time's
  //version numbers.
  FBanner := '';
  FHardware := '';
  FFirmware := '';
  FHwMajor := 0;
  FHwMinor := 0;
  FFwMajor := 0;
  FFwMinor := 0;
  FIsBuzzpirat := false;

  //Clear stale bytes now. Once 0x0F is out everything on the wire is the boot
  //banner, and the version information is in its very first line.
  FPort.Purge;

  TxReset;
  TxAddByte(BBIO_RESET_DEVICE);
  if not TxSend then Exit(false);

  //The reset byte is out: the PIC is about to reboot, so nothing that was in
  //flight before survives and the stream is trustworthy again from here.
  FDesynced := false;

  //The acknowledgement still comes out at whatever rate the link is running,
  //but the banner that follows the hardware reset is always at 115200, so
  //follow the device down before reading it.
  RxByte(status, 500);
  if FPort.BaudRate <> BP_DEFAULT_BAUD then
    if not FPort.SetBaudRate(BP_DEFAULT_BAUD) then Exit(SetError(FPort.LastError));

  FMode := bpmTerminal;
  FCSLow := false;
  FPendingLen := 0;

  if not ReadBanner(5000) then
  begin
    //No banner means the reset is not proven. Leave FTerminalFresh alone: the
    //blind NUL burst is only safe when the firmware's counter is known to be
    //zero, and only a completed reset proves that.
    Log(bplInfo, 'Buzzpirat: no version banner after reset (device still usable)');
    Exit(true);
  end;

  //The banner is proof the PIC rebooted, so menu_state.binary_mode_counter is
  //back at zero and the first nineteen NULs can go out in one burst.
  FTerminalFresh := true;

  ParseBanner;
  if FHardware <> '' then
    Log(bplInfo, 'Buzzpirat: hardware v' + FHardware + ', firmware v' + FFirmware);
  result := true;
  finally
    FRecovering := false;
  end;
end;

function TBusPirate.SendTerminalLine(const Line: string): boolean;
var
  s: string;
begin
  s := Line + #13;
  TxReset;
  TxAddBuffer(s[1], Length(s));
  result := TxSend;
end;

//flashrom's version comparison, unchanged: buspirate_spi.c:299
//  #define BP_FWVERSION(a,b) ((a) << 8 | (b))
//  #define BP_HWVERSION(a,b) BP_FWVERSION(a,b)
function BPVersion(Major, Minor: integer): integer; inline;
begin
  result := (Major shl 8) or Minor;
end;

function TBusPirate.SupportsBinarySPI: boolean;
begin
  //flashrom, buspirate_spi.c:536 - firmware 2.3 and older has no binary SPI.
  //An unparsed banner leaves the versions at zero, and refusing then would
  //break every device whose banner we simply did not catch, so only a version
  //we actually read counts against it.
  result := (FFwMajor = 0) or
            (BPVersion(FFwMajor, FFwMinor) >= BPVersion(2, 4));
end;

//The real v3 firmware indexes its own twelve entry spi_bus_speed[], whose
//order stops matching the BBIO documentation above 1 MHz. The Bus Pirate
//v5/v6/v7 legacy emulation is a different implementation entirely and decodes
//the index exactly as documented (legacy4third.c, the 0x60..0x67 branch), so
//the same index means a different clock there. Worse, the PIC indices 9 and 11
//fall outside 0x60..0x67 and are swallowed by the emulation's 0x40 peripheral
//handler, which leaves the SPI clock unconfigured and switches the target
//supply on regardless of what the user chose. The emulation announces itself as
//hardware v2.5, so the very test flashrom uses to hold the serial speed down
//also tells us which table to index.  By Dreg
function TBusPirate.UsesDocumentedSpeedTable: boolean;
begin
  result := (FHwMajor > 0) and (BPVersion(FHwMajor, FHwMinor) < BPVersion(3, 0));
end;

//The same index means a different clock on the two firmwares, so the frequency
//has to come out of whichever table was actually indexed. This feeds the log
//line and the transfer timeout estimate, both of which were reading the PIC
//table even when the documented index had been sent.  By Dreg
function TBusPirate.SPISpeedHz(Index: byte): LongWord;
begin
  if UsesDocumentedSpeedTable then
  begin
    if Index <= High(BP_SPI_SPEED_DOC_HZ) then Exit(BP_SPI_SPEED_DOC_HZ[Index]);
    Exit(BP_SPI_SPEED_DOC_HZ[1]);
  end;
  if Index <= High(BP_SPI_SPEED_HZ) then Exit(BP_SPI_SPEED_HZ[Index]);
  result := BP_SPI_SPEED_HZ[1];
end;

function TBusPirate.UsableSerialSpeed(Wanted: LongWord; out Reason: string): LongWord;
begin
  Reason := '';
  result := Wanted;
  if Wanted = BP_DEFAULT_BAUD then Exit;

  //Nothing was parsed out of the banner, so there is no evidence either way.
  //Trying is safe: SetHighSpeedSerial verifies the switch and falls back.
  if (FHwMajor = 0) and (FFwMajor = 0) then Exit;

  //flashrom, buspirate_spi.c:592 - custom serial speeds need firmware 5.5.
  if (FFwMajor > 0) and (BPVersion(FFwMajor, FFwMinor) < BPVersion(5, 5)) then
  begin
    Reason := Format('firmware v%d.%d is older than 5.5, which is where custom ' +
                     'serial speeds arrived', [FFwMajor, FFwMinor]);
    Exit(BP_DEFAULT_BAUD);
  end;

  //flashrom, buspirate_spi.c:585 and :599 - it only defaults to 2 Mbaud on
  //hardware 3.0 and newer, and warns that higher speeds may not work below
  //that. The Bus Pirate v5/v6 legacy emulation reports itself as hardware
  //v2.5, so this is also what keeps the link at a rate that emulation can
  //actually follow.
  if (FHwMajor > 0) and (BPVersion(FHwMajor, FHwMinor) < BPVersion(3, 0)) then
  begin
    Reason := Format('hardware v%d.%d is older than v3.0 (flashrom does not ' +
                     'raise the serial speed below that, and the Bus Pirate ' +
                     'v5+ legacy emulation reports v2.5)', [FHwMajor, FHwMinor]);
    Exit(BP_DEFAULT_BAUD);
  end;
end;

function TBusPirate.SetHighSpeedSerial(Baud: LongWord): boolean;
var
  divisor: integer;
  attempt: integer;

  //Leaving this menu half way is not free. Once the firmware reaches
  //set_baud_rate it drains its transmitter, reprograms U1BRG and then blocks
  //until it reads a space, and nothing else releases it. A space costs nothing
  //at the number prompt, where it only rings the bell, so send one on the way
  //out rather than handing EnterBitbang a terminal that can never answer.
  //By Dreg
  function LeaveBaudMenu(const Msg: string): boolean;
  begin
    TxReset;
    TxAddByte(Ord(' '));
    if TxSend then FPort.Drain(80, 800);
    result := SetError(Msg);
  end;

begin
  if Baud = BP_DEFAULT_BAUD then Exit(true);
  if FMode <> bpmTerminal then
    Exit(SetError('the serial speed can only be changed from the terminal'));

  //Raw BRG entry ("b", option 10) landed in firmware 5.5. A banner we never
  //managed to parse leaves the version at zero, and refusing then would
  //contradict UsableSerialSpeed, which deliberately lets an unknown device try
  //because the handshake below verifies the result anyway.
  if (FFwMajor > 0) and (BPVersion(FFwMajor, FFwMinor) < BPVersion(5, 5)) then
  begin
    Log(bplInfo, 'Buzzpirat: firmware older than v5.5, staying at 115200 baud');
    Exit(false);
  end;

  //Ask the driver first. Telling the device to move to a rate this host cannot
  //produce would leave it deaf until it is unplugged.
  if not FPort.SupportsBaudRate(Baud) then
  begin
    Log(bplInfo, 'Buzzpirat: the serial driver refuses ' + IntToStr(Baud) +
                 ' baud, staying at 115200');
    Exit(false);
  end;

  //U1BRG with BRGH=1 on a 16 MIPS PIC24: baud = FCY / (4 * (BRG + 1)).
  divisor := (4000000 div integer(Baud)) - 1;
  if divisor < 0 then divisor := 0;

  FRecovering := true;
  try
    FPort.Drain(50, 300);
    if not SendTerminalLine('b') then Exit(false);
    if not WaitText('>', 3000) then Exit(LeaveBaudMenu('no answer from the terminal baud menu'));

    //Entry 10 is "raw BRG value".
    if not SendTerminalLine('10') then Exit(false);
    if not WaitText('>', 3000) then
      Exit(LeaveBaudMenu('the terminal baud menu did not ask for a BRG value'));

    if not SendTerminalLine(IntToStr(divisor)) then Exit(false);

    //The firmware prints "Adjust your terminal" / "Space to continue", drains
    //its transmitter, reprograms U1BRG and then blocks until it reads a space
    //at the new rate. Waiting for that notice beats a blind sleep, but a miss
    //is not fatal: the register was already written.
    if not WaitText('Space to continue', 3000) then
      Log(bplInfo, 'Buzzpirat: baud change notice not seen, switching anyway');
    Sleep(150);
    FPort.WaitSent;
    if not FPort.SetBaudRate(Baud) then Exit(SetError(FPort.LastError));
    Sleep(60);
    FPort.Purge;

    //The device has already reprogrammed U1BRG and is blocked in an unbounded
    //wait for one space AT THE NEW RATE. Dropping the host back to 115200 now
    //would strand it there for good, because every recovery path this driver
    //has speaks 0x00, never 0x20. So keep trying at the rate the device is
    //actually using, and be generous about it.
    for attempt := 1 to 12 do
    begin
      TxReset;
      TxAddByte(Ord(' '));
      if not TxSend then Exit(false);
      if WaitText('HiZ>', 700) then
      begin
        Log(bplInfo, 'Buzzpirat: serial link running at ' + IntToStr(Baud) + ' baud');
        Exit(true);
      end;
      //A bare CR redraws the prompt if the device already took the space and
      //we simply missed the echo.
      SendTerminalLine('');
      if WaitText('HiZ>', 300) then
      begin
        Log(bplInfo, 'Buzzpirat: serial link running at ' + IntToStr(Baud) + ' baud');
        Exit(true);
      end;
    end;

    //Still nothing. Only now is it worth assuming the device never made the
    //switch; a hardware reset from the caller is the way back either way.
    Log(bplError, 'Buzzpirat: no answer at ' + IntToStr(Baud) +
                  ' baud after the switch; falling back to 115200. If the ' +
                  'device stays silent, unplug and replug the USB cable.');
    FPort.SetBaudRate(BP_DEFAULT_BAUD);
    FPort.Purge;
    result := SetError('could not confirm ' + IntToStr(Baud) + ' baud; staying at 115200');
  finally
    FRecovering := false;
  end;
end;

function TBusPirate.Open(const APortName: string): boolean;
const
  //115200 first, where a healthy device lives, then the rates a previous run
  //could have left it at.
  CANDIDATES: array[0..4] of LongWord = (115200, 2000000, 1000000, 250000, 230400);
var
  i: integer;
  seen: int64;
begin
  Close(false);

  if not FPort.Open(APortName, BP_DEFAULT_BAUD) then
    Exit(SetError(FPort.LastError));

  for i := 0 to High(CANDIDATES) do
  begin
    if FPort.BaudRate <> CANDIDATES[i] then
      if not FPort.SetBaudRate(CANDIDATES[i]) then Continue;

    if i > 0 then
      Log(bplInfo, 'Buzzpirat: retrying at ' + IntToStr(CANDIDATES[i]) + ' baud');

    seen := FPort.RxCount;
    if EnterBitbang then Exit(true);

    //A device parked at another rate still answers every NUL, the host just
    //decodes framing garbage. Not one byte back means nothing is listening on
    //this port at all, so the remaining rates cannot help - and the GUI is
    //blocked meanwhile, so do not spend another half minute on them.
    if FPort.RxCount = seen then
    begin
      Log(bplInfo, 'Buzzpirat: no bytes at all from ' + APortName + ', giving up early');
      Break;
    end;
  end;

  FPort.Close;
  result := SetError('no Buzzpirat / Bus Pirate answered on ' + APortName +
                     '. Check the port, the cable, and unplug/replug the USB.');
end;

procedure TBusPirate.Close(ResetDevice: boolean);
begin
  if FPort.IsOpen then
  begin
    if ResetDevice and (FMode in [bpmBitbang, bpmSPI, bpmI2C]) then
    begin
      //Best effort: park the device back at its user terminal so the next run
      //(or a plain serial terminal) finds it in a known state. A desynchronised
      //stream is a reason to do this, not a reason to skip it.
      FRecovering := true;
      try
        if FMode <> bpmBitbang then
        begin
          TxReset;
          TxAddByte(BBIO_RESET_BITBANG);
          TxSend;
          WaitText('BBIO1', 600);
        end;
        TxReset;
        TxAddByte(BBIO_RESET_DEVICE);
        TxSend;
        //The PIC reboots through its bootloader window here; stay off the line.
        Sleep(300);
      except
        //Never let shutdown throw.
      end;
      FRecovering := false;
    end;
    FPort.Close;
  end;

  FMode := bpmClosed;
  FCSLow := false;
  FPendingLen := 0;
  FTerminalFresh := false;
  FDesynced := false;
  FRecovering := false;
  FBusHz := 125000;

  //The next Open may well find a different device on that port, so nothing
  //about this one may survive.
  FBanner := '';
  FHardware := '';
  FFirmware := '';
  FHwMajor := 0;
  FHwMinor := 0;
  FFwMajor := 0;
  FFwMinor := 0;
  FIsBuzzpirat := false;
end;

function TBusPirate.Ping: boolean;
var
  detected: TBPMode;
begin
  if not FPort.IsOpen then Exit(false);
  //A desynchronised link can answer anything; Resync is the only way back.
  if FDesynced then Exit(false);
  //Only inside a protocol mode: 0x01 is the mode identifier there, but in raw
  //bitbang the same byte means "enter SPI mode".
  if not (FMode in [bpmSPI, bpmI2C]) then Exit(false);
  if FPendingLen > 0 then Exit(false);

  if not ProbeCurrentMode(detected, 400) then Exit(false);
  result := detected = FMode;
end;

function TBusPirate.SendPeripherals(Power, Pullups, AuxHigh, CSHigh: boolean): boolean;
var
  cmd: byte;
begin
  cmd := BPCMD_PERIPHERALS;
  if Power then cmd := cmd or BP_PERIPH_POWER;
  if Pullups then cmd := cmd or BP_PERIPH_PULLUPS;
  if AuxHigh then cmd := cmd or BP_PERIPH_AUX;
  if CSHigh then cmd := cmd or BP_PERIPH_CS;
  result := CommandWithAck(cmd, 'peripheral setup');
end;

function TBusPirate.EnterSPI(const Settings: TBPSPISettings): boolean;
var
  config: byte;
begin
  if not FPort.IsOpen then Exit(SetError('device is not open'));
  if Settings.Speed > High(BP_SPI_SPEED_HZ) then Exit(SetError('invalid SPI speed index'));

  FPendingLen := 0;
  FCSLow := false;

  if FMode <> bpmBitbang then
    if not EnterBitbang then Exit(false);

  TxReset;
  TxAddByte(BBIO_ENTER_SPI);
  if not TxSend then Exit(false);
  if not WaitText('SPI1', 2000) then Exit(SetError('the device would not enter raw SPI mode'));
  FPort.Drain(40, 300);

  FMode := bpmSPI;
  FSPI := Settings;
  FBusHz := SPISpeedHz(Settings.Speed);

  if not ApplySPISettings then Exit(false);

  Log(bplInfo, 'Buzzpirat: SPI ready, ' + IntToStr(FBusHz div 1000) +
               ' kHz, output ' + BoolToStr(Settings.PushPull and not Settings.Pullups, '3.3V', 'open drain'));
  result := true;
end;

function TBusPirate.ApplySPISettings: boolean;
var
  config: byte;
begin
  if FMode <> bpmSPI then Exit(SetError('not in SPI mode'));

  //CS bit set so the pin starts idle-high (it follows the HiZ setting).
  if not SendPeripherals(FSPI.Power, FSPI.Pullups, FSPI.AuxHigh, true) then Exit(false);

  //Both of the next two commands run spi_setup() on the device, which is what
  //puts SPICS back to an output. In open drain mode the peripheral command
  //above turned it into an input, so neither of them is optional.
  if not CommandWithAck(SPICMD_SPEED or FSPI.Speed, 'SPI speed') then Exit(false);

  config := SPICMD_CONFIG;
  //Pull-ups need the pins open drain, otherwise the push-pull driver fights
  //the resistors and the bus level is whatever wins.
  if FSPI.PushPull and (not FSPI.Pullups) then config := config or SPI_CFG_OUT_3V3;
  if FSPI.ClockIdleHigh then config := config or SPI_CFG_CKP_IDLE_HIGH;
  if FSPI.ClockEdgeActiveToIdle then config := config or SPI_CFG_CKE_ACT2IDLE;
  if FSPI.SampleAtEnd then config := config or SPI_CFG_SMP_END;
  if not CommandWithAck(config, 'SPI configuration') then Exit(false);

  //Known starting point: CS idle high.
  if not CommandWithAck(SPICMD_CS_HIGH, 'CS high') then Exit(false);
  FCSLow := false;
  result := true;
end;

function TBusPirate.EnterI2C(const Settings: TBPI2CSettings): boolean;
begin
  if not FPort.IsOpen then Exit(SetError('device is not open'));
  if Settings.Speed > High(BP_I2C_SPEED_HZ) then Exit(SetError('invalid I2C speed index'));

  FPendingLen := 0;
  FCSLow := false;

  if FMode <> bpmBitbang then
    if not EnterBitbang then Exit(false);

  TxReset;
  TxAddByte(BBIO_ENTER_I2C);
  if not TxSend then Exit(false);
  if not WaitText('I2C1', 2000) then Exit(SetError('the device would not enter raw I2C mode'));
  FPort.Drain(40, 300);

  FMode := bpmI2C;
  FI2C := Settings;
  FBusHz := BP_I2C_SPEED_HZ[Settings.Speed];

  if not ApplyI2CSettings then Exit(false);

  Log(bplInfo, 'Buzzpirat: I2C ready, ' + IntToStr(BP_I2C_SPEED_HZ[Settings.Speed] div 1000) + ' kHz');
  result := true;
end;

function TBusPirate.ApplyI2CSettings: boolean;
begin
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));
  if not CommandWithAck(I2CCMD_SPEED or FI2C.Speed, 'I2C speed') then Exit(false);
  result := SendPeripherals(FI2C.Power, FI2C.Pullups, FI2C.AuxHigh, false);
end;

//--- SPI ----------------------------------------------------------------------

function TBusPirate.PendingAdd(const Buffer; Count: integer): boolean;
begin
  if Count <= 0 then Exit(true);
  if FPendingLen + Count > Length(FPending) then
    SetLength(FPending, FPendingLen + Count + 4096);
  Move(Buffer, FPending[FPendingLen], Count);
  Inc(FPendingLen, Count);
  result := true;
end;

function TBusPirate.SPIQueueWrite(Data: Pointer; Count: integer): boolean;
begin
  if FMode <> bpmSPI then Exit(SetError('not in SPI mode'));
  if (Count <= 0) or (Data = nil) then Exit(true);

  //Bounded, so a script that only ever queues cannot eat the heap.
  if FPendingLen + Count > BP_PENDING_LIMIT then
    if not SPIFlushQueued then Exit(false);

  result := PendingAdd(PByte(Data)^, Count);
end;

function TBusPirate.SPIFlushQueued: boolean;
begin
  if FPendingLen = 0 then Exit(true);
  result := SPITransfer(nil, 0, nil, 0, false);
end;

function TBusPirate.SPIExecSlice(WriteOffset, WriteCount: integer;
                                 ReadPtr: Pointer; ReadCount: integer;
                                 Deassert: boolean): boolean;
var
  autoCS, needCSLow, needCSHigh: boolean;
  timeout: integer;
begin
  if (WriteCount < 0) or (WriteCount > BP_MAX_BULK) or
     (ReadCount < 0) or (ReadCount > BP_MAX_BULK) then
    Exit(SetError('internal error: SPI slice out of range'));
  if (ReadCount > 0) and (ReadPtr = nil) then
    Exit(SetError('internal error: SPI read with no destination buffer'));

  //With CS idle and a full transaction asked for, let the firmware drive CS:
  //one command instead of three.
  autoCS := Deassert and (not FCSLow);
  needCSLow := (not autoCS) and (not FCSLow);
  needCSHigh := (not autoCS) and Deassert;

  TxReset;
  if needCSLow then TxAddByte(SPICMD_CS_LOW);
  if autoCS then TxAddByte(SPICMD_WRITE_READ_CS) else TxAddByte(SPICMD_WRITE_READ_NOCS);
  TxAddByte((WriteCount shr 8) and $FF);
  TxAddByte(WriteCount and $FF);
  TxAddByte((ReadCount shr 8) and $FF);
  TxAddByte(ReadCount and $FF);
  if WriteCount > 0 then TxAddBuffer(FPending[WriteOffset], WriteCount);
  if needCSHigh then TxAddByte(SPICMD_CS_HIGH);
  if not TxSend then Exit(false);

  //The firmware moves CS before it acknowledges, so from the moment those
  //bytes leave the host the pin has moved, however the rest of this slice
  //ends. Tracking the acknowledgement instead would leave the driver believing
  //CS is asserted when it is not - and the next slice would then clock a whole
  //flash command with the chip deselected.
  if needCSLow then FCSLow := true;
  if needCSHigh then FCSLow := false;

  timeout := BusTimeout(WriteCount + ReadCount, FTxLen + ReadCount + 4);

  if needCSLow then
    if not ExpectAck('CS low', timeout) then Exit(false);

  if not ExpectAck('SPI transfer', timeout) then Exit(false);

  if ReadCount > 0 then
    if not RxBuffer(PByte(ReadPtr)^, ReadCount, timeout) then Exit(false);

  if needCSHigh then
  begin
    //FCSLow was already cleared above: the byte is out and the pin has moved.
    if not ExpectAck('CS high', timeout) then Exit(false);
  end
  else
    FCSLow := not Deassert;

  result := true;
end;

function TBusPirate.SPITransfer(WritePtr: Pointer; WriteCount: integer;
                                ReadPtr: Pointer; ReadCount: integer;
                                Deassert: boolean): boolean;
var
  total, offset, readDone, slice: integer;
  last: boolean;
begin
  if FMode <> bpmSPI then Exit(SetError('not in SPI mode'));
  if WriteCount < 0 then WriteCount := 0;
  if ReadCount < 0 then ReadCount := 0;

  if (WriteCount > 0) and (WritePtr <> nil) then
    if not PendingAdd(PByte(WritePtr)^, WriteCount) then Exit(false);

  //From here on the queue is this transfer's write stream. Drop the claim on
  //it straight away so an error cannot make stale bytes reappear later.
  total := FPendingLen;
  FPendingLen := 0;
  offset := 0;

  //Everything that does not fit in the slice carrying the read goes out first,
  //with CS held low.
  while (total - offset) > BP_MAX_BULK do
  begin
    if not SPIExecSlice(offset, BP_MAX_BULK, nil, 0, false) then Exit(false);
    Inc(offset, BP_MAX_BULK);
  end;

  readDone := 0;
  repeat
    slice := ReadCount - readDone;
    if slice > BP_MAX_BULK then slice := BP_MAX_BULK;
    last := (readDone + slice) >= ReadCount;

    if not SPIExecSlice(offset, total - offset,
                        Pointer(PtrUInt(ReadPtr) + PtrUInt(readDone)), slice,
                        Deassert and last) then Exit(false);

    offset := total;   //the write stream is spent after the first slice
    Inc(readDone, slice);
  until last;

  result := true;
end;

function TBusPirate.SPISetCS(Low: boolean): boolean;
begin
  if FMode <> bpmSPI then Exit(SetError('not in SPI mode'));

  if Low then
  begin
    //Queued bytes belong to a transfer that is still being assembled, so they
    //have to go out before CS moves.
    if FPendingLen > 0 then
      if not SPIFlushQueued then Exit(false);

    if FCSLow then Exit(true);
    TxReset;
    TxAddByte(SPICMD_CS_LOW);
    if not TxSend then Exit(false);
    //The pin moves before the acknowledgement, so the flag follows the wire.
    FCSLow := true;
    result := ExpectAck('CS low', BusTimeout(0, 4));
    Exit;
  end;

  //Releasing CS with bytes still queued only ever happens when a transfer was
  //abandoned - this is the teardown path, called from DevOpen, DevClose and
  //SPIDeinit. Flushing them here would turn a half assembled command fragment
  //into a complete, CS framed SPI transaction against the flash chip.
  if FPendingLen > 0 then
  begin
    Log(bplInfo, 'Buzzpirat: dropping ' + IntToStr(FPendingLen) +
                 ' queued byte(s) from an abandoned transfer');
    FPendingLen := 0;
  end;

  if not FCSLow then Exit(true);
  TxReset;
  TxAddByte(SPICMD_CS_HIGH);
  if not TxSend then Exit(false);
  FCSLow := false;
  result := ExpectAck('CS high', BusTimeout(0, 4));
end;

//--- I2C ----------------------------------------------------------------------

function TBusPirate.I2CWriteRead(DevAddr: byte; WritePtr: Pointer; WriteCount: integer;
                                 ReadPtr: Pointer; ReadCount: integer): boolean;
var
  txCount, timeout: integer;
  status: byte;
begin
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));
  if WriteCount < 0 then WriteCount := 0;
  if ReadCount < 0 then ReadCount := 0;

  txCount := WriteCount + 1;   //the address byte counts as a written byte
  //Over the limit the firmware answers 0x00 and drops back to its command
  //loop without eating the payload, which would then run as commands.
  if (txCount > BP_MAX_BULK) or (ReadCount > BP_MAX_BULK) then
    Exit(SetError('I2C transfer too large (max ' + IntToStr(BP_MAX_BULK) + ' bytes each way)'));
  if (ReadCount > 0) and (ReadPtr = nil) then
    Exit(SetError('internal error: I2C read with no destination buffer'));

  TxReset;
  TxAddByte(I2CCMD_WRITE_READ);
  TxAddByte((txCount shr 8) and $FF);
  TxAddByte(txCount and $FF);
  TxAddByte((ReadCount shr 8) and $FF);
  TxAddByte(ReadCount and $FF);

  //The firmware takes the first written byte as the address and only inserts a
  //repeated start when more than one byte was written. A read with no register
  //write therefore has to carry the read address itself.
  if (WriteCount = 0) and (ReadCount > 0) then
    TxAddByte(DevAddr or $01)
  else
    TxAddByte(DevAddr);

  if (WriteCount > 0) and (WritePtr <> nil) then TxAddBuffer(PByte(WritePtr)^, WriteCount);
  if not TxSend then Exit(false);

  timeout := BusTimeout(txCount + ReadCount, FTxLen + ReadCount + 2);
  if not RxByte(status, timeout) then Exit(false);

  if status <> BP_ACK then
  begin
    //The firmware bailed out part way through, so the bus still belongs to us.
    I2CStop;
    Exit(SetError('no I2C answer from device $' + IntToHex(DevAddr, 2)));
  end;

  if ReadCount > 0 then
    if not RxBuffer(PByte(ReadPtr)^, ReadCount, timeout) then Exit(false);

  result := true;
end;

function TBusPirate.I2CStart: boolean;
begin
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));
  result := CommandWithAck(I2CCMD_START, 'I2C start');
end;

function TBusPirate.I2CStop: boolean;
begin
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));
  result := CommandWithAck(I2CCMD_STOP, 'I2C stop');
end;

function TBusPirate.I2CWriteByte(Data: byte; out Acked: boolean): boolean;
var
  reply: array[0..1] of byte;
begin
  Acked := false;
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));

  TxReset;
  TxAddByte(I2CCMD_BULK_WRITE);   //bulk write, one byte
  TxAddByte(Data);
  if not TxSend then Exit(false);

  //0x01 for the command, then the ack bit read off the bus: 0 = ACK, 1 = NACK.
  if not RxBuffer(reply, 2, BusTimeout(2, 4)) then Exit(false);
  if reply[0] <> BP_ACK then
  begin
    MarkDesynced('I2C write byte answered $' + IntToHex(reply[0], 2));
    Exit(SetError('I2C write byte: device answered $' + IntToHex(reply[0], 2)));
  end;

  Acked := reply[1] = 0;
  result := true;
end;

function TBusPirate.I2CReadByte(out Data: byte; SendAck: boolean): boolean;
var
  reply: array[0..1] of byte;
begin
  Data := 0;
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));

  //Read plus the ack/nack bit in one go: the firmware answers the data byte
  //for 0x04 and then 0x01 for the bit.
  TxReset;
  TxAddByte(I2CCMD_READ_BYTE);
  if SendAck then TxAddByte(I2CCMD_ACK) else TxAddByte(I2CCMD_NACK);
  if not TxSend then Exit(false);

  if not RxBuffer(reply, 2, BusTimeout(2, 4)) then Exit(false);
  Data := reply[0];
  if reply[1] <> BP_ACK then
  begin
    MarkDesynced('I2C read byte answered $' + IntToHex(reply[1], 2));
    Exit(SetError('I2C read byte: device answered $' + IntToHex(reply[1], 2)));
  end;
  result := true;
end;

function TBusPirate.I2CScan(FirstAddr, LastAddr: integer; out Found: TBytes): boolean;
var
  addr: integer;
  status: byte;
  count: integer;
begin
  SetLength(Found, 0);
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));

  if FirstAddr < 0 then FirstAddr := 0;
  if LastAddr > 127 then LastAddr := 127;
  if LastAddr < FirstAddr then Exit(true);

  count := 0;
  SetLength(Found, LastAddr - FirstAddr + 1);

  //One address per round trip on purpose. Concatenating probes would keep the
  //host talking while the firmware is bit-banging, and its four byte UART FIFO
  //would overrun long before a 5 kHz bus finished an address byte.
  for addr := FirstAddr to LastAddr do
  begin
    //Write the address and nothing else: 0x01 back means somebody acked.
    TxReset;
    TxAddByte(I2CCMD_WRITE_READ);
    TxAddByte(0); TxAddByte(1);
    TxAddByte(0); TxAddByte(0);
    TxAddByte((addr shl 1) and $FF);
    if not TxSend then Exit(false);

    if not RxByte(status, BusTimeout(2, 8)) then Exit(false);

    if status = BP_ACK then
    begin
      Found[count] := byte(addr);
      Inc(count);
    end
    else
      //A NACK aborts the firmware's transfer before the stop bit, so release
      //the bus by hand before probing the next address.
      if not I2CStop then Exit(false);
  end;

  //A bus held low answers every address. The v3 firmware's binary write path
  //throws away the return value of its own start condition (i2c.c calls
  //bitbang_i2c_start without checking, while the interactive path checks it and
  //prints a pull-up warning), so with SDA stuck at ground the address byte is
  //clocked with no start, the acknowledge bit reads back as the grounded line,
  //and the firmware reports success. Every address then looks present. That is
  //not a bus with 112 chips on it, it is a bus with no pull-ups, which on a v3
  //most often means the Vpullup pin is not fed. Say so instead of handing the
  //user a grid full of devices that are not there. The BPIO2 firmware
  //propagates its start failure, so its scanner never needed this.  By Dreg
  if (count > 0) and (count = LastAddr - FirstAddr + 1) then
  begin
    SetLength(Found, 0);
    Exit(SetError('every address answered, which means the bus is held low ' +
                  'rather than busy: check the pull-ups, and that the Vpullup ' +
                  'pin is connected to your supply'));
  end;

  SetLength(Found, count);
  result := true;
end;

//--- buzz extensions ----------------------------------------------------------

function TBusPirate.ReadVoltages(out Volts: TBPVoltages): boolean;
var
  reply: array[0..13] of byte;

  function ToVolts(Hi, Lo: byte): double;
  begin
    result := ((Hi shl 8) or Lo) / 1024.0 * 6.6;
  end;

begin
  FillChar(Volts, SizeOf(Volts), 0);
  if not FIsBuzzpirat then
    Exit(SetError('voltage readout needs Buzzpirat firmware'));
  if not (FMode in [bpmSPI, bpmI2C]) then
    //0xFE only escapes to buzz mode from a protocol mode; in raw bitbang it is
    //a pin state write and the sub command would run as a bitbang command.
    Exit(SetError('buzz commands need SPI or I2C mode'));
  if FPendingLen > 0 then
    if not SPIFlushQueued then Exit(false);

  TxReset;
  TxAddByte(BPCMD_BUZZ);
  TxAddByte(BUZZ_VOLTAGES);
  if not TxSend then Exit(false);

  //0x01 for entering buzz mode, six big endian ADC words, then 0x01.
  if not RxBuffer(reply, 14, 3000) then Exit(false);
  if (reply[0] <> BP_ACK) or (reply[13] <> BP_ACK) then
  begin
    MarkDesynced('voltage read answered $' + IntToHex(reply[0], 2) + '/$' + IntToHex(reply[13], 2));
    Exit(SetError('unexpected answer to the voltage command'));
  end;

  Volts.V50     := ToVolts(reply[1], reply[2]);
  Volts.V33     := ToVolts(reply[3], reply[4]);
  Volts.V25     := ToVolts(reply[5], reply[6]);
  Volts.V18     := ToVolts(reply[7], reply[8]);
  Volts.VPullup := ToVolts(reply[9], reply[10]);
  Volts.VProbe  := ToVolts(reply[11], reply[12]);
  result := true;
end;

function TBusPirate.CheckPowerSupplies(out Healthy: boolean): boolean;
var
  reply: array[0..1] of byte;
  ok: boolean;
begin
  Healthy := false;
  if not FIsBuzzpirat then
    Exit(SetError('power supply check needs Buzzpirat firmware'));
  if not (FMode in [bpmSPI, bpmI2C]) then
    //0xFE only escapes to buzz mode from a protocol mode; in raw bitbang it is
    //a pin state write and the sub command would run as a bitbang command.
    Exit(SetError('buzz commands need SPI or I2C mode'));
  if FPendingLen > 0 then
    if not SPIFlushQueued then Exit(false);

  TxReset;
  TxAddByte(BPCMD_BUZZ);
  TxAddByte(BUZZ_PSU_CHECK);
  if not TxSend then Exit(false);

  ok := RxBuffer(reply, 2, 3000);

  if ok and (reply[0] <> BP_ACK) then
  begin
    MarkDesynced('power supply check answered $' + IntToHex(reply[0], 2));
    SetError('unexpected answer to the power supply check');
    ok := false;
  end;

  //The firmware turns every rail on, measures, turns them off again and
  //answers 0x01 when they all came up. 0x00 means one of them is loaded down.
  if ok then Healthy := reply[1] = BP_ACK;

  //Whatever happened above, the check left VREGEN low and no SPI or I2C
  //command puts it back - so the restore runs on the error paths too, or the
  //next operation talks to an unpowered chip and reads nothing but $FF.
  //Re-sending the peripheral byte on its own is not enough either: in open
  //drain mode the firmware turns CS into an input for it, and only the speed
  //and configuration commands (which run spi_setup) make it an output again.
  //So the whole mode is re-armed.
  if not FDesynced then
    case FMode of
      bpmSPI: if not ApplySPISettings then ok := false;
      bpmI2C: if not ApplyI2CSettings then ok := false;
    end;

  result := ok;
end;


//============================================================================
//  AsProgrammer hardware back end
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

constructor TBuzzpiratHardware.Create;
begin
  FHardwareName := 'Buzzpirat / BusPirateV3';
  FHardwareID := CHW_BUZZPIRAT;

  FBP := TBusPirate.Create;
  FBP.OnLog := @HandleLog;
end;

destructor TBuzzpiratHardware.Destroy;
begin
  FDevOpened := false;

  //Last chance to tidy up: DevClose deliberately keeps the link alive between
  //operations, so without this the program would exit leaving the device in
  //raw binary mode with the target still powered from the on-board regulator.
  if FBP.IsOpen then
  begin
    if FBP.Mode = bpmSPI then FBP.SPISetCS(false);
    FBP.Close(true);
  end;

  FBP.Free;
  inherited Destroy;
end;

procedure TBuzzpiratHardware.HandleLog(Level: TBPLogLevel; const Msg: string);
begin
  if (Level = bplDebug) and (not MainForm.MenuBuzzpiratVerbose.Checked) then Exit;
  LogPrint(Msg);
end;

function TBuzzpiratHardware.Complain(const Msg: string): boolean;
begin
  FStrError := Msg;
  //Anything that went wrong makes the session suspect, so the next DevOpen
  //re-arms the device instead of trusting a four byte liveness check.
  FAppliedConfig := '';
  LogPrint('Buzzpirat: ' + Msg);
  result := false;
end;

function TBuzzpiratHardware.GetLastError: string;
begin
  result := FStrError;
end;

//--- settings -----------------------------------------------------------------

function TBuzzpiratHardware.SPIClockIndex: byte;
begin
  result := SelectedSPISpeed;
end;

function TBuzzpiratHardware.UsesDocumentedTable: boolean;
begin
  result := (FBP <> nil) and FBP.UsesDocumentedSpeedTable;
end;

function TBuzzpiratHardware.BannerSummary: string;
begin
  if FBP = nil then Exit('(not connected)');
  result := Format('hardware v%s, firmware v%s', [FBP.Hardware, FBP.Firmware]);
end;

function TBuzzpiratHardware.WantI2C: boolean;
begin
  result := MainForm.RadioI2C.Checked;
end;

//Indices into the firmware's spi_bus_speed[], which is not in ascending order.
//The menu offers exactly the eight clocks the BBIO documentation lists, and no
//more. The index sent for each one still comes from the firmware's own twelve
//entry spi_bus_speed[] table, because the documented index-to-speed mapping is
//wrong from 2 MHz upwards: the documentation calls index 4 "2 MHz" where the
//hardware runs 50 kHz. Measured on a Bus Pirate v3.5, see software/tests.
function TBuzzpiratHardware.SelectedSPISpeed: byte;
begin
  //A Bus Pirate v5 or newer running the legacy emulation takes the documented
  //index, and only 0..7 exist there. Anything else is not just a wrong clock,
  //it is decoded as a different command altogether.
  if (FBP <> nil) and FBP.UsesDocumentedSpeedTable then
  begin
    if MainForm.MenuBuzzpiratSPI30KHz.Checked then Exit(0);  //30 kHz
    if MainForm.MenuBuzzpiratSPI125KHz.Checked then Exit(1); //125 kHz
    if MainForm.MenuBuzzpiratSPI250KHz.Checked then Exit(2); //250 kHz
    if MainForm.MenuBuzzpiratSPI1MHz.Checked then Exit(3);   //1 MHz
    if MainForm.MenuBuzzpiratSPI2MHz.Checked then Exit(4);   //2 MHz
    if MainForm.MenuBuzzpiratSPI2P6MHz.Checked then Exit(5); //2.6 MHz
    if MainForm.MenuBuzzpiratSPI4MHz.Checked then Exit(6);   //4 MHz
    if MainForm.MenuBuzzpiratSPI8MHz.Checked then Exit(7);   //8 MHz
    Exit(1); //125 kHz
  end;

  if MainForm.MenuBuzzpiratSPI30KHz.Checked then Exit(0);    //30 kHz
  if MainForm.MenuBuzzpiratSPI125KHz.Checked then Exit(1);   //125 kHz
  if MainForm.MenuBuzzpiratSPI250KHz.Checked then Exit(2);   //250 kHz
  if MainForm.MenuBuzzpiratSPI1MHz.Checked then Exit(3);     //1 MHz
  if MainForm.MenuBuzzpiratSPI2MHz.Checked then Exit(6);     //2 MHz
  if MainForm.MenuBuzzpiratSPI2P6MHz.Checked then Exit(7);   //2.6 MHz
  if MainForm.MenuBuzzpiratSPI4MHz.Checked then Exit(9);     //4 MHz
  if MainForm.MenuBuzzpiratSPI8MHz.Checked then Exit(11);    //8 MHz
  result := 1; //125 kHz
end;

function TBuzzpiratHardware.SelectedI2CSpeed: byte;
begin
  if MainForm.MenuBuzzpiratI2C5KHz.Checked then Exit(0);
  if MainForm.MenuBuzzpiratI2C50KHz.Checked then Exit(1);
  if MainForm.MenuBuzzpiratI2C100KHz.Checked then Exit(2);
  if MainForm.MenuBuzzpiratI2C400KHz.Checked then Exit(3);
  result := 1; //50 kHz
end;

function TBuzzpiratHardware.SelectedSerialSpeed: LongWord;
begin
  if MainForm.MenuBuzzpiratSerial115200.Checked then Exit(115200);
  if MainForm.MenuBuzzpiratSerial230400.Checked then Exit(230400);
  if MainForm.MenuBuzzpiratSerial250000.Checked then Exit(250000);
  if MainForm.MenuBuzzpiratSerial1M.Checked then Exit(1000000);
  if MainForm.MenuBuzzpiratSerial2M.Checked then Exit(2000000);
  result := BP_DEFAULT_BAUD;
end;

function TBuzzpiratHardware.SPISettings: TBPSPISettings;
begin
  FillChar(result, SizeOf(result), 0);
  result.Speed := SelectedSPISpeed;
  result.PushPull := MainForm.MenuBuzzpiratSPINormal.Checked;
  result.Pullups := MainForm.MenuBuzzpiratPullups.Checked;
  result.Power := MainForm.MenuBuzzpiratPower.Checked;
  result.AuxHigh := true;
  //Same framing flashrom uses for SPI flash: clock idles low, data changes on
  //the active-to-idle edge, sampled in the middle. Mode 0 as chips expect it.
  result.ClockIdleHigh := false;
  result.ClockEdgeActiveToIdle := true;
  result.SampleAtEnd := false;
end;

function TBuzzpiratHardware.I2CSettings: TBPI2CSettings;
begin
  FillChar(result, SizeOf(result), 0);
  result.Speed := SelectedI2CSpeed;
  result.Pullups := MainForm.MenuBuzzpiratPullups.Checked;
  result.Power := MainForm.MenuBuzzpiratPower.Checked;
  result.AuxHigh := true;
end;

//Anything in here changing means the device has to be reconfigured.
function TBuzzpiratHardware.ConfigSignature: string;
begin
  //The speed index alone is ambiguous: index 7 means 2.6 MHz on a real v3 and
  //8 MHz on the v5+ legacy emulation, so which table produced it is part of
  //what was applied and has to be part of the signature.  By Dreg
  if WantI2C then
    result := Format('i2c|%d|%d%d|%d', [SelectedI2CSpeed,
                Ord(MainForm.MenuBuzzpiratPullups.Checked),
                Ord(MainForm.MenuBuzzpiratPower.Checked),
                Ord((FBP <> nil) and FBP.UsesDocumentedSpeedTable)])
  else
    result := Format('spi|%d|%d%d%d|%d', [SelectedSPISpeed,
                Ord(MainForm.MenuBuzzpiratSPINormal.Checked),
                Ord(MainForm.MenuBuzzpiratPullups.Checked),
                Ord(MainForm.MenuBuzzpiratPower.Checked),
                Ord((FBP <> nil) and FBP.UsesDocumentedSpeedTable)]);
end;

//--- connection ---------------------------------------------------------------

function TBuzzpiratHardware.Connect(const APort: string): boolean;
var
  wanted: LongWord;
  reason: string;
begin
  FBP.Verbose := MainForm.MenuBuzzpiratVerbose.Checked;
  FAppliedConfig := '';
  FOpenPort := '';
  FAppliedSerial := SelectedSerialSpeed;

  if not FBP.Open(APort) then Exit(Complain(FBP.LastError));

  //A reset gets us the hardware/firmware banner and a known starting point,
  //and it is the only place the terminal will accept a baud rate change.
  if FBP.ResetToTerminal then
  begin
    if FBP.Hardware <> '' then
      LogPrint(Format('Buzzpirat: Bus Pirate v%s, firmware v%s%s',
        [FBP.Hardware, FBP.Firmware,
         BoolToStr(FBP.IsBuzzpirat, ' (Buzzpirat)', '')]));

    //What the hardware can really do, decided from its own banner with
    //flashrom's rules. An old or emulated device is held at 115200 rather than
    //being talked into a rate it cannot follow.
    wanted := FBP.UsableSerialSpeed(FAppliedSerial, reason);
    if (wanted <> FAppliedSerial) and (reason <> '') then
      LogPrint(Format('Buzzpirat: staying at %d baud instead of %d - %s',
                      [wanted, FAppliedSerial, reason]));

    if not FBP.SupportsBinarySPI then
      LogPrint(Format('Buzzpirat: firmware v%d.%d is older than 2.4 and has no ' +
                      'binary SPI mode; upgrade the firmware',
                      [FBP.FwMajor, FBP.FwMinor]));

    if wanted <> BP_DEFAULT_BAUD then
      //A refusal is not fatal: 115200 still works, only slower.
      FBP.SetHighSpeedSerial(wanted);
  end;

  if not FBP.EnterBitbang then Exit(Complain(FBP.LastError));

  FOpenPort := APort;
  result := true;
end;

function TBuzzpiratHardware.DevOpen: boolean;
var
  port: string;
  signature: string;
  needConnect: boolean;
  lostPing: boolean = false;
begin
  FStrError := '';
  FDevOpened := false;
  FBP.Verbose := MainForm.MenuBuzzpiratVerbose.Checked;

  port := Trim(main.Buzzpirat_COMPort);
  if port = '' then Exit(Complain('no COM port selected (Buzzpirat menu -> COMPort)'));

  signature := ConfigSignature;

  //A transfer that died left the device mid-answer. Get the stream back in
  //step before anything else is even considered.
  if FBP.Desynced then
  begin
    LogPrint('Buzzpirat: the last transfer failed, re-arming the link');
    FAppliedConfig := '';
    if not FBP.Resync then
      if not Connect(port) then Exit(false);
  end;

  //Fast path: same port, same settings, device still answering. This is what
  //makes a read/verify/write cycle cost one round trip instead of a full
  //reset-and-handshake every time.
  if FBP.IsOpen and (port = FOpenPort) and (signature = FAppliedConfig) and
     (SelectedSerialSpeed = FAppliedSerial) and
     (not MainForm.MenuBuzzpiratResetEach.Checked) then
  begin
    if FBP.Ping then
    begin
      //An operation cancelled mid transaction can leave CS asserted, and can
      //also leave a late byte in the receive queue. Ping only needs to find
      //'SPI1' inside its answer, so it can match on a stale byte and still
      //pass, leaving this release to read the next one as its acknowledgement,
      //fail, and mark the link out of sync. Returning true then hands the
      //caller a link that refuses every byte. Same defect the BPIO2 fast path
      //had.  By Dreg
      if (FBP.Mode <> bpmSPI) or FBP.SPISetCS(false) then
      begin
        FDevOpened := true;
        Exit(true);
      end;
      LogPrint('Buzzpirat: could not release chip select, reconnecting');
      lostPing := true;
    end
    else
    begin
      LogPrint('Buzzpirat: device stopped answering, reconnecting');
      lostPing := true;
    end;
  end;

  //A different link speed can only be negotiated from the user terminal,
  //which means going all the way round through a reset.
  //A fast path that failed has to force the reconnect it just logged, or the
  //operation carries on over the link it was about to fix.  By Dreg
  needConnect := lostPing or
                 MainForm.MenuBuzzpiratResetEach.Checked or
                 (not FBP.IsOpen) or (port <> FOpenPort) or
                 (SelectedSerialSpeed <> FAppliedSerial);

  if needConnect then
  begin
    if not Connect(port) then Exit(false);
  end
  else
    //Still connected, only the settings moved: back to bitbang and re-arm.
    if not FBP.EnterBitbang then
    begin
      if not Connect(port) then Exit(false);
    end;

  //Drop the claim before touching the device: a mode change that dies half way
  //must not leave a signature behind that the next DevOpen would fast path on.
  FAppliedConfig := '';

  if WantI2C then
  begin
    if not FBP.EnterI2C(I2CSettings) then Exit(Complain(FBP.LastError));
  end
  else
    if not FBP.EnterSPI(SPISettings) then Exit(Complain(FBP.LastError));

  //Recomputed here on purpose. The signature at the top of this function was
  //taken before Connect parsed the banner, and the banner is what decides which
  //clock table the index came from, so storing that one could claim a
  //configuration the device was never given.  By Dreg
  FAppliedConfig := ConfigSignature;
  FDevOpened := true;
  result := true;
end;

procedure TBuzzpiratHardware.DevClose;
begin
  FDevOpened := false;

  if not FBP.IsOpen then Exit;

  //Leave CS idle so the chip is never left selected between operations.
  if FBP.Mode = bpmSPI then FBP.SPISetCS(false);

  //Only tear the link down when the user asked for it. Keeping it up is what
  //makes the next operation start instantly.
  if MainForm.MenuBuzzpiratResetEach.Checked then
  begin
    FBP.Close(true);
    FOpenPort := '';
    FAppliedConfig := '';
  end;
end;

procedure TBuzzpiratHardware.Disconnect;
begin
  FDevOpened := false;
  FBP.Close(true);
  FOpenPort := '';
  FAppliedConfig := '';
end;

//--- SPI ----------------------------------------------------------------------

function TBuzzpiratHardware.SPIInit(speed: integer): boolean;
begin
  //The clock comes from the Buzzpirat menu, not from the generic speed table,
  //and it was already programmed by DevOpen.
  result := FDevOpened and (FBP.Mode = bpmSPI);
  if not result then FStrError := 'SPI mode is not active';
end;

procedure TBuzzpiratHardware.SPIDeinit;
begin
  if not FDevOpened then Exit;
  if FBP.Mode <> bpmSPI then Exit;
  //Teardown: SPISetCS(false) drops anything still queued rather than clocking
  //an abandoned fragment onto the chip as a complete CS framed transaction.
  FBP.SPISetCS(false);
end;

function TBuzzpiratHardware.SPIRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer;
begin
  if not FDevOpened then Exit(-1);

  if not FBP.SPITransfer(nil, 0, SlicePtr(buffer, BufferLen), BufferLen, CS = 1) then
  begin
    Complain(FBP.LastError);
    Exit(-1);
  end;

  result := BufferLen;
end;

function TBuzzpiratHardware.SPIWrite(CS: byte; BufferLen: integer; buffer: array of byte): integer;
begin
  if not FDevOpened then Exit(-1);

  if CS = 1 then
  begin
    //Closing half of a transaction: push everything and raise CS.
    if not FBP.SPITransfer(SlicePtr(buffer, BufferLen), BufferLen, nil, 0, true) then
    begin
      Complain(FBP.LastError);
      Exit(-1);
    end;
  end
  else
    //Opening half: hold the bytes back so they can travel with the next call
    //as a single command instead of two.
    if not FBP.SPIQueueWrite(SlicePtr(buffer, BufferLen), BufferLen) then
    begin
      Complain(FBP.LastError);
      Exit(-1);
    end;

  result := BufferLen;
end;

//--- I2C ----------------------------------------------------------------------

procedure TBuzzpiratHardware.I2CInit;
begin
  //Configured by DevOpen.
end;

procedure TBuzzpiratHardware.I2CDeinit;
begin
  //Nothing to undo, the mode stays valid until the link is closed.
end;

function TBuzzpiratHardware.I2CReadWrite(DevAddr: byte;
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

  result := RBufferLen + WBufferLen;
end;

procedure TBuzzpiratHardware.I2CStart;
begin
  if not FDevOpened then Exit;
  if not FBP.I2CStart then Complain(FBP.LastError);
end;

procedure TBuzzpiratHardware.I2CStop;
begin
  if not FDevOpened then Exit;
  if not FBP.I2CStop then Complain(FBP.LastError);
end;

function TBuzzpiratHardware.I2CReadByte(ack: boolean): byte;
var
  data: byte;
begin
  result := 0;
  if not FDevOpened then Exit;
  if not FBP.I2CReadByte(data, ack) then
  begin
    Complain(FBP.LastError);
    Exit;
  end;
  result := data;
end;

function TBuzzpiratHardware.I2CWriteByte(data: byte): boolean;
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

function TBuzzpiratHardware.ScanI2CBus(out Found: TBytes; out ErrMsg: string): boolean;
var
  port: string;
begin
  SetLength(Found, 0);
  ErrMsg := '';
  result := false;
  FBP.Verbose := MainForm.MenuBuzzpiratVerbose.Checked;

  port := Trim(main.Buzzpirat_COMPort);
  if port = '' then
  begin
    ErrMsg := 'No COM port selected. Pick one in the Buzzpirat menu.';
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
    //A link left out of sync by an earlier failure would refuse every byte the
    //scan tries to send, and only DevOpen re-arms it, so without this the
    //scanner stays broken for the rest of the session however many times it is
    //opened. The BPIO2 back end already does this.  By Dreg
    if FBP.Desynced then
      if not FBP.Resync then
        if not Connect(port) then
        begin
          ErrMsg := FBP.LastError;
          Exit;
        end;

  //The scan runs whatever the SPI/I2C radio says, so the session is left
  //dirty on purpose: the next real operation re-arms the user's own settings.
  FAppliedConfig := '';

  if not FBP.EnterBitbang then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;

  if not FBP.EnterI2C(I2CSettings) then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;

  if not FBP.I2CScan(BP_I2C_SCAN_FIRST, BP_I2C_SCAN_LAST, Found) then
  begin
    ErrMsg := FBP.LastError;
    Exit;
  end;

  result := true;
end;

function TBuzzpiratHardware.I2CDeviceLine(Addr: byte): string;
var
  hint: string;
begin
  result := Format('0x%.2x    0x%.2x    0x%.2x',
                   [Addr, (Addr shl 1) and $FF, ((Addr shl 1) or 1) and $FF]);
  hint := BPI2CAddressHint(Addr);
  if hint <> '' then result := result + '    ' + hint;
end;

function TBuzzpiratHardware.I2CBusDescription: string;
var
  idx: byte;
begin
  idx := SelectedI2CSpeed;
  result := Format('%d kHz, pull-ups %s, target power %s',
    [BP_I2C_SPEED_HZ[idx] div 1000,
     BoolToStr(MainForm.MenuBuzzpiratPullups.Checked, 'on', 'off'),
     BoolToStr(MainForm.MenuBuzzpiratPower.Checked, 'on', 'off')]);
end;

function TBuzzpiratHardware.DeviceReport: string;
var
  volts: TBPVoltages;
  healthy: boolean;
begin
  if not FBP.IsOpen then
  begin
    if Trim(main.Buzzpirat_COMPort) = '' then Exit('No COM port selected');
    if not Connect(Trim(main.Buzzpirat_COMPort)) then Exit('Cannot reach the device: ' + FBP.LastError);
  end
  else
    //Everything below can be answered from the banner cached at the last
    //successful open, so a desynced link would produce a report that looks
    //exactly like a healthy one and the user would keep retrying. Re-arm the
    //link first, and say so plainly when that is not possible.  By Dreg
    if FBP.Desynced then
      if not FBP.Resync then
        if not Connect(Trim(main.Buzzpirat_COMPort)) then
          Exit('The device is not answering: ' + FBP.LastError);

  //The voltage and power-supply commands are buzz commands, and buzz mode is
  //only reachable from SPI or I2C. Arm one if this session never got that far.
  if not (FBP.Mode in [bpmSPI, bpmI2C]) then
  begin
    if not FBP.EnterSPI(SPISettings) then Exit('Cannot reach the device: ' + FBP.LastError);
    //That is not necessarily the mode the user picked, so make the next DevOpen
    //re-arm instead of trusting the session.
    FAppliedConfig := '';
  end;

  result := 'Port          : ' + FBP.Port.PortName + LineEnding +
            'Serial speed  : ' + IntToStr(FBP.Port.BaudRate) + ' baud' + LineEnding +
            'Hardware      : v' + FBP.Hardware + LineEnding +
            'Firmware      : v' + FBP.Firmware + LineEnding +
            'Buzzpirat fw  : ' + BoolToStr(FBP.IsBuzzpirat, 'yes', 'no') + LineEnding;

  if not FBP.IsBuzzpirat then Exit;

  if FBP.ReadVoltages(volts) then
    result := result + Format(
      '5.0V rail     : %.2f V' + LineEnding +
      '3.3V rail     : %.2f V' + LineEnding +
      '2.5V rail     : %.2f V' + LineEnding +
      '1.8V rail     : %.2f V' + LineEnding +
      'Vpullup       : %.2f V' + LineEnding +
      'ADC probe     : %.2f V' + LineEnding,
      [volts.V50, volts.V33, volts.V25, volts.V18, volts.VPullup, volts.VProbe]);

  //The check switches the on-board regulator on to measure under load. Running
  //it when the user asked for the target to stay unpowered would put voltage on
  //a chip they deliberately left cold, so it is offered, not forced.
  if not MainForm.MenuBuzzpiratPower.Checked then
    result := result + 'Power supplies: not checked ("Power ON" is off; the test ' +
                       'would power the target)' + LineEnding
  else
    if FBP.CheckPowerSupplies(healthy) then
      result := result + 'Power supplies: ' +
        BoolToStr(healthy, 'OK', 'LOW - possible short circuit on the target!') + LineEnding
    else
      result := result + 'Power supplies: check failed - ' + FBP.LastError + LineEnding;
end;

//--- MICROWIRE ----------------------------------------------------------------

function TBuzzpiratHardware.MWInit(speed: integer): boolean;
begin
  //Logged here and not in MWRead/MWWrite: those run once per two byte chunk
  //and would flood the log pane.
  result := Complain('Microwire is not supported by the Buzzpirat driver');
end;

procedure TBuzzpiratHardware.MWDeinit;
begin
end;

function TBuzzpiratHardware.MWRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer;
begin
  FStrError := 'Microwire is not supported by the Buzzpirat driver';
  result := -1;
end;

function TBuzzpiratHardware.MWWrite(CS: byte; BitsWrite: byte; buffer: array of byte): integer;
begin
  FStrError := 'Microwire is not supported by the Buzzpirat driver';
  result := -1;
end;

function TBuzzpiratHardware.MWIsBusy: boolean;
begin
  result := false;
end;

end.
