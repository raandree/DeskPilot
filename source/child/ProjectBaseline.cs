#nullable enable
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace DeskPilot.Child
{
    /// <summary>Immutable selected Project bytes and their provenance.</summary>
    public sealed class BaselineEntry
    {
        private readonly byte[] _bytes;

        internal BaselineEntry(string path, byte[] bytes)
        {
            Path = path;
            _bytes = bytes;
            Sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        }

        /// <summary>Selected Project-relative path.</summary>
        public string Path { get; }

        /// <summary>Digest of the captured bytes.</summary>
        public string Sha256 { get; }

        /// <summary>Captured byte count.</summary>
        public long Length => _bytes.LongLength;

        /// <summary>Returns an independent copy of the captured bytes.</summary>
        public byte[] GetBytes() => (byte[])_bytes.Clone();

        /// <summary>Copies captured bytes to a caller-owned bounded stream.</summary>
        public void CopyTo(Stream destination) => destination.Write(_bytes, 0, _bytes.Length);
    }

    /// <summary>Owns stable Windows handles for an explicitly selected baseline.</summary>
    public sealed class ProjectBaseline : IDisposable
    {
        private static readonly Regex JsonCredentialKeyNormalizer =
            new Regex("[^A-Za-z0-9]+", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private readonly List<SafeFileHandle> _handles = new List<SafeFileHandle>();
        private readonly Dictionary<string, SafeFileHandle> _directories =
            new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
        private readonly List<BaselineEntry> _entries = new List<BaselineEntry>();
        private uint? _volume;
        private bool _disposed;

        private ProjectBaseline()
        {
            Entries = _entries.AsReadOnly();
        }

        /// <summary>The immutable captured entries in canonical path order.</summary>
        public ReadOnlyCollection<BaselineEntry> Entries { get; }

        /// <summary>Total captured bytes, including every selected input.</summary>
        public long TotalBytes { get; private set; }

        /// <summary>Creates owned control directories through pinned, non-reparse ancestors.</summary>
        public static ProjectBaseline CreateControlDirectory(string directory)
        {
            if (!OperatingSystem.IsWindows() || string.IsNullOrWhiteSpace(directory) ||
                !Regex.IsMatch(directory, @"^[A-Za-z]:[\\/]"))
            {
                throw new PlatformNotSupportedException("Child control storage requires a local Windows path.");
            }
            string full = System.IO.Path.GetFullPath(directory).TrimEnd('\\');
            var missing = new Stack<string>();
            string existing = full;
            while (!Directory.Exists(existing))
            {
                missing.Push(existing);
                existing = System.IO.Path.GetDirectoryName(existing) ??
                    throw new IOException("The control storage ancestor is unavailable.");
            }
            var ownership = new ProjectBaseline();
            try
            {
                ownership.PinDirectory(existing);
                while (missing.Count > 0)
                {
                    string next = missing.Pop();
                    Directory.CreateDirectory(next);
                    ownership.PinDirectory(next);
                }
                return ownership;
            }
            catch { ownership.Dispose(); throw; }
        }

        /// <summary>Captures selected files without changing files or Git state.</summary>
        public static ProjectBaseline Open(
            string project, string[] selectedPaths, long byteLimit, int fileLimit)
        {
            if (!OperatingSystem.IsWindows())
            {
                throw new PlatformNotSupportedException("Stable selected Project capture requires Windows.");
            }
            if (byteLimit < 1 || byteLimit > 67108864 || fileLimit < 1 || fileLimit > 4000 ||
                selectedPaths == null || selectedPaths.Length == 0 || selectedPaths.Length > fileLimit)
            {
                throw new InvalidOperationException("The selected baseline exceeds its supported limit.");
            }
            if (string.IsNullOrWhiteSpace(project) || !Regex.IsMatch(project, @"^[A-Za-z]:[\\/]"))
            {
                throw new InvalidOperationException("The selected Project must use a local absolute path.");
            }
            string root = System.IO.Path.GetFullPath(project).TrimEnd('\\', '/');
            if (root.Length < 4 || root.Equals(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("The selected Project cannot be a drive root or home directory.");
            }

            var normalized = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string selected in selectedPaths)
            {
                string relative = ValidateRelativePath(selected);
                if (!normalized.Add(relative))
                {
                    throw new InvalidOperationException("Duplicate selected paths or case aliases are not supported.");
                }
            }

            var baseline = new ProjectBaseline();
            try
            {
                baseline.PinDirectory(root);
                var files = new List<(string Relative, string Full, SafeFileHandle Handle, int Length)>();
                foreach (string relative in normalized)
                {
                    string full = System.IO.Path.Combine(root, relative.Replace('/', '\\'));
                    baseline.PinDirectory(System.IO.Path.GetDirectoryName(full)!);
                    SafeFileHandle handle = baseline.OpenStable(full, false);
                    FileInformation information = ReadInformation(handle);
                    if (information.NumberOfLinks != 1)
                    {
                        throw new InvalidOperationException("A selected file has a hard link.");
                    }
                    RejectStreams(full);
                    ulong length = ((ulong)information.SizeHigh << 32) | information.SizeLow;
                    if (length > (ulong)(byteLimit - baseline.TotalBytes))
                    {
                        throw new InvalidOperationException("The selected baseline byte limit was exceeded.");
                    }
                    baseline.TotalBytes += (long)length;
                    files.Add((relative, full, handle, (int)length));
                }

                foreach (var file in files)
                {
                    var bytes = new byte[file.Length];
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        int count = RandomAccess.Read(file.Handle, bytes.AsSpan(offset), offset);
                        if (count == 0) { throw new IOException("The selected file was not stable during capture."); }
                        offset += count;
                    }
                    FileInformation after = ReadInformation(file.Handle);
                    ulong finalLength = ((ulong)after.SizeHigh << 32) | after.SizeLow;
                    if (finalLength != (ulong)file.Length || after.NumberOfLinks != 1)
                    {
                        throw new IOException("The selected file was not stable during capture.");
                    }
                    RejectStreams(file.Full);
                    RejectCredentialContent(file.Relative, bytes);
                    baseline._entries.Add(new BaselineEntry(file.Relative, bytes));
                }
                return baseline;
            }
            catch
            {
                baseline.Dispose();
                throw;
            }
        }

        /// <summary>Validates the portable, non-credential selected path profile.</summary>
        public static string ValidateRelativePath(string selected)
        {
            if (string.IsNullOrWhiteSpace(selected) || selected.Length > 1024 ||
                selected.StartsWith('/') || selected.StartsWith('\\') || selected.Contains(':'))
            {
                throw new InvalidOperationException("An invalid selected relative path was refused.");
            }
            string relative = selected.Replace('\\', '/');
            string[] segments = relative.Split('/');
            foreach (string segment in segments)
            {
                if (segment.Length == 0 || segment.Length > 255 || segment == "." || segment == ".." ||
                    segment.EndsWith('.') || segment.EndsWith(' ') ||
                    Regex.IsMatch(segment, "[\\x00-\\x1f\\x7f<>:\"|?*]") ||
                    Regex.IsMatch(segment, @"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)", RegexOptions.IgnoreCase) ||
                    Regex.IsMatch(segment,
                        @"^(\.git|\.ssh|\.aws|\.azure|\.kube|\.kubeconfig|\.env(?:\..*)?|\.shellpilot-token|\.copilot-demo-token|\.npmrc|\.pypirc|(?:secrets?|credentials?|tokens?)(?:\..*)?|id_rsa|id_ed25519)$|\.(pfx|p12|key|pem|cer|crt|der|jks|keystore|kdbx|kubeconfig)$",
                        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                {
                    throw new InvalidOperationException("An unsafe selected path, credential file or Git metadata was refused.");
                }
            }
            return relative;
        }

        private static void RejectCredentialContent(string path, byte[] bytes)
        {
            string text = Encoding.UTF8.GetString(bytes);
            if (Regex.IsMatch(text,
                @"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*[^;\r\n]+",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)))
            {
                throw new InvalidDataException("Selected credential-bearing content was refused.");
            }
            if (!path.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) { return; }
            try
            {
                ReadOnlyMemory<byte> json = bytes;
                if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) { json = json.Slice(3); }
                using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 });
                RejectCredentialProperties(document.RootElement);
            }
            catch (JsonException)
            {
                throw new InvalidDataException("Selected JSON could not be checked for credential fields.");
            }
        }

        private static void RejectCredentialProperties(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.Object)
            {
                foreach (JsonProperty property in value.EnumerateObject())
                {
                    string name = JsonCredentialKeyNormalizer.Replace(property.Name, string.Empty).ToLowerInvariant();
                    if (name is "secret" or "secrets" or "credential" or "credentials" or "password" or "passwd" or "pwd" or
                        "token" or "tokens" or "accesstoken" or "refreshtoken" or "sessiontoken" or "githubtoken" or
                        "apikey" or "privatekey" or "clientsecret" or "authorization" or "cookie" or "cookies" or
                        "accountkey" or "sharedaccesskey" or "connectionstring" or "connectionstrings")
                    {
                        throw new InvalidDataException("Selected JSON contains a credential field.");
                    }
                    RejectCredentialProperties(property.Value);
                }
            }
            else if (value.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement item in value.EnumerateArray()) { RejectCredentialProperties(item); }
            }
        }

        private void PinDirectory(string directory)
        {
            if (_directories.ContainsKey(directory)) { return; }
            string? parent = System.IO.Path.GetDirectoryName(directory.TrimEnd('\\'));
            if (!string.IsNullOrEmpty(parent)) { PinDirectory(parent); }
            _directories.Add(directory, OpenStable(directory, true));
        }

        private SafeFileHandle OpenStable(string path, bool directory)
        {
            SafeFileHandle handle = CreateFileW(path, 0x80000000, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new IOException("A stable selected Project handle could not be acquired.", new Win32Exception(error));
            }
            _handles.Add(handle);
            FileInformation information = ReadInformation(handle);
            if ((information.Attributes & 0x400) != 0)
            {
                throw new InvalidOperationException("A selected Project reparse point was refused.");
            }
            if (GetFileType(handle) != 1 || ((information.Attributes & 0x10) != 0) != directory)
            {
                throw new InvalidOperationException("The selected Project contains an unsupported file type.");
            }
            if (_volume.HasValue && _volume.Value != information.Volume)
            {
                throw new InvalidOperationException("A selected Project nested volume was refused.");
            }
            _volume ??= information.Volume;
            var final = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, final, (uint)final.Capacity, 0);
            if (length == 0 || length >= final.Capacity)
            {
                throw new IOException("The stable selected path could not be verified.");
            }
            string resolved = final.ToString();
            if (resolved.StartsWith(@"\\?\", StringComparison.Ordinal)) { resolved = resolved.Substring(4); }
            if (!string.Equals(resolved.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("A selected path alias was refused.");
            }
            return handle;
        }

        private static FileInformation ReadInformation(SafeFileHandle handle)
        {
            if (!GetFileInformationByHandle(handle, out FileInformation information))
            {
                throw new IOException("A stable selected file identity could not be verified.");
            }
            return information;
        }

        private static void RejectStreams(string path)
        {
            IntPtr search = FindFirstStreamW(path, 0, out StreamInformation stream, 0);
            if (search == new IntPtr(-1))
            {
                throw new IOException("The selected file streams could not be verified.");
            }
            try
            {
                do
                {
                    if (!string.Equals(stream.Name, "::$DATA", StringComparison.Ordinal))
                    {
                        throw new InvalidOperationException("A selected alternate stream was refused.");
                    }
                } while (FindNextStreamW(search, out stream));
                if (Marshal.GetLastWin32Error() != 38)
                {
                    throw new IOException("The selected file stream enumeration was incomplete.");
                }
            }
            finally { FindClose(search); }
        }

        /// <summary>Releases capture locks; captured bytes remain immutable.</summary>
        public void Dispose()
        {
            if (_disposed) { return; }
            _disposed = true;
            for (int index = _handles.Count - 1; index >= 0; index--) { _handles[index].Dispose(); }
            _handles.Clear();
            _directories.Clear();
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetFileType(SafeFileHandle handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstStreamW(string path, int level, out StreamInformation information, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindNextStreamW(IntPtr search, out StreamInformation information);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindClose(IntPtr search);

        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created;
            public System.Runtime.InteropServices.ComTypes.FILETIME Accessed;
            public System.Runtime.InteropServices.ComTypes.FILETIME Written;
            public uint Volume;
            public uint SizeHigh;
            public uint SizeLow;
            public uint NumberOfLinks;
            public uint IndexHigh;
            public uint IndexLow;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StreamInformation
        {
            public long Size;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)]
            public string Name;
        }
    }
}
