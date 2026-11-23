// Audeze Maxwell 2 dongle: Airoha RACE commands over the vendor HID collection (MI_05 COL02).
// Shared by chatmix.ps1 and chatmix-tray.ps1. Must stay C# 5 (Windows PowerShell 5.1 Add-Type).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class Maxwell : IDisposable {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool WriteFile(SafeFileHandle h, byte[] b, int n, out int w, IntPtr o);
  [DllImport("hid.dll", SetLastError = true)]
  static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] b, int n);
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
  static extern int CM_Get_Device_Interface_List_SizeW(out int len, ref Guid g, string devId, int flags);
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
  static extern int CM_Get_Device_Interface_ListW(ref Guid g, string devId, char[] buf, int len, int flags);

  static Guid HidInterface = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
  const string PathMatch = "vid_3329&pid_4b28&mi_05&col02";

  // HID report framing: <report id> <data length> <flags> <data...>, zero-padded.
  const int ReportSize = 62;
  const int MaxReportData = 0x3B;
  const byte OutReportId = 6, InReportId = 7;
  const byte ViaDongle = 0x80;  // isOpenedDongle << 7; 0x00 when wired

  // RACE packet: 05 <type> <length LE> <command id LE> <payload...>
  const byte RaceChannel = 0x05;
  const byte RaceCommand = 0x5A, RaceResponse = 0x5B, RaceIndication = 0x5D;

  // Device path of the dongle's vendor HID collection, or null if not plugged in.
  public static string FindPath() {
    for (int attempt = 0; attempt < 3; attempt++) {  // list can grow between the two calls
      Guid g = HidInterface; int len;
      if (CM_Get_Device_Interface_List_SizeW(out len, ref g, null, 0) != 0 || len <= 1) return null;
      var buf = new char[len];
      if (CM_Get_Device_Interface_ListW(ref g, null, buf, len, 0) != 0) continue;
      foreach (var p in new string(buf).Split('\0'))
        if (p.ToLowerInvariant().Contains(PathMatch)) return p;
      return null;
    }
    return null;
  }

  readonly SafeFileHandle h;

  // Hex of the last packet received for the last request's command, "" if none. For debugging.
  public string LastRaw { get; private set; }

  public Maxwell(string path) {
    LastRaw = "";
    h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new IOException("open failed: " + Marshal.GetLastWin32Error());
  }

  public void Dispose() { h.Dispose(); }

  // Game/chat mix dial: 0..20, 10 = centre. -1 if the headset did not answer.
  // Reply: 05 5B 06 00 83 2C <status> 0B 00 <value>.
  public int ReadChatMix() {
    byte[] p = Request(0x2C83, RaceResponse, 0x0B, 0x00);
    return p != null && p.Length > 9 ? p[9] : -1;
  }

  // Battery percent. -1 if the headset did not answer.
  // Reply is an ack (05 5B 03 00 D6 0C <status>), then an indication (05 5D 05 00 D6 0C 00 00 <level>).
  public int ReadBattery() {
    byte[] p = Request(0x0CD6, RaceIndication, 0x00);
    return p != null && p.Length > 8 ? p[8] : -1;
  }

  // Sends RACE command `cmd` and returns its first reply of type `replyType`. Returns null after
  // ~400 ms, or when the headset acks with a non-zero status. Throws IOException if the write
  // fails (dongle unplugged).
  byte[] Request(ushort cmd, byte replyType, params byte[] payload) {
    var race = new byte[6 + payload.Length];
    race[0] = RaceChannel; race[1] = RaceCommand;
    race[2] = (byte)(2 + payload.Length);  // [3], the length high byte, stays 0
    race[4] = (byte)cmd; race[5] = (byte)(cmd >> 8);
    payload.CopyTo(race, 6);

    LastRaw = "";
    Write(race);
    foreach (byte[] pkt in ReadPackets()) {
      if (pkt.Length < 7 || pkt[4] != race[4] || pkt[5] != race[5]) continue;  // not for this command
      LastRaw = BitConverter.ToString(pkt);
      if (pkt[1] == RaceResponse && pkt[6] != 0) return null;  // error status
      if (pkt[1] == replyType) return pkt;
    }
    return null;
  }

  void Write(byte[] race) {
    var report = new byte[ReportSize];
    report[0] = OutReportId; report[1] = (byte)race.Length; report[2] = ViaDongle;
    Array.Copy(race, 0, report, 3, race.Length);
    int w;
    if (!WriteFile(h, report, report.Length, out w, IntPtr.Zero))
      throw new IOException("write failed: " + Marshal.GetLastWin32Error());
  }

  // Polls input reports for ~400 ms and yields each whole RACE packet in the reply stream.
  IEnumerable<byte[]> ReadPackets() {
    var stream = new List<byte>();
    for (int tries = 0; tries < 40; tries++) {
      Thread.Sleep(10);
      var report = new byte[ReportSize]; report[0] = InReportId;
      if (!HidD_GetInputReport(h, report, report.Length)) continue;
      int n = report[1];
      if (n == 0 || n > MaxReportData) continue;
      for (int i = 0; i < n; i++) stream.Add(report[3 + i]);

      // The stream also carries other packets (e.g. firmware debug text). Resync on 05 5A..5D.
      while (true) {
        while (stream.Count > 0 && stream[0] != RaceChannel) stream.RemoveAt(0);
        if (stream.Count < 4) break;
        int total = (stream[2] | (stream[3] << 8)) + 4;
        if (stream[1] < RaceCommand || stream[1] > RaceIndication || total > 0x400) { stream.RemoveAt(0); continue; }
        if (stream.Count < total) break;
        byte[] pkt = stream.GetRange(0, total).ToArray();
        stream.RemoveRange(0, total);
        yield return pkt;
      }
    }
  }
}

