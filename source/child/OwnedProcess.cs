#nullable enable
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DeskPilot.Child
{
    /// <summary>Starts a Windows process suspended inside a bounded kill-on-close job.</summary>
    public sealed class OwnedProcess : IDisposable
    {
        private readonly AnonymousPipeServerStream _input = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
        private readonly AnonymousPipeServerStream _output = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        private readonly AnonymousPipeServerStream _error = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        private readonly object _control = new object();
        private IntPtr _job;
        private IntPtr _thread;
        private Process? _process;
        private bool _disposed;
        private readonly bool _ownsJob;
        private readonly double _cpuCount;
        private readonly OwnedProcess _budgetOwner;
        private long _cleanupUntil;

        /// <summary>Creates only a suspended process; the host persists ownership before Resume.</summary>
        public OwnedProcess(string executable, string[] arguments, string directory,
            IDictionary<string, string> environment, long memoryBytes, double cpuCount, int processLimit)
            : this(executable, arguments, directory, environment, memoryBytes, cpuCount, processLimit, null) { }

        private OwnedProcess(string executable, string[] arguments, string directory,
            IDictionary<string, string> environment, long memoryBytes, double cpuCount, int processLimit, OwnedProcess? owner)
        {
            if (!OperatingSystem.IsWindows()) { throw new PlatformNotSupportedException(); }
            if (memoryBytes < 64 * 1024 * 1024 || memoryBytes > 1024L * 1024 * 1024 ||
                cpuCount <= 0 || cpuCount > 2 || processLimit < 1 || processLimit > 16)
            { throw new ArgumentOutOfRangeException(nameof(memoryBytes)); }
            MemoryLimit = memoryBytes;
            ActiveProcessLimit = processLimit;
            _ownsJob = owner == null;
            _cpuCount = cpuCount;
            _budgetOwner = owner ?? this;
            IntPtr attributes = IntPtr.Zero;
            IntPtr handles = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            ProcessInformation created = default;
            try
            {
                if (owner == null)
                {
                    _job = CreateJobObject(IntPtr.Zero, null);
                    Check(_job != IntPtr.Zero);
                    var limits = new ExtendedLimits
                    {
                        Basic = new BasicLimits { LimitFlags = 0x2000 | 0x200 | 0x8 | 0x400, ActiveProcessLimit = (uint)processLimit },
                        JobMemoryLimit = (UIntPtr)(ulong)memoryBytes
                    };
                    SetJob(9, limits);
                    uint rate = (uint)Math.Max(1, Math.Floor(cpuCount / Environment.ProcessorCount * 10000));
                    SetJob(15, new CpuLimits { ControlFlags = 0x1 | 0x4, CpuRate = Math.Min(10000, rate) });
                }
                else { _job = owner._job; }

                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                attributes = Marshal.AllocHGlobal(size);
                Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref size));
                handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handles, 0, _input.ClientSafePipeHandle.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, IntPtr.Size, _output.ClientSafePipeHandle.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, IntPtr.Size * 2, _error.ClientSafePipeHandle.DangerousGetHandle());
                Check(UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x20002, handles,
                    (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero));

                var entries = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (KeyValuePair<string, string> entry in environment)
                {
                    if (entry.Key.IndexOfAny(new[] { '=', '\0' }) >= 0 || entry.Value.Contains('\0'))
                    { throw new ArgumentException("Invalid explicit environment."); }
                    entries.Add(entry.Key, entry.Value);
                }
                var block = new StringBuilder();
                foreach (KeyValuePair<string, string> entry in entries) { block.Append(entry.Key).Append('=').Append(entry.Value).Append('\0'); }
                block.Append('\0');
                environmentBlock = Marshal.StringToHGlobalUni(block.ToString());
                var startup = new StartupInfoEx
                {
                    Startup = new StartupInfo
                    {
                        Size = (uint)Marshal.SizeOf<StartupInfoEx>(), Flags = 0x100,
                        Input = _input.ClientSafePipeHandle.DangerousGetHandle(),
                        Output = _output.ClientSafePipeHandle.DangerousGetHandle(),
                        Error = _error.ClientSafePipeHandle.DangerousGetHandle()
                    },
                    Attributes = attributes
                };
                var command = new StringBuilder(Quote(Path.GetFullPath(executable)));
                foreach (string argument in arguments) { command.Append(' ').Append(Quote(argument)); }
                Check(CreateProcess(Path.GetFullPath(executable), command, IntPtr.Zero, IntPtr.Zero,
                    true, 0x4 | 0x400 | 0x80000 | 0x8000000, environmentBlock,
                    Path.GetFullPath(directory), ref startup, out created));
                _thread = created.Thread;
                _process = Process.GetProcessById((int)created.ProcessId);
                _ = _process.Handle;
                _ = _process.StartTime;
                Check(AssignProcessToJobObject(_job, created.Process));
                Check(IsProcessInJob(created.Process, _job, out bool assigned) && assigned);
                _input.DisposeLocalCopyOfClientHandle();
                _output.DisposeLocalCopyOfClientHandle();
                _error.DisposeLocalCopyOfClientHandle();
            }
            catch
            {
                if (created.Process != IntPtr.Zero) { TerminateProcess(created.Process, 1); }
                Dispose();
                throw;
            }
            finally
            {
                if (created.Process != IntPtr.Zero) { CloseHandle(created.Process); }
                if (attributes != IntPtr.Zero) { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
                if (handles != IntPtr.Zero) { Marshal.FreeHGlobal(handles); }
                if (environmentBlock != IntPtr.Zero) { Marshal.FreeHGlobal(environmentBlock); }
            }
        }

        /// <summary>Owned input stream; never exposed to child Tools.</summary>
        public Stream Input => _input;
        /// <summary>Owned output stream.</summary>
        public Stream Output => _output;
        /// <summary>Owned bounded-error reader source.</summary>
        public Stream Error => _error;
        /// <summary>Process identity recorded before resume.</summary>
        public int Id => _process!.Id;
        /// <summary>Start identity used with the process id during recovery.</summary>
        public long StartTimeUtcTicks => _process!.StartTime.ToUniversalTime().Ticks;
        /// <summary>Requested aggregate job memory bound.</summary>
        public long MemoryLimit { get; }
        /// <summary>Requested aggregate process bound.</summary>
        public int ActiveProcessLimit { get; }
        /// <summary>True only after the owned suspended thread was resumed.</summary>
        public bool Resumed { get; private set; }
        /// <summary>Whether the direct process exited.</summary>
        public bool HasExited => _process == null || _process.HasExited;
        /// <summary>Waits for direct-process exit with a caller-specified bound.</summary>
        public bool WaitForExit(int milliseconds) => _process == null || _process.WaitForExit(milliseconds);
        /// <summary>Waits asynchronously for direct-process exit.</summary>
        public System.Threading.Tasks.Task WaitForExitAsync(CancellationToken cancellationToken) => _process!.WaitForExitAsync(cancellationToken);
        /// <summary>Exit code after the process has exited.</summary>
        public int ExitCode => _process!.ExitCode;
        /// <summary>Verifies assignment against the actual Windows job.</summary>
        public bool IsInOwnedJob => _process != null && IsProcessInJob(_process.Handle, _job, out bool result) && result;

        /// <summary>Creates another suspended process within the same aggregate host budget.</summary>
        public OwnedProcess CreateSibling(string executable, string[] arguments, string directory, IDictionary<string, string> environment)
        {
            lock (_control)
            {
                if (_disposed || !_ownsJob) { throw new InvalidOperationException("Host process group is unavailable."); }
                return new OwnedProcess(executable, arguments, directory, environment, MemoryLimit, _cpuCount, ActiveProcessLimit, this);
            }
        }

        /// <summary>Resumes only after the host has recorded the immutable process identity.</summary>
        public void Resume()
        {
            lock (_control)
            {
                if (_disposed || Resumed || _thread == IntPtr.Zero) { throw new InvalidOperationException("Process cannot be resumed."); }
                Check(ResumeThread(_thread) != uint.MaxValue);
                CloseHandle(_thread);
                _thread = IntPtr.Zero;
                Resumed = true;
            }
        }

        /// <summary>Terminates the complete job and verifies that its active process count reaches zero.</summary>
        public void Stop()
        {
            lock (_control)
            {
                long cleanupUntil = Volatile.Read(ref _budgetOwner._cleanupUntil);
                int timeout = cleanupUntil == 0 ? 5000 : Math.Clamp((int)((cleanupUntil - Stopwatch.GetTimestamp()) * 1000.0 / Stopwatch.Frequency), 1, 5000);
                if (_job == IntPtr.Zero) { return; }
                if (!_ownsJob)
                {
                    if (_process != null && !_process.HasExited)
                    {
                        _process.Kill(true);
                        if (!_process.WaitForExit(timeout)) { throw new IOException("Owned sibling cleanup could not be confirmed."); }
                    }
                    return;
                }
                Check(TerminateJobObject(_job, 1));
                var clock = Stopwatch.StartNew();
                while (clock.ElapsedMilliseconds < timeout)
                {
                    Check(QueryInformationJobObject(_job, 1, out BasicAccounting accounting,
                        (uint)Marshal.SizeOf<BasicAccounting>(), IntPtr.Zero));
                    if (accounting.ActiveProcesses == 0) { return; }
                    Thread.Sleep(Math.Min(10, timeout));
                }
                throw new IOException("Owned process cleanup could not be confirmed.");
            }
        }

        /// <summary>Starts one non-extendable cleanup deadline shared with all sibling processes.</summary>
        public void BeginCleanup(int milliseconds)
        {
            if (milliseconds < 1 || milliseconds > 10000) { throw new ArgumentOutOfRangeException(nameof(milliseconds)); }
            long deadline = Stopwatch.GetTimestamp() + (long)(milliseconds / 1000.0 * Stopwatch.Frequency);
            Interlocked.CompareExchange(ref _budgetOwner._cleanupUntil, deadline, 0);
        }

        /// <summary>Closes the kill-on-close job even if normal cleanup fails.</summary>
        public void Dispose()
        {
            lock (_control)
            {
                if (_disposed) { return; }
                _disposed = true;
                try { Stop(); }
                finally
                {
                    if (_thread != IntPtr.Zero) { CloseHandle(_thread); _thread = IntPtr.Zero; }
                    if (_job != IntPtr.Zero) { if (_ownsJob) { CloseHandle(_job); } _job = IntPtr.Zero; }
                    _input.Dispose(); _output.Dispose(); _error.Dispose(); _process?.Dispose();
                }
            }
        }

        private void SetJob<T>(int informationClass, T information) where T : struct
        {
            IntPtr buffer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
            try { Marshal.StructureToPtr(information, buffer, false); Check(SetInformationJobObject(_job, informationClass, buffer, (uint)Marshal.SizeOf<T>())); }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        private static void Check(bool success) { if (!success) { throw new Win32Exception(Marshal.GetLastWin32Error()); } }
        private static string Quote(string value)
        {
            if (value.Contains('\0')) { throw new ArgumentException("NUL in process argument."); }
            var quoted = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') { quoted.Append('\\', slashes * 2 + 1).Append('"'); }
                else { quoted.Append('\\', slashes).Append(character); }
                slashes = 0;
            }
            return quoted.Append('\\', slashes * 2).Append('"').ToString();
        }

        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
        { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters
        { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
        { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [StructLayout(LayoutKind.Sequential)] private struct CpuLimits { public uint ControlFlags, CpuRate; }
        [StructLayout(LayoutKind.Sequential)] private struct BasicAccounting
        { public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime; public uint PageFaults, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo
        { public uint Size; public IntPtr Reserved, Desktop, Title; public uint X, Y, Width, Height, XChars, YChars, FillAttribute, Flags; public ushort ShowWindow, ReservedBytes; public IntPtr ReservedData, Input, Output, Error; }
        [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, IntPtr information, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int kind, out BasicAccounting information, uint length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    }
}
