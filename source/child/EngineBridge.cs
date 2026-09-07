#nullable enable
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>Per-process Engine RPC with a control reader independent of its Runspace.</summary>
    public sealed class EngineBridge : IDisposable
    {
        private readonly MessageChannel _channel;
        private readonly Timer _lease;
        private readonly int _leaseMilliseconds;
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly object _sync = new object();
        private readonly TaskCompletionSource<string> _configuration = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        private TaskCompletionSource<string>? _pending;
        private string? _pendingId;
        private long _renewed;
        private int _disposed;

        /// <summary>One bridge owned by this fresh Engine process.</summary>
        public static EngineBridge? Current { get; private set; }

        private EngineBridge(MessageChannel channel, int leaseSeconds)
        {
            _channel = channel;
            _leaseMilliseconds = checked(leaseSeconds * 1000);
            _lease = new Timer(_ =>
            {
                if (Volatile.Read(ref _disposed) == 0 && _clock.ElapsedMilliseconds - Interlocked.Read(ref _renewed) > _leaseMilliseconds)
                { Terminate(); }
            }, null, 100, 100);
            _ = Task.Run(ReadControlAsync);
        }

        /// <summary>Reads a per-run key only from owned stdin, then starts control supervision.</summary>
        public static EngineBridge Start(int leaseSeconds, int maximumBytes)
        {
            if (leaseSeconds < 1 || leaseSeconds > 30) { throw new ArgumentOutOfRangeException(nameof(leaseSeconds)); }
            using var startup = new Timer(_ => Terminate(), null, leaseSeconds * 1000, Timeout.Infinite);
            Stream input = Console.OpenStandardInput();
            Stream output = Console.OpenStandardOutput();
            byte[] key = new byte[32];
            input.ReadExactly(key);
            var channel = new MessageChannel(input, output, key, false, maximumBytes);
            CryptographicOperations.ZeroMemory(key);
            if (Current != null) { throw new InvalidOperationException("An Engine bridge already exists."); }
            Current = new EngineBridge(channel, leaseSeconds);
            channel.Send("{\"type\":\"ready\"}");
            return Current;
        }

        /// <summary>Host-owned immutable launch configuration.</summary>
        public string Configuration => _configuration.Task.GetAwaiter().GetResult();

        /// <summary>Requests a provider call or confined Tool operation and awaits its correlated reply.</summary>
        public string Invoke(string kind, string payload)
        {
            if (kind != "provider" && kind != "tool") { throw new InvalidDataException("Unsupported Engine request kind."); }
            using JsonDocument document = JsonDocument.Parse(payload);
            TaskCompletionSource<string> response;
            string id = Guid.NewGuid().ToString("N");
            lock (_sync)
            {
                if (_pending != null || Volatile.Read(ref _disposed) != 0) { throw new InvalidOperationException("Engine request unavailable."); }
                response = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
                _pending = response;
                _pendingId = id;
            }
            _channel.Send(JsonSerializer.Serialize(new { type = kind, id, payload = document.RootElement }));
            return response.Task.GetAwaiter().GetResult();
        }

        /// <summary>Returns a bounded final result as data, never a control instruction.</summary>
        public void Complete(string result)
        {
            using JsonDocument document = JsonDocument.Parse(result);
            _channel.Send(JsonSerializer.Serialize(new { type = "complete", result = document.RootElement }));
        }

        private async Task ReadControlAsync()
        {
            try
            {
                while (Volatile.Read(ref _disposed) == 0)
                {
                    using JsonDocument document = JsonDocument.Parse(await _channel.ReceiveAsync(CancellationToken.None).ConfigureAwait(false));
                    JsonElement root = document.RootElement;
                    switch (root.GetProperty("type").GetString())
                    {
                        case "renew":
                            Interlocked.Exchange(ref _renewed, _clock.ElapsedMilliseconds);
                            break;
                        case "configure":
                            if (!_configuration.TrySetResult(root.GetProperty("configuration").GetRawText()))
                            { throw new InvalidDataException("Duplicate configuration."); }
                            break;
                        case "reply":
                            lock (_sync)
                            {
                                if (_pending == null || root.GetProperty("id").GetString() != _pendingId)
                                { throw new InvalidDataException("Stale or mismatched reply."); }
                                TaskCompletionSource<string> pending = _pending;
                                _pending = null;
                                _pendingId = null;
                                pending.SetResult(root.GetProperty("payload").GetRawText());
                            }
                            break;
                        case "stop":
                            Terminate();
                            break;
                        default:
                            throw new InvalidDataException("Unsupported host control.");
                    }
                }
            }
            catch
            {
                if (Volatile.Read(ref _disposed) == 0) { Terminate(); }
            }
        }

        private static void Terminate()
        {
            if (OperatingSystem.IsWindows()) { ExitProcess(125); }
            else if (OperatingSystem.IsLinux()) { ExitUnix(125); }
            else { Environment.FailFast("Unsupported child runtime platform."); }
        }

        [DllImport("kernel32.dll")]
        private static extern void ExitProcess(uint exitCode);

        [DllImport("libc", EntryPoint = "_exit")]
        private static extern void ExitUnix(int exitCode);

        /// <summary>Closes the channel and withdraws supervision only after the process has completed.</summary>
        public void Dispose()
        {
            Interlocked.Exchange(ref _disposed, 1);
            _lease.Dispose();
            _channel.Dispose();
        }
    }
}
