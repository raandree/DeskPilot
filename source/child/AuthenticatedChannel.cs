#nullable enable
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    /// <summary>Length-bounded, direction-bound, replay-resistant per-run IPC.</summary>
    public sealed class AuthenticatedChannel : IDisposable
    {
        private readonly Stream _input;
        private readonly Stream _output;
        private readonly byte[] _key;
        private readonly bool _host;
        private readonly int _limit;
        private readonly object _sendLock = new object();
        private readonly SemaphoreSlim _receiveLock = new SemaphoreSlim(1, 1);
        private readonly UTF8Encoding _encoding = new UTF8Encoding(false, true);
        private ulong _sent;
        private ulong _received;
        private int _closed;

        /// <summary>Creates a channel over independently owned process streams.</summary>
        public AuthenticatedChannel(Stream input, Stream output, byte[] key, bool host, int payloadLimit)
        {
            if (key == null || key.Length != 32) { throw new ArgumentException("A 256-bit per-run key is required."); }
            if (payloadLimit < 64 || payloadLimit > 65536) { throw new ArgumentOutOfRangeException(nameof(payloadLimit)); }
            _input = input ?? throw new ArgumentNullException(nameof(input));
            _output = output ?? throw new ArgumentNullException(nameof(output));
            _key = (byte[])key.Clone();
            _host = host;
            _limit = payloadLimit;
        }

        /// <summary>Writes one complete authenticated record.</summary>
        public void Send(string message)
        {
            ThrowIfClosed();
            int length = _encoding.GetByteCount(message);
            if (length > _limit) { throw new InvalidDataException("The IPC payload limit was exceeded."); }
            byte[] payload = _encoding.GetBytes(message);
            ValidateJson(payload);
            lock (_sendLock)
            {
                ThrowIfClosed();
                ulong sequence = checked(_sent + 1);
                var frame = new byte[4 + 8 + payload.Length + 32];
                BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(0, 4), frame.Length - 4);
                BinaryPrimitives.WriteUInt64BigEndian(frame.AsSpan(4, 8), sequence);
                payload.CopyTo(frame, 12);
                byte[] tag = Authenticate(_host ? (byte)1 : (byte)2, frame.AsSpan(4, 8 + payload.Length));
                tag.CopyTo(frame, 12 + payload.Length);
                try
                {
                    _output.Write(frame, 0, frame.Length);
                    _output.Flush();
                    _sent = sequence;
                }
                catch
                {
                    Interlocked.Exchange(ref _closed, 1);
                    throw;
                }
            }
        }

        /// <summary>Receives one record or refuses the channel.</summary>
        public string Receive() => ReceiveAsync(CancellationToken.None).GetAwaiter().GetResult();

        /// <summary>Receives with cancellation without blocking control threads.</summary>
        public async Task<string> ReceiveAsync(CancellationToken cancellationToken)
        {
            ThrowIfClosed();
            await _receiveLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                ThrowIfClosed();
                var header = new byte[4];
                await ReadExactlyAsync(header, cancellationToken).ConfigureAwait(false);
                int length = BinaryPrimitives.ReadInt32BigEndian(header);
                if (length < 42 || length > _limit + 40)
                {
                    throw new InvalidDataException("The IPC frame limit was exceeded or the length was invalid.");
                }
                var frame = new byte[length];
                await ReadExactlyAsync(frame, cancellationToken).ConfigureAwait(false);
                byte[] tag = Authenticate(_host ? (byte)2 : (byte)1, frame.AsSpan(0, length - 32));
                if (!CryptographicOperations.FixedTimeEquals(tag, frame.AsSpan(length - 32)))
                {
                    throw new InvalidDataException("IPC authentication failed.");
                }
                ulong sequence = BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(0, 8));
                if (sequence != checked(_received + 1))
                {
                    throw new InvalidDataException("The IPC sequence is stale, duplicated or out of order.");
                }
                ReadOnlyMemory<byte> payload = frame.AsMemory(8, length - 40);
                ValidateJson(payload);
                string message = _encoding.GetString(payload.Span);
                _received = sequence;
                return message;
            }
            catch
            {
                Interlocked.Exchange(ref _closed, 1);
                throw;
            }
            finally { _receiveLock.Release(); }
        }

        private byte[] Authenticate(byte direction, ReadOnlySpan<byte> record)
        {
            var authenticated = new byte[record.Length + 2];
            authenticated[0] = 1;
            authenticated[1] = direction;
            record.CopyTo(authenticated.AsSpan(2));
            return HMACSHA256.HashData(_key, authenticated);
        }

        private async Task ReadExactlyAsync(byte[] buffer, CancellationToken cancellationToken)
        {
            int offset = 0;
            while (offset < buffer.Length)
            {
                int received = await _input.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
                if (received == 0) { throw new EndOfStreamException("The owned IPC channel closed."); }
                offset += received;
            }
        }

        private static void ValidateJson(ReadOnlyMemory<byte> payload)
        {
            using JsonDocument document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 24 });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException("An IPC record must be a JSON object.");
            }
            RejectDuplicateProperties(document.RootElement);
        }

        private static void RejectDuplicateProperties(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.Object)
            {
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (JsonProperty property in value.EnumerateObject())
                {
                    if (!names.Add(property.Name)) { throw new InvalidDataException("Duplicate IPC properties are refused."); }
                    RejectDuplicateProperties(property.Value);
                }
            }
            else if (value.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement item in value.EnumerateArray()) { RejectDuplicateProperties(item); }
            }
        }

        private void ThrowIfClosed()
        {
            if (Volatile.Read(ref _closed) != 0) { throw new InvalidOperationException("The IPC channel is closed."); }
        }

        /// <summary>Closes owned streams and clears the per-run authentication key.</summary>
        public void Dispose()
        {
            Interlocked.Exchange(ref _closed, 1);
            _input.Dispose();
            _output.Dispose();
            CryptographicOperations.ZeroMemory(_key);
        }
    }
}
