#nullable enable
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>Host-owned message framing and independent per-process lease renewal.</summary>
    public sealed class HostBridge : IDisposable
    {
        private readonly MessageChannel _channel;
        private readonly Timer _renewal;
        private readonly CancellationTokenSource _cancel = new CancellationTokenSource();
        private int _disposed;

        /// <summary>Initializes a unique authenticated connection over already owned process streams.</summary>
        public HostBridge(Stream input, Stream output, int leaseSeconds, int maximumBytes)
        {
            if (leaseSeconds < 1 || leaseSeconds > 30) { throw new ArgumentOutOfRangeException(nameof(leaseSeconds)); }
            byte[] key = RandomNumberGenerator.GetBytes(32);
            _channel = new MessageChannel(input, output, key, true, maximumBytes);
            try { output.Write(key); output.Flush(); }
            finally { CryptographicOperations.ZeroMemory(key); }
            _renewal = new Timer(_ =>
            {
                try { if (Volatile.Read(ref _disposed) == 0) { _channel.Send("{\"type\":\"renew\"}"); } }
                catch { _cancel.Cancel(); }
            }, null, 0, Math.Max(100, leaseSeconds * 1000 / 3));
            try
            {
                using var startup = new CancellationTokenSource(30000);
                using JsonDocument response = JsonDocument.Parse(_channel.ReceiveAsync(startup.Token).GetAwaiter().GetResult());
                if (response.RootElement.GetProperty("type").GetString() != "ready")
                { throw new InvalidDataException("The owned process did not acknowledge startup."); }
            }
            catch { Dispose(); throw; }
        }

        /// <summary>Sends the trusted launch configuration once; the peer rejects repeats.</summary>
        public void Configure(string configuration)
        {
            using JsonDocument document = JsonDocument.Parse(configuration);
            _channel.Send(JsonSerializer.Serialize(new { type = "configure", configuration = document.RootElement }));
        }

        /// <summary>Replies only to one authenticated peer request id.</summary>
        public void Reply(string id, string payload)
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(id, "^[a-f0-9]{32}$")) { throw new InvalidDataException("Invalid host reply identity."); }
            using JsonDocument document = JsonDocument.Parse(payload);
            _channel.Send(JsonSerializer.Serialize(new { type = "reply", id, payload = document.RootElement }));
        }

        /// <summary>Receives one bounded message with caller and connection cancellation.</summary>
        public async Task<string> ReceiveAsync(CancellationToken cancellationToken)
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _cancel.Token);
            return await _channel.ReceiveAsync(linked.Token).ConfigureAwait(false);
        }

        /// <summary>Withdraws authority renewal without relying on the peer Runspace.</summary>
        public void WithdrawLease() => _renewal.Dispose();

        /// <summary>Closes the connection after owned-process termination.</summary>
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
            _renewal.Dispose();
            _cancel.Cancel();
            _channel.Dispose();
        }
    }
}
