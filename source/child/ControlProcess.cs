#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace DeskPilot.Child
{
    internal sealed class ControlProcess : IDisposable
    {
        private readonly Process? _process;
        private readonly OwnedProcess? _owned;

        internal ControlProcess(ProcessStartInfo start, OwnedProcess? owner)
        {
            if (owner == null)
            {
                _process = new Process { StartInfo = start };
                _process.Start();
                Input = _process.StandardInput.BaseStream;
                Output = _process.StandardOutput.BaseStream;
                Error = _process.StandardError.BaseStream;
            }
            else
            {
                var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (KeyValuePair<string, string?> entry in start.Environment)
                {
                    if (entry.Value != null) { environment.Add(entry.Key, entry.Value); }
                }
                _owned = owner.CreateSibling(start.FileName, new List<string>(start.ArgumentList).ToArray(),
                    start.WorkingDirectory, environment);
                try { _owned.Resume(); }
                catch { _owned.Dispose(); throw; }
                Input = _owned.Input;
                Output = _owned.Output;
                Error = _owned.Error;
            }
        }

        internal Stream Input { get; }
        internal Stream Output { get; }
        internal Stream Error { get; }
        internal bool HasExited => _owned?.HasExited ?? _process!.HasExited;
        internal int ExitCode => _owned?.ExitCode ?? _process!.ExitCode;
        internal Task WaitForExitAsync(CancellationToken cancellationToken) =>
            _owned?.WaitForExitAsync(cancellationToken) ?? _process!.WaitForExitAsync(cancellationToken);

        internal void Kill(bool descendants)
        {
            if (_owned != null) { _owned.Stop(); }
            else if (!_process!.HasExited) { _process.Kill(descendants); }
        }

        public void Dispose()
        {
            if (_owned != null) { _owned.Dispose(); }
            else
            {
                try { if (!_process!.HasExited) { _process.Kill(true); } }
                finally { _process!.Dispose(); }
            }
        }
    }
}
