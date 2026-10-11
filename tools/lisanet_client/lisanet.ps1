# ---------------------------------------------------------------------------------------------
# lisanet.ps1 -- PC client for ESFloppy's LisaNet SD server (docs/lisanet_link_protocol.md), over ESFloppy's USB port.
# For development and testing before the external WiFi board exists. Written with an AI assistant.
#
#   powershell -ExecutionPolicy Bypass -File tools/lisanet_client/lisanet.ps1 -Port COM4 <command> [args]
#
#   hello                      protocol version and firmware string
#   info                       card size and free space
#   ls [path]                  list a directory
#   stat <path>
#   get <remote> <local>       download a file
#   put <local> <remote>       upload a file
#   delete <path>              delete a file or empty directory on the SD card (alias: rm)
#   mv <old> <new>
#   mkdir <path>
#   mountnext [path|clear]     show, set, or clear the image ESFloppy mounts on returning to FLOPPY
#
# ESFloppy must be in its SD-server personality: ESP32 MODE = WIFI in the LisaFPGA menu.
# ---------------------------------------------------------------------------------------------
param(
    [string]$Port = 'COM4',
    [Parameter(Position = 0, Mandatory = $true)][string]$Command,
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Ports;
using System.Text;
using System.Collections.Generic;

public class LisaNetException : Exception { public LisaNetException(string m) : base(m) {} }

public class LisaNet : IDisposable {
    public const int MaxData = 4096;
    static readonly string[] StatusNames = { "OK", "NOT_FOUND", "EXISTS", "IO", "BAD_REQUEST", "NO_HANDLE", "UNKNOWN_CMD", "NO_CARD", "NO_CONTIGUOUS (no unbroken free space that large)" };
    static readonly uint[] Table = MakeTable();
    readonly SerialPort sp;
    byte seq = 0;
    public int Retries = 0;

    static uint[] MakeTable() {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[i] = c; }
        return t;
    }
    static uint Crc(byte[] b, int off, int n) {
        uint c = 0xFFFFFFFFu;
        for (int i = 0; i < n; i++) c = Table[(c ^ b[off + i]) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }

    public LisaNet(string port) {
        sp = new SerialPort(port, 115200);
        sp.DtrEnable = false; sp.RtsEnable = false;       // don't reset the ESP32
        sp.ReadTimeout = 200; sp.WriteTimeout = 2000;
        sp.Open();
        sp.DiscardInBuffer();
    }
    public void Dispose() { sp.Close(); }

    // Sends one request and returns the response payload after the status byte. Retries on timeout or corruption.
    public byte[] Call(byte cmd, byte[] payload, int timeoutMs) {
        seq++;
        var frame = new byte[6 + payload.Length + 4];
        frame[0] = 0xA5; frame[1] = 0x5A; frame[2] = cmd; frame[3] = seq;
        frame[4] = (byte)payload.Length; frame[5] = (byte)(payload.Length >> 8);
        Buffer.BlockCopy(payload, 0, frame, 6, payload.Length);
        uint c = Crc(frame, 2, 4 + payload.Length);
        for (int i = 0; i < 4; i++) frame[6 + payload.Length + i] = (byte)(c >> (8 * i));
        for (int attempt = 0; attempt < 5; attempt++) {
            if (attempt > 0) Retries++;
            sp.DiscardInBuffer();
            sp.Write(frame, 0, frame.Length);
            byte[] r = ReadResponse((byte)(cmd | 0x80), seq, timeoutMs);
            if (r == null) continue;
            if (r.Length < 1) throw new LisaNetException("empty response");
            if (r[0] != 0) throw new LisaNetException("server: " + (r[0] < StatusNames.Length ? StatusNames[r[0]] : "status " + r[0]));
            var data = new byte[r.Length - 1];
            Buffer.BlockCopy(r, 1, data, 0, data.Length);
            return data;
        }
        throw new LisaNetException("no valid response after 5 attempts (is ESP32 MODE set to WIFI?)");
    }

    byte[] ReadResponse(byte wantCmd, byte wantSeq, int timeoutMs) {
        var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        var hdr = new byte[6];
        int have = 0;
        while (DateTime.Now < deadline) {
            int b;
            try { b = sp.ReadByte(); } catch (TimeoutException) { continue; }
            if (have == 0 && b != 0xA5) continue;                         // skip log text
            if (have == 1 && b != 0x5A) { have = b == 0xA5 ? 1 : 0; continue; }
            hdr[have++] = (byte)b;
            if (have < 6) continue;
            int len = hdr[4] | (hdr[5] << 8);
            if (len > MaxData + 64) { have = 0; continue; }
            var rest = new byte[len + 4];
            int got = 0;
            while (got < rest.Length && DateTime.Now < deadline) {
                try { got += sp.Read(rest, got, rest.Length - got); } catch (TimeoutException) { }
            }
            if (got < rest.Length) return null;
            var all = new byte[4 + len];
            Buffer.BlockCopy(hdr, 2, all, 0, 4);
            Buffer.BlockCopy(rest, 0, all, 4, len);
            uint crc = (uint)(rest[len] | (rest[len + 1] << 8) | (rest[len + 2] << 16) | (rest[len + 3] << 24));
            if (Crc(all, 0, all.Length) != crc) return null;
            if (hdr[2] != wantCmd || hdr[3] != wantSeq) { have = 0; continue; }  // stale answer to an earlier try
            var payload = new byte[len];
            Buffer.BlockCopy(rest, 0, payload, 0, len);
            return payload;
        }
        return null;
    }

    static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s); }
    static byte[] Cat(params byte[][] parts) {
        var ms = new MemoryStream();
        foreach (var p in parts) ms.Write(p, 0, p.Length);
        return ms.ToArray();
    }
    static byte[] U16(int v) { return new byte[] { (byte)v, (byte)(v >> 8) }; }
    static byte[] U64(long v) { var b = new byte[8]; for (int i = 0; i < 8; i++) b[i] = (byte)(v >> (8 * i)); return b; }
    static long R64(byte[] b, int o) { long v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | b[o + i]; return v; }

    public string Hello() {
        var r = Call(0x01, new byte[0], 500);
        return "protocol v" + r[0] + ", max data " + (r[1] | (r[2] << 8)) + ", \"" + Encoding.UTF8.GetString(r, 3, r.Length - 3) + "\"";
    }
    public long[] Info() { var r = Call(0x02, new byte[0], 20000); return new long[] { R64(r, 0), R64(r, 8) }; }

    public List<string> List(string path) {
        var lines = new List<string>();
        int start = 0;
        while (start != 0xFFFF) {
            var r = Call(0x10, Cat(U16(start), Utf8(path)), 5000);
            int next = r[0] | (r[1] << 8), o = 2;
            while (o < r.Length) {
                bool dir = (r[o] & 1) != 0; long size = R64(r, o + 1); int nl = r[o + 9];
                string name = Encoding.UTF8.GetString(r, o + 10, nl);
                lines.Add(dir ? String.Format("{0,12}  {1}/", "<dir>", name) : String.Format("{0,12:N0}  {1}", size, name));
                o += 10 + nl;
            }
            start = next;
        }
        return lines;
    }
    public string Stat(string path) {
        var r = Call(0x11, Utf8(path), 2000);
        return ((r[0] & 1) != 0 ? "directory" : "file") + ", " + R64(r, 1).ToString("N0") + " bytes";
    }
    public void Get(string remote, string local) {
        var o = Call(0x20, Cat(new byte[] { 0 }, Utf8(remote)), 2000);
        long size = R64(o, 1);
        using (var f = File.Create(local)) {
            long off = 0;
            while (off < size) {
                int n = (int)Math.Min(MaxData, size - off);
                var d = Call(0x21, Cat(new byte[] { 1 }, U64(off), U16(n)), 2000);
                if (d.Length == 0) throw new LisaNetException("unexpected end of file at " + off);
                f.Write(d, 0, d.Length);
                off += d.Length;
            }
        }
        Call(0x23, new byte[] { 1 }, 2000);
    }
    public void Put(string local, string remote) {
        byte[] all = File.ReadAllBytes(local);
        Call(0x20, Cat(new byte[] { 3 }, U64(all.Length), Utf8(remote)), 5000);   // mode 3: reserve contiguous space (ESFloppy needs it)
        for (long off = 0; off < all.Length; off += MaxData) {
            int n = (int)Math.Min(MaxData, all.Length - off);
            var chunk = new byte[n];
            Buffer.BlockCopy(all, (int)off, chunk, 0, n);
            Call(0x22, Cat(new byte[] { 1 }, U64(off), chunk), 3000);
        }
        Call(0x23, new byte[] { 1 }, 5000);
    }
    public void Delete(string p) { Call(0x30, Utf8(p), 3000); }
    public void Rename(string a, string b) { Call(0x31, Cat(Utf8(a), new byte[] { 0 }, Utf8(b)), 3000); }
    public void Mkdir(string p) { Call(0x32, Utf8(p), 3000); }
    public void MountNextSet(string p) { Call(0x40, Utf8(p), 3000); }
    public string MountNextGet() { return Encoding.UTF8.GetString(Call(0x41, new byte[0], 2000)); }
}
'@