// One consistent reading of the headset. The poller replaces the whole object, so a reader
// never sees half an update.
public sealed class MaxwellState {
  public readonly int ChatMix;    // -1 = unknown
  public readonly int Battery;    // -1 = unknown
  public readonly string Status;  // "" when the headset answers

  public MaxwellState(int chatMix, int battery, string status) {
    ChatMix = chatMix; Battery = battery; Status = status;
  }
}

// Polls the headset on a background thread. The UI reads State; nothing calls back into it.
// State is replaced only when a value changes, so a reference compare tells the UI to redraw.
public sealed class MaxwellPoller {
  const int BatteryIntervalMs = 60000;
  const int BatteryRetryMs = 5000;

  public volatile MaxwellState State = new MaxwellState(-1, -1, "Starting");

  readonly int mixIntervalMs;
  readonly ManualResetEvent stop = new ManualResetEvent(false);
  readonly ManualResetEvent batteryNow = new ManualResetEvent(false);
  Thread thread;

  // Used only on the poller thread.
  Maxwell dev;
  DateTime nextBattery = DateTime.MinValue;

  public MaxwellPoller(int mixIntervalMs) { this.mixIntervalMs = mixIntervalMs; }

  public void Start() {
    thread = new Thread(Run) { IsBackground = true, Name = "Maxwell poller" };
    thread.Start();
  }

  public void Stop() { stop.Set(); if (thread != null) thread.Join(2000); }

  public void RefreshBattery() { batteryNow.Set(); }

  void Run() {
    while (!stop.WaitOne(SafeStep())) { }
    Close();
  }

  int SafeStep() {
    try { return Step(); }
    catch (Exception e) { Close(); return Lost(e.Message, 3000); }
  }

  // One poll. Returns how long to wait before the next one.
  int Step() {
    // The Audeze app polls the same interface and the two steal each other's replies.
    if (Process.GetProcessesByName("Audeze").Length > 0) {
      Close();
      return Lost("Paused: Audeze app is running", 3000);
    }
    if (dev == null) {
      string path = Maxwell.FindPath();
      if (path == null) return Lost("Dongle not found", 3000);
      dev = new Maxwell(path);
    }

    int mix = dev.ReadChatMix();
    if (mix < 0) return Lost("Headset off or out of range", 2000);
    Publish(mix, State.Battery, "");

    if (batteryNow.WaitOne(0) || DateTime.UtcNow >= nextBattery) {
      batteryNow.Reset();
      int battery = dev.ReadBattery();
      if (battery >= 0) Publish(mix, battery, "");
      nextBattery = DateTime.UtcNow.AddMilliseconds(battery >= 0 ? BatteryIntervalMs : BatteryRetryMs);
    }
    return mixIntervalMs;
  }

  // Headset unreachable: clear the readings, and read the battery as soon as it is back.
  int Lost(string why, int retryMs) {
    Publish(-1, -1, why);
    nextBattery = DateTime.MinValue;
    return retryMs;
  }

  void Publish(int mix, int battery, string status) {
    MaxwellState s = State;
    if (s.ChatMix != mix || s.Battery != battery || s.Status != status)
      State = new MaxwellState(mix, battery, status);
  }

  void Close() { if (dev != null) { dev.Dispose(); dev = null; } }
}
