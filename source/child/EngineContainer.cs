#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>Owns the separate credentialless, network-disabled Engine container.</summary>
    public sealed class EngineContainer : IDisposable
    {
        private readonly ToolContainer _owner;
        private readonly string _name;
        private readonly string _image;
        private readonly object _sync = new object();
        private readonly CancellationTokenSource _cancel = new CancellationTokenSource();
        private ControlProcess? _attach;
        private Task<byte[]>? _errors;
        private HostBridge? _bridge;
        private string _containerId = string.Empty;
        private volatile bool _starting = true;
        private volatile bool _stopped;

        /// <summary>Records ownership, creates and inspects the immutable image, then starts its IPC.</summary>
        public EngineContainer(ToolContainer owner, string image)
        {
            _owner = owner ?? throw new ArgumentNullException(nameof(owner));
            if (owner.HostProcess == null || owner.Policy.GetProperty("profile").GetString() != "single-child-v3" ||
                !System.Text.RegularExpressions.Regex.IsMatch(image, "^sha256:[a-f0-9]{64}$"))
            { throw new InvalidOperationException("The complete child owner or Engine image is unavailable."); }
            _image = image;
            _name = "deskpilot-child-engine-" + owner.RunId;
            owner.AttachEngine(this);
            try
            {
                WriteRecord("engine-ownership.json", "starting", true);
                WriteRecord("engine.json", "starting", true);
                JsonElement policy = owner.Policy;
                long memory = policy.GetProperty("memoryBytes").GetInt64() / 4;
                var arguments = new List<string>
                {
                    "create", "--pull", "never", "--name", _name,
                    "--label", "io.deskpilot.child=1", "--label", "io.deskpilot.child.component=engine",
                    "--label", "io.deskpilot.child.run=" + owner.RunId,
                    "--network", "none", "--read-only", "--cap-drop", "ALL",
                    "--security-opt", "no-new-privileges", "--ipc", "none", "--log-driver", "none",
                    "--user", "65534:65534", "--interactive", "--workdir", "/",
                    "--memory", memory.ToString(CultureInfo.InvariantCulture),
                    "--memory-swap", memory.ToString(CultureInfo.InvariantCulture),
                    "--cpus", (policy.GetProperty("cpuCount").GetDouble() / 4).ToString(CultureInfo.InvariantCulture),
                    "--pids-limit", "16", "--ulimit", "core=0:0",
                    "--env", "HOME=/opt/deskpilot-child/home", "--env", "TMPDIR=/opt/deskpilot-child/home/tmp",
                    "--env", "XDG_CACHE_HOME=/opt/deskpilot-child/home/.cache", "--env", "XDG_CONFIG_HOME=/opt/deskpilot-child/home/.config",
                    "--env", "XDG_DATA_HOME=/opt/deskpilot-child/home/.local/share",
                    "--env", "DOTNET_PROCESSOR_COUNT=1", "--env", "DOTNET_EnableDiagnostics=0",
                    "--env", "POWERSHELL_TELEMETRY_OPTOUT=1", "--env", "PSModuleAnalysisCachePath=/dev/null",
                    "--env", "PSModulePath=/opt/microsoft/powershell/7/Modules",
                    "--entrypoint", "/opt/microsoft/powershell/7/pwsh", image,
                    "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/opt/deskpilot-child/Start-DpChildEngine.ps1",
                    "-EngineModulePath", "/opt/deskpilot-child/engine/ShellPilot.psd1",
                    "-LeaseSeconds", policy.GetProperty("leaseSeconds").GetInt32().ToString(CultureInfo.InvariantCulture)
                };
                EnsureStarting();
                _containerId = owner.Control(arguments, Math.Min(30000, owner.RemainingMilliseconds())).Trim();
                if (!System.Text.RegularExpressions.Regex.IsMatch(_containerId, "^[a-f0-9]{64}$"))
                { throw new IOException("The Engine container identity is invalid."); }
                WriteRecord("engine.json", "created", false);
                _ = Inspect();
                EnsureStarting();
                _attach = owner.Start(new[] { "start", "--attach", "--interactive", _containerId });
                _bridge = new HostBridge(_attach.Output, _attach.Input, policy.GetProperty("leaseSeconds").GetInt32(), 4194304);
                _errors = ToolContainer.DrainAsync(_attach.Error, new ToolContainer.OutputBudget(16384), _cancel, null);
                WriteRecord("engine.json", "running", false);
                _starting = false;
                if (_stopped || owner.IsStopped) { throw new OperationCanceledException("Child admission closed during Engine startup."); }
            }
            catch { _starting = false; Stop(); throw; }
        }

        /// <summary>Immutable daemon identity recorded before execution.</summary>
        public string ContainerId => _containerId;
        /// <summary>True only after positive owned-resource removal.</summary>
        public bool CleanupSucceeded { get; private set; }

        private void EnsureStarting()
        {
            if (_stopped || _owner.IsStopped) { throw new OperationCanceledException("Child Engine startup was cancelled."); }
            _ = _owner.RemainingMilliseconds();
        }

        /// <summary>Supplies only the Host Server approved bounded configuration.</summary>
        public void Configure(string configuration)
        {
            EnsureStarting();
            if (Encoding.UTF8.GetByteCount(configuration) > _owner.Policy.GetProperty("requestBytes").GetInt32())
            { throw new InvalidDataException("Child configuration exceeds its request limit."); }
            _bridge!.Configure(configuration);
        }

        /// <summary>Receives untrusted data through the authenticated per-run channel.</summary>
        public Task<string> ReceiveAsync(CancellationToken cancellationToken) => _bridge!.ReceiveAsync(cancellationToken);
        /// <summary>Returns one bounded Host Server result to the waiting Engine request.</summary>
        public void Reply(string id, string payload) { EnsureStarting(); _bridge!.Reply(id, payload); }
        /// <summary>Stops renewal independently of the Engine Runspace.</summary>
        public void WithdrawLease() => _bridge?.WithdrawLease();

        /// <summary>Validates effective daemon settings and returns only profile facts.</summary>
        public string Inspect()
        {
            using JsonDocument document = JsonDocument.Parse(_owner.Control(new[] { "inspect", _containerId }, 5000));
            JsonElement container = document.RootElement[0];
            JsonElement host = container.GetProperty("HostConfig");
            JsonElement configuration = container.GetProperty("Config");
            long memory = _owner.Policy.GetProperty("memoryBytes").GetInt64() / 4;
            long cpu = (long)(_owner.Policy.GetProperty("cpuCount").GetDouble() / 4 * 1000000000);
            if (container.GetProperty("Id").GetString() != _containerId || container.GetProperty("Image").GetString() != _image ||
                container.GetProperty("Name").GetString() != "/" + _name ||
                configuration.GetProperty("Labels").GetProperty("io.deskpilot.child.run").GetString() != _owner.RunId ||
                configuration.GetProperty("User").GetString() != "65534:65534" ||
                !host.GetProperty("ReadonlyRootfs").GetBoolean() || host.GetProperty("Privileged").GetBoolean() ||
                host.GetProperty("NetworkMode").GetString() != "none" || host.GetProperty("IpcMode").GetString() != "none" ||
                host.GetProperty("Memory").GetInt64() != memory || host.GetProperty("MemorySwap").GetInt64() != memory ||
                host.GetProperty("NanoCpus").GetInt64() != cpu || host.GetProperty("PidsLimit").GetInt64() != 16 ||
                container.GetProperty("Mounts").GetArrayLength() != 0 ||
                host.GetProperty("CapAdd").ValueKind != JsonValueKind.Null ||
                host.GetProperty("CapDrop").GetArrayLength() != 1 || host.GetProperty("CapDrop")[0].GetString() != "ALL" ||
                host.GetProperty("SecurityOpt").GetArrayLength() != 1 || host.GetProperty("SecurityOpt")[0].GetString() != "no-new-privileges")
            { throw new InvalidDataException("The effective Engine isolation profile does not match its authority."); }
            return JsonSerializer.Serialize(new { image = _image, network = "none", hostMounts = 0,
                readOnly = true, memoryBytes = memory, cpuNano = cpu, pids = 16 });
        }

        private void WriteRecord(string file, string state, bool create)
        {
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new
            {
                schemaVersion = 1, runId = _owner.RunId, name = _name, image = _image,
                containerId = _containerId, state, cleanupSucceeded = CleanupSucceeded
            });
            if (bytes.Length > 2048) { throw new InvalidDataException("Engine ownership exceeds its byte limit."); }
            using var record = new FileStream(Path.Combine(_owner.DirectoryPath, file),
                create ? FileMode.CreateNew : FileMode.Create, FileAccess.Write, FileShare.None);
            record.Write(bytes);
            record.Flush(true);
        }

        /// <summary>Closes admission, removes only the owned Engine, and verifies absence.</summary>
        public void Stop()
        {
            lock (_sync)
            {
                if (_stopped && CleanupSucceeded) { return; }
                _stopped = true;
                _bridge?.WithdrawLease();
                _cancel.Cancel();
                if (_starting) { CleanupSucceeded = false; return; }
                try
                {
                    string found = _owner.Control(new[] { "ps", "--all", "--no-trunc", "--filter", "name=^/" + _name + "$",
                        "--filter", "label=io.deskpilot.child.run=" + _owner.RunId, "--format", "{{.ID}}" }, 5000).Trim();
                    if (found.Length > 0)
                    {
                        if (!System.Text.RegularExpressions.Regex.IsMatch(found, "^[a-f0-9]{64}$") ||
                            (_containerId.Length > 0 && found != _containerId)) { throw new InvalidDataException("Ambiguous Engine cleanup identity."); }
                        _owner.Control(new[] { "rm", "--force", found }, 5000);
                    }
                    string remaining = _owner.Control(new[] { "ps", "--all", "--filter", "name=^/" + _name + "$", "--format", "{{.ID}}" }, 5000).Trim();
                    CleanupSucceeded = remaining.Length == 0;
                    WriteRecord("engine.json", CleanupSucceeded ? "stopped" : "cleanup-failed", false);
                }
                catch { CleanupSucceeded = false; }
                finally
                {
                    _attach?.Dispose();
                    _bridge?.Dispose();
                }
            }
        }

        /// <summary>Terminates the owned component; the complete owner retains transport admission.</summary>
        public void Dispose() => Stop();
    }
}
