#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Formats.Tar;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>Owns one quota-backed Tool container and its independent control path.</summary>
    public sealed class ToolContainer : IDisposable
    {
        private readonly string _docker;
        private readonly string _directory;
        private readonly string _name = "deskpilot-child-" + Guid.NewGuid().ToString("N");
        private readonly string _runId = Guid.NewGuid().ToString("N");
        private readonly JsonDocument _policy;
        private readonly CancellationTokenSource _cancel = new CancellationTokenSource();
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly Stopwatch _cleanupClock = new Stopwatch();
        private readonly object _stopLock = new object();
        private readonly ManualResetEventSlim _toolOutput = new ManualResetEventSlim(false);
        private readonly FileStream? _owner;
        private readonly ProjectBaseline _controlRoot;
        private readonly ProjectBaseline? _runRoot;
        private readonly DateTime _createdUtc = DateTime.UtcNow;
        private readonly SortedDictionary<string, string> _baseline = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly OwnedProcess? _hostProcess;
        private readonly bool _ownsHostProcess;
        private EngineContainer? _engine;
        private readonly CancellationTokenRegistration _externalCancellation;
        private ControlProcess? _attach;
        private AuthenticatedChannel? _channel;
        private Timer? _renewal;
        private Timer? _deadline;
        private bool _sealed;
        private bool _frozen;
        private bool _stopped;
        private long _seedBytes;
        private int _seedFiles;
        private string _containerId = string.Empty;

        /// <summary>Creates ownership before launch and validates the effective container profile.</summary>
        public ToolContainer(string docker, string image, string directory, string policyJson)
            : this(docker, image, directory, policyJson, null, null) { }

        /// <summary>Creates a Tool container whose control processes share the trusted host budget.</summary>
        public ToolContainer(string docker, string image, string directory, string policyJson, OwnedProcess? hostProcess)
            : this(docker, image, directory, policyJson, hostProcess, null) { }

        /// <summary>Creates and records a suspended provider within the complete-run resource budget.</summary>
        public ToolContainer(string docker, string image, string directory, string policyJson, ProcessStartInfo providerStart)
            : this(docker, image, directory, policyJson, null, providerStart) { }

        /// <summary>Creates complete-run ownership under an external admission deadline.</summary>
        public ToolContainer(string docker, string image, string directory, string policyJson,
            ProcessStartInfo providerStart, string runId, CancellationToken cancellationToken)
            : this(docker, image, directory, policyJson, null, providerStart, runId, cancellationToken) { }

        private ToolContainer(string docker, string image, string directory, string policyJson,
            OwnedProcess? hostProcess, ProcessStartInfo? providerStart, string? runId = null, CancellationToken cancellationToken = default)
        {
            if (runId != null)
            {
                if (!System.Text.RegularExpressions.Regex.IsMatch(runId, "^[a-f0-9]{32}$")) { throw new ArgumentException("Invalid child identity."); }
                _runId = runId;
            }
            cancellationToken.ThrowIfCancellationRequested();
            _externalCancellation = cancellationToken.Register(() => _cancel.Cancel());
            _docker = docker;
            _hostProcess = hostProcess;
            _policy = JsonDocument.Parse(policyJson);
            string installation = Path.Combine(Path.GetFullPath(directory), "child-runs");
            _controlRoot = ProjectBaseline.CreateControlDirectory(installation);
            try
            {
                _owner = new FileStream(Path.Combine(installation, "active.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                long retained = VerifyPreviousCleanup(installation);
                if (retained + _policy.RootElement.GetProperty("storageBytes").GetInt64() >
                    _policy.RootElement.GetProperty("retentionBytes").GetInt64())
                {
                    throw new InvalidOperationException("The installation child retention limit cannot reserve another run.");
                }
            }
            catch { _owner?.Dispose(); _controlRoot.Dispose(); throw; }
            _directory = Path.Combine(installation, _runId);
            ClaimPath = Path.Combine(_directory, "claim.json");
            try
            {
                _runRoot = ProjectBaseline.CreateControlDirectory(_directory);
                File.WriteAllText(Path.Combine(_directory, "config.json"), "{\"auths\":{},\"proxies\":{}}", new UTF8Encoding(false));
                SaveClaim("starting");
                JsonElement policy = _policy.RootElement;
                if (providerStart != null)
                {
                    using (var profileBarrier = new FileStream(Path.Combine(_directory, "AppData"), FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        profileBarrier.Flush(true);
                    }
                    var environment = new Dictionary<string, string>
                    {
                        ["SystemRoot"] = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows",
                        ["TEMP"] = _directory, ["TMP"] = _directory, ["USERPROFILE"] = _directory,
                        ["APPDATA"] = _directory, ["LOCALAPPDATA"] = _directory,
                        ["PSModulePath"] = Path.Combine(Path.GetDirectoryName(providerStart.FileName)!, "Modules"),
                        ["HOME"] = _directory, ["DOTNET_EnableDiagnostics"] = "0",
                        ["DOTNET_PROCESSOR_COUNT"] = "1", ["POWERSHELL_TELEMETRY_OPTOUT"] = "1",
                        ["PSModuleAnalysisCachePath"] = "NUL"
                    };
                    _ownsHostProcess = true;
                    _hostProcess = new OwnedProcess(providerStart.FileName, new List<string>(providerStart.ArgumentList).ToArray(),
                        _directory, environment, policy.GetProperty("memoryBytes").GetInt64() / 4,
                        policy.GetProperty("cpuCount").GetDouble() / 4, 8);
                    byte[] identity = JsonSerializer.SerializeToUtf8Bytes(new
                    {
                        schemaVersion = 1, runId = _runId, processId = _hostProcess.Id,
                        startTimeUtcTicks = _hostProcess.StartTimeUtcTicks
                    });
                    using var record = new FileStream(Path.Combine(_directory, "provider.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    record.Write(identity);
                    record.Flush(true);
                }
                string access = policy.GetProperty("projectAccess").GetString()!;
                var arguments = new List<string>
                {
                    "create", "--pull", "never", "--name", _name,
                    "--label", "io.deskpilot.child=1", "--label", "io.deskpilot.child.run=" + _runId,
                    "--network", "none", "--read-only", "--cap-drop", "ALL",
                    "--security-opt", "no-new-privileges", "--ipc", "none", "--log-driver", "none",
                    "--user", "0:0", "--interactive", "--workdir", "/",
                    "--memory", (policy.GetProperty("memoryBytes").GetInt64() / 2).ToString(CultureInfo.InvariantCulture),
                    "--memory-swap", (policy.GetProperty("memoryBytes").GetInt64() / 2).ToString(CultureInfo.InvariantCulture),
                    "--cpus", (policy.GetProperty("cpuCount").GetDouble() / 2).ToString(CultureInfo.InvariantCulture),
                    "--pids-limit", "40", "--ulimit", "core=0:0",
                    "--tmpfs", "/work:rw,nosuid,nodev,noexec,mode=0755,size=" + policy.GetProperty("toolStorageBytes").GetInt64() +
                        ",nr_inodes=" + policy.GetProperty("inodeLimit").GetInt64(),
                    "--env", "HOME=/work/home", "--env", "TMPDIR=/work/tmp", "--env", "DOTNET_PROCESSOR_COUNT=1",
                    "--env", "DOTNET_EnableDiagnostics=0", "--env", "POWERSHELL_TELEMETRY_OPTOUT=1",
                    "--env", "PSModuleAnalysisCachePath=/dev/null"
                };
                foreach (string capability in new[] { "CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID", "SETPCAP", "KILL" })
                {
                    arguments.AddRange(new[] { "--cap-add", capability });
                }
                arguments.AddRange(new[] { "--entrypoint", "/opt/microsoft/powershell/7/pwsh", image,
                    "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/opt/deskpilot-child/Start-DpChildSupervisor.ps1",
                    "-LeaseSeconds", policy.GetProperty("leaseSeconds").GetInt32().ToString(CultureInfo.InvariantCulture),
                    "-ProjectAccess", access });
                _containerId = Control(arguments, 30000).Trim();
                if (!System.Text.RegularExpressions.Regex.IsMatch(_containerId, "^[a-f0-9]{64}$"))
                {
                    throw new IOException("The child container identity could not be verified.");
                }
                SaveClaim("created");
                _attach = Start(new[] { "start", "--attach", "--interactive", _containerId });
                byte[] key = RandomNumberGenerator.GetBytes(32);
                _channel = new AuthenticatedChannel(_attach.Output, _attach.Input, key, true, 16384);
                _attach.Input.Write(key);
                _attach.Input.Flush();
                CryptographicOperations.ZeroMemory(key);
                _ = DrainAsync(_attach.Error, new OutputBudget(16384), _cancel, null);
                ReceiveControl("ready");
                int renewalMs = Math.Max(100, policy.GetProperty("leaseSeconds").GetInt32() * 1000 / 3);
                _renewal = new Timer(_ =>
                {
                    try { _channel.Send("{\"type\":\"renew\"}"); }
                    catch { _cancel.Cancel(); }
                }, null, 0, renewalMs);
                int remaining = Math.Max(1, policy.GetProperty("durationSeconds").GetInt32() * 1000 - (int)_clock.ElapsedMilliseconds);
                _deadline = new Timer(_ => Stop(), null, remaining, Timeout.Infinite);
                SaveClaim("seeding");
            }
            catch
            {
                Stop();
                if (_ownsHostProcess) { _hostProcess?.Dispose(); }
                _owner?.Dispose();
                _runRoot?.Dispose();
                _controlRoot.Dispose();
                throw;
            }
        }

        /// <summary>Durable ownership claim written before creation.</summary>
        public string ClaimPath { get; }
        /// <summary>Immutable Docker identity, not a child-provided identity.</summary>
        public string ContainerId => _containerId;
        /// <summary>Host-owned run identity shared by both containers and the transport.</summary>
        public string RunId => _runId;
        /// <summary>Private bounded control storage, never sent to the child.</summary>
        public string DirectoryPath => _directory;
        /// <summary>The trusted aggregate job; provider code remains suspended until Host Server resume.</summary>
        public OwnedProcess? HostProcess => _hostProcess;
        internal long HostStorageLimit => _policy.RootElement.GetProperty("storageBytes").GetInt64() - _policy.RootElement.GetProperty("toolStorageBytes").GetInt64();
        internal JsonElement Policy => _policy.RootElement;
        internal bool IsStopped => _stopped;

        internal void AttachEngine(EngineContainer engine)
        {
            lock (_stopLock)
            {
                if (_stopped || _engine != null) { throw new InvalidOperationException("Child Engine ownership is unavailable."); }
                _engine = engine;
            }
        }
        /// <summary>True only after verified removal.</summary>
        public bool CleanupSucceeded { get; private set; }

        /// <summary>Seeds one selected file before any Tool operation is admitted.</summary>
        public void Seed(string path, byte[] bytes)
        {
            if (_sealed || _stopped) { throw new InvalidOperationException("Child input is already sealed or stopped."); }
            ProjectBaseline.ValidateRelativePath(path);
            if (_seedFiles + 1 > _policy.RootElement.GetProperty("baselineFiles").GetInt32() ||
                _seedBytes + bytes.LongLength > _policy.RootElement.GetProperty("baselineBytes").GetInt64())
            {
                throw new InvalidOperationException("The selected baseline limit was exceeded.");
            }
            string result = FileOperation("seed", path, bytes, 0, 8192, true);
            using JsonDocument record = JsonDocument.Parse(result);
            if (!record.RootElement.GetProperty("ok").GetBoolean()) { throw new IOException("The selected baseline could not be seeded."); }
            _seedBytes += bytes.LongLength;
            _seedFiles++;
            _baseline.Add(path.Replace('\\', '/'), Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
        }

        /// <summary>Freezes baseline ownership before enabling File or Terminal.</summary>
        public void Seal()
        {
            if (_sealed || _stopped) { throw new InvalidOperationException("Child input is already sealed or stopped."); }
            _channel!.Send("{\"type\":\"seal\"}");
            ReceiveControl("sealed");
            _sealed = true;
            SaveClaim("running");
        }

        /// <summary>Reads only through the contained File implementation.</summary>
        public string Read(string path, int offset, int count)
        {
            EnsureRunning();
            return FileOperation("read", path, Array.Empty<byte>(), offset, count, false);
        }

        /// <summary>Writes only through the contained File implementation.</summary>
        public string Write(string path, byte[] bytes)
        {
            EnsureRunning();
            if (_policy.RootElement.GetProperty("projectAccess").GetString() != "read-write")
            {
                return "{\"ok\":false,\"code\":\"read_only\"}";
            }
            return FileOperation("write", path, bytes, 0, 8192, false);
        }

        /// <summary>Executes a Host Server-authorized command as the unprivileged Tool user.</summary>
        public string Execute(string command)
        {
            EnsureRunning();
            _toolOutput.Reset();
            if (string.IsNullOrWhiteSpace(command) || command.Length > 2000) { throw new InvalidDataException("The command limit was exceeded."); }
            string script = "$ErrorActionPreference = 'Stop'\n" + command;
            var arguments = ToolArguments(false);
            arguments.AddRange(new[] { "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) });
            NativeResult result;
            try { result = Call(arguments, Array.Empty<byte>(), RemainingMilliseconds(), _policy.RootElement.GetProperty("outputBytes").GetInt32(), _cancel.Token, _toolOutput); }
            catch { Stop(); throw; }
            using JsonDocument quota = JsonDocument.Parse(Quota());
            bool exhausted = quota.RootElement.GetProperty("freeBytes").GetUInt64() == 0 || quota.RootElement.GetProperty("freeInodes").GetUInt64() == 0;
            return JsonSerializer.Serialize(new { exitCode = result.ExitCode, stdout = result.Output, stderr = result.Error, quotaExceeded = exhausted });
        }

        /// <summary>Runs a command without blocking the Host Server control path.</summary>
        public Task<string> ExecuteAsync(string command) => Task.Run(() => Execute(command));

        /// <summary>Waits for actual command output, not merely client process creation.</summary>
        public bool WaitForToolOutput(int timeoutMilliseconds) => _toolOutput.Wait(timeoutMilliseconds);

        /// <summary>Withdraws renewals without relying on a busy command or closed pipe.</summary>
        public void WithdrawLease()
        {
            _renewal?.Dispose();
            _renewal = null;
        }

        /// <summary>Exports bounded proposed bytes after terminating every Tool descendant.</summary>
        public string Export()
        {
            EnsureRunning();
            _frozen = true;
            try
            {
                _channel!.Send("{\"type\":\"freeze\"}");
                ReceiveControl("frozen");
                SaveClaim("exporting");
                var validate = ToolArguments(true);
                validate.AddRange(new[] { "-File", "/opt/deskpilot-child/Invoke-DpChildFile.ps1", "-Operation", "validate-export",
                    "-Count", _policy.RootElement.GetProperty("inodeLimit").GetInt32().ToString(CultureInfo.InvariantCulture) });
                NativeResult validation = Call(validate, Array.Empty<byte>(), 10000, 16384, _cancel.Token);
                if (validation.ExitCode != 0) { throw new InvalidDataException("Unsafe export file, link or mount was refused."); }
                using ControlProcess copy = Start(new[] { "exec", "--user", "0:0", _containerId,
                    "/usr/bin/tar", "--format=pax", "--one-file-system", "-C", "/work", "-cf", "-", "--", "project" });
                copy.Input.Close();
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_cancel.Token);
                deadline.CancelAfter(RemainingMilliseconds());
                using CancellationTokenRegistration kill = deadline.Token.Register(() =>
                {
                    try { if (!copy.HasExited) { copy.Kill(true); } }
                    catch (InvalidOperationException) { }
                });
                Task<byte[]> errors = DrainAsync(copy.Error, new OutputBudget(16384), deadline, null);
                long archiveLimit = _policy.RootElement.GetProperty("toolStorageBytes").GetInt64() +
                    _policy.RootElement.GetProperty("inodeLimit").GetInt64() * 4096;
                using var bounded = new BoundedReadStream(copy.Output, archiveLimit);
                using var archive = new TarReader(bounded, leaveOpen: true);
                var files = new List<object>();
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                long proposedBytes = 0;
                long scannedBytes = 0;
                int entries = 0;
                try
                {
                    TarEntry? entry;
                    while ((entry = archive.GetNextEntryAsync(false, deadline.Token).AsTask().GetAwaiter().GetResult()) != null)
                    {
                        if (++entries > _policy.RootElement.GetProperty("inodeLimit").GetInt32())
                        {
                            throw new InvalidDataException("The export entry limit was exceeded.");
                        }
                        string name = entry.Name.TrimEnd('/');
                        if (name == "project" && entry.EntryType == TarEntryType.Directory) { continue; }
                        if (!name.StartsWith("project/", StringComparison.Ordinal)) { throw new InvalidDataException("Unsafe export archive path."); }
                        string relative = ProjectBaseline.ValidateRelativePath(name.Substring(8));
                        if (!seen.Add(relative)) { throw new InvalidDataException("Duplicate export paths or case aliases were refused."); }
                        if (entry.EntryType == TarEntryType.Directory) { continue; }
                        if (entry.EntryType != TarEntryType.RegularFile || entry.Length < 0 ||
                            entry.Length > _policy.RootElement.GetProperty("toolStorageBytes").GetInt64())
                        {
                            throw new InvalidDataException("Unsafe export file type or size was refused.");
                        }
                        scannedBytes += entry.Length;
                        if (scannedBytes > _policy.RootElement.GetProperty("toolStorageBytes").GetInt64())
                        {
                            throw new InvalidDataException("The export byte limit was exceeded.");
                        }
                        var bytes = new byte[(int)entry.Length];
                        if (bytes.Length > 0) { entry.DataStream!.ReadExactlyAsync(bytes, deadline.Token).AsTask().GetAwaiter().GetResult(); }
                        string digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
                        _baseline.TryGetValue(relative, out string? baselineDigest);
                        if (digest == baselineDigest) { continue; }
                        proposedBytes += bytes.LongLength;
                        CheckProposalLimit(files.Count + 1, proposedBytes);
                        files.Add(new
                        {
                            path = relative, operation = baselineDigest == null ? "add" : "modify", size = bytes.LongLength,
                            baselineSha256 = baselineDigest, resultSha256 = digest, contentBase64 = Convert.ToBase64String(bytes)
                        });
                    }
                    foreach (KeyValuePair<string, string> baseline in _baseline)
                    {
                        if (seen.Contains(baseline.Key)) { continue; }
                        CheckProposalLimit(files.Count + 1, proposedBytes);
                        files.Add(new { path = baseline.Key, operation = "delete", size = 0, baselineSha256 = baseline.Value,
                            resultSha256 = (string?)null, contentBase64 = (string?)null });
                    }
                    bounded.CopyToAsync(Stream.Null, 8192, deadline.Token).GetAwaiter().GetResult();
                    copy.WaitForExitAsync(deadline.Token).GetAwaiter().GetResult();
                    errors.GetAwaiter().GetResult();
                    if (copy.ExitCode != 0) { throw new IOException("The contained export did not complete."); }
                }
                catch { deadline.Cancel(); throw; }
                string proposal = JsonSerializer.Serialize(new
                {
                    schemaVersion = 1, runId = _runId, containerId = _containerId,
                    files, totalBytes = proposedBytes, realProjectFilesWritten = Array.Empty<string>()
                });
                long hostLimit = _policy.RootElement.GetProperty("storageBytes").GetInt64() -
                    _policy.RootElement.GetProperty("toolStorageBytes").GetInt64();
                long reserved = _engine == null ? 8192 : 65536 + _policy.RootElement.GetProperty("resultBytes").GetInt64() +
                    _policy.RootElement.GetProperty("eventBytes").GetInt64() * _policy.RootElement.GetProperty("eventLimit").GetInt64() +
                    _policy.RootElement.GetProperty("requestBytes").GetInt64() * 12 + _policy.RootElement.GetProperty("outputBytes").GetInt64() * 8;
                if (Encoding.UTF8.GetByteCount(proposal) > hostLimit - reserved)
                {
                    throw new InvalidDataException("The retained proposal storage limit was exceeded.");
                }
                using (var destination = new FileStream(Path.Combine(_directory, "proposal.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    byte[] bytes = Encoding.UTF8.GetBytes(proposal);
                    destination.Write(bytes);
                    destination.Flush(true);
                }
                SaveClaim("exported");
                return proposal;
            }
            catch { Stop(); throw; }
        }

        private void CheckProposalLimit(int count, long bytes)
        {
            if (count > _policy.RootElement.GetProperty("proposalFiles").GetInt32() ||
                bytes > _policy.RootElement.GetProperty("proposalBytes").GetInt64())
            {
                throw new InvalidDataException("The proposal file or byte limit was exceeded.");
            }
        }

        /// <summary>Reports kernel quotas and daemon-observed network and mounts.</summary>
        public string Inspect()
        {
            EnsureRunning();
            using JsonDocument quota = JsonDocument.Parse(Quota());
            using JsonDocument inspection = JsonDocument.Parse(Control(new[] { "inspect", _containerId }, 5000));
            JsonElement state = inspection.RootElement[0];
            int hostMounts = 0;
            foreach (JsonElement mount in state.GetProperty("Mounts").EnumerateArray())
            {
                if (mount.GetProperty("Type").GetString() != "tmpfs") { hostMounts++; }
            }
            JsonElement host = state.GetProperty("HostConfig");
            long memory = _policy.RootElement.GetProperty("memoryBytes").GetInt64() / 2;
            long cpu = (long)(_policy.RootElement.GetProperty("cpuCount").GetDouble() / 2 * 1000000000);
            if (state.GetProperty("Id").GetString() != _containerId || hostMounts != 0 ||
                state.GetProperty("Config").GetProperty("Labels").GetProperty("io.deskpilot.child.run").GetString() != _runId ||
                !host.GetProperty("ReadonlyRootfs").GetBoolean() || host.GetProperty("Privileged").GetBoolean() ||
                host.GetProperty("NetworkMode").GetString() != "none" || host.GetProperty("IpcMode").GetString() != "none" ||
                host.GetProperty("Memory").GetInt64() != memory || host.GetProperty("MemorySwap").GetInt64() != memory ||
                host.GetProperty("NanoCpus").GetInt64() != cpu || host.GetProperty("PidsLimit").GetInt64() != 40 ||
                quota.RootElement.GetProperty("bytes").GetUInt64() != (ulong)_policy.RootElement.GetProperty("toolStorageBytes").GetInt64() ||
                quota.RootElement.GetProperty("inodes").GetUInt64() != (ulong)_policy.RootElement.GetProperty("inodeLimit").GetInt64())
            { throw new InvalidDataException("The effective child Tool profile does not match its authority."); }
            return JsonSerializer.Serialize(new
            {
                bytes = quota.RootElement.GetProperty("bytes").GetUInt64(),
                inodes = quota.RootElement.GetProperty("inodes").GetUInt64(),
                network = host.GetProperty("NetworkMode").GetString(), hostMounts,
                memoryBytes = memory, cpuNano = cpu, pids = 40, readOnly = true
            });
        }

        private string Quota()
        {
            var arguments = ToolArguments(false);
            arguments.AddRange(new[] { "-File", "/opt/deskpilot-child/Invoke-DpChildFile.ps1", "-Operation", "inspect" });
            NativeResult result = Call(arguments, Array.Empty<byte>(), 5000, 16384, _cancel.Token);
            if (result.ExitCode != 0) { throw new IOException("The effective Tool quota could not be inspected."); }
            return result.Output.Trim();
        }

        private string FileOperation(string operation, string path, byte[] bytes, int offset, int count, bool seed)
        {
            ProjectBaseline.ValidateRelativePath(path);
            if (bytes.LongLength > 67108864) { throw new InvalidDataException("The File input limit was exceeded."); }
            var arguments = ToolArguments(seed);
            arguments.AddRange(new[] { "-File", "/opt/deskpilot-child/Invoke-DpChildFile.ps1", "-Operation", operation,
                "-PathBase64", Convert.ToBase64String(Encoding.UTF8.GetBytes(path)),
                "-Offset", offset.ToString(CultureInfo.InvariantCulture), "-Count", count.ToString(CultureInfo.InvariantCulture),
                "-InputLength", bytes.LongLength.ToString(CultureInfo.InvariantCulture) });
            NativeResult result = Call(arguments, bytes, RemainingMilliseconds(), 65536, _cancel.Token);
            if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.Output)) { throw new IOException("The contained File operation failed: " + result.Error); }
            return result.Output.Trim();
        }

        private List<string> ToolArguments(bool seed)
        {
            var arguments = new List<string> { "exec", "--interactive", "--user", "0:0", "--workdir", "/work/project", _containerId };
            if (!seed)
            {
                arguments.AddRange(new[] { "/usr/bin/setpriv", "--reuid=10001", "--regid=10001", "--clear-groups",
                    "--bounding-set=-all", "--inh-caps=-all", "--ambient-caps=-all", "--" });
            }
            arguments.AddRange(new[] { "/opt/microsoft/powershell/7/pwsh", "-NoLogo", "-NoProfile", "-NonInteractive" });
            return arguments;
        }

        private void ReceiveControl(string expected)
        {
            using var timeout = new CancellationTokenSource(Math.Min(30000, RemainingMilliseconds()));
            using JsonDocument record = JsonDocument.Parse(_channel!.ReceiveAsync(timeout.Token).GetAwaiter().GetResult());
            if (record.RootElement.GetProperty("type").GetString() != expected) { throw new InvalidDataException("Unexpected child control state."); }
        }

        private void EnsureRunning()
        {
            if (!_sealed || _frozen || _stopped || _cancel.IsCancellationRequested) { throw new InvalidOperationException("The child Tool container is not running."); }
        }

        internal int RemainingMilliseconds()
        {
            long remaining = _policy.RootElement.GetProperty("durationSeconds").GetInt32() * 1000L - _clock.ElapsedMilliseconds;
            if (remaining <= 0) { throw new TimeoutException("The complete child deadline expired."); }
            return (int)remaining;
        }

        private void SaveClaim(string state)
        {
            string record = JsonSerializer.Serialize(new
            {
                schemaVersion = 1, runId = _runId, name = _name, containerId = _containerId, state,
                ownerPid = Environment.ProcessId, ownerStartUtc = Process.GetCurrentProcess().StartTime.ToUniversalTime(),
                policyDigest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_policy.RootElement.GetRawText()))).ToLowerInvariant(),
                retainedBytes = _policy.RootElement.GetProperty("storageBytes").GetInt64() - _policy.RootElement.GetProperty("toolStorageBytes").GetInt64(),
                expiresUtc = _createdUtc.AddHours(_policy.RootElement.GetProperty("retentionHours").GetInt32()),
                cleanupSucceeded = CleanupSucceeded
            });
            byte[] bytes = Encoding.UTF8.GetBytes(record);
            if (bytes.Length > 2048) { throw new InvalidDataException("The child ownership record limit was exceeded."); }
            string ownership = Path.Combine(_directory, "ownership.json");
            if (!File.Exists(ownership))
            {
                using var identity = new FileStream(ownership, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                identity.Write(bytes);
                identity.Flush(true);
            }
            using var stateFile = new FileStream(ClaimPath, FileMode.Create, FileAccess.Write, FileShare.None);
            stateFile.Write(bytes);
            stateFile.Flush(true);
        }

        private static long VerifyPreviousCleanup(string installation)
        {
            int count = 0;
            long retained = 0;
            foreach (string directory in Directory.EnumerateDirectories(installation))
            {
                if (++count > 4096 || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new IOException("Child cleanup records exceed their limit or require reconciliation.");
                }
                string claim = Path.Combine(directory, "claim.json");
                try
                {
                    if (!File.Exists(claim) || new FileInfo(claim).Length > 4096)
                    {
                        throw new InvalidDataException("Missing or oversized ownership claim.");
                    }
                    using JsonDocument record = JsonDocument.Parse(File.ReadAllText(claim));
                    if (!record.RootElement.GetProperty("cleanupSucceeded").GetBoolean() ||
                        record.RootElement.GetProperty("state").GetString() != "stopped")
                    {
                        throw new InvalidDataException("Unfinished ownership claim.");
                    }
                    long reservation = record.RootElement.GetProperty("retainedBytes").GetInt64();
                    if (reservation < 8192 || reservation > 67108864 ||
                        record.RootElement.GetProperty("runId").GetString() != Path.GetFileName(directory))
                    {
                        throw new InvalidDataException("Invalid retention reservation.");
                    }
                    long actual = 0;
                    int fileCount = 0;
                    foreach (string file in Directory.EnumerateFileSystemEntries(directory))
                    {
                        if (++fileCount > 9 || (File.GetAttributes(file) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                        {
                            throw new InvalidDataException("Unsupported retained child data.");
                        }
                        actual += new FileInfo(file).Length;
                        if (actual > reservation) { throw new InvalidDataException("Retained child data exceeds its reservation."); }
                    }
                    retained = checked(retained + reservation);
                }
                catch (Exception error) when (error is IOException || error is InvalidDataException || error is JsonException ||
                    error is KeyNotFoundException || error is InvalidOperationException)
                {
                    throw new IOException("Child cleanup must be reconciled before another run.", error);
                }
            }
            return retained;
        }

        internal ControlProcess Start(IEnumerable<string> arguments)
        {
            var start = new ProcessStartInfo(_docker)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = _directory
            };
            start.Environment.Clear();
            start.Environment["SystemRoot"] = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
            start.Environment["PATH"] = Path.GetDirectoryName(_docker)!;
            start.Environment["USERPROFILE"] = _directory;
            start.Environment["TEMP"] = _directory;
            start.Environment["TMP"] = _directory;
            start.ArgumentList.Add("--host");
            start.ArgumentList.Add("npipe:////./pipe/dockerDesktopLinuxEngine");
            start.ArgumentList.Add("--config");
            start.ArgumentList.Add(_directory);
            foreach (string argument in arguments) { start.ArgumentList.Add(argument); }
            return new ControlProcess(start, _hostProcess);
        }

        internal string Control(IEnumerable<string> arguments, int timeout)
        {
            if (_stopped)
            {
                int remaining = _policy.RootElement.GetProperty("cleanupSeconds").GetInt32() * 1000 - (int)_cleanupClock.ElapsedMilliseconds;
                if (remaining <= 0) { throw new TimeoutException("The complete child cleanup grace expired."); }
                timeout = Math.Min(timeout, remaining);
            }
            else { timeout = Math.Min(timeout, RemainingMilliseconds()); }
            NativeResult result = Call(arguments, Array.Empty<byte>(), timeout, 1048576, _stopped ? CancellationToken.None : _cancel.Token);
            if (result.ExitCode != 0) { throw new IOException("Docker child control failed: " + result.Error); }
            return result.Output;
        }

        private NativeResult Call(IEnumerable<string> arguments, byte[] input, int timeout, int limit,
            CancellationToken cancellation, ManualResetEventSlim? observed = null)
        {
            cancellation.ThrowIfCancellationRequested();
            using ControlProcess process = Start(arguments);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            deadline.CancelAfter(timeout);
            using CancellationTokenRegistration kill = deadline.Token.Register(() =>
            {
                try { if (!process.HasExited) { process.Kill(true); } }
                catch (InvalidOperationException) { }
            });
            var budget = new OutputBudget(limit);
            Task<byte[]> output = DrainAsync(process.Output, budget, deadline, observed);
            Task<byte[]> error = DrainAsync(process.Error, budget, deadline, observed);
            Task write = WriteInputAsync(process.Input, input, deadline.Token);
            try
            {
                Task.WhenAll(output, error, write, process.WaitForExitAsync(deadline.Token)).GetAwaiter().GetResult();
                return new NativeResult { ExitCode = process.ExitCode, Output = Encoding.UTF8.GetString(output.Result), Error = Encoding.UTF8.GetString(error.Result) };
            }
            catch
            {
                deadline.Cancel();
                if (budget.Exceeded) { throw new InvalidDataException("The combined child output limit was exceeded."); }
                throw;
            }
        }

        private static async Task WriteInputAsync(Stream stream, byte[] bytes, CancellationToken cancellation)
        {
            try { await stream.WriteAsync(bytes.AsMemory(), cancellation).ConfigureAwait(false); }
            catch (IOException) { }
            finally { stream.Close(); }
        }

        internal static async Task<byte[]> DrainAsync(Stream stream, OutputBudget budget,
            CancellationTokenSource cancellation, ManualResetEventSlim? observed)
        {
            using var result = new MemoryStream();
            var buffer = new byte[4096];
            while (true)
            {
                int count = await stream.ReadAsync(buffer.AsMemory(), cancellation.Token).ConfigureAwait(false);
                if (count == 0) { return result.ToArray(); }
                observed?.Set();
                if (!budget.Reserve(count))
                {
                    cancellation.Cancel();
                    throw new InvalidDataException("The combined child output limit was exceeded.");
                }
                result.Write(buffer, 0, count);
            }
        }

        /// <summary>Stops through a control path independent of the busy Tool process.</summary>
        public void Stop()
        {
            lock (_stopLock)
            {
                if (_stopped) { return; }
                _stopped = true;
                _cleanupClock.Start();
                _hostProcess?.BeginCleanup(Math.Max(1, _policy.RootElement.GetProperty("cleanupSeconds").GetInt32() * 1000 - (int)_cleanupClock.ElapsedMilliseconds));
                _renewal?.Dispose();
                _deadline?.Dispose();
                _cancel.Cancel();
                try
                {
                    _engine?.Stop();
                    string found = Control(new[] { "ps", "--all", "--filter", "name=^/" + _name + "$", "--filter", "label=io.deskpilot.child.run=" + _runId, "--format", "{{.ID}}" }, 5000).Trim();
                    if (found.Length > 0) { Control(new[] { "rm", "--force", found }, 15000); }
                    string remaining = Control(new[] { "ps", "--all", "--filter", "name=^/" + _name + "$", "--format", "{{.ID}}" }, 5000).Trim();
                    CleanupSucceeded = remaining.Length == 0 && (_engine == null || _engine.CleanupSucceeded);
                }
                catch { CleanupSucceeded = false; }
                finally
                {
                    try { if (_ownsHostProcess) { _hostProcess?.Stop(); } }
                    catch { CleanupSucceeded = false; }
                    try { SaveClaim(CleanupSucceeded ? "stopped" : "cleanup-failed"); }
                    catch { CleanupSucceeded = false; }
                    _channel?.Dispose();
                    if (_attach != null)
                    {
                        if (!_attach.HasExited) { _attach.Kill(true); }
                        _attach.Dispose();
                    }
                }
            }
        }

        /// <summary>Stops owned resources and releases installation admission.</summary>
        public void Dispose()
        {
            Stop();
            if (_ownsHostProcess) { _hostProcess?.Dispose(); }
            _externalCancellation.Dispose();
            _owner?.Dispose();
            _runRoot?.Dispose();
            _controlRoot.Dispose();
        }

        private sealed class NativeResult
        {
            public int ExitCode { get; set; }
            public string Output { get; set; } = string.Empty;
            public string Error { get; set; } = string.Empty;
        }

        internal sealed class OutputBudget
        {
            private readonly int _limit;
            private int _bytes;
            public OutputBudget(int limit) { _limit = limit; }
            public bool Exceeded => Volatile.Read(ref _bytes) > _limit;
            public bool Reserve(int bytes) => Interlocked.Add(ref _bytes, bytes) <= _limit;
        }

        private sealed class BoundedReadStream : Stream
        {
            private readonly Stream _source;
            private readonly long _limit;
            private long _read;
            public BoundedReadStream(Stream source, long limit) { _source = source; _limit = limit; }
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => _read; set => throw new NotSupportedException(); }
            public override void Flush() => throw new NotSupportedException();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            public override int Read(byte[] buffer, int offset, int count)
            {
                int read = _source.Read(buffer, offset, (int)Math.Min(count, Math.Max(1, _limit - _read + 1)));
                _read += read;
                if (_read > _limit) { throw new InvalidDataException("The export archive limit was exceeded."); }
                return read;
            }
            public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            {
                int count = (int)Math.Min(buffer.Length, Math.Max(1, _limit - _read + 1));
                int read = await _source.ReadAsync(buffer.Slice(0, count), cancellationToken).ConfigureAwait(false);
                _read += read;
                if (_read > _limit) { throw new InvalidDataException("The export archive limit was exceeded."); }
                return read;
            }
        }
    }
}
