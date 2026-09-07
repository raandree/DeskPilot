#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>One complete child run, controlled outside both Engine Runspaces.</summary>
    public sealed class RunController : IDisposable
    {
        private readonly JsonDocument _runtime;
        private readonly JsonDocument _request;
        private readonly JsonElement _policy;
        private readonly string _directory;
        private readonly object _sync = new object();
        private readonly object _cleanupSync = new object();
        private readonly ManualResetEventSlim _changed = new ManualResetEventSlim(false);
        private readonly RunAuthority _authority;
        private readonly List<JsonElement> _events = new List<JsonElement>();
        private readonly List<string> _filesRead = new List<string>();
        private readonly List<object> _commandsRun = new List<object>();
        private ToolContainer? _owner;
        private EngineContainer? _engine;
        private HostBridge? _provider;
        private Task<byte[]>? _providerErrors;
        private JsonElement? _usage;
        private string _status = "starting";
        private string _phase = "ownership";
        private string _code = string.Empty;
        private string _content = string.Empty;
        private bool _cleanupSucceeded;
        private bool _hasProposal;
        private long _eventBytes;
        private string? _lastRequestShape;
        private int _disposed;

        /// <summary>Starts only from trusted frozen artifacts and Host Server launch data.</summary>
        public RunController(string runtimeJson, string directory, string requestJson)
        {
            if (Encoding.UTF8.GetByteCount(runtimeJson) > 65536 || Encoding.UTF8.GetByteCount(requestJson) > 2097152)
            { throw new InvalidDataException("Child launch data exceeds its byte limit."); }
            AuthenticatedChannel.ValidateJson(Encoding.UTF8.GetBytes(runtimeJson));
            AuthenticatedChannel.ValidateJson(Encoding.UTF8.GetBytes(requestJson));
            _runtime = JsonDocument.Parse(runtimeJson);
            _request = JsonDocument.Parse(requestJson);
            _directory = Path.GetFullPath(directory);
            JsonElement request = _request.RootElement;
            _policy = request.GetProperty("policy");
            if (_policy.GetProperty("profile").GetString() != "single-child-v3" ||
                _policy.GetProperty("budgetMode").GetString() != "provider-estimate" ||
                _policy.GetProperty("model").GetString() != "claude-haiku-4.5")
            { throw new InvalidDataException("Unsupported complete child profile."); }
            Id = Guid.NewGuid().ToString("N");
            ConversationId = RequiredText(request, "conversationId", 128);
            ParentTurnId = RequiredText(request, "parentTurnId", 128);
            string digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_policy.GetRawText()))).ToLowerInvariant();
            JsonElement permissions = request.GetProperty("permissions");
            _authority = new RunAuthority(RequiredText(request, "launchId", 128), ConversationId, ParentTurnId, Id, digest,
                permissions.GetProperty("file").GetBoolean(), permissions.GetProperty("terminal").GetBoolean(),
                _policy.GetProperty("projectAccess").GetString() == "read-write",
                _policy.GetProperty("durationSeconds").GetInt32(), _policy.GetProperty("approvalSeconds").GetInt32());
            _authority.Cancellation.Register(() =>
            {
                lock (_sync) { _status = "stopping"; }
                _changed.Set();
                _ = Task.Run(StopResources);
            });
            Completion = Task.Run(Execute);
        }

        /// <summary>Host-generated run identity, unrelated to child output.</summary>
        public string Id { get; }
        /// <summary>Frozen Conversation identity.</summary>
        public string ConversationId { get; }
        /// <summary>Frozen parent Turn identity.</summary>
        public string ParentTurnId { get; }
        /// <summary>Completes only after bounded execution and attempted verified cleanup.</summary>
        public Task Completion { get; }
        /// <summary>Waits for a status change without using the parent Engine Runspace.</summary>
        public bool WaitForChange(int milliseconds)
        {
            bool changed = _changed.Wait(Math.Clamp(milliseconds, 0, 1000));
            _changed.Reset();
            return changed;
        }

        /// <summary>Allows only an exact one-use child approval from the window.</summary>
        public bool SubmitApproval(string conversation, string child, string approvalId, string fingerprint, bool approved) =>
            _authority.Submit(conversation, child, approvalId, fingerprint, approved);

        /// <summary>Revokes, but never expands, captured scope.</summary>
        public void UpdatePermissions(bool file, bool terminal, bool enabled) => _authority.UpdatePermissions(file, terminal, enabled);
        /// <summary>Applies live private-write revocation as well as Tool category Permissions.</summary>
        public void UpdatePermissions(bool file, bool terminal, bool enabled, bool writable) => _authority.UpdatePermissions(file, terminal, enabled, writable);

        /// <summary>Closes admission before asynchronous process and container cleanup.</summary>
        public void Stop() => _authority.Close("stopped");

        /// <summary>Projects bounded data for the authenticated window; never provider state.</summary>
        public string Snapshot() => Snapshot(true);

        private string Snapshot(bool includeApproval)
        {
            string? pending = includeApproval ? _authority.PendingApproval : null;
            JsonElement? approval = pending == null ? null : Parse(pending);
            lock (_sync)
            {
                return JsonSerializer.Serialize(new
                {
                    schemaVersion = 1, id = Id, conversationId = ConversationId, parentTurnId = ParentTurnId,
                    profile = "single-child-v3", budgetMode = "provider-estimate", model = "claude-haiku-4.5",
                    status = _status, phase = _phase, code = _code, cleanupSucceeded = _cleanupSucceeded,
                    content = _content, usage = _usage, approval, events = _events.ToArray(),
                    filesRead = _filesRead.ToArray(), filesWritten = Array.Empty<string>(),
                    commandsRun = _commandsRun.ToArray(), hasProposal = _hasProposal,
                    effectiveLimits = _policy
                });
            }
        }

        /// <summary>Returns validated private proposal data only after successful cleanup.</summary>
        public string GetProposal()
        {
            if (!Completion.IsCompleted || !_cleanupSucceeded || !_hasProposal || _owner == null)
            { throw new InvalidOperationException("A private proposal is not available."); }
            string path = Path.Combine(_owner.DirectoryPath, "proposal.json");
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > _owner.HostStorageLimit || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            { throw new InvalidDataException("Private proposal storage is invalid."); }
            using var reader = new StreamReader(file, new UTF8Encoding(false, true));
            string result = reader.ReadToEnd();
            using JsonDocument document = JsonDocument.Parse(result);
            if (document.RootElement.GetProperty("runId").GetString() != Id)
            { throw new InvalidDataException("Private proposal identity mismatch."); }
            return result;
        }

        private void Execute()
        {
            string outcome = "failed";
            try
            {
                JsonElement runtime = _runtime.RootElement;
                JsonElement request = _request.RootElement;
                string assembly = RequiredText(runtime, "assembly", 32768);
                string providerEntry = RequiredText(runtime, "providerEntry", 32768);
                string manifest = RequiredText(runtime, "engineManifest", 32768);
                string executable = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath!)!, "pwsh.exe");
                var providerStart = new ProcessStartInfo(executable);
                foreach (string argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", providerEntry,
                    "-EngineModulePath", manifest, "-RuntimeAssembly", assembly, "-LeaseSeconds", _policy.GetProperty("leaseSeconds").GetInt32().ToString() })
                { providerStart.ArgumentList.Add(argument); }
                string docker = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Docker", "Docker", "resources", "bin", "docker.exe");
                _owner = new ToolContainer(docker, RequiredText(runtime, "image", 80), _directory,
                    _policy.GetRawText(), providerStart, Id, _authority.Cancellation);
                _authority.Ensure("read");
                SetPhase("capture");
                var paths = new List<string>();
                foreach (JsonElement path in request.GetProperty("selectedPaths").EnumerateArray()) { paths.Add(path.GetString()!); }
                using (ProjectBaseline baseline = ProjectBaseline.Open(RequiredText(request, "projectPath", 32768), paths.ToArray(),
                    _policy.GetProperty("baselineBytes").GetInt64(), _policy.GetProperty("baselineFiles").GetInt32()))
                {
                    foreach (BaselineEntry entry in baseline.Entries)
                    {
                        _authority.Ensure("read");
                        _owner.Seed(entry.Path, entry.GetBytes());
                    }
                }
                _owner.Seal();
                _ = _owner.Inspect();
                SetPhase("provider-initialization");
                _authority.Ensure("provider");
                _owner.HostProcess!.Resume();
                _provider = new HostBridge(_owner.HostProcess.Output, _owner.HostProcess.Input, _policy.GetProperty("leaseSeconds").GetInt32(), 4194304);
                _providerErrors = ToolContainer.DrainAsync(_owner.HostProcess.Error, new ToolContainer.OutputBudget(16384),
                    CancellationTokenSource.CreateLinkedTokenSource(_authority.Cancellation), null);
                var providerConfiguration = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(_policy.GetRawText())!;
                providerConfiguration["permissions"] = request.GetProperty("permissions").Clone();
                providerConfiguration["durationSeconds"] = JsonSerializer.SerializeToElement(Math.Max(1, _authority.RemainingMilliseconds / 1000));
                if (request.TryGetProperty("tokenPath", out JsonElement tokenPath)) { providerConfiguration["tokenPath"] = tokenPath.Clone(); }
                _provider.Configure(JsonSerializer.Serialize(providerConfiguration));
                JsonElement providerPending = ReceiveProvider();
                if (providerPending.GetProperty("payload").GetProperty("stage").GetString() != "ready")
                { throw new RunFailure("provider-failed"); }
                UpdateUsage(providerPending.GetProperty("payload").GetProperty("usage"));
                SetPhase("engine-startup");
                _engine = new EngineContainer(_owner, RequiredText(runtime, "engineImage", 80));
                var engineConfiguration = new
                {
                    profile = "single-child-v3", budgetMode = "provider-estimate", model = "claude-haiku-4.5",
                    prompt = RequiredText(request, "prompt", _policy.GetProperty("requestBytes").GetInt32()),
                    agentBody = RequiredText(request, "agentBody", _policy.GetProperty("requestBytes").GetInt32()),
                    permissions = request.GetProperty("permissions"), projectAccess = _policy.GetProperty("projectAccess").GetString(),
                    outputTokens = _policy.GetProperty("outputTokens").GetInt32(), iterations = _policy.GetProperty("iterations").GetInt32(),
                    requestBytes = _policy.GetProperty("requestBytes").GetInt32(), resultBytes = _policy.GetProperty("resultBytes").GetInt32()
                };
                _engine.Configure(JsonSerializer.Serialize(engineConfiguration));
                SetPhase("running");
                while (true)
                {
                    _authority.Ensure("provider");
                    JsonElement message = Parse(_engine.ReceiveAsync(_authority.Cancellation).GetAwaiter().GetResult());
                    string kind = RequiredText(message, "type", 16);
                    if (kind == "complete")
                    {
                        JsonElement result = message.GetProperty("result");
                        if (result.GetProperty("status").GetString() != "completed") { throw new RunFailure("engine-failed"); }
                        string content = RequiredText(result, "content", _policy.GetProperty("resultBytes").GetInt32());
                        lock (_sync) { _content = content; }
                        break;
                    }
                    string requestId = RequiredText(message, "id", 32);
                    _authority.AdmitRequest(requestId);
                    JsonElement payload = message.GetProperty("payload");
                    if (kind == "provider")
                    {
                        var shape = new List<object>();
                        foreach (JsonElement entry in payload.GetProperty("Conversation").EnumerateArray())
                        {
                            var fields = new List<string>();
                            foreach (JsonProperty property in entry.EnumerateObject())
                            {
                                fields.Add(property.Name + ":" + property.Value.ValueKind);
                                if (property.Name == "tool_calls" && property.Value.ValueKind == JsonValueKind.Array)
                                {
                                    foreach (JsonElement call in property.Value.EnumerateArray())
                                    { foreach (JsonProperty field in call.EnumerateObject()) { fields.Add("call." + field.Name + ":" + field.Value.ValueKind); } }
                                }
                            }
                            shape.Add(fields);
                        }
                        _lastRequestShape = JsonSerializer.Serialize(shape);
                        SetPhase("provider-request");
                        Send("provider", () => _provider.Reply(providerPending.GetProperty("id").GetString()!,
                            JsonSerializer.Serialize(new { action = "invoke", request = payload })));
                        JsonElement reservation = ReceiveProvider();
                        JsonElement reserved = reservation.GetProperty("payload");
                        if (reserved.GetProperty("stage").GetString() != "reserved" ||
                            reserved.GetProperty("requestId").GetString() != payload.GetProperty("RequestId").GetString())
                        { throw new InvalidDataException("Provider reservation identity mismatch."); }
                        UpdateUsage(reserved.GetProperty("usage"));
                        Send("provider", () => _provider.Reply(reservation.GetProperty("id").GetString()!, "{\"admitted\":true}"));
                        providerPending = ReceiveProvider();
                        JsonElement response = providerPending.GetProperty("payload");
                        if (response.GetProperty("stage").GetString() != "response" ||
                            response.GetProperty("requestId").GetString() != payload.GetProperty("RequestId").GetString())
                        { throw new InvalidDataException("Provider response identity mismatch."); }
                        UpdateUsage(response.GetProperty("usage"));
                        Send("provider", () => _engine.Reply(requestId, JsonSerializer.Serialize(new { ok = true, response = response.GetProperty("response") })));
                    }
                    else if (kind == "tool") { HandleTool(requestId, payload); }
                    else { throw new InvalidDataException("Unsupported child control record."); }
                    SetPhase("running");
                }
                SetPhase("export");
                _authority.Ensure("export");
                _engine.Stop();
                if (!_engine.CleanupSucceeded) { throw new RunFailure("cleanup-failed"); }
                _ = _owner.Export();
                _hasProposal = true;
                outcome = "completed";
            }
            catch (RunFailure failure) { _code = failure.Code; }
            catch (Exception) { _code = _authority.Open ? "child-failed" : _authority.Reason; }
            finally
            {
                if (_authority.Reason == "stopped") { outcome = "stopped"; }
                _authority.Close(outcome == "completed" ? "completed" : (_code.Length > 0 ? _code : outcome));
                lock (_sync) { _status = "stopping"; }
                _changed.Set();
                StopResources();
                lock (_sync)
                {
                    _cleanupSucceeded = _owner != null ? _owner.CleanupSucceeded : VerifyUnreturnedOwner();
                    _status = _cleanupSucceeded ? outcome : "cleanup-failed";
                    if (_status == "completed") { _code = string.Empty; }
                }
                try { Persist(); }
                catch { lock (_sync) { _status = "cleanup-failed"; _cleanupSucceeded = false; _code = "record-failed"; } }
                _owner?.Dispose();
                _changed.Set();
            }
        }

        private JsonElement ReceiveProvider()
        {
            JsonElement message = Parse(_provider!.ReceiveAsync(_authority.Cancellation).GetAwaiter().GetResult());
            if (message.GetProperty("type").GetString() == "complete")
            {
                JsonElement result = message.GetProperty("result");
                if (result.TryGetProperty("usage", out JsonElement usage) && usage.ValueKind == JsonValueKind.Object) { UpdateUsage(usage); }
                string code = RequiredText(result, "code", 64);
                if (code != "budget-overrun" && code != "usage-unknown" && code != "pricing-unavailable" && code != "admission-revoked" && code != "unsupported-request")
                { code = "provider-failed"; }
                throw new RunFailure(code);
            }
            if (message.GetProperty("type").GetString() != "provider") { throw new InvalidDataException("Unexpected provider control record."); }
            return message;
        }

        private void HandleTool(string requestId, JsonElement payload)
        {
            string operation = RequiredText(payload, "operation", 16);
            _authority.Ensure(operation);
            string path = operation == "terminal" ? string.Empty : ProjectBaseline.ValidateRelativePath(RequiredText(payload, "path", 2048));
            string command = operation == "terminal" ? RequiredText(payload, "command", 8000) : string.Empty;
            if (command.Length > 2000) { throw new InvalidDataException("Child command exceeds its limit."); }
            byte[]? content = operation == "write" ? Encoding.UTF8.GetBytes(payload.GetProperty("content").GetString()!) : null;
            if (content != null && content.Length > _policy.GetProperty("requestBytes").GetInt32()) { throw new InvalidDataException("Child write exceeds its request limit."); }
            if (operation == "write" || operation == "terminal")
            {
                string facts = operation == "terminal" ? JsonSerializer.Serialize(new { command }) :
                    JsonSerializer.Serialize(new { path, bytes = content!.Length, sha256 = Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant() });
                string approvalJson = _authority.Prepare(requestId, operation, facts);
                JsonElement approval = Parse(approvalJson);
                lock (_sync) { _status = "awaiting-approval"; _phase = operation; }
                _changed.Set();
                _ = _authority.WaitForDecisionAsync().GetAwaiter().GetResult();
                if (!_authority.Consume(requestId, approval.GetProperty("fingerprint").GetString()!))
                {
                    _authority.Ensure(operation);
                    AddEvent("denied", operation, path);
                    _engine!.Reply(requestId, "{\"ok\":false,\"code\":\"approval-denied\"}");
                    return;
                }
            }
            SetPhase("tool-" + operation);
            Task<string>? execution = null;
            _authority.Commit(operation, () =>
            {
                switch (operation)
                {
                    case "read":
                        int offset = payload.GetProperty("offset").GetInt32();
                        int count = payload.GetProperty("count").GetInt32();
                        if (offset < 0 || count < 1 || count > 8192) { throw new InvalidDataException("Invalid child read window."); }
                        execution = Task.Run(() => _owner!.Read(path, offset, count));
                        break;
                    case "write": execution = Task.Run(() => _owner!.Write(path, content!)); break;
                    case "terminal": execution = _owner!.ExecuteAsync(command); break;
                    default: throw new InvalidDataException("Unsupported child Tool operation.");
                }
            });
            string value = execution!.GetAwaiter().GetResult();
            JsonElement result = Parse(value);
            if ((result.TryGetProperty("quotaExceeded", out JsonElement quota) && quota.ValueKind == JsonValueKind.True) ||
                (result.TryGetProperty("code", out JsonElement code) && code.GetString() == "quota_exceeded"))
            { throw new RunFailure("storage-limit"); }
            bool succeeded = operation == "terminal" ? result.GetProperty("exitCode").GetInt32() == 0 :
                !result.TryGetProperty("ok", out JsonElement ok) || ok.ValueKind == JsonValueKind.True;
            lock (_sync)
            {
                if (operation == "read" && succeeded && !_filesRead.Contains(path)) { _filesRead.Add(path); }
                if (operation == "terminal") { _commandsRun.Add(new { sha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(command))).ToLowerInvariant(), exitCode = result.GetProperty("exitCode").GetInt32() }); }
            }
            AddEvent(succeeded ? "completed" : "failed", operation, path);
            Send(operation, () => _engine!.Reply(requestId, JsonSerializer.Serialize(new { ok = true, value })));
        }

        private void Send(string operation, Action write)
        {
            Task? sending = null;
            _authority.Commit(operation, () => sending = Task.Run(() =>
            {
                _authority.Ensure(operation);
                write();
            }));
            sending!.WaitAsync(_authority.Cancellation).GetAwaiter().GetResult();
        }

        private void UpdateUsage(JsonElement usage)
        {
            if (Encoding.UTF8.GetByteCount(usage.GetRawText()) > 16384) { throw new InvalidDataException("Provider Usage exceeds its bound."); }
            lock (_sync) { _usage = usage.Clone(); }
            Persist();
            _changed.Set();
        }

        private void SetPhase(string phase)
        {
            lock (_sync)
            {
                if (!_authority.Open) { throw new OperationCanceledException("Child admission is closed."); }
                _phase = phase; _status = phase == "ownership" || phase == "capture" || phase == "provider-initialization" || phase == "engine-startup" ? "starting" : "running";
            }
            Persist();
            _changed.Set();
        }

        private void AddEvent(string status, string operation, string path)
        {
            lock (_sync)
            {
                if (!_authority.Open) { throw new OperationCanceledException("Late child Activity was refused."); }
                string record = JsonSerializer.Serialize(new { sequence = _events.Count + 1, timestamp = DateTime.UtcNow,
                    kind = "tool", status, operation, path, profile = "single-child-v3", budgetMode = "provider-estimate" });
                int bytes = Encoding.UTF8.GetByteCount(record);
                if (bytes > _policy.GetProperty("eventBytes").GetInt32() || _events.Count >= _policy.GetProperty("eventLimit").GetInt32())
                { throw new RunFailure("event-limit"); }
                _events.Add(Parse(record));
                _eventBytes += bytes;
            }
            Persist();
            _changed.Set();
        }

        private void Persist()
        {
            if (_owner == null) { return; }
            byte[] bytes = Encoding.UTF8.GetBytes(Snapshot(false));
            long limit = _policy.GetProperty("resultBytes").GetInt64() + _policy.GetProperty("eventBytes").GetInt64() * _policy.GetProperty("eventLimit").GetInt64() + 32768;
            if (bytes.Length > limit || bytes.Length > _owner.HostStorageLimit / 2) { throw new InvalidDataException("Child record exceeds its reserved storage."); }
            using var file = new FileStream(Path.Combine(_owner.DirectoryPath, "run.json"), FileMode.Create, FileAccess.Write, FileShare.Read);
            file.Write(bytes);
            file.Flush(true);
        }

        private void StopResources()
        {
            lock (_cleanupSync)
            {
                try { _provider?.Dispose(); }
                finally { _owner?.Stop(); }
            }
        }

        private bool VerifyUnreturnedOwner()
        {
            string directory = Path.Combine(_directory, "child-runs", Id);
            if (!Directory.Exists(directory)) { return true; }
            try
            {
                string claim = Path.Combine(directory, "claim.json");
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0 ||
                    (File.GetAttributes(claim) & FileAttributes.ReparsePoint) != 0 || new FileInfo(claim).Length > 4096)
                { return false; }
                using JsonDocument record = JsonDocument.Parse(File.ReadAllText(claim));
                return record.RootElement.GetProperty("runId").GetString() == Id &&
                    record.RootElement.GetProperty("state").GetString() == "stopped" &&
                    record.RootElement.GetProperty("cleanupSucceeded").ValueKind == JsonValueKind.True;
            }
            catch { return false; }
        }

        private static JsonElement Parse(string json)
        {
            using JsonDocument document = JsonDocument.Parse(json);
            return document.RootElement.Clone();
        }

        private static string RequiredText(JsonElement source, string property, int maximumBytes)
        {
            JsonElement value = source.GetProperty(property);
            if (value.ValueKind != JsonValueKind.String) { throw new InvalidDataException("Invalid child string field."); }
            string result = value.GetString()!;
            if (Encoding.UTF8.GetByteCount(result) > maximumBytes) { throw new InvalidDataException("Child string field exceeds its limit."); }
            return result;
        }

        private sealed class RunFailure : Exception
        {
            internal RunFailure(string code) : base("Child continuation refused.") { Code = code; }
            internal string Code { get; }
        }

        /// <summary>Stops authority and waits only for the bounded cleanup period.</summary>
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
            if (!Completion.IsCompleted) { Stop(); }
            _ = Completion.Wait(_policy.GetProperty("cleanupSeconds").GetInt32() * 1000);
            _authority.Dispose();
        }
    }
}
