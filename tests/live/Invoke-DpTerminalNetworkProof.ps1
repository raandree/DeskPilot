[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' '..' 'source' 'Private' 'Invoke-DpDockerControl.ps1')
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$imageRows = Invoke-DpDockerControl -Argument @('image', 'ls', '--filter', 'reference=deskpilot-terminal', '--no-trunc', '--format', '{{json .}}')
$image = ($imageRows -split "`n" | Select-Object -First 1 | ConvertFrom-Json).ID
$proxy = 'deskpilot-network-proof-' + [guid]::NewGuid().ToString('N')
$client = $proxy + '-client'
$addresses = @([Net.Dns]::GetHostAddresses('example.com') | Where-Object AddressFamily -eq InterNetwork | ForEach-Object ToString)
$policy = @{ hosts = @(@{ name = 'example.com'; addresses = $addresses }) } | ConvertTo-Json -Depth 5 -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($policy))
$startup = '/opt/microsoft/powershell/7/pwsh -NoLogo -NoProfile -NonInteractive -File /opt/deskpilot/Start-DpProxy.ps1 -PolicyBase64 "$1" && exec /usr/bin/setpriv --reuid=10002 --regid=10002 --clear-groups --bounding-set=-all --inh-caps=-all --ambient-caps=-all --no-new-privs /usr/sbin/squid -N -d1 -f /run/deskpilot/squid.conf'
try {
    $arguments = @(
        'run', '--detach', '--pull', 'never', '--name', $proxy, '--network', 'bridge', '--read-only', '--cap-drop', 'ALL',
        '--cap-add', 'NET_ADMIN', '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'SETUID',
        '--cap-add', 'SETGID', '--cap-add', 'SETPCAP', '--security-opt', 'no-new-privileges', '--user', '0:0',
        '--memory', '256m', '--pids-limit', '64', '--tmpfs', '/run/deskpilot:rw,nosuid,nodev,noexec,size=32m',
        '--tmpfs', '/tmp:rw,nosuid,nodev,noexec,size=16m', '--log-driver', 'local', '--log-opt', 'max-size=64k',
        '--entrypoint', '/bin/sh', $image, '-c', $startup, 'deskpilot-proxy', $encoded
    )
    $null = Invoke-DpDockerControl -Argument $arguments
    $ready = '/opt/microsoft/powershell/7/pwsh'
    $wait = '$clock=[Diagnostics.Stopwatch]::StartNew(); while (-not [IO.File]::Exists("/run/deskpilot/squid.pid")) { if ($clock.Elapsed.TotalSeconds -gt 15) { exit 1 }; [Threading.Tasks.Task]::Delay(100).GetAwaiter().GetResult() }'
    $null = Invoke-DpDockerControl -Argument @('exec', '--user', '0', $proxy, $ready, '-NoProfile', '-NonInteractive', '-Command', $wait) -TimeoutSeconds 20
    $certificate = Invoke-DpDockerControl -Argument @('exec', '--user', '0', $proxy, '/bin/cat', '/run/deskpilot/ca.crt')
    $certificate64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($certificate))
    $command = "[IO.File]::WriteAllText('/tmp/ca.pem',[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$certificate64'))); & /usr/bin/curl --verbose --max-time 8 --cacert /tmp/ca.pem --proxy http://127.0.0.1:3128 https://example.com; exit `$LASTEXITCODE"
    $clientArguments = @(
        '--host', 'npipe:////./pipe/dockerDesktopLinuxEngine', 'run', '--rm', '--pull', 'never', '--name', $client,
        '--network', "container:$proxy", '--read-only', '--user', '10001:10001', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges', '--memory', '256m', '--pids-limit', '64',
        '--tmpfs', '/tmp:rw,nosuid,nodev,noexec,size=32m', $image, '-Command', $command
    )
    & $docker @clientArguments
    $clientExit = $LASTEXITCODE
    $counters = Invoke-DpDockerControl -Argument @('exec', '--user', '0', $proxy, '/usr/sbin/iptables', '-nvL')
    $processes = Invoke-DpDockerControl -Argument @('top', $proxy, '-eo', 'pid,uid,args')
    $sockets = Invoke-DpDockerControl -Argument @('exec', '--user', '0', $proxy, '/bin/cat', '/proc/net/tcp', '/proc/net/tcp6')
    $logs = (& $docker --host npipe:////./pipe/dockerDesktopLinuxEngine logs --tail 30 $proxy 2>&1 | Out-String)
    [pscustomobject]@{ ClientExit = $clientExit; Counters = $counters; Processes = $processes; Sockets = $sockets; Logs = $logs }
}
finally {
    $null = & $docker --host npipe:////./pipe/dockerDesktopLinuxEngine rm --force $client $proxy 2>$null
    $remaining = Invoke-DpDockerControl -Argument @('ps', '--all', '--filter', "name=$proxy", '--format', '{{.ID}}')
    if ($remaining) { throw 'The network proof left a container behind.' }
}
