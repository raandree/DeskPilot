#nullable enable
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace DeskPilot.Child
{
    /// <summary>Protected PID-1 lease and filesystem initialization.</summary>
    public static class ToolSupervisor
    {
        /// <summary>Runs independently of all unprivileged Tool processes.</summary>
        public static void Run(int leaseSeconds, string access)
        {
            if (!OperatingSystem.IsLinux() || getuid() != 0 || getpid() != 1 ||
                leaseSeconds < 1 || leaseSeconds > 30 ||
                (access != "read-only" && access != "read-write"))
            {
                throw new InvalidOperationException("The protected Tool supervisor profile is invalid.");
            }
            long renewed = Stopwatch.GetTimestamp();
            using var timer = new Timer(_ =>
            {
                if (Stopwatch.GetElapsedTime(Interlocked.Read(ref renewed)).TotalSeconds >= leaseSeconds)
                {
                    Environment.Exit(124);
                }
            }, null, 100, 100);
            foreach (string directory in new[] { "/work/project", "/work/control", "/work/tmp", "/work/home" })
            {
                Directory.CreateDirectory(directory);
                File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            foreach (string directory in new[] { "/work/tmp", "/work/home" })
            {
                if (chown(directory, 10001, 10001) != 0) { throw new IOException("Tool storage ownership failed."); }
            }
            Stream input = Console.OpenStandardInput();
            var key = new byte[32];
            input.ReadExactly(key);
            using var channel = new AuthenticatedChannel(input, Console.OpenStandardOutput(), key, false, 16384);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
            channel.Send("{\"type\":\"ready\"}");
            bool sealedInput = false;
            while (true)
            {
                string message;
                try { message = channel.Receive(); }
                catch (EndOfStreamException) { Environment.Exit(125); return; }
                using JsonDocument request = JsonDocument.Parse(message);
                string type = request.RootElement.GetProperty("type").GetString()!;
                if (type == "renew") { Interlocked.Exchange(ref renewed, Stopwatch.GetTimestamp()); }
                else if (type == "stop") { Environment.Exit(125); }
                else if (type == "freeze" && sealedInput)
                {
                    LinuxToolFile.StopToolProcesses();
                    channel.Send("{\"type\":\"frozen\"}");
                }
                else if (type == "seal" && !sealedInput)
                {
                    foreach (string entry in Directory.EnumerateFileSystemEntries("/work/project", "*", SearchOption.AllDirectories))
                    {
                        bool directory = Directory.Exists(entry);
                        File.SetUnixFileMode(entry, access == "read-write"
                            ? (directory ? (UnixFileMode)448 : (UnixFileMode)384)
                            : (directory ? (UnixFileMode)365 : (UnixFileMode)292));
                        if (access == "read-write" && chown(entry, 10001, 10001) != 0)
                        {
                            throw new IOException("Tool Project ownership failed.");
                        }
                    }
                    File.SetUnixFileMode("/work/project", access == "read-write" ? (UnixFileMode)448 : (UnixFileMode)365);
                    if (access == "read-write" && chown("/work/project", 10001, 10001) != 0)
                    {
                        throw new IOException("Tool Project ownership failed.");
                    }
                    sealedInput = true;
                    channel.Send("{\"type\":\"sealed\"}");
                }
                else { throw new InvalidDataException("An unexpected Tool control record was refused."); }
            }
        }

        [DllImport("libc", SetLastError = true)]
        private static extern int chown(string path, uint owner, uint group);
        [DllImport("libc")]
        private static extern uint getuid();
        [DllImport("libc")]
        private static extern int getpid();
    }

    /// <summary>Kernel-resolved File access inside the private Tool filesystem.</summary>
    public static class LinuxToolFile
    {
        /// <summary>Performs one bounded File operation from a fixed entry point.</summary>
        public static string Invoke(string operation, string path, int offset, int count, long inputLength)
        {
            if (!OperatingSystem.IsLinux() || RuntimeInformation.ProcessArchitecture != Architecture.X64)
            {
                throw new PlatformNotSupportedException("The Tool File boundary requires Linux x64 openat2.");
            }
            string relative = ProjectBaseline.ValidateRelativePath(path);
            if (offset < 0 || count < 1 || count > 8192 || inputLength < 0 || inputLength > 67108864)
            {
                throw new InvalidDataException("The File request exceeds its limit.");
            }
            if (operation == "seed")
            {
                if (getuid() != 0) { throw new UnauthorizedAccessException("Seed is a Host Server operation."); }
                Directory.CreateDirectory(Path.GetDirectoryName("/work/project/" + relative)!);
            }
            int root = open("/work/project", 0x90000, 0);
            if (root < 0) { throw new IOException("The Tool Project is not available."); }
            using var rootHandle = new SafeFileHandle(new IntPtr(root), true);
            bool write = operation == "write" || operation == "seed";
            if (!write && operation != "read") { throw new InvalidDataException("Unknown File operation."); }
            var how = new OpenHow { Flags = (ulong)(0x80000 | (write ? 0x41 : 0)), Mode = write ? 384UL : 0UL, Resolve = 15 };
            int descriptor = (int)syscall(437, root, relative, ref how, (ulong)Marshal.SizeOf<OpenHow>());
            if (descriptor < 0) { return Failure(Marshal.GetLastWin32Error()); }
            using var handle = new SafeFileHandle(new IntPtr(descriptor), true);
            if (fstat(descriptor, out FileStat metadata) != 0 || (metadata.Mode & 0xF000) != 0x8000 || metadata.Links != 1)
            {
                return "{\"ok\":false,\"code\":\"unsafe_file\"}";
            }
            try
            {
                using var file = new FileStream(handle, write ? FileAccess.Write : FileAccess.Read, 4096, false);
                if (write)
                {
                    file.SetLength(0);
                    Stream input = Console.OpenStandardInput();
                    var buffer = new byte[16384];
                    long remaining = inputLength;
                    while (remaining > 0)
                    {
                        int received = input.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                        if (received == 0) { throw new EndOfStreamException("Incomplete File input."); }
                        file.Write(buffer, 0, received);
                        remaining -= received;
                    }
                    file.Flush(true);
                    return JsonSerializer.Serialize(new { ok = true, bytes = inputLength });
                }
                file.Position = Math.Min(offset, file.Length);
                var bytes = new byte[(int)Math.Min(count, file.Length - file.Position)];
                file.ReadExactly(bytes);
                return JsonSerializer.Serialize(new
                {
                    ok = true, path = relative, offset, bytes = bytes.Length, totalBytes = file.Length,
                    hasMore = file.Position < file.Length, text = Encoding.UTF8.GetString(bytes),
                    base64 = Convert.ToBase64String(bytes)
                });
            }
            catch (IOException error)
            {
                return Failure(error.HResult & 0xFFFF);
            }
        }

        /// <summary>Reads kernel filesystem quota counters.</summary>
        public static string Inspect()
        {
            if (statvfs("/work", out FileSystemStat state) != 0) { throw new IOException("Tool quota inspection failed."); }
            return JsonSerializer.Serialize(new
            {
                bytes = state.Blocks * state.FragmentSize,
                freeBytes = state.AvailableBlocks * state.FragmentSize,
                inodes = state.Files, freeInodes = state.AvailableFiles
            });
        }

        /// <summary>Terminates the Tool identity before export without stopping the lease.</summary>
        public static void StopToolProcesses()
        {
            var clock = Stopwatch.StartNew();
            while (clock.Elapsed.TotalSeconds < 5)
            {
                bool found = false;
                foreach (string directory in Directory.EnumerateDirectories("/proc"))
                {
                    if (!int.TryParse(Path.GetFileName(directory), out int processId)) { continue; }
                    int descriptor = open(directory, 0x90000, 0);
                    if (descriptor < 0) { continue; }
                    using var handle = new SafeFileHandle(new IntPtr(descriptor), true);
                    if (fstat(descriptor, out FileStat state) != 0 || state.User != 10001) { continue; }
                    found = true;
                    if (kill(processId, 9) != 0 && Marshal.GetLastWin32Error() != 3)
                    {
                        throw new IOException("Tool descendants could not be stopped for export.");
                    }
                }
                while (waitpid(-1, out _, 1) > 0) { }
                if (!found) { return; }
                Thread.Yield();
            }
            throw new IOException("Tool descendants remain; export was refused.");
        }

        /// <summary>Checks actual file identities and types after Tool execution is frozen.</summary>
        public static string ValidateExport(int entryLimit)
        {
            var pending = new System.Collections.Generic.Queue<string>();
            pending.Enqueue(string.Empty);
            int visited = 0;
            int root = open("/work/project", 0x90000, 0);
            if (root < 0) { throw new IOException("The export Project is missing."); }
            using var rootHandle = new SafeFileHandle(new IntPtr(root), true);
            while (pending.Count > 0)
            {
                string parent = pending.Dequeue();
                foreach (string entry in Directory.EnumerateFileSystemEntries("/work/project/" + parent))
                {
                    if (++visited > entryLimit) { throw new InvalidDataException("The export entry limit was exceeded."); }
                    string relative = Path.GetRelativePath("/work/project", entry);
                    ProjectBaseline.ValidateRelativePath(relative);
                    var how = new OpenHow { Flags = 0x280000, Resolve = 15 };
                    int descriptor = (int)syscall(437, root, relative, ref how, (ulong)Marshal.SizeOf<OpenHow>());
                    if (descriptor < 0) { throw new InvalidDataException("Unsafe export link or mount was refused."); }
                    using var handle = new SafeFileHandle(new IntPtr(descriptor), true);
                    if (fstat(descriptor, out FileStat state) != 0) { throw new IOException("Export identity inspection failed."); }
                    if ((state.Mode & 0xF000) == 0x4000) { pending.Enqueue(relative); }
                    else if ((state.Mode & 0xF000) != 0x8000 || state.Links != 1)
                    {
                        throw new InvalidDataException("Unsafe export file type or hard link was refused.");
                    }
                }
            }
            return "{\"ok\":true}";
        }

        private static string Failure(int code) => JsonSerializer.Serialize(new
        {
            ok = false,
            code = code == 28 || code == 122 ? "quota_exceeded" : code == 13 || code == 30 ? "access_denied" : "file_refused"
        });

        [StructLayout(LayoutKind.Sequential)]
        private struct OpenHow { public ulong Flags; public ulong Mode; public ulong Resolve; }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileStat
        {
            public ulong Device; public ulong Inode; public ulong Links;
            public uint Mode; public uint User; public uint Group; public uint Padding;
            public ulong SpecialDevice; public long Size; public long BlockSize; public long Blocks;
            public long AccessSeconds; public long AccessNanos; public long WriteSeconds; public long WriteNanos;
            public long ChangeSeconds; public long ChangeNanos; public long Unused1; public long Unused2; public long Unused3;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileSystemStat
        {
            public ulong BlockSize; public ulong FragmentSize; public ulong Blocks; public ulong FreeBlocks;
            public ulong AvailableBlocks; public ulong Files; public ulong FreeFiles; public ulong AvailableFiles;
            public ulong Id; public ulong Flags; public ulong NameMaximum;
            public int Spare1; public int Spare2; public int Spare3; public int Spare4; public int Spare5; public int Spare6;
        }
        [DllImport("libc", SetLastError = true)]
        private static extern int open(string path, int flags, int mode);
        [DllImport("libc", SetLastError = true)]
        private static extern long syscall(long number, int root, string path, ref OpenHow how, ulong size);
        [DllImport("libc", SetLastError = true)]
        private static extern int fstat(int descriptor, out FileStat state);
        [DllImport("libc", SetLastError = true)]
        private static extern int statvfs(string path, out FileSystemStat state);
        [DllImport("libc")]
        private static extern uint getuid();
        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int processId, int signal);
        [DllImport("libc", SetLastError = true)]
        private static extern int waitpid(int processId, out int status, int options);
    }
}
