#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Isolation
{
    public sealed class TerminalSession : IDisposable
    {
        private readonly string _docker;
        private readonly string _project;
        private readonly string _configurationDirectory;
        private readonly string _image;
        private readonly string _version;
        private readonly JsonDocument _policy;
        private readonly Dictionary<string, string> _environment = new Dictionary<string, string>();
        private readonly List<string> _secrets = new List<string>();
        private readonly CancellationTokenSource _cancellation = new CancellationTokenSource();
        private readonly HashSet<string> _changedFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private int _active;
        private bool _disposed;

        public bool Active => Volatile.Read(ref _active) != 0;
        public bool CleanupFailed { get; private set; }
        public string LastContainer { get; private set; } = string.Empty;
        public string[] FilesWritten
        {
            get
            {
                lock (_changedFiles)
                {
                    var paths = new string[_changedFiles.Count];
                    _changedFiles.CopyTo(paths);
                    return paths;
                }
            }
        }

        public TerminalSession(string docker, string project, string dataDirectory,
            string image, string version, string policyJson)
        {
            _docker = docker;
            _project = NormalizeProject(project);
            _image = image;
            _version = version;
            _policy = JsonDocument.Parse(policyJson);
            foreach (JsonElement entry in _policy.RootElement.GetProperty("environment").EnumerateArray())
            {
                string name = entry.GetProperty("name").GetString()!;
                string? value = Environment.GetEnvironmentVariable(name);
                if (value == null || value.Length > 4096)
                {
                    throw new InvalidOperationException("A selected environment variable is absent or exceeds its size limit: " + name);
                }
                _environment.Add(name, value);
                if (entry.GetProperty("secret").GetBoolean() && value.Length > 0) { _secrets.Add(value); }
            }
            string data = Path.GetFullPath(dataDirectory);
            RejectLinks(data);
            if (IsWithin(data, _project)) { throw new InvalidOperationException("The Project must not contain DeskPilot's control data."); }
            _configurationDirectory = Path.Combine(data, "terminal-client-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_configurationDirectory);
            File.WriteAllText(Path.Combine(_configurationDirectory, "config.json"), "{\"auths\":{}}", new UTF8Encoding(false));
        }

        public void Cancel()
        {
            if (!_disposed) { _cancellation.Cancel(); }
        }

        public string MapWorkingDirectory(string? requested)
        {
            string candidate = string.IsNullOrWhiteSpace(requested) ? _project : requested!;
            if (candidate == "/project") { candidate = _project; }
            else if (candidate.StartsWith("/project/", StringComparison.Ordinal))
            {
                candidate = Path.Combine(_project, candidate.Substring(9).Replace('/', Path.DirectorySeparatorChar));
            }
            else if (!Path.IsPathRooted(candidate)) { candidate = Path.Combine(_project, candidate); }
            candidate = Path.GetFullPath(candidate);
            if (!IsWithin(candidate, _project) || !Directory.Exists(candidate))
            {
                throw new InvalidOperationException("The working directory must be inside the selected Project.");
            }
            RejectLinks(candidate);
            string relative = Path.GetRelativePath(_project, candidate);
            return relative == "." ? "/project" : "/project/" + relative.Replace('\\', '/');
        }

        public string Run(string command, string? workingDirectory, int timeoutSeconds)
        {
            if (_disposed || _cancellation.IsCancellationRequested || CleanupFailed)
            {
                throw new InvalidOperationException("Isolated execution is stopped or requires cleanup.");
            }
            if (Interlocked.CompareExchange(ref _active, 1, 0) != 0)
            {
                throw new InvalidOperationException("An isolated command is already running.");
            }
            string name = "deskpilot-terminal-" + Guid.NewGuid().ToString("N");
            string proxy = name + "-proxy";
            LastContainer = name;
            NativeResult result = new NativeResult();
            bool creationUncertain = false;
            bool outOfMemory = false;
            string failure = string.Empty;
            bool proxyCreated = false;
            Dictionary<string, string>? before = null;
            var written = new List<string>();
            try
            {
                if (string.IsNullOrWhiteSpace(command) || command.Length > 2000)
                {
                    throw new InvalidOperationException("An isolated command must contain between 1 and 2000 characters.");
                }
                string directory = MapWorkingDirectory(workingDirectory);
                RejectLinks(_project);
                JsonElement policy = _policy.RootElement;
                string access = policy.GetProperty("projectAccess").GetString()!;
                if (access == "read-write") { before = CaptureProject(false); }
                string mount = "type=bind,source=" + _project + ",target=/project,bind-recursive=disabled";
                if (access == "read-only") { mount += ",readonly"; }
                string prologue = "$ErrorActionPreference = 'Stop'\n" +
                    "if (-not $IsLinux -or $PSVersionTable.PSVersion.ToString() -ne '" + _version + "') { throw 'Unexpected isolated runtime.' }\n" +
                    "foreach ($boundary in @('/mnt/host','/mnt/c','/mnt/d','/host_mnt','/run/desktop/mnt/host','/var/run/docker.sock','/run/docker.sock')) { if ([IO.Directory]::Exists($boundary) -or [IO.File]::Exists($boundary)) { throw 'Unexpected host access in isolated runtime.' } }\n";
                string network = "none";
                string certificate = string.Empty;
                if (policy.GetProperty("network").GetString() == "allow-list")
                {
                    proxyCreated = true;
                    certificate = StartProxy(proxy);
                    network = "container:" + proxy;
                }
                var arguments = new List<string>
                {
                    "create", "--pull", "never", "--name", name,
                    "--label", "io.deskpilot.terminal=1", "--label", "io.deskpilot.owner=" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture),
                    "--network", network, "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                    "--user", "10001:10001", "--init", "--ipc", "none", "--log-driver", "none",
                    "--memory", policy.GetProperty("memoryMB").GetInt32().ToString(CultureInfo.InvariantCulture) + "m",
                    "--memory-swap", policy.GetProperty("memoryMB").GetInt32().ToString(CultureInfo.InvariantCulture) + "m",
                    "--cpus", policy.GetProperty("cpuCount").GetDouble().ToString(CultureInfo.InvariantCulture),
                    "--pids-limit", policy.GetProperty("processLimit").GetInt32().ToString(CultureInfo.InvariantCulture),
                    "--ulimit", "core=0:0", "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=" + policy.GetProperty("tempMB").GetInt32().ToString(CultureInfo.InvariantCulture) + "m",
                    "--mount", mount, "--workdir", directory, "--env", "HOME=/tmp", "--env", "TMPDIR=/tmp",
                    "--env", "POWERSHELL_TELEMETRY_OPTOUT=1", "--env", "DOTNET_CLI_TELEMETRY_OPTOUT=1", "--env", "DOTNET_EnableDiagnostics=0"
                };
                if (access == "read-write" && (Directory.Exists(Path.Combine(_project, ".git")) || File.Exists(Path.Combine(_project, ".git"))))
                {
                    arguments.AddRange(new[] { "--mount", "type=bind,source=" + Path.Combine(_project, ".git") + ",target=/project/.git,readonly" });
                }
                foreach (string key in _environment.Keys) { arguments.AddRange(new[] { "--env", key }); }
                string command64 = Convert.ToBase64String(Encoding.Unicode.GetBytes(prologue + command));
                if (proxyCreated)
                {
                    foreach (string variable in new[] { "SSL_CERT_FILE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO", "REQUESTS_CA_BUNDLE" })
                    {
                        arguments.AddRange(new[] { "--env", variable + "=/tmp/deskpilot-ca.pem" });
                    }
                    foreach (string variable in new[] { "HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy" })
                    {
                        arguments.AddRange(new[] { "--env", variable + "=http://127.0.0.1:3128" });
                    }
                    arguments.AddRange(new[] { "--env", "NO_PROXY=", "--entrypoint", "/bin/sh", _image, "-c",
                        "/bin/cat /etc/ssl/certs/ca-certificates.crt > /tmp/deskpilot-ca.pem && /usr/bin/printf '%s' \"$1\" | /usr/bin/base64 --decode >> /tmp/deskpilot-ca.pem && exec /opt/microsoft/powershell/7/pwsh -NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand \"$2\"",
                        "deskpilot-command", certificate, command64 });
                }
                else
                {
                    arguments.AddRange(new[] { "--entrypoint", "/opt/microsoft/powershell/7/pwsh", _image,
                        "-NoLogo", "-NoProfile", "-NonInteractive", "-OutputFormat", "Text", "-EncodedCommand", command64 });
                }
                NativeResult created = Call(arguments, 30000, 65536, CancellationToken.None);
                creationUncertain = created.TimedOut || created.OutputLimit;
                if (created.ExitCode != 0 || creationUncertain) { throw new InvalidOperationException("Container creation failed: " + created.Error); }
                _cancellation.Token.ThrowIfCancellationRequested();
                int deadline = Math.Min(timeoutSeconds, policy.GetProperty("timeoutSeconds").GetInt32()) * 1000;
                result = Call(new[] { "start", "--attach", name }, deadline, policy.GetProperty("outputBytes").GetInt32(), _cancellation.Token, proxyCreated ? proxy : null);
                if (result.DependencyFailed) { failure = "The HTTPS boundary stopped; the command was terminated."; }
                NativeResult state = Call(new[] { "inspect", "--format", "{{json .State}}", name }, 5000, 65536, CancellationToken.None);
                if (state.ExitCode != 0) { throw new InvalidOperationException("The isolated command state could not be verified."); }
                using (JsonDocument status = JsonDocument.Parse(state.Output))
                {
                    outOfMemory = status.RootElement.GetProperty("OOMKilled").GetBoolean();
                    if (!result.TimedOut && !result.Cancelled && !result.OutputLimit && !result.DependencyFailed)
                    {
                        result.ExitCode = status.RootElement.GetProperty("ExitCode").GetInt32();
                    }
                }
            }
            catch (OperationCanceledException) { result.Cancelled = true; result.ExitCode = 125; }
            catch (Exception error) { failure = Redact(error.Message); result.ExitCode = -1; }
            finally
            {
                try
                {
                    Call(new[] { "rm", "--force", name }, 15000, 65536, CancellationToken.None);
                    if (proxyCreated) { Call(new[] { "rm", "--force", proxy }, 15000, 65536, CancellationToken.None); }
                    NativeResult remaining = Call(new[] { "ps", "--all", "--filter", "name=^/" + name + "$", "--format", "{{.ID}}" }, 5000, 65536, CancellationToken.None);
                    CleanupFailed = creationUncertain || remaining.ExitCode != 0 || !string.IsNullOrWhiteSpace(remaining.Output);
                    if (proxyCreated)
                    {
                        NativeResult proxyRemaining = Call(new[] { "ps", "--all", "--filter", "name=^/" + proxy + "$", "--format", "{{.ID}}" }, 5000, 65536, CancellationToken.None);
                        CleanupFailed |= proxyRemaining.ExitCode != 0 || !string.IsNullOrWhiteSpace(proxyRemaining.Output);
                    }
                }
                catch (Exception error) { CleanupFailed = true; failure = "Container cleanup could not be verified: " + Redact(error.Message); }
                if (before != null)
                {
                    try
                    {
                        Dictionary<string, string> after = CaptureProject(true);
                        foreach (KeyValuePair<string, string> entry in after)
                        {
                            if (!before.TryGetValue(entry.Key, out string? prior) || prior != entry.Value) { written.Add(entry.Key); }
                        }
                        foreach (string path in before.Keys) { if (!after.ContainsKey(path)) { written.Add(path); } }
                        lock (_changedFiles) { foreach (string path in written) { _changedFiles.Add(path); } }
                    }
                    catch (Exception error) { result.ExitCode = -1; failure = "Project change accounting failed: " + Redact(error.Message); }
                }
                Volatile.Write(ref _active, 0);
            }
            if (result.OutputLimit) { result.Output = string.Empty; result.Error = "The combined command output limit was exceeded."; }
            if (CleanupFailed) { result.ExitCode = -1; failure = "Isolated cleanup failed; further Isolated commands are blocked."; }
            return JsonSerializer.Serialize(new
            {
                exitCode = result.ExitCode, stdout = Redact(result.Output), stderr = Redact(result.Error),
                error = failure, timedOut = result.TimedOut, cancelled = result.Cancelled,
                outputLimitExceeded = result.OutputLimit, outOfMemory, cleanupSucceeded = !CleanupFailed,
                filesWritten = written,
                execution = new { mode = "isolated", network = _policy.RootElement.GetProperty("network").GetString(), projectAccess = _policy.RootElement.GetProperty("projectAccess").GetString() }
            });
        }

        private Dictionary<string, string> CaptureProject(bool allowNewLinks)
        {
            var snapshot = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var directories = new Stack<string>();
            directories.Push(_project);
            var clock = Stopwatch.StartNew();
            long bytes = 0;
            int entries = 0;
            while (directories.Count > 0)
            {
                string directory = directories.Pop();
                foreach (string path in Directory.EnumerateFileSystemEntries(directory))
                {
                    if (++entries > 50000 || clock.ElapsedMilliseconds > 15000)
                    {
                        throw new IOException("Read-write Project accounting is limited to 50000 entries and 15 seconds.");
                    }
                    string relative = Path.GetRelativePath(_project, path).Replace('\\', '/');
                    FileAttributes attributes = File.GetAttributes(path);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        if (!allowNewLinks) { throw new IOException("Read-write Projects must not contain symbolic links or junctions."); }
                        snapshot[relative] = "link:" + new FileInfo(path).LinkTarget;
                        continue;
                    }
                    if (string.Equals(relative, ".git", StringComparison.OrdinalIgnoreCase)) { continue; }
                    if ((attributes & FileAttributes.Directory) != 0) { directories.Push(path); continue; }
                    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    if (!GetFileInformationByHandle(stream.SafeFileHandle, out FileInformation information))
                    {
                        throw new IOException("A Project file identity could not be verified.");
                    }
                    if (information.NumberOfLinks != 1) { throw new IOException("Read-write Projects must not contain hard-linked files."); }
                    bytes += stream.Length;
                    if (stream.Length > 100L * 1024 * 1024 || bytes > 512L * 1024 * 1024)
                    {
                        throw new IOException("Read-write Project accounting is limited to 100 MiB per file and 512 MiB total.");
                    }
                    snapshot[relative] = Convert.ToHexString(SHA256.HashData(stream));
                }
            }
            return snapshot;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

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

        private string StartProxy(string name)
        {
            var hosts = new List<object>();
            foreach (JsonElement entry in _policy.RootElement.GetProperty("allowedHosts").EnumerateArray())
            {
                string hostname = entry.GetString()!;
                Task<IPAddress[]> resolve = Dns.GetHostAddressesAsync(hostname);
                if (!resolve.Wait(5000)) { throw new InvalidOperationException("An allowed HTTPS origin could not be resolved in time."); }
                var addresses = new List<string>();
                foreach (IPAddress address in resolve.Result)
                {
                    if (address.AddressFamily != AddressFamily.InterNetwork) { continue; }
                    if (!IsPublicAddress(address)) { throw new InvalidOperationException("An allowed HTTPS origin resolves to a non-public address."); }
                    addresses.Add(address.ToString());
                }
                if (addresses.Count == 0 || addresses.Count > 32) { throw new InvalidOperationException("The HTTPS origin has no supported bounded public address set."); }
                hosts.Add(new { name = hostname, addresses });
            }
            string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { hosts })));
            string startup = "/opt/microsoft/powershell/7/pwsh -NoLogo -NoProfile -NonInteractive -File /opt/deskpilot/Start-DpProxy.ps1 -PolicyBase64 \"$1\" && exec /usr/bin/setpriv --reuid=10002 --regid=10002 --clear-groups --bounding-set=-all --inh-caps=-all --ambient-caps=-all --no-new-privs /usr/sbin/squid -N -f /run/deskpilot/squid.conf";
            NativeResult created = Call(new[]
            {
                "run", "--detach", "--pull", "never", "--name", name,
                "--label", "io.deskpilot.terminal=1", "--label", "io.deskpilot.owner=" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture),
                "--network", "bridge", "--read-only", "--cap-drop", "ALL", "--cap-add", "NET_ADMIN", "--cap-add", "CHOWN", "--cap-add", "DAC_OVERRIDE",
                "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "SETPCAP", "--security-opt", "no-new-privileges", "--user", "0:0",
                "--memory", "256m", "--memory-swap", "256m", "--cpus", "0.5", "--pids-limit", "64", "--log-driver", "none",
                "--tmpfs", "/run/deskpilot:rw,nosuid,nodev,noexec,size=32m", "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=16m",
                "--health-cmd", "test -f /run/deskpilot/prepared && grep -q '0100007F:0C38 .* 0A ' /proc/net/tcp",
                "--health-interval", "1s", "--health-timeout", "1s", "--health-retries", "2",
                "--entrypoint", "/bin/sh", _image, "-c", startup, "deskpilot-proxy", encoded
            }, 30000, 65536, CancellationToken.None);
            if (created.ExitCode != 0) { throw new InvalidOperationException("HTTPS boundary startup failed: " + created.Error); }
            var clock = Stopwatch.StartNew();
            while (clock.ElapsedMilliseconds < 20000)
            {
                _cancellation.Token.ThrowIfCancellationRequested();
                NativeResult state = Call(new[] { "inspect", "--format", "{{json .State}}", name }, 5000, 65536, CancellationToken.None);
                if (state.ExitCode != 0) { throw new InvalidOperationException("The HTTPS boundary state could not be inspected."); }
                using JsonDocument status = JsonDocument.Parse(state.Output);
                if (!status.RootElement.GetProperty("Running").GetBoolean()) { throw new InvalidOperationException("The HTTPS boundary failed during startup."); }
                if (status.RootElement.GetProperty("Health").GetProperty("Status").GetString() == "healthy")
                {
                    NativeResult certificate = Call(new[] { "exec", "--user", "0", name, "/bin/cat", "/run/deskpilot/ca.crt" }, 5000, 65536, CancellationToken.None);
                    if (certificate.ExitCode != 0 || !certificate.Output.Contains("BEGIN CERTIFICATE", StringComparison.Ordinal)) { throw new InvalidOperationException("The disposable HTTPS certificate is unavailable."); }
                    return Convert.ToBase64String(Encoding.UTF8.GetBytes(certificate.Output));
                }
                Task.Delay(100, _cancellation.Token).GetAwaiter().GetResult();
            }
            throw new InvalidOperationException("The HTTPS boundary did not become ready in time.");
        }

        private static bool IsPublicAddress(IPAddress address)
        {
            byte[] bytes = address.GetAddressBytes();
            return bytes.Length == 4 && bytes[0] != 0 && bytes[0] != 10 && bytes[0] != 127 && bytes[0] < 224 &&
                !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) &&
                !(bytes[0] == 169 && bytes[1] == 254) && !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
                !(bytes[0] == 192 && (bytes[1] == 168 || bytes[1] == 0 || (bytes[1] == 88 && bytes[2] == 99))) &&
                !(bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19 || (bytes[1] == 51 && bytes[2] == 100))) &&
                !(bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113);
        }

        private NativeResult Call(IEnumerable<string> arguments, int timeout, int outputLimit, CancellationToken cancellation, string? requiredContainer = null)
        {
            var start = new ProcessStartInfo(_docker)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
                WorkingDirectory = Path.GetDirectoryName(_docker)!
            };
            start.Environment.Clear();
            start.Environment["SystemRoot"] = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
            start.Environment["PATH"] = Path.GetDirectoryName(_docker)!;
            start.Environment["TEMP"] = _configurationDirectory;
            start.Environment["TMP"] = _configurationDirectory;
            foreach (KeyValuePair<string, string> entry in _environment) { start.Environment[entry.Key] = entry.Value; }
            start.ArgumentList.Add("--config"); start.ArgumentList.Add(_configurationDirectory);
            start.ArgumentList.Add("--host"); start.ArgumentList.Add("npipe:////./pipe/dockerDesktopLinuxEngine");
            foreach (string argument in arguments) { start.ArgumentList.Add(argument); }
            using var process = new Process { StartInfo = start };
            using var output = new MemoryStream();
            using var error = new MemoryStream();
            var exceeded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var sync = new object();
            long count = 0;
            async Task DrainAsync(Stream source, MemoryStream target)
            {
                var buffer = new byte[4096];
                int read;
                while ((read = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
                {
                    lock (sync)
                    {
                        count += read;
                        if (count <= outputLimit) { target.Write(buffer, 0, read); }
                        else { exceeded.TrySetResult(true); }
                    }
                }
            }
            process.Start();
            process.StandardInput.Close();
            Task stdout = DrainAsync(process.StandardOutput.BaseStream, output);
            Task stderr = DrainAsync(process.StandardError.BaseStream, error);
            Task complete = Task.WhenAll(stdout, stderr, process.WaitForExitAsync());
            Task expiry = Task.Delay(timeout, cancellation);
            Task finished;
            bool dependencyFailed = false;
            while (true)
            {
                Task inspection = requiredContainer == null ? Task.Delay(Timeout.Infinite) : Task.Delay(500);
                finished = Task.WhenAny(complete, expiry, exceeded.Task, inspection).GetAwaiter().GetResult();
                if (finished != inspection) { break; }
                try
                {
                    NativeResult health = Call(new[] { "inspect", "--format", "{{.State.Running}}", requiredContainer! }, 2000, 16384, CancellationToken.None);
                    dependencyFailed = health.ExitCode != 0 || health.Output.Trim() != "true";
                }
                catch (Exception) { dependencyFailed = true; }
                if (dependencyFailed) { break; }
            }
            var result = new NativeResult
            {
                DependencyFailed = dependencyFailed,
                OutputLimit = exceeded.Task.IsCompleted,
                Cancelled = cancellation.IsCancellationRequested,
                TimedOut = finished == expiry && !cancellation.IsCancellationRequested
            };
            if (finished != complete && !process.HasExited) { process.Kill(true); }
            if (!complete.Wait(5000)) { throw new IOException("The Docker command did not close its output streams."); }
            complete.GetAwaiter().GetResult();
            result.Output = Encoding.UTF8.GetString(output.ToArray());
            result.Error = Encoding.UTF8.GetString(error.ToArray());
            result.ExitCode = dependencyFailed ? -1 : result.TimedOut ? 124 : result.Cancelled ? 125 : result.OutputLimit ? 126 : process.ExitCode;
            return result;
        }

        private string Redact(string text)
        {
            foreach (string secret in _secrets) { text = text.Replace(secret, "[secret]", StringComparison.Ordinal); }
            return text;
        }

        private static string NormalizeProject(string project)
        {
            if (string.IsNullOrWhiteSpace(project) || !Path.IsPathFullyQualified(project) || project.StartsWith(@"\\", StringComparison.Ordinal) ||
                project.IndexOfAny(new[] { ',', '"', '\r', '\n', '\0', '~' }) >= 0)
            {
                throw new InvalidOperationException("Isolated execution requires an unambiguous local Project path.");
            }
            string root = Path.GetFullPath(project).TrimEnd(Path.DirectorySeparatorChar);
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!Directory.Exists(root) || root == Path.GetPathRoot(root)!.TrimEnd(Path.DirectorySeparatorChar) || IsWithin(home, root))
            {
                throw new InvalidOperationException("Isolated execution cannot mount a drive root or the home directory.");
            }
            RejectLinks(root);
            return root;
        }

        private static bool IsWithin(string path, string root)
        {
            return string.Equals(path.TrimEnd(Path.DirectorySeparatorChar), root, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }

        private static void RejectLinks(string path)
        {
            string? candidate = path;
            while (!string.IsNullOrEmpty(candidate))
            {
                if ((Directory.Exists(candidate) || File.Exists(candidate)) && (File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException("An isolated path must not contain a symbolic link or junction.");
                }
                string segment = Path.GetFileName(candidate);
                if (segment.EndsWith(".", StringComparison.Ordinal) || segment.EndsWith(" ", StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("An isolated path must not use a trailing-dot or trailing-space alias.");
                }
                candidate = Path.GetDirectoryName(candidate);
            }
        }

        public void Dispose()
        {
            if (_disposed) { return; }
            if (Active) { throw new InvalidOperationException("An active isolated command must stop before disposal."); }
            _disposed = true;
            _cancellation.Dispose();
            _policy.Dispose();
            _environment.Clear();
            _secrets.Clear();
            File.Delete(Path.Combine(_configurationDirectory, "config.json"));
            Directory.Delete(_configurationDirectory);
        }

        private sealed class NativeResult
        {
            public int ExitCode { get; set; } = -1;
            public string Output { get; set; } = string.Empty;
            public string Error { get; set; } = string.Empty;
            public bool TimedOut { get; set; }
            public bool Cancelled { get; set; }
            public bool OutputLimit { get; set; }
            public bool DependencyFailed { get; set; }
        }
    }
}
