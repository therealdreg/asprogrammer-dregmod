unit buzzpirathw;

{
  Buzzpirat / Bus Pirate v3.x programmer back end for AsProgrammer.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  Originally based on arduinohw.

  The unit has three layers:

    TBPSerialPort         serial transport over Synapse's TBlockSerial
                          (synaser.pas). Nothing in this unit calls an OS API
                          directly.

    TBusPirate            the binary (BBIO) protocol engine: mode entry, SPI,
                          I2C and the Buzzpirat specific "buzz" commands.

    TBuzzpiratHardware    the TBaseHardware implementation AsProgrammer talks
                          to, plus the reading of the Buzzpirat menu settings.

  Reference material:
    - http://buzzpirat.com/docs/binaryio/  (BBIO command reference)
    - buzzpirat firmware: binary_io.c, spi.c, i2c.c, buzz.c, proc_menu.c
    - flashrom programmers/buspirate_spi.c

  Design notes:

  * The terminal enters bitbang mode on the twentieth 0x00, and bitbang mode
    answers each 0x00 with "BBIO1". A burst of them overruns the PIC UART and
    can leave the firmware in an endless BBIO1 loop that only a USB re-plug
    clears, so one 0x00 goes out at a time, its answer checked before the
    next. Right after a reset that count starts at zero and the first nineteen
    get no answer, so those go out together (FTerminalFresh).

  * Bulk transfers (write-then-read) are capped at 4096 bytes each way, the
    size of the firmware's terminal_input buffer. Past that an SPI transfer or
    an I2C write gets 0x00 and its payload, never read in, runs as commands.
    Never let a slice exceed BP_MAX_BULK.

  * A whole transaction is assembled into one buffer and written in a single
    call, then all the replies are read back together. Every round trip costs
    time: an FT232R's latency timer is 16 ms by default.

  * AsProgrammer calls DevOpen/DevClose around every operation. Re-running the
    whole handshake (Connect) each time costs seconds, so unless
    MenuBuzzpiratResetEach is ticked the link stays up between operations and
    DevOpen only checks it with a four byte round trip (Ping). A failed check,
    another port or another serial speed runs Connect again; any other changed
    setting only re-enters the mode.

  * The link starts at 115200 baud (BP_DEFAULT_BAUD). A faster rate is
    negotiated through the firmware's own "b" terminal menu, so only from the
    terminal (SetHighSpeedSerial). It asks the serial driver whether it can
    produce the rate before it tells the device to move, checks every step and
    falls back to 115200 on any failure. The device divides 4 MHz by
    (BRG+1), so 250000, 1M and 2M are exact; 230400 is not: its nearest
    divisor is 2.1% off.

  * Never send a command while the firmware may be bit-banging. In binary mode
    user_serial_read_byte() (base.c) is a blocking poll on the raw PIC UART:
    there is no interrupt ring buffer, only the four byte hardware FIFO. More
    than four bytes of backlog latches OERR, and OERR is only cleared back in
    the user terminal (proc_menu.c), so the device goes deaf until it is
    unplugged. Everything here is strictly request/response, and a command
    only goes out with another when the firmware takes both without clocking
    the bus in between:
      - a bulk command reads its whole payload into terminal_input before the
        first clock edge (streaming is off: configuration.h #undefs it for
        SPI and nothing defines it for I2C), so a 4096 byte payload is safe;
      - one byte may still follow a command that clocks the bus (CS high after
        a bulk transfer, ACK or NACK after an I2C read byte): one byte always
        fits in the FIFO, however long the bus takes.
    Batching several bus transactions into one write would overrun the FIFO
    at low bus speeds.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Dialogs, Synaser, basehw;

//Serial transport

const
  //Windows queues only 4096 bytes by default (synaser), too tight for a
  //4096 byte bulk read at 2 Mbaud.
  BPSER_RX_BUFFER   = 65536;

  //Upper bound for a single SendBuffer/RecvBuffer to complete.
  BPSER_DEADLOCK_MS = 15000;

type

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

  //Changes the line rate of the host side only. PurgeAfter drops what the
  //driver already holds; a caller expecting text right after the switch passes
  //false, because the purge can reach into the adapter's own buffer.
  function SetBaudRate(ABaudRate: LongWord; PurgeAfter: boolean = true): boolean;
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
  //Reads and discards whatever comes until Deadline (GetTickCount64), quiet
  //or not.  By Dreg
  function DrainUntil(Deadline: QWord): integer;
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

//Bus Pirate binary protocol engine

const
  //Raw bitbang (BBIO)
  BBIO_RESET_BITBANG     = $00;   // answers "BBIO1"
  BBIO_ENTER_SPI         = $01;   // answers "SPI1"
  BBIO_ENTER_I2C         = $02;   // answers "I2C1"
  BBIO_ENTER_BUZZ        = $0A;   // answers 0x01
  BBIO_RESET_DEVICE      = $0F;   // answers 0x01, resets, prints the banner

  //Common to every binary protocol mode
  BPCMD_MODE_ID          = $01;   // answers the mode name, "SPI1" or "I2C1"
  BPCMD_PERIPHERALS      = $40;   // or wxyz: w=power x=pullups y=aux z=cs
  BPCMD_BUZZ             = $FE;   // answers 0x01, then one buzz sub command

  BP_PERIPH_CS           = $01;
  BP_PERIPH_AUX          = $02;
  BP_PERIPH_PULLUPS      = $04;
  BP_PERIPH_POWER        = $08;

  //Raw SPI
  SPICMD_CS_LOW          = $02;
  SPICMD_CS_HIGH         = $03;
  SPICMD_WRITE_READ_CS   = $04;   // firmware drives CS around the transfer
  SPICMD_WRITE_READ_NOCS = $05;
  SPICMD_SPEED           = $60;   // or the clock index, 0..7 (0..11 reordered)
  SPICMD_CONFIG          = $80;   // or wxyz: w=3v3 x=ckp y=cke z=smp

  SPI_CFG_OUT_3V3        = $08;   // 0 = HiZ / open drain
  SPI_CFG_CKP_IDLE_HIGH  = $04;
  SPI_CFG_CKE_ACT2IDLE   = $02;
  SPI_CFG_SMP_END        = $01;

  //Raw I2C
  I2CCMD_START           = $02;
  I2CCMD_STOP            = $03;
  I2CCMD_READ_BYTE       = $04;
  I2CCMD_ACK             = $06;
  I2CCMD_NACK            = $07;
  I2CCMD_WRITE_READ      = $08;
  I2CCMD_BULK_WRITE      = $10;   // or (n-1), 1..16 bytes
  I2CCMD_SPEED           = $60;   // or 0..3

  //Buzz mode sub commands
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

  //The rate the device boots at and returns to after every hardware reset.
  BP_DEFAULT_BAUD        = 115200;

  //Highest amount of queued CS-low write bytes before they get pushed out.
  BP_PENDING_LIMIT       = 65536;

  //The reordered spi_bus_speed[] of community firmware from 2016 to 2025 and
  //of the Buzzpirat firmware (TBusPirate.SpeedTable).
  BP_SPI_SPEED_HZ: array[0..11] of LongWord =
    (30000, 125000, 250000, 1000000, 50000, 1300000, 2000000, 2600000,
     3200000, 4000000, 5300000, 8000000);

  //The eight clocks the BBIO documentation defines, in the order it defines
  //them: what DP firmware, community v8.0 and the Bus Pirate v5/v6/v7 legacy
  //emulation decode. The two tables part from index 4 upwards.  By Dreg
  BP_SPI_SPEED_DOC_HZ: array[0..7] of LongWord =
    (30000, 125000, 250000, 1000000, 2000000, 2600000, 4000000, 8000000);

  BP_I2C_SPEED_HZ: array[0..3] of LongWord =
    (5000, 50000, 100000, 400000);

  //Range i2cdetect probes by default. 0x00..0x07 and 0x78..0x7F are reserved
  //by the I2C specification (general call, CBUS, 10-bit addressing), and
  //probing them can reset or confuse devices.
  BP_I2C_SCAN_FIRST      = $08;
  BP_I2C_SCAN_LAST       = $77;

type
  TBPMode = (bpmClosed, bpmTerminal, bpmBitbang, bpmSPI, bpmI2C);

  //What Disconnect did: there was no session, the device rebooted into its
  //user terminal (a v3), or it keeps running its binary mode (the legacy
  //binmode of a Bus Pirate v5 or newer answers the reset with a banner,
  //legacy4third.c).
  TBPDisconnect = (bpdNoSession, bpdReset, bpdKeptBinmode);

  //The order a device indexes its SPI clocks in, from its banner (SpeedTable).
  //Capped: not known, so only 0..3, which every table agrees on.
  TBPSpeedTable = (bptCapped, bptDocumented, bptReordered);

  TBPLogLevel = (bplError, bplInfo, bplDebug);
  TBPLogEvent = procedure(Level: TBPLogLevel; const Msg: string) of object;

  TBPSPISettings = record
    Speed: byte;                  // the device's clock index (SPIIndexFor)
    PushPull: boolean;            // true: 3.3V push-pull, unless Pullups
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
  //When the last reply still to come is due at the latest: BusTimeout moves it
  //to a command's wire time and twice its bus time from then, plus 100 ms,
  //when that is later. Resync takes in whatever comes until then.
  FReplyDue: QWord;
  //Set once the banner after a reset came back: the firmware's NUL counter is
  //then zero, and 19 NULs can go out in one burst with no answer.
  FTerminalFresh: boolean;
  FDesynced: boolean;
  FRecovering: boolean;
  //TxSend logs its refusal once per out of sync episode: an I2C busy poll
  //asks again with no pause for 5 s.
  FRefusalLogged: boolean;
  //Some community builds never acknowledge an SPI write that reads nothing
  //back. Decided once per connection, on the first SPI entry; only a v7.1
  //banner on hardware 3.0 and up is probed.
  FWriteAckChecked: boolean;
  //A write the port refused (the cable came out, say). Open stops on it.
  FWriteFailed: boolean;
  FWriteNoAck: boolean;
  //The rate the last switch asked the device for, done or not, and its port.
  //Kept across Close: a device left waiting for a space at that rate answers
  //at no other rate.
  FFastBaud: LongWord;
  FFastBaudPort: string;

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
  //Sets Desynced, which stops TxSend, and drops the queued bytes. Does nothing
  //while FRecovering is set.
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
  //The I2C address byte alone, as the bus scan sends it. False only when the
  //link failed; Acked says whether a device took the address.
  function AddressAcks(Addr8: byte; out Acked: boolean): boolean;

  function ProbeCurrentMode(out Detected: TBPMode; TimeoutMs: integer): boolean;
  function SendPeripherals(Power, Pullups, AuxHigh, CSHigh: boolean): boolean;
  //Everything a protocol mode needs after the mode identifier has come back.
  //Separate from EnterSPI/EnterI2C because the buzz power supply check, which
  //leaves the regulator off, has to run it again.
  function ApplySPISettings: boolean;
  function ApplyI2CSettings: boolean;
  function SPIConfigByte: byte;
  //False when the probe could not run or left the stream out of step.
  function ProbeWriteAck(out Acked: boolean): boolean;
  //Re-enters a protocol mode from bitbang with the settings already stored.
  function ApplyModeAgain(Wanted: TBPMode): boolean;
  //Seed: what was already read of the banner.
  function ReadBanner(TimeoutMs: integer; const Seed: string = ''): boolean;
  procedure ParseBanner;
  function SendTerminalLine(const Line: string): boolean;
  //Frees a device waiting for a space after a baud change at Baud, then
  //resets it, which brings it back at 115200. Leaves the host at 115200.
  //QuickIfSilent: no banner wait when nothing at all came back at Baud.
  function EscapeBaudWait(Baud: LongWord; QuickIfSilent: boolean): boolean;

  function PendingAdd(const Buffer; Count: integer): boolean;
  function SPIExecSlice(WriteOffset, WriteCount: integer;
                        ReadPtr: Pointer; ReadCount: integer;
                        Deassert: boolean): boolean;
public
  constructor Create;
  destructor Destroy; override;

  //Opens the port and gets the device into raw bitbang mode, retrying at the
  //other plausible line rates if a previous run left the device fast.
  //HintBaud: a rate a previous run would have asked for, tried after FFastBaud.
  function Open(const APortName: string; HintBaud: LongWord = 0): boolean;
  procedure Close(ResetDevice: boolean);
  function IsOpen: boolean;

  //Cheap liveness check: asks the current mode to name itself.
  function Ping: boolean;

  //Waits for the device to finish whatever it was answering, throws the answer
  //away and re-arms the mode it was in. The way out of a desynchronised link
  //short of a hardware reset (ResetToTerminal) or Close.
  function Resync: boolean;

  function EnterBitbang: boolean;
  //0x0F: a v3 acknowledges, reboots into its user terminal and prints its
  //banner; the v5+ legacy binmode prints the banner with no acknowledgement
  //and keeps running. Leaves the host at BP_DEFAULT_BAUD.
  function ResetToTerminal: boolean;
  //Talks the terminal's "b" menu into a raw BRG value, then follows on the
  //host side. Only call while in terminal mode. A refusal is not fatal: the
  //link stays at 115200.
  function SetHighSpeedSerial(Baud: LongWord): boolean;
  //What this device can run at, from its banner: 115200 below firmware 5.5 or
  //hardware 3.0, the versions flashrom checks. Reason explains any downgrade.
  function UsableSerialSpeed(Wanted: LongWord; out Reason: string): LongWord;
  //False when the banner shows firmware older than 2.4, which has no binary SPI
  //(flashrom); a version not read counts as supported.
  function SupportsBinarySPI: boolean;
  //False when the firmware is older than 5.5 and has no write-then-read
  //command (0x04, 0x05), which every SPI transfer here uses.
  function SupportsWriteThenRead: boolean;
  //The Bus Pirate v5/v6/v7 legacy binmode: SPI only, hardware v2.5.
  function IsLegacyEmulation: boolean;
  function SpeedTable: TBPSpeedTable;
  function UsesDocumentedSpeedTable: boolean;
  //The index to send for one of the eight documented clocks (0..7), after
  //the device's table and its limits.
  function SPIIndexFor(DocIndex: byte): byte;
  //Why some clocks of the menu are slower on this device, '' when none are.
  function SPIClockLimitNote: string;
  function SPISpeedHz(Index: byte): LongWord;

  function EnterSPI(const Settings: TBPSPISettings): boolean;
  function EnterI2C(const Settings: TBPI2CSettings): boolean;

  //SPI
  //Queues bytes to be written with CS held low (nothing hits the wire yet).
  function SPIQueueWrite(Data: Pointer; Count: integer): boolean;
  //Pushes anything queued out, leaving CS low.
  function SPIFlushQueued: boolean;
  //Writes the queued bytes and WriteCount more, then reads ReadCount, in
  //firmware sized slices. Deassert raises CS when the last slice is done.
  function SPITransfer(WritePtr: Pointer; WriteCount: integer;
                       ReadPtr: Pointer; ReadCount: integer;
                       Deassert: boolean): boolean;
  //Raises CS and drops anything queued: the teardown of an abandoned transfer.
  function SPIReleaseCS: boolean;
  //Drops the bytes an abandoned transfer left queued, sending nothing.
  procedure SPIDropQueued;

  //I2C
  function I2CWriteRead(DevAddr: byte; WritePtr: Pointer; WriteCount: integer;
                        ReadPtr: Pointer; ReadCount: integer): boolean;
  function I2CStart: boolean;
  function I2CStop: boolean;
  function I2CWriteByte(Data: byte; out Acked: boolean): boolean;
  function I2CReadByte(out Data: byte; SendAck: boolean): boolean;
  //Probes every 7-bit address in [FirstAddr..LastAddr]; Found gets the ones
  //that acknowledged. False when all of them did: the bus is held low.
  function I2CScan(FirstAddr, LastAddr: integer; out Found: TBytes): boolean;

  //Buzz extensions (Buzzpirat firmware only)
  function ReadVoltages(out Volts: TBPVoltages): boolean;
  function CheckPowerSupplies(out Healthy: boolean): boolean;

  property LastError: string read FLastError;
  //True once a transfer failed: the device may still be talking and its bytes
  //would be mistaken for the next command's answer. Nothing goes out until
  //Resync, ResetToTerminal or Close runs.
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

//What is commonly found at a 7-bit I2C address, '' when nothing is known.
//Only ever a hint: I2C addresses are not registered anywhere.
function BPI2CAddressHint(Addr: byte): string;
//i2cdetect style 16 x 8 address map of a scan result. Needs a fixed pitch font.
function BPFormatI2CGrid(const Found: TBytes): string;

//AsProgrammer hardware back end

type

TBuzzpiratHardware = class(TBaseHardware)
private
  FBP: TBusPirate;
  FDevOpened: boolean;
  FStrError: string;
  //Whether FStrError reached the log (Complain) or was only kept.
  FErrorLogged: boolean;
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
  function ErrorWasLogged: boolean; override;
  function DevOpen: boolean; override;
  procedure DevClose; override;

  //SPI
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

  //Microwire
  function MWInit(speed: integer): boolean; override;
  procedure MWDeinit; override;
  function MWRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer; override;
  function MWWrite(CS: byte; BitsWrite: byte; buffer: array of byte): integer; override;
  function MWIsBusy: boolean; override;

  //Not part of TBaseHardware.
  function Disconnect: TBPDisconnect;

  //SPIClockIndex: the index the SPI clock menu's choice sends; SPIClockTable:
  //the name of the device's table; BannerSummary: the hardware and firmware
  //versions of the banner. None of the three talks to the device.  By Dreg
  function SPIClockIndex: byte;
  function SPIClockTable: string;
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


//Serial transport

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
    //Synaser returns a comma separated list; a ';' counts as a comma too.
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
  //The Bus Pirate has no handshake lines wired, so never test DSR or CTS.
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

function TBPSerialPort.SetBaudRate(ABaudRate: LongWord; PurgeAfter: boolean): boolean;
begin
  if not IsOpen then
  begin
    FLastError := 'port not open';
    Exit(false);
  end;
  if ABaudRate = FBaudRate then Exit(true);

  WaitSent;
  result := ApplyBaudRate(ABaudRate);
  if result and PurgeAfter then FSerial.Purge;
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

    //Only the byte count says whether the write worked. Synaser folds
    //ClearCommError's mask into LastError at the end of every send, and that
    //mask carries receive side conditions too: a host RX overrun right after a
    //good write would otherwise be reported as a write failure. If bytes
    //really were lost the reply read fails next, and that marks the link out
    //of sync.
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
  got, n, avail, early: integer;
  last, t: QWord;
begin
  if Count <= 0 then Exit(true);
  if not IsOpen then
  begin
    FLastError := 'port not open';
    Exit(false);
  end;
  if TimeoutMs < 50 then TimeoutMs := 50;

  //RecvBufferEx can come back at once with ErrTimeout and nothing read:
  //Synaser's RecvPacket reports a timeout whenever the queue is still empty
  //after CanRead, and CanRead can return at once. On the legacy binmode of a
  //Bus Pirate 6 (a USB serial port) that happens two or three times in a
  //whole-chip AAI write, the bytes coming a moment later, and taking it for a
  //timeout would abort the write. So ReadAll measures the timeout itself, from
  //the last byte that came, as TBP5Port's reader does: what has arrived is
  //taken at once, otherwise the next byte is waited for 20 ms at a time, until
  //TimeoutMs pass with nothing.
  //By Dreg
  got := 0;
  early := 0;
  last := GetTickCount64;
  repeat
    avail := FSerial.WaitingDataEx;
    //With Synaser's own buffer empty that asks the driver (ClearCommError), and
    //an error there ends the read: RecvBufferEx would not show it, since
    //RecvPacket reports ErrTimeout in its place.
    if (avail = 0) and (FSerial.LastError <> sOK) then Break;
    if avail > Count - got then avail := Count - got;
    t := GetTickCount64;
    if avail > 0 then
      n := FSerial.RecvBufferEx(PByte(@Buffer) + got, avail, 50)
    else
      n := FSerial.RecvBufferEx(PByte(@Buffer) + got, 1, 20);
    if n > 0 then
    begin
      Inc(got, n);
      Inc(FRxCount, n);
      last := GetTickCount64;
      early := 0;
      if got >= Count then Exit(true);
    end
    else
    begin
      //A driver error other than a timeout will not get better by waiting.
      if (FSerial.LastError <> sOK) and (FSerial.LastError <> ErrTimeout) then Break;
      //Nothing came and the call did not wait: try again at once, and pace an
      //early return that repeats, so it cannot spin.
      if GetTickCount64 - t < 10 then
      begin
        Inc(early);
        if early > 1 then Sleep(1);
      end
      else
        early := 0;
    end;
  until GetTickCount64 - last >= QWord(TimeoutMs);

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
  started, last: QWord;
  left: integer;
begin
  result := 0;
  if not IsOpen then Exit;
  if IdleMs < 1 then IdleMs := 1;

  //An empty RecvPacket does not prove a quiet line: it can come back at once,
  //as in ReadAll, and the late bytes left behind would be read as the next
  //command's answer. The line is quiet once IdleMs pass with nothing.  By Dreg
  started := GetTickCount64;
  last := started;
  repeat
    //As in ReadAll: with Synaser's own buffer empty this asks the driver, and
    //an error there ends the drain.
    if (FSerial.WaitingDataEx = 0) and (FSerial.LastError <> sOK) then Break;
    left := IdleMs - integer(GetTickCount64 - last);
    if left < 1 then left := 1;
    chunk := FSerial.RecvPacket(left);
    if chunk <> '' then
    begin
      Inc(result, Length(chunk));
      Inc(FRxCount, Length(chunk));
      last := GetTickCount64;
    end
    else if (GetTickCount64 - last >= QWord(IdleMs)) or
            ((FSerial.LastError <> sOK) and (FSerial.LastError <> ErrTimeout)) then
      Break
    else
      Sleep(1);
  until GetTickCount64 - started > QWord(MaxMs);

  FLastError := '';
end;

function TBPSerialPort.DrainUntil(Deadline: QWord): integer;
var
  chunk: AnsiString;
  t, left: QWord;
begin
  result := 0;
  if not IsOpen then Exit;
  //As in Drain, a driver error ends it, but a quiet line does not.
  repeat
    t := GetTickCount64;
    if t >= Deadline then Break;
    if (FSerial.WaitingDataEx = 0) and (FSerial.LastError <> sOK) then Break;
    left := Deadline - t;
    if left > 100 then left := 100;
    chunk := FSerial.RecvPacket(integer(left));
    if chunk <> '' then
    begin
      Inc(result, Length(chunk));
      Inc(FRxCount, Length(chunk));
    end
    else if (FSerial.LastError <> sOK) and (FSerial.LastError <> ErrTimeout) then
      Break
    else
      Sleep(1);
  until false;

  FLastError := '';
end;


//Bus Pirate binary protocol engine

function BPI2CAddressHint(Addr: byte): string;
begin
  //I2C addresses are not registered, so every one of these is a guess. The
  //serial EEPROM block matters most: it is what this program writes.
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

//Raw transport helpers

const
  BP_REFUSED_MSG = 'the link is out of sync after a failed transfer; it must be re-armed first';

//Text off the wire for the verbose log, bytes outside ' '..'~' as dots.
function Printable(const S: string): string;
var
  i: integer;
begin
  result := S;
  for i := 1 to Length(result) do
    if (result[i] < ' ') or (result[i] > '~') then result[i] := '.';
end;

//The first bytes of a buffer in hex, for the verbose log.
function HexPreview(const Buffer; Count: integer): string;
const
  SHOW = 16;
var
  p: PByte;
  i: integer;
begin
  result := '';
  p := @Buffer;
  for i := 0 to Count - 1 do
  begin
    if i = SHOW then Exit(result + '...');
    result := result + IntToHex(p[i], 2) + ' ';
  end;
  result := TrimRight(result);
end;

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
  begin
    if FRefusalLogged then
    begin
      FLastError := BP_REFUSED_MSG;
      Exit(false);
    end;
    FRefusalLogged := true;
    Exit(SetError(BP_REFUSED_MSG));
  end;
  if FVerbose then
    Log(bplDebug, Format('Buzzpirat: > %d byte(s): %s', [FTxLen, HexPreview(FTx[0], FTxLen)]));
  if FPort.WriteAll(FTx[0], FTxLen) then Exit(true);
  FWriteFailed := true;
  //In a session, a port that takes no bytes (the cable came out) fails every
  //call after this one too: let the gate say so once instead. Open has no
  //session yet, and stops on FWriteFailed itself.
  if FMode <> bpmClosed then MarkDesynced('write failed');
  result := SetError(FPort.LastError);
end;

procedure TBusPirate.MarkDesynced(const Why: string);
begin
  if FDesynced or FRecovering then Exit;
  FDesynced := true;
  FRefusalLogged := false;
  //Whatever was queued belonged to the transfer that just died.
  FPendingLen := 0;
  Log(bplInfo, 'Buzzpirat: link out of sync (' + Why +
               '), it will be re-armed before the next operation');
end;

function TBusPirate.RxBuffer(var Buffer; Count, TimeoutMs: integer): boolean;
begin
  if FPort.ReadAll(Buffer, Count, TimeoutMs) then
  begin
    if FVerbose then
      Log(bplDebug, Format('Buzzpirat: < %d byte(s): %s', [Count, HexPreview(Buffer, Count)]));
    Exit(true);
  end;

  //A short read does not mean the device stopped: it may still be running the
  //command and send the rest, seconds later for a slow bulk transfer. Those
  //bytes would be read as the next command's acknowledgement.
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
  //the stream is. Draining here on a fixed timer cannot work (a bulk reply
  //can legitimately start a second later), so hand it to Resync, which the
  //next operation runs: it waits for silence and then re-arms the mode.
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
      //A read that fails on a driver error comes back at once, so pace the
      //retry by hand.
      if not FPort.IsOpen then Exit(false);
      Sleep(10);
      Continue;
    end;
    window := window + Chr(b);
    if Length(window) > n then Delete(window, 1, Length(window) - n);
    if window = Text then
    begin
      if FVerbose then Log(bplDebug, 'Buzzpirat: < "' + Printable(Text) + '"');
      Exit(true);
    end;
  end;

  //Only a miss with something else on the line says anything: EnterBitbang
  //polls with short waits, fifty of them on a silent port.
  if FVerbose and (window <> '') then
    Log(bplDebug, 'Buzzpirat: no "' + Printable(Text) + '" within ' + IntToStr(TimeoutMs) +
                  ' ms, the line ended with "' + Printable(window) + '"');
  result := false;
end;

function TBusPirate.BusTimeout(BusBytes, WireBytes: integer): integer;
var
  wire, bus: int64;
  baud: LongWord;
  hz: LongWord;
  due: QWord;
begin
  baud := FPort.BaudRate;
  if baud < 9600 then baud := BP_DEFAULT_BAUD;
  hz := FBusHz;
  if hz < 1000 then hz := 1000;

  //A character is 10 bits on the wire and a byte 9 clocks on the bus (SPI
  //needs 8, I2C 9 with the ack). The wire counts 12 bits, the bus time counts
  //twice and 3 s go on top: a safety net, not a schedule.
  wire := (int64(WireBytes) * 12000) div baud;
  bus := (int64(BusBytes) * 9000) div hz;
  //The latest due time is kept: an I2C failure's stop and address probe come
  //after the command whose reply may still be on its way.
  due := GetTickCount64 + QWord(wire + bus * 2 + 100);
  if due > FReplyDue then FReplyDue := due;

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

//Mode handling

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

  //0x01 asks SPI and I2C mode for their identifier and does nothing harmful
  //at the user terminal, but raw bitbang takes it as "enter SPI": call this
  //from a protocol mode only.
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
      //80 ms is the pacing of one poll, not the budget: breaking here would
      //make the caller's timeout meaningless and declare a device that answers
      //a little late dead. The while condition holds the real deadline. A read
      //that fails on a driver error comes back at once, so pace it by hand.
      if not FPort.IsOpen then Break;
      Sleep(10);
      Continue;
    end;
    got := got + Chr(b);

    //Stop on the first identifier so the common case costs four bytes and no
    //waiting at all.
    if Pos('SPI1', got) > 0 then begin Detected := bpmSPI; Break; end;
    if Pos('I2C1', got) > 0 then begin Detected := bpmI2C; Break; end;
    if Pos('BBIO1', got) > 0 then begin Detected := bpmBitbang; Break; end;
  end;

  if FVerbose then Log(bplDebug, 'Buzzpirat: < mode id "' + Printable(got) + '"');
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
  //Carriage returns finish whatever it is waiting for, and '#' resets the
  //device. One byte at a time, with the line quiet in between: the terminal
  //answers each byte with an echo, a bell or a new prompt and is not reading
  //the UART meanwhile, so a burst overruns the four byte FIFO and latches
  //OERR, which the submenu readers never clear. The device would then stay
  //stuck in that submenu until it is unplugged.
  Log(bplInfo, 'Buzzpirat: terminal looks stuck, trying to reset it');

  //A space first, before any carriage return. A baud change cut short can
  //leave the firmware in set_baud_rate(): at its number prompt NUL and '#'
  //only ring the bell and a CR takes the default, and past that prompt it
  //drains its transmitter, reprograms U1BRG and loops until it reads exactly
  //0x20. At an ordinary HiZ> prompt a space is a harmless character on the
  //command line, which the carriage returns below then submit as an empty
  //command.  By Dreg
  TxReset;
  TxAddByte(Ord(' '));
  if not TxSend then Exit(false);
  FPort.Drain(80, 800);

  //A space after every carriage return too. The leading space frees a device
  //already blocked in set_baud_rate, but a CR at the baud menu's number prompt
  //puts it into that block: getnumber takes the CR as an empty answer and
  //returns the default, and set_baud_rate then loops until it reads 0x20.
  //With only the leading space, the first CR would send the device there and
  //the wait would swallow everything after it, the '#' that resets the device
  //included.  By Dreg
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
  t, deadline: QWord;
begin
  if not FDesynced then Exit(true);
  if not FPort.IsOpen then Exit(false);

  wasMode := FMode;
  FRecovering := true;
  try
    //Wait for the device to finish: take in whatever comes until the last
    //reply is due (FReplyDue), then wait for 400 ms of silence, 20 s at most
    //each. A 4096 byte bulk reply at 30 kHz starts over a second late: a read
    //that timed out has waited past that already, a failure that came back at
    //once has not.  By Dreg
    junk := 0;
    t := GetTickCount64;
    if FReplyDue > t then
    begin
      deadline := FReplyDue;
      if deadline - t > 20000 then deadline := t + 20000;
      junk := FPort.DrainUntil(deadline);
    end;
    junk := junk + FPort.Drain(400, 20000);
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
    //The reason is the log line just above: every failure in here goes
    //through SetError, and the gate does not refuse while FRecovering is set.
    Log(bplError, 'Buzzpirat: could not re-arm the link');
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

function TBusPirate.ReadBanner(TimeoutMs: integer; const Seed: string): boolean;
var
  b: byte;
  deadline: QWord;
begin
  FBanner := Seed;
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while GetTickCount64 < deadline do
  begin
    if not FPort.ReadAll(b, 1, 150) then
    begin
      //The line went quiet with the prompt already in the banner: done.
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

  //Case insensitive, because the banner is whatever survived the wire, and its
  //first characters can be lost: a device found at a fast rate starts the
  //banner at 115200 while the host may still be switching down. The hardware
  //version decides whether the link may leave 115200 and which SPI clock table
  //the device indexes, so one lost character must not turn both of those rules
  //off. Callers pass the longest marker first and shorter suffixes after it.
  //By Dreg
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

  //flashrom's reading (buspirate_spi.c): the leading digits, then whatever
  //digits come after the next non-digit, so "6.3-beta1" is 6.3, not 6.0.
  procedure SplitVersion(const S: string; out Major, Minor: integer);
  var
    i: integer;
  begin
    Major := 0;
    Minor := 0;
    i := 1;
    while (i <= Length(S)) and (S[i] in ['0'..'9']) and (Major < 1000) do
    begin
      Major := Major * 10 + Ord(S[i]) - Ord('0');
      Inc(i);
    end;
    while (i <= Length(S)) and not (S[i] in ['0'..'9']) do Inc(i);
    while (i <= Length(S)) and (S[i] in ['0'..'9']) and (Minor < 1000) do
    begin
      Minor := Minor * 10 + Ord(S[i]) - Ord('0');
      Inc(i);
    end;
  end;

begin
  //"Bus Pirate v3.6" / "Community Firmware v7.1 - buzzpirat.com by Dreg ..."
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
  seed: string;
begin
  if FMode = bpmClosed then Exit(SetError('device is not open'));

  //A hardware reset is the strongest resynchronisation there is, so it runs
  //even when the stream is out of step, and clears the flag on its way.
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
  //banner, and the versions are in its first two lines.
  FPort.Purge;

  TxReset;
  TxAddByte(BBIO_RESET_DEVICE);
  if not TxSend then Exit(false);

  //The reset byte is out: a v3 reboots and drops whatever was in flight, and
  //the v5+ legacy binmode answers with its banner, so the stream is in step
  //again from here.
  FDesynced := false;

  //The acknowledgement still comes out at whatever rate the link is running,
  //but the banner that follows the hardware reset is always at 115200, so
  //follow the device down before reading it, keeping what already arrived.
  //The v5+ legacy binmode sends no acknowledgement (legacy4third.c, 0x0F): its
  //first byte is the B of "Bus Pirate v2.5", so anything but 0x01 is banner.
  seed := '';
  if FPort.ReadByteValue(status, 500) and (status <> BP_ACK) then seed := Chr(status);
  if FPort.BaudRate <> BP_DEFAULT_BAUD then
    if not FPort.SetBaudRate(BP_DEFAULT_BAUD, false) then Exit(SetError(FPort.LastError));

  FMode := bpmTerminal;
  FCSLow := false;
  FPendingLen := 0;

  if not ReadBanner(5000, seed) then
  begin
    //No banner means the reset is not proven. Leave FTerminalFresh alone: the
    //blind NUL burst is only safe when the firmware's counter is known to be
    //zero, and only a completed reset proves that.
    Log(bplInfo, 'Buzzpirat: no version banner after reset (device still usable)');
    Exit(true);
  end;

  //On a v3 the banner proves the PIC rebooted: menu_state.binary_mode_counter
  //is back at zero and the first nineteen NULs can go out in one burst. The
  //v5+ legacy binmode answers only the first NUL of a run (legacy4third.c).
  FTerminalFresh := true;

  if FVerbose then
    Log(bplDebug, Format('Buzzpirat: < reset answer $%.2x, banner "%s"', [status, Printable(FBanner)]));
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

//flashrom's version comparison, unchanged (buspirate_spi.c):
//  #define BP_FWVERSION(a,b) ((a) << 8 | (b))
//  #define BP_HWVERSION(a,b) BP_FWVERSION(a,b)
function BPVersion(Major, Minor: integer): integer; inline;
begin
  result := (Major shl 8) or Minor;
end;

function TBusPirate.SupportsBinarySPI: boolean;
begin
  //Firmware 2.3 and older has no binary SPI (flashrom, buspirate_spi_init).
  //An unparsed banner leaves the versions at zero, and refusing then would
  //break every device whose banner was missed, so only a version actually
  //read counts against it.
  result := (FFwMajor = 0) or
            (BPVersion(FFwMajor, FFwMinor) >= BPVersion(2, 4));
end;

//Every SPI transfer here is a write-then-read (0x04, 0x05), which flashrom
//uses from firmware 5.5 on (buspirate_spi_init). An unread version counts as
//new enough, as in SupportsBinarySPI.
function TBusPirate.SupportsWriteThenRead: boolean;
begin
  result := (FFwMajor = 0) or
            (BPVersion(FFwMajor, FFwMinor) >= BPVersion(5, 5));
end;

//The legacy binmode of a Bus Pirate v5, v6 or v7 announces "Bus Pirate v2.5"
//and "Community Firmware v7.1" (legacy4third.c, 0x0F). No real v2 board runs
//a v7 firmware: community firmware dropped v2 in August 2016, before v7.1.
function TBusPirate.IsLegacyEmulation: boolean;
begin
  result := (FHwMajor = 2) and (FHwMinor = 5) and (FFwMajor = 7);
end;

//The order the device indexes its SPI clocks in. Three tables are in use:
//  - documented, 30k 125k 250k 1M 2M 2.6M 4M 8M: DP firmware up to v6.x
//    (binSPIspeed, the index masked to 3 bits), community v8.0 and newer and
//    the v5+ legacy binmode, which takes 0..7 only. Hardware below v3.0 runs
//    one of these;
//  - reordered, twelve entries with 50k at index 4: community builds from
//    2016-10-09 (63974b1426) until PR #182 put the order back on master on
//    2025-07-17 (a7021b83e9), which say v7.0 or v7.1, and the Buzzpirat
//    firmware. A build of that PR's branch from 2025-07-09, or of master in
//    the 4 h 36 min between the merge and the v8.0 banner (b030366a1d), says
//    v7.1 and is documented: taken as reordered;
//  - capped: a banner not read in full, or community v7.0, which shipped both.
//The same index is another clock in the other table: 6 is 4 MHz documented
//and 2 MHz reordered. Before 2026-08-16 (448161080b) the legacy binmode took
//indices 8 to 11 as its 0x40 peripheral command, which switched the target
//supply on; it refuses them since.  By Dreg
function TBusPirate.SpeedTable: TBPSpeedTable;
begin
  if FIsBuzzpirat then Exit(bptReordered);
  if (FHwMajor = 0) or (FFwMajor = 0) then Exit(bptCapped);
  if BPVersion(FHwMajor, FHwMinor) < BPVersion(3, 0) then Exit(bptDocumented);
  if FFwMajor >= 8 then Exit(bptDocumented);
  if FFwMajor = 7 then
  begin
    if FFwMinor >= 1 then Exit(bptReordered);
    Exit(bptCapped);
  end;
  result := bptDocumented;
end;

function TBusPirate.UsesDocumentedSpeedTable: boolean;
begin
  result := SpeedTable = bptDocumented;
end;

function TBusPirate.SPIIndexFor(DocIndex: byte): byte;
const
  REORDERED: array[0..7] of byte = (0, 1, 2, 3, 6, 7, 9, 11);
begin
  if DocIndex > 7 then DocIndex := 7;
  case SpeedTable of
    bptReordered:
      result := REORDERED[DocIndex];
    bptDocumented:
      begin
        result := DocIndex;
        //flashrom, buspirate_spi_init: firmware 6.1 and older cannot run SPI
        //above 2 MHz.
        if (BPVersion(FFwMajor, FFwMinor) < BPVersion(6, 2)) and (result > 4) then
          result := 4;
      end;
  else
    if DocIndex > 3 then result := 3 else result := DocIndex;
  end;
end;

function TBusPirate.SPIClockLimitNote: string;
begin
  result := '';
  case SpeedTable of
    bptCapped:
      result := 'the version banner was not read in full, or it is community v7.0, ' +
                'which shipped two SPI clock tables, so the clocks above 1 MHz run at 1 MHz';
    bptDocumented:
      if BPVersion(FFwMajor, FFwMinor) < BPVersion(6, 2) then
        result := 'firmware 6.1 and older cannot run SPI above 2 MHz (flashrom), so ' +
                  'the clocks above 2 MHz run at 2 MHz';
    bptReordered: ;
  end;
end;

//The same index means a different clock in the two tables, so the frequency
//has to come out of whichever table was actually indexed. This feeds the log
//line and the transfer timeout estimate.  By Dreg
function TBusPirate.SPISpeedHz(Index: byte): LongWord;
begin
  //Documented, or capped to 0..3, where the two tables agree.
  if SpeedTable <> bptReordered then
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

  //Custom serial speeds need firmware 5.5 (flashrom, buspirate_spi_init).
  if (FFwMajor > 0) and (BPVersion(FFwMajor, FFwMinor) < BPVersion(5, 5)) then
  begin
    Reason := Format('firmware v%d.%d is older than 5.5, which is where custom ' +
                     'serial speeds arrived', [FFwMajor, FFwMinor]);
    Exit(BP_DEFAULT_BAUD);
  end;

  //flashrom (buspirate_spi_init) only defaults to 2 Mbaud on hardware 3.0
  //and newer, and warns that higher speeds may not work below that. The Bus
  //Pirate v5+ legacy emulation reports hardware v2.5 and has no baud menu:
  //after 0x0F it stays in its binary mode, which would take the menu text as
  //commands.
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

  //Leaving this menu half way is not free: past its number prompts
  //set_baud_rate drains its transmitter, reprograms U1BRG and then blocks
  //until it reads a space, and nothing else releases it. At a number prompt a
  //space only rings the bell, so send one on the way out, or EnterBitbang's
  //NULs go unanswered until its last resort sends a space.
  //By Dreg
  function LeaveBaudMenu(const Msg: string): boolean;
  begin
    TxReset;
    TxAddByte(Ord(' '));
    if TxSend then FPort.Drain(80, 800);
    //The terminal may still sit in a prompt that answers every NUL, so the
    //burst EnterBitbang sends after a reset could overrun its UART.
    FTerminalFresh := false;
    result := SetError(Msg);
  end;

begin
  if Baud = BP_DEFAULT_BAUD then Exit(true);
  if FMode <> bpmTerminal then
    Exit(SetError('the serial speed can only be changed from the terminal'));

  //Raw BRG entry ("b", option 10) needs firmware 5.5. An unparsed banner
  //leaves the version at zero, and refusing then would contradict
  //UsableSerialSpeed, which lets an unknown device try because the handshake
  //below verifies the result anyway.
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

    //Entry 10 is "BRG raw value".
    if not SendTerminalLine('10') then Exit(false);
    if not WaitText('>', 3000) then
      Exit(LeaveBaudMenu('the terminal baud menu did not ask for a BRG value'));

    //From here the device may end up waiting at this rate, whatever happens
    //below or to this program: that is where Open looks for it next time.
    FFastBaud := Baud;
    FFastBaudPort := FPort.PortName;
    if not SendTerminalLine(IntToStr(divisor)) then Exit(false);

    //The firmware prints "Adjust your terminal" / "Space to continue", drains
    //its transmitter, reprograms U1BRG and then blocks until it reads a space
    //at the new rate. Waiting for that notice beats a blind sleep, but a miss
    //is not fatal: the register was already written.
    if not WaitText('Space to continue', 3000) then
      Log(bplInfo, 'Buzzpirat: baud change notice not seen, switching anyway');
    Sleep(150);
    FPort.WaitSent;
    if not FPort.SetBaudRate(Baud) then
    begin
      //The device waits at the new rate and this host cannot follow it there.
      FTerminalFresh := false;
      Exit(SetError(FPort.LastError));
    end;
    Sleep(60);
    FPort.Purge;

    //The device has already reprogrammed U1BRG and waits for one space at the
    //new rate, with no timeout and deaf to 115200, so keep trying at that
    //rate. If it stays silent, EscapeBaudWait frees and resets it there.
    for attempt := 1 to 12 do
    begin
      TxReset;
      TxAddByte(Ord(' '));
      if not TxSend then Exit(false);
      //If the device took the space and this host missed the prompt, a bare
      //CR makes the terminal print it again.
      if WaitText('HiZ>', 700) or (SendTerminalLine('') and WaitText('HiZ>', 300)) then
      begin
        Log(bplInfo, 'Buzzpirat: serial link running at ' + IntToStr(Baud) + ' baud');
        Exit(true);
      end;
    end;

    //Still no prompt. The device may have switched all the same and sit at
    //that rate, deaf at 115200, waiting for a space or at a prompt this host
    //never saw, so free and reset it there before falling back. The banner
    //wait stays even when nothing came back: this host may not read at Baud.
    Log(bplError, 'Buzzpirat: no answer at ' + IntToStr(Baud) +
                  ' baud after the switch; resetting the device and falling back ' +
                  'to 115200. If it stays silent, unplug and replug the USB cable.');
    EscapeBaudWait(Baud, false);
    result := SetError('could not confirm ' + IntToStr(Baud) + ' baud; staying at 115200');
  finally
    FRecovering := false;
  end;
end;

//set_baud_rate (proc_menu.c) reprograms U1BRG and then waits for a space at
//the new rate, answering nothing else, so a device left there is reachable at
//that rate only. A space frees it, and '#' with a CR resets it back to
//115200. One key at a time: the terminal echoes and is not reading its UART
//meanwhile. True when the banner after the reset came, which also proves the
//NUL counter is back at zero. A freed device prints its prompt and echoes the
//'#', so with QuickIfSilent two silent drains mean nobody is at Baud.
function TBusPirate.EscapeBaudWait(Baud: LongWord; QuickIfSilent: boolean): boolean;
const
  KEYS: array[0..2] of byte = (Ord(' '), Ord('#'), 13);
var
  i, heard: integer;
begin
  FTerminalFresh := false;
  heard := 0;
  if FPort.SetBaudRate(Baud) then
    for i := 0 to High(KEYS) do
    begin
      TxReset;
      TxAddByte(KEYS[i]);
      if not TxSend then Break;
      //Not after the CR: the banner comes at 115200 a moment later.
      if i < High(KEYS) then Inc(heard, FPort.Drain(80, 800));
    end;
  FPort.SetBaudRate(BP_DEFAULT_BAUD, false);
  if QuickIfSilent and (heard = 0) then Exit(false);
  result := ReadBanner(2000);
  FTerminalFresh := result;
end;

function TBusPirate.Open(const APortName: string; HintBaud: LongWord): boolean;
const
  //The rates a previous run could have left the device at, after 115200.
  RATES: array[0..3] of LongWord = (2000000, 1000000, 250000, 230400);
  //TryRate starts no new rate after this: EnterBitbang takes up to about 20 s
  //at a rate where a device answers garbage, and the GUI waits meanwhile.
  OPEN_BUDGET_MS = 60000;
var
  i, n: integer;
  seen: int64;
  likely: array[0..1] of LongWord;
  deadline: QWord;

  function TryRate(Baud: LongWord): boolean;
  begin
    result := false;
    if FWriteFailed or (GetTickCount64 > deadline) then Exit;
    if not FPort.SetBaudRate(Baud) then Exit;
    Log(bplInfo, 'Buzzpirat: retrying at ' + IntToStr(Baud) + ' baud');
    result := EnterBitbang;
  end;

  function IsLikely(Baud: LongWord): boolean;
  var
    k: integer;
  begin
    result := false;
    for k := 0 to n - 1 do
      if likely[k] = Baud then Exit(true);
  end;

begin
  Close(false);

  if not FPort.Open(APortName, BP_DEFAULT_BAUD) then
    Exit(SetError(FPort.LastError));
  deadline := GetTickCount64 + OPEN_BUDGET_MS;

  //Where a device left waiting by a switch that never finished would be: the
  //rate this process last asked for on the port, and the caller's.
  n := 0;
  if (FFastBaud <> 0) and SameText(FFastBaudPort, FPort.PortName) then
  begin
    likely[n] := FFastBaud;
    Inc(n);
  end;
  if (HintBaud <> BP_DEFAULT_BAUD) and (HintBaud <> 0) and not IsLikely(HintBaud) then
  begin
    likely[n] := HintBaud;
    Inc(n);
  end;

  //115200 first, where a healthy device lives.
  seen := FPort.RxCount;
  if EnterBitbang then Exit(true);

  //A port that refused the bytes (TxSend logged it) has nothing to find at
  //any rate, so the search below stops on FWriteFailed.
  if (not FWriteFailed) and (FPort.RxCount = seen) then
  begin
    //Not one byte back. Nothing is listening, or the device waits in
    //set_baud_rate, silent until it reads a space at the rate of a switch that
    //never finished: only that rate reaches it.
    for i := 0 to n - 1 do
    begin
      Log(bplInfo, 'Buzzpirat: no bytes at 115200, trying to free a device left at ' +
                   IntToStr(likely[i]) + ' baud');
      seen := FPort.RxCount;
      if (EscapeBaudWait(likely[i], true) or (FPort.RxCount <> seen)) and EnterBitbang then
        Exit(true);
      if FWriteFailed then Break;
    end;
    if n = 0 then
      Log(bplInfo, 'Buzzpirat: no bytes at all from ' + APortName + ', giving up early');
  end
  else if not FWriteFailed then
  begin
    //Bytes but no BBIO1: a device answering at another rate, the likely ones
    //first.
    for i := 0 to n - 1 do
      if TryRate(likely[i]) then Exit(true);
    for i := 0 to High(RATES) do
      if (not IsLikely(RATES[i])) and TryRate(RATES[i]) then Exit(true);
    //EnterBitbang's way out of a stuck terminal sends '#', which resets the
    //device to 115200 whatever rate it ran at, so look there once more, budget
    //or not: a device the search reset is there now.
    if (not FWriteFailed) and FPort.SetBaudRate(BP_DEFAULT_BAUD) and EnterBitbang then
      Exit(true);
  end;

  FPort.Close;
  if FWriteFailed then Exit(false);
  result := SetError('no Buzzpirat / Bus Pirate answered on ' + APortName +
                     '. Check the port, the cable, and unplug/replug the USB.');
end;

procedure TBusPirate.Close(ResetDevice: boolean);
begin
  if FPort.IsOpen then
  begin
    if ResetDevice and (FMode in [bpmBitbang, bpmSPI, bpmI2C]) then
    begin
      //Best effort: park a v3 back at its user terminal so the next run, or a
      //plain serial terminal, finds it in a known state. A desynchronised
      //stream is one more reason to reset, so FRecovering opens the gate.
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
  FRefusalLogged := false;
  FBusHz := 125000;

  //The next Open may find another device on that port, so nothing about this
  //one survives except FFastBaud, which says where to look.
  FWriteAckChecked := false;
  FWriteNoAck := false;
  FWriteFailed := false;
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
  //A desynchronised link can answer anything: Resync, ResetToTerminal or Close
  //has to run first.
  if FDesynced then Exit(false);
  //Only inside a protocol mode: 0x01 is the mode identifier there, but in raw
  //bitbang the same byte means "enter SPI mode".
  if not (FMode in [bpmSPI, bpmI2C]) then Exit(false);
  if FPendingLen > 0 then Exit(false);

  if not ProbeCurrentMode(detected, 400) then Exit(false);
  result := detected = FMode;

  //Since 448161080b (2026-08-16) the Bus Pirate v5+ legacy binmode takes 0x01
  //as "enter SPI" and goes back to 125 kHz and mode 0 (legacy4third.c,
  //LEGACY_SPI_ENTRY_SPEED), so after every check there the clock has to be
  //sent again, and its speed command only takes effect with the configuration
  //command after it. Until b27685883f (2026-10-23) that configuration command
  //also selected the chip, so CS high goes last. A real v3 only answers "SPI1".
  if result and (FMode = bpmSPI) and IsLegacyEmulation then
  begin
    result := CommandWithAck(SPICMD_SPEED or FSPI.Speed, 'SPI speed') and
              CommandWithAck(SPIConfigByte, 'SPI configuration') and
              CommandWithAck(SPICMD_CS_HIGH, 'CS high');
    if result then FCSLow := false;
  end;
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
  acked: boolean;
begin
  if not FPort.IsOpen then Exit(SetError('device is not open'));
  if Settings.Speed > High(BP_SPI_SPEED_HZ) then Exit(SetError('invalid SPI speed index'));
  if not SupportsWriteThenRead then
    Exit(SetError(Format('firmware v%d.%d is older than 5.5 and has no write-then-read ' +
                         'SPI command, which this driver needs: update the firmware',
                         [FFwMajor, FFwMinor])));

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

  //Only a v7.1 banner on real hardware can lack the acknowledgement
  //(ProbeWriteAck); DP firmware, community v8.0 and the v5+ legacy binmode
  //all send it, and probing a firmware that was not identified risks more
  //than it tells.
  if not FWriteAckChecked then
  begin
    acked := true;
    if (FFwMajor = 7) and (FFwMinor = 1) and (FHwMajor >= 3) then
      if not ProbeWriteAck(acked) then Exit(false);
    FWriteAckChecked := true;
    FWriteNoAck := not acked;
    if FWriteNoAck then
      Log(bplInfo, 'Buzzpirat: this firmware does not acknowledge an SPI write that ' +
                   'reads nothing back (community builds from 2019 to July 2025, ' +
                   'Buzzpirat before v7.1.9), so commands with no answer, such as ' +
                   'write enable, erase and program, will be refused. Update the firmware');
  end;

  Log(bplInfo, 'Buzzpirat: SPI ready, ' + IntToStr(FBusHz div 1000) +
               ' kHz, output ' + BoolToStr(Settings.PushPull and not Settings.Pullups, '3.3V', 'open drain'));
  result := true;
end;

function TBusPirate.SPIConfigByte: byte;
begin
  result := SPICMD_CONFIG;
  //Pull-ups need the pins open drain, otherwise the push-pull driver fights
  //the resistors.
  if FSPI.PushPull and (not FSPI.Pullups) then result := result or SPI_CFG_OUT_3V3;
  if FSPI.ClockIdleHigh then result := result or SPI_CFG_CKP_IDLE_HIGH;
  if FSPI.ClockEdgeActiveToIdle then result := result or SPI_CFG_CKE_ACT2IDLE;
  if FSPI.SampleAtEnd then result := result or SPI_CFG_SMP_END;
end;

//Community firmware sent no acknowledgement for a write-then-read that reads
//nothing back from February 2019 (8df3c33f70) until 35a3518cbf came to master
//with PR #182 on 2025-07-17, and the Buzzpirat firmware until v7.1.9
//(f141a3e1b3, 2023-11-26). Every write enable, erase and page program would
//wait out its timeout there. One zero byte written with CS high, which no chip
//takes, says which kind this is. Silence gets a second probe: the host can
//lose a byte under load, and one lost acknowledgement would refuse every write.
function TBusPirate.ProbeWriteAck(out Acked: boolean): boolean;
var
  status: byte;
  attempt: integer;
  detected: TBPMode;
begin
  Acked := true;
  for attempt := 1 to 2 do
  begin
    TxReset;
    TxAddByte(SPICMD_WRITE_READ_NOCS);
    TxAddByte(0); TxAddByte(1);
    TxAddByte(0); TxAddByte(0);
    TxAddByte($00);
    if not TxSend then Exit(false);

    if FPort.ReadByteValue(status, 500) then
    begin
      if FVerbose then Log(bplDebug, 'Buzzpirat: < $' + IntToHex(status, 2) + ' to the write probe');
      if status = BP_ACK then Exit(true);
      MarkDesynced('SPI write probe answered $' + IntToHex(status, 2));
      Exit(SetError('SPI write probe: device answered $' + IntToHex(status, 2)));
    end;

    //Silence: the firmware took the command and says nothing, or the link died
    //just now. 0x01 tells them apart: it names the mode, and a late
    //acknowledgement in front of its "SPI1" does no harm.
    if (not ProbeCurrentMode(detected, 1000)) or (detected <> bpmSPI) then
    begin
      MarkDesynced('no answer after the SPI write probe');
      Exit(SetError('SPI write probe: the device stopped answering'));
    end;
  end;
  Acked := false;
  result := true;
end;

function TBusPirate.ApplySPISettings: boolean;
begin
  if FMode <> bpmSPI then Exit(SetError('not in SPI mode'));

  //CS bit set so the pin starts idle-high (it follows the HiZ setting).
  if not SendPeripherals(FSPI.Power, FSPI.Pullups, FSPI.AuxHigh, true) then Exit(false);

  //Both of the next two commands run spi_setup() on the device, which puts
  //SPICS back to an output. In open drain mode the peripheral command above
  //made it an input, so the peripheral command has to come first.
  if not CommandWithAck(SPICMD_SPEED or FSPI.Speed, 'SPI speed') then Exit(false);
  if not CommandWithAck(SPIConfigByte, 'SPI configuration') then Exit(false);

  //Known starting point: CS idle high.
  if not CommandWithAck(SPICMD_CS_HIGH, 'CS high') then Exit(false);
  FCSLow := false;
  result := true;
end;

function TBusPirate.EnterI2C(const Settings: TBPI2CSettings): boolean;
begin
  if not FPort.IsOpen then Exit(SetError('device is not open'));
  if Settings.Speed > High(BP_I2C_SPEED_HZ) then Exit(SetError('invalid I2C speed index'));
  //The v5+ legacy binmode has no I2C mode: 0x02 is CS low there
  //(legacy4third.c), so asking for I2C would only drive chip select.
  if IsLegacyEmulation then
    Exit(SetError('the legacy binary mode of a Bus Pirate v5 or newer is SPI only: ' +
                  'for I2C, pick the BusPirateV5+ programmer'));

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
  //CS high, which in I2C's open drain mode makes CS an input (binary_io.c,
  //bp_binary_io_peripherals_set): with the pull-ups on, an SPI chip left on
  //the clip is deselected. CS low would drive it low and keep that chip
  //selected while SCL and SDA toggle its clock and data pins.
  result := SendPeripherals(FI2C.Power, FI2C.Pullups, FI2C.AuxHigh, true);
end;

//SPI

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
  //ProbeWriteAck: the acknowledgement would never come, and waiting for it
  //would end in a timeout and a link out of sync.
  if (ReadCount = 0) and FWriteNoAck then
    Exit(SetError('this firmware does not acknowledge an SPI write that reads ' +
                  'nothing back, so this command cannot be sent: update the firmware'));

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

  //The firmware moves CS before it acknowledges, so the pin has moved once
  //these bytes leave the host, however the rest of this slice ends.
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

procedure TBusPirate.SPIDropQueued;
begin
  if FPendingLen > 0 then
    Log(bplInfo, 'Buzzpirat: dropping ' + IntToStr(FPendingLen) +
                 ' queued byte(s) from an abandoned transfer');
  FPendingLen := 0;
end;

function TBusPirate.SPIReleaseCS: boolean;
begin
  if FMode <> bpmSPI then Exit(SetError('not in SPI mode'));

  //Releasing CS with bytes still queued only ever happens when a transfer was
  //abandoned: this is the teardown path, called from DevOpen, DevClose,
  //SPIDeinit and Destroy. Flushing them here would turn a half assembled
  //command fragment into a complete, CS framed SPI transaction against the
  //flash chip.
  SPIDropQueued;

  if not FCSLow then Exit(true);
  TxReset;
  TxAddByte(SPICMD_CS_HIGH);
  if not TxSend then Exit(false);
  FCSLow := false;
  result := ExpectAck('CS high', BusTimeout(0, 4));
end;

//I2C

function TBusPirate.AddressAcks(Addr8: byte; out Acked: boolean): boolean;
var
  status: byte;
begin
  Acked := false;
  TxReset;
  TxAddByte(I2CCMD_WRITE_READ);
  TxAddByte(0); TxAddByte(1);
  TxAddByte(0); TxAddByte(0);
  TxAddByte(Addr8);
  if not TxSend then Exit(false);
  if not RxByte(status, BusTimeout(2, 8)) then Exit(false);
  Acked := status = BP_ACK;
  //A NACK ends the firmware's transfer before its stop bit.
  if not Acked then
    if not I2CStop then Exit(false);
  result := true;
end;

function TBusPirate.I2CWriteRead(DevAddr: byte; WritePtr: Pointer; WriteCount: integer;
                                 ReadPtr: Pointer; ReadCount: integer): boolean;
var
  txCount, timeout: integer;
  status: byte;
  acked: boolean;
begin
  if FMode <> bpmI2C then Exit(SetError('not in I2C mode'));
  if WriteCount < 0 then WriteCount := 0;
  if ReadCount < 0 then ReadCount := 0;

  txCount := WriteCount + 1;   //the address byte counts as a written byte
  //A write over the limit gets 0x00, and its payload, never read in, would
  //run as commands. The Buzzpirat firmware does not check a read's count.
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
  //repeated start when more than one byte was written, so a read with no
  //register write has to carry the read address itself.
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
    //The firmware bailed out part way through and sent no stop bit.
    I2CStop;
    //Its 0x00 only says that some byte got no acknowledge. When bytes followed
    //the address, the address goes out again alone: a device that takes it now
    //refused what came after (its WP pin high, a protected area), unless it was
    //only busy the first time.  By Dreg
    if WriteCount > 0 then
    begin
      if not AddressAcks(DevAddr and $FE, acked) then Exit(false);
      if acked then
        Exit(SetError('device $' + IntToHex(DevAddr, 2) +
                      ' acknowledged its address but refused the data after it'));
    end;
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
    //The address alone, nothing read: 0x01 back means a device acked.
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
  //ignores the result of its own start condition (i2c.c calls
  //bitbang_i2c_start without checking it, while the interactive path checks it
  //and prints a pull-up warning), so with SDA stuck at ground the address byte
  //is clocked with no start, the acknowledge bit reads back as the grounded
  //line, and the firmware reports success. Every address then looks present:
  //such a bus has no pull-ups, which on a v3 most often means the Vpullup pin
  //is not fed. The BPIO2 scanner has the same guard: that firmware fails a
  //start only on a PIO timeout and takes the sampled SDA bit for the
  //acknowledge.  By Dreg
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

//Buzz extensions

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

  //The check leaves VREGEN low, and in SPI or I2C mode only the peripheral
  //command turns it on again, so the mode is re-armed here while the link is
  //in step, an unhealthy answer included, or the next operation talks to an
  //unpowered chip and reads nothing but $FF. After a failure Resync re-arms it
  //before the next operation. For SPI the peripheral byte alone is not enough:
  //in open drain mode it turns CS into an input, and only the speed and
  //configuration commands (which run spi_setup) make it an output again.
  if not FDesynced then
    case FMode of
      bpmSPI: if not ApplySPISettings then ok := false;
      bpmI2C: if not ApplyI2CSettings then ok := false;
    end;

  result := ok;
end;


//AsProgrammer hardware back end

//Address of the first element, or nil for an empty slice or array. The slice
//is Count bytes: callers pass buffers that are almost always larger, and
//sometimes a bare byte variable.
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
    if FBP.Mode = bpmSPI then FBP.SPIReleaseCS;
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
  FErrorLogged := true;
  //Anything that went wrong makes the session suspect, so the next DevOpen
  //re-arms the device instead of trusting a four byte liveness check.
  FAppliedConfig := '';
  //The engine's own error was logged where it happened (SetError), or kept
  //quiet on purpose (the refusals of a link out of sync after the first).
  if Msg <> FBP.LastError then LogPrint('Buzzpirat: ' + Msg);
  result := false;
end;

function TBuzzpiratHardware.GetLastError: string;
begin
  result := FStrError;
end;

function TBuzzpiratHardware.ErrorWasLogged: boolean;
begin
  result := FErrorLogged;
end;

//Settings

function TBuzzpiratHardware.SPIClockIndex: byte;
begin
  result := SelectedSPISpeed;
end;

function TBuzzpiratHardware.SPIClockTable: string;
const
  NAMES: array[TBPSpeedTable] of string =
    ('not known, held at 1 MHz', 'the documented BBIO order', 'the reordered spi_bus_speed[]');
begin
  result := NAMES[FBP.SpeedTable];
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

//The menu offers the eight clocks the BBIO documentation lists, as documented
//indices; TBusPirate.SPIIndexFor turns one into what this device's firmware
//indexes (SpeedTable has the tables and where each one runs).
function TBuzzpiratHardware.SelectedSPISpeed: byte;
var
  doc: byte;
begin
  if MainForm.MenuBuzzpiratSPI30KHz.Checked then doc := 0
  else if MainForm.MenuBuzzpiratSPI125KHz.Checked then doc := 1
  else if MainForm.MenuBuzzpiratSPI250KHz.Checked then doc := 2
  else if MainForm.MenuBuzzpiratSPI1MHz.Checked then doc := 3
  else if MainForm.MenuBuzzpiratSPI2MHz.Checked then doc := 4
  else if MainForm.MenuBuzzpiratSPI2P6MHz.Checked then doc := 5
  else if MainForm.MenuBuzzpiratSPI4MHz.Checked then doc := 6
  else if MainForm.MenuBuzzpiratSPI8MHz.Checked then doc := 7
  else doc := 1;  //125 kHz
  result := FBP.SPIIndexFor(doc);
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
  //The speed index alone is ambiguous: index 7 means 2.6 MHz on Buzzpirat
  //firmware and 8 MHz on the v5+ legacy emulation, so which table produced it
  //is part of what was applied and has to be part of the signature.  By Dreg
  if WantI2C then
    result := Format('i2c|%d|%d%d|%d', [SelectedI2CSpeed,
                Ord(MainForm.MenuBuzzpiratPullups.Checked),
                Ord(MainForm.MenuBuzzpiratPower.Checked),
                Ord(FBP.SpeedTable)])
  else
    result := Format('spi|%d|%d%d%d|%d', [SelectedSPISpeed,
                Ord(MainForm.MenuBuzzpiratSPINormal.Checked),
                Ord(MainForm.MenuBuzzpiratPullups.Checked),
                Ord(MainForm.MenuBuzzpiratPower.Checked),
                Ord(FBP.SpeedTable)]);
end;

//Connection

function TBuzzpiratHardware.Connect(const APort: string): boolean;
var
  wanted: LongWord;
  reason: string;
begin
  FBP.Verbose := MainForm.MenuBuzzpiratVerbose.Checked;
  FAppliedConfig := '';
  FOpenPort := '';
  FAppliedSerial := SelectedSerialSpeed;

  //The menu's rate is where a device would wait if an earlier run's switch to
  //it never finished.
  if not FBP.Open(APort, FAppliedSerial) then Exit(Complain(FBP.LastError));

  //A reset gives the hardware and firmware banner and a known starting point,
  //and only the terminal it leads to accepts a baud rate change.
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

    //EnterSPI refuses such a firmware: say why when connecting.
    if not FBP.SupportsWriteThenRead then
      LogPrint(Format('Buzzpirat: firmware v%d.%d is older than 5.5 and has no ' +
                      'write-then-read SPI command, so SPI is refused; update the firmware',
                      [FBP.FwMajor, FBP.FwMinor]))
    else
    begin
      reason := FBP.SPIClockLimitNote;
      if reason <> '' then LogPrint('Buzzpirat: ' + reason);
    end;

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
  FErrorLogged := false;
  FDevOpened := false;
  FBP.Verbose := MainForm.MenuBuzzpiratVerbose.Checked;

  port := Trim(main.Buzzpirat_COMPort);
  if port = '' then Exit(Complain('no COM port selected (Buzzpirat / BusPirateV3 menu -> COM port)'));

  signature := ConfigSignature;

  //After a failed transfer the device may still be answering. Get the stream
  //back in step before anything else.
  if FBP.Desynced then
  begin
    LogPrint('Buzzpirat: the last transfer failed, re-arming the link');
    FAppliedConfig := '';
    if not FBP.Resync then
      if not Connect(port) then Exit(false);
  end;

  //Fast path: same port, same settings, device still answering. Each DevOpen
  //then costs one round trip (four on the v5+ legacy binmode, see Ping)
  //instead of a full reset and handshake.
  if FBP.IsOpen and (port = FOpenPort) and (signature = FAppliedConfig) and
     (SelectedSerialSpeed = FAppliedSerial) and
     (not MainForm.MenuBuzzpiratResetEach.Checked) then
  begin
    //Bytes still queued belong to an abandoned transfer. Ping refuses to run
    //with them there, and that reads as "stopped answering" and costs a
    //reconnect, as in the BPIO2 back end.  By Dreg
    FBP.SPIDropQueued;
    if FBP.Ping then
    begin
      //An operation cancelled mid transaction can leave CS asserted and stale
      //bytes in the receive queue. Ping passes as long as 'SPI1' is in its
      //answer, so this release can read the next stale byte as its
      //acknowledgement, fail and mark the link out of sync. Returning true then
      //would hand the caller a link that refuses every byte.  By Dreg
      if (FBP.Mode <> bpmSPI) or FBP.SPIReleaseCS then
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
    //Still connected but the configuration differs: back to bitbang and re-arm.
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
  if FBP.Mode = bpmSPI then FBP.SPIReleaseCS;

  //Only tear the link down when the user asked for it. Keeping it up lets the
  //next DevOpen take the fast path.
  if MainForm.MenuBuzzpiratResetEach.Checked then
  begin
    FBP.Close(true);
    FOpenPort := '';
    FAppliedConfig := '';
  end;
end;

function TBuzzpiratHardware.Disconnect: TBPDisconnect;
begin
  if not FBP.IsOpen then
    result := bpdNoSession
  else if FBP.IsLegacyEmulation then
    result := bpdKeptBinmode
  else
    result := bpdReset;
  FDevOpened := false;
  FBP.Close(true);
  FOpenPort := '';
  FAppliedConfig := '';
end;

//SPI

function TBuzzpiratHardware.SPIInit(speed: integer): boolean;
begin
  //The clock comes from the Buzzpirat menu, not from the generic speed table,
  //and it was already programmed by DevOpen.
  result := FDevOpened and (FBP.Mode = bpmSPI);
  if not result then
  begin
    FStrError := 'SPI mode is not active';
    FErrorLogged := false;
  end;
end;

procedure TBuzzpiratHardware.SPIDeinit;
begin
  if not FDevOpened then Exit;
  if FBP.Mode <> bpmSPI then Exit;
  FBP.SPIReleaseCS;
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

//I2C

procedure TBuzzpiratHardware.I2CInit;
begin
  //Configured by DevOpen.
end;

procedure TBuzzpiratHardware.I2CDeinit;
begin
  //Nothing to undo: the mode stays valid until the link is closed.
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
    ErrMsg := 'No COM port selected. Pick one in the Buzzpirat / BusPirateV3 menu.';
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
    //scan sends, however many times the scanner is opened. The BPIO2 back end
    //does the same.  By Dreg
    if FBP.Desynced then
      if not FBP.Resync then
        if not Connect(port) then
        begin
          ErrMsg := FBP.LastError;
          Exit;
        end;

  //The scan runs I2C whatever the SPI/I2C radio says, so the session is left
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
  healthy, ok: boolean;
begin
  if not FBP.IsOpen then
  begin
    if Trim(main.Buzzpirat_COMPort) = '' then Exit('No COM port selected');
    if not Connect(Trim(main.Buzzpirat_COMPort)) then Exit('Cannot reach the device: ' + FBP.LastError);
  end
  else
    //The first lines below come from what the last successful open cached, so
    //on a desynced link the report would look much like a healthy one and the
    //user would keep retrying. Re-arm the link first, and say so when that is
    //not possible.  By Dreg
    if FBP.Desynced then
      if not FBP.Resync then
        if not Connect(Trim(main.Buzzpirat_COMPort)) then
          Exit('The device is not answering: ' + FBP.LastError);

  result := 'Port          : ' + FBP.Port.PortName + LineEnding +
            'Serial speed  : ' + IntToStr(FBP.Port.BaudRate) + ' baud' + LineEnding +
            'Hardware      : v' + FBP.Hardware + LineEnding +
            'Firmware      : v' + FBP.Firmware + LineEnding +
            'Buzzpirat fw  : ' + BoolToStr(FBP.IsBuzzpirat, 'yes', 'no') + LineEnding;

  //The rest is buzz commands, which only Buzzpirat firmware has.
  if not FBP.IsBuzzpirat then Exit;

  //The buzz commands below need SPI or I2C mode. Arm the one the SPI/I2C radio
  //picks if this session never got that far: SPI can drive the pins push-pull,
  //which an I2C wiring should not see.
  if not (FBP.Mode in [bpmSPI, bpmI2C]) then
  begin
    if WantI2C then ok := FBP.EnterI2C(I2CSettings) else ok := FBP.EnterSPI(SPISettings);
    //That is not necessarily what the next operation wants, so make the next
    //DevOpen re-arm instead of trusting the session.
    FAppliedConfig := '';
    if not ok then Exit(result + 'Cannot reach the device: ' + FBP.LastError + LineEnding);
  end;

  if FBP.ReadVoltages(volts) then
    result := result + Format(
      '5.0V rail     : %.2f V' + LineEnding +
      '3.3V rail     : %.2f V' + LineEnding +
      '2.5V rail     : %.2f V' + LineEnding +
      '1.8V rail     : %.2f V' + LineEnding +
      'Vpullup       : %.2f V' + LineEnding +
      'ADC probe     : %.2f V' + LineEnding,
      [volts.V50, volts.V33, volts.V25, volts.V18, volts.VPullup, volts.VProbe])
  else
    //Said in the report, as the supply check below does: a report with no
    //rail lines at all would read as a firmware that has none.  By Dreg
    result := result + 'Rail voltages : not read - ' + FBP.LastError + LineEnding;

  //The check switches the on-board regulator on to measure under load. With
  //the power option off the user wants the target unpowered, so it is skipped.
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

//Microwire

//Names the programmers that do Microwire, as the BusPirateV5+ driver does.
//By Dreg
const
  MW_UNSUPPORTED = 'Microwire is not supported by the Buzzpirat driver. Use a ' +
                   'CH341a, CH347T, UsbAsp, AVRISP-MKII, Arduino or FT232H for ' +
                   'Microwire parts.';

function TBuzzpiratHardware.MWInit(speed: integer): boolean;
begin
  //Logged here and not in MWRead/MWWrite: those run once per two byte chunk
  //and would flood the log pane.
  result := Complain(MW_UNSUPPORTED);
end;

procedure TBuzzpiratHardware.MWDeinit;
begin
end;

function TBuzzpiratHardware.MWRead(CS: byte; BufferLen: integer; var buffer: array of byte): integer;
begin
  FStrError := MW_UNSUPPORTED;
  FErrorLogged := false;
  result := -1;
end;

function TBuzzpiratHardware.MWWrite(CS: byte; BitsWrite: byte; buffer: array of byte): integer;
begin
  FStrError := MW_UNSUPPORTED;
  FErrorLogged := false;
  result := -1;
end;

function TBuzzpiratHardware.MWIsBusy: boolean;
begin
  result := false;
end;

end.
