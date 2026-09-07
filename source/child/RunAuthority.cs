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
    /// <summary>Single-child, narrowing-only authority and one-use action approval.</summary>
    public sealed class RunAuthority : IDisposable
    {
        private readonly object _sync = new object();
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly string _launch;
        private readonly string _conversation;
        private readonly string _parentTurn;
        private readonly string _child;
        private readonly string _policyDigest;
        private readonly bool _file;
        private readonly bool _terminal;
        private readonly bool _writable;
        private readonly int _duration;
        private readonly int _approvalSeconds;
        private readonly HashSet<string> _requests = new HashSet<string>(StringComparer.Ordinal);
        private readonly HashSet<string> _received = new HashSet<string>(StringComparer.Ordinal);
        private readonly CancellationTokenSource _cancel = new CancellationTokenSource();
        private readonly Timer _deadline;
        private int _closed;
        private long _generation = 1;
        private string _reason = string.Empty;
        private string? _request;
        private string? _approvalId;
        private string? _fingerprint;
        private string? _pendingJson;
        private long _approvalExpires;
        private TaskCompletionSource<bool>? _decision;
        private bool _decided;
        private bool _consumed;

        /// <summary>Freezes all identities and scope before any capture or execution.</summary>
        public RunAuthority(string launch, string conversation, string parentTurn, string child,
            string policyDigest, bool file, bool terminal, bool writable, int durationSeconds, int approvalSeconds)
        {
            foreach (string identity in new[] { launch, conversation, parentTurn, child })
            {
                if (string.IsNullOrWhiteSpace(identity) || identity.Length > 128)
                { throw new ArgumentException("Invalid child authority identity."); }
            }
            if (!System.Text.RegularExpressions.Regex.IsMatch(policyDigest, "^[a-f0-9]{64}$") ||
                durationSeconds < 1 || durationSeconds > 600 || approvalSeconds < 1 || approvalSeconds > 120)
            { throw new ArgumentException("Invalid child authority limits."); }
            _launch = launch; _conversation = conversation; _parentTurn = parentTurn; _child = child;
            _policyDigest = policyDigest; _file = file; _terminal = terminal; _writable = writable;
            _duration = durationSeconds; _approvalSeconds = approvalSeconds;
            _deadline = new Timer(_ => Close("duration-limit"), null, durationSeconds * 1000, Timeout.Infinite);
        }

        /// <summary>Cancellation shared by all complete-run waits.</summary>
        public CancellationToken Cancellation => _cancel.Token;
        /// <summary>Whether any new work can be admitted.</summary>
        public bool Open => Volatile.Read(ref _closed) == 0 && _clock.Elapsed.TotalSeconds < _duration;
        /// <summary>First terminal cause, never overwritten by cleanup errors.</summary>
        public string Reason => Volatile.Read(ref _reason);
        /// <summary>Current approval facts as untrusted display data, without any execution authority.</summary>
        public string? PendingApproval { get { if (!Open) { return null; } lock (_sync) { return Open && !_decided && !_consumed ? _pendingJson : null; } } }
        /// <summary>Complete-run monotonic time remaining.</summary>
        public int RemainingMilliseconds => Math.Max(0, _duration * 1000 - (int)_clock.ElapsedMilliseconds);

        /// <summary>Refuses unavailable authority before an effect.</summary>
        public void Ensure(string operation)
        {
            lock (_sync)
            {
                if (!Open || (operation == "read" && !_file) ||
                    (operation == "write" && (!_file || !_writable)) || (operation == "terminal" && !_terminal) ||
                    (operation != "read" && operation != "write" && operation != "terminal" && operation != "provider" && operation != "export"))
                { throw new InvalidOperationException("Child authority is unavailable."); }
            }
        }

        /// <summary>Prepares one exact action without executing it or inheriting any prior grant.</summary>
        public string Prepare(string requestId, string operation, string actionJson)
        {
            lock (_sync)
            {
                Ensure(operation);
                if (operation != "write" && operation != "terminal") { throw new InvalidDataException("Unsupported child approval action."); }
                if (_requests.Count >= 256 || string.IsNullOrEmpty(requestId) || requestId.Length > 128 ||
                    _requests.Contains(requestId) || (_decision != null && !_consumed))
                { throw new InvalidOperationException("Stale or overlapping child approval."); }
                if (Encoding.UTF8.GetByteCount(actionJson) > 8192) { throw new InvalidDataException("Approval facts exceed their byte limit."); }
                using JsonDocument action = JsonDocument.Parse(actionJson, new JsonDocumentOptions { MaxDepth = 8 });
                if (action.RootElement.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Invalid approval facts."); }
                _requests.Add(requestId);
                _request = requestId;
                _approvalId = Guid.NewGuid().ToString("N");
                _approvalExpires = Math.Min(_duration * 1000L, _clock.ElapsedMilliseconds + _approvalSeconds * 1000L);
                byte[] identity = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    launchId = _launch, conversationId = _conversation, parentTurnId = _parentTurn, childId = _child,
                    attempt = 1, generation = _generation, requestId, approvalId = _approvalId, policyDigest = _policyDigest,
                    operation, action = action.RootElement
                });
                _fingerprint = Convert.ToHexString(SHA256.HashData(identity)).ToLowerInvariant();
                _pendingJson = JsonSerializer.Serialize(new
                {
                    id = _approvalId, fingerprint = _fingerprint, launchId = _launch, conversationId = _conversation,
                    parentTurnId = _parentTurn, childId = _child, requestId, attempt = 1, generation = _generation,
                    profile = "single-child-v3", budgetMode = "provider-estimate", policyDigest = _policyDigest,
                    operation, action = action.RootElement,
                    expiresUtc = DateTime.UtcNow.AddMilliseconds(_approvalExpires - _clock.ElapsedMilliseconds)
                });
                _decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                _decided = false;
                _consumed = false;
                return _pendingJson;
            }
        }

        /// <summary>Accepts one exact window answer; cross-run, expired and replayed answers do nothing.</summary>
        public bool Submit(string conversation, string child, string approvalId, string fingerprint, bool approved)
        {
            lock (_sync)
            {
                if (!Open || _decision == null || _decided || _consumed || _clock.ElapsedMilliseconds >= _approvalExpires ||
                    conversation != _conversation || child != _child || approvalId != _approvalId || fingerprint != _fingerprint)
                { return false; }
                _decided = true;
                return _decision.TrySetResult(approved);
            }
        }

        /// <summary>Waits only within the approval and complete-run deadlines.</summary>
        public async Task<bool> WaitForDecisionAsync()
        {
            Task<bool> pending;
            int milliseconds;
            lock (_sync)
            {
                if (_decision == null || !Open) { return false; }
                pending = _decision.Task;
                milliseconds = (int)Math.Max(1, _approvalExpires - _clock.ElapsedMilliseconds);
            }
            try { return await pending.WaitAsync(TimeSpan.FromMilliseconds(milliseconds), _cancel.Token).ConfigureAwait(false); }
            catch (Exception error) when (error is TimeoutException || error is OperationCanceledException)
            {
                lock (_sync) { _decided = true; _decision?.TrySetResult(false); }
                return false;
            }
        }

        /// <summary>Consumes a positive decision exactly once immediately before committed dispatch.</summary>
        public bool Consume(string requestId, string fingerprint)
        {
            lock (_sync)
            {
                if (!Open || _decision == null || !_decided || _consumed || requestId != _request || fingerprint != _fingerprint)
                { return false; }
                _consumed = true;
                return _clock.ElapsedMilliseconds < _approvalExpires && _decision.Task.IsCompletedSuccessfully && _decision.Task.Result;
            }
        }

        internal void Commit(string operation, Action dispatch)
        {
            lock (_sync) { Ensure(operation); dispatch(); }
        }

        /// <summary>Admits each authenticated child request identity once within a fixed message bound.</summary>
        public void AdmitRequest(string requestId)
        {
            lock (_sync)
            {
                Ensure("provider");
                if (!System.Text.RegularExpressions.Regex.IsMatch(requestId, "^[a-f0-9]{32}$") ||
                    _received.Count >= 256 || !_received.Add(requestId))
                { throw new InvalidDataException("Stale or excessive child requests were refused."); }
            }
        }

        /// <summary>Live Permissions can revoke captured authority but cannot widen it.</summary>
        public void UpdatePermissions(bool file, bool terminal, bool enabled) => UpdatePermissions(file, terminal, enabled, true);

        /// <summary>Also revokes private write access independently of File Permission.</summary>
        public void UpdatePermissions(bool file, bool terminal, bool enabled, bool writable)
        {
            if (!enabled || (_file && !file) || (_terminal && !terminal) || (_writable && !writable)) { Close("permission-revoked"); }
        }

        /// <summary>Closes admission and releases waits before any resource cleanup starts.</summary>
        public void Close(string reason)
        {
            if (Interlocked.CompareExchange(ref _closed, 1, 0) != 0) { return; }
            Volatile.Write(ref _reason, reason);
            Interlocked.Increment(ref _generation);
            _cancel.Cancel();
            Volatile.Read(ref _decision)?.TrySetResult(false);
        }

        /// <summary>Withdraws authority and its independent deadline.</summary>
        public void Dispose() { Close("stopped"); _deadline.Dispose(); }
    }
}