$c = New-Object LisaNet $Port
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    switch ($Command) {
        'hello' { $c.Hello() }
        'info'  { $r = $c.Info(); '{0:N0} bytes on card, {1:N0} free' -f $r[0], $r[1] }
        'ls'    { $c.List($(if ($Arg1) { $Arg1 } else { '/' })) }
        'stat'  { $c.Stat($Arg1) }
        'get'   { $Arg2 = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Arg2)
                  $c.Get($Arg1, $Arg2); $n = (Get-Item $Arg2).Length; '{0:N0} bytes in {1:N1} s ({2:N1} KB/s)' -f $n, $sw.Elapsed.TotalSeconds, ($n / 1KB / $sw.Elapsed.TotalSeconds) }
        'put'   { $n = (Get-Item $Arg1).Length; $c.Put((Resolve-Path $Arg1).Path, $Arg2); '{0:N0} bytes in {1:N1} s ({2:N1} KB/s)' -f $n, $sw.Elapsed.TotalSeconds, ($n / 1KB / $sw.Elapsed.TotalSeconds) }
        { $_ -in 'delete','rm' } { $c.Delete($Arg1); 'deleted' }
        'mv'    { $c.Rename($Arg1, $Arg2); 'renamed' }
        'mkdir' { $c.Mkdir($Arg1); 'created' }
        'mountnext' {
            if (-not $Arg1) { $m = $c.MountNextGet(); if ($m) { $m } else { '(none)' } }
            elseif ($Arg1 -eq 'clear') { $c.MountNextSet(''); 'cleared' }
            else { $c.MountNextSet($Arg1); 'set' }
        }
        default { throw "unknown command '$Command'" }
    }
    if ($c.Retries) { "($($c.Retries) retries)" }
} finally { $c.Dispose() }
