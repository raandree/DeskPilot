#nullable enable
using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>Bounded complete JSON messages over replay-resistant authenticated frames.</summary>
    public sealed class MessageChannel : IDisposable
    {
        private readonly AuthenticatedChannel _channel;
        private readonly int _maximum;
        private readonly object _sendLock = new object();
        private readonly SemaphoreSlim _receiveLock = new SemaphoreSlim(1, 1);
        private readonly UTF8Encoding _encoding = new UTF8Encoding(false, true);

        /// <summary>Creates an independently owned channel with a complete-message bound.</summary>
        public MessageChannel(Stream input, Stream output, byte[] key, bool host, int maximumBytes)
        {
            if (maximumBytes < 64 || maximumBytes > 4 * 1024 * 1024) { throw new ArgumentOutOfRangeException(nameof(maximumBytes)); }
            _maximum = maximumBytes;
            _channel = new AuthenticatedChannel(input, output, key, host, 16384);
        }

        /// <summary>Validates the whole message before writing any frames.</summary>
        public void Send(string message)
        {
            if (_encoding.GetByteCount(message) > _maximum) { throw new InvalidDataException("Complete IPC message limit exceeded."); }
            byte[] bytes = _encoding.GetBytes(message);
            AuthenticatedChannel.ValidateJson(bytes);
            lock (_sendLock)
            {
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int length = Math.Min(8192, bytes.Length - offset);
                    bool last = offset + length == bytes.Length;
                    _channel.Send(JsonSerializer.Serialize(new { type = "chunk", data = Convert.ToBase64String(bytes, offset, length), last }));
                    offset += length;
                }
            }
        }

        /// <summary>Receives one complete bounded JSON object.</summary>
        public string Receive() => ReceiveAsync(CancellationToken.None).GetAwaiter().GetResult();

        /// <summary>Receives with independent cancellation and a bounded number of chunks.</summary>
        public async Task<string> ReceiveAsync(CancellationToken cancellationToken)
        {
            await _receiveLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                using var assembled = new MemoryStream();
                for (int frame = 0; frame <= _maximum / 8192; frame++)
                {
                    using JsonDocument chunk = JsonDocument.Parse(await _channel.ReceiveAsync(cancellationToken).ConfigureAwait(false));
                    JsonElement root = chunk.RootElement;
                    int properties = 0;
                    foreach (JsonProperty property in root.EnumerateObject()) { properties++; }
                    if (properties != 3 || root.GetProperty("type").GetString() != "chunk") { throw new InvalidDataException("Invalid IPC chunk."); }
                    byte[] data = root.GetProperty("data").GetBytesFromBase64();
                    bool last = root.GetProperty("last").GetBoolean();
                    if (data.Length < 1 || data.Length > 8192 || (!last && data.Length != 8192) || assembled.Length + data.Length > _maximum)
                    { throw new InvalidDataException("Invalid IPC chunk size."); }
                    assembled.Write(data, 0, data.Length);
                    if (last)
                    {
                        byte[] bytes = assembled.ToArray();
                        AuthenticatedChannel.ValidateJson(bytes);
                        return _encoding.GetString(bytes);
                    }
                }
                throw new InvalidDataException("IPC chunk count exceeded.");
            }
            catch { _channel.Dispose(); throw; }
            finally { _receiveLock.Release(); }
        }

        /// <summary>Closes owned streams and clears channel authentication material.</summary>
        public void Dispose() => _channel.Dispose();
    }
}
