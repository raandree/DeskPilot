[CmdletBinding()]
param([Parameter(Mandatory)][string]$PolicyBase64)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$policy = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PolicyBase64)) | ConvertFrom-Json -AsHashtable
$root = '/run/deskpilot'
$null = New-Item -Path $root -ItemType Directory -Force

foreach ($program in @('/usr/sbin/iptables', '/usr/sbin/ip6tables')) {
    & $program -w -P OUTPUT DROP
    & $program -w -P INPUT DROP
    & $program -w -P FORWARD DROP
}
& /usr/sbin/iptables -w -A OUTPUT -o lo -p tcp -d 127.0.0.1 --dport 3128 -m owner --uid-owner 10001 -j ACCEPT
& /usr/sbin/iptables -w -A OUTPUT -o lo -p tcp -s 127.0.0.1 --sport 3128 -m owner --uid-owner 10002 -j ACCEPT
& /usr/sbin/iptables -w -A INPUT -i lo -p tcp --dport 3128 -j ACCEPT
& /usr/sbin/iptables -w -A INPUT -i lo -p tcp --sport 3128 -m conntrack --ctstate ESTABLISHED -j ACCEPT

$hosts = [Collections.Generic.List[string]]::new()
$names = [Collections.Generic.List[string]]::new()
foreach ($entry in $policy.hosts) {
    if ($entry.name -notmatch '^[a-z0-9.-]+$') { throw 'Invalid proxy name.' }
    $names.Add([string]$entry.name)
    foreach ($address in $entry.addresses) {
        $parsed = [Net.IPAddress]::Parse([string]$address)
        if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IPv6 is not enabled.' }
        $hosts.Add("$parsed $($entry.name)")
        & /usr/sbin/iptables -w -A OUTPUT -p tcp -d "$parsed" --dport 443 -m owner --uid-owner 10002 -j ACCEPT
        & /usr/sbin/iptables -w -A INPUT -p tcp -s "$parsed" --sport 443 -m conntrack --ctstate ESTABLISHED -j ACCEPT
    }
}
if ($names.Count -eq 0) { throw 'A proxy requires an explicit host allow-list.' }
[IO.File]::WriteAllLines("$root/hosts", $hosts)
& /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$root/ca.key" -out "$root/ca.crt" -days 1 -subj '/CN=DeskPilot disposable Terminal CA' 2>$null
$authorityPattern = '^(' + (($names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(:443)?$'

$configuration = @"
visible_hostname deskpilot-terminal
http_port 127.0.0.1:3128 ssl-bump cert=$root/ca.crt key=$root/ca.key generate-host-certificates=on dynamic_cert_mem_cache_size=4MB
acl connect method CONNECT
acl inspected_tls connections_encrypted
acl https_request proto HTTPS
acl secure_port port 443
acl allowed dstdomain -n $($names -join ' ')
acl has_host req_header Host .+
acl allowed_authority req_header Host -i $authorityPattern
acl upgrade req_header Upgrade .+
acl step_one at_step SslBump1
http_access deny !connect !inspected_tls
http_access deny !connect !https_request
http_access deny !secure_port
http_access deny !allowed
http_access deny !has_host
http_access deny !allowed_authority
http_access deny upgrade
http_access allow allowed
http_access deny all
ssl_bump bump step_one
ssl_bump terminate all
sslcrtd_program /usr/lib/squid/security_file_certgen -s $root/certificates -M 4MB
sslcrtd_children 2 startup=1 idle=1
sslproxy_cert_error deny all
tls_outgoing_options min-version=1.2
host_verify_strict on
client_dst_passthru off
hosts_file $root/hosts
dns_nameservers 127.0.0.1
dns_timeout 2 seconds
connect_timeout 10 seconds
request_timeout 20 seconds
read_timeout 20 seconds
cache deny all
cache_mem 8 MB
pinger_enable off
access_log none
cache_log /dev/null
cache_store_log none
pid_filename $root/squid.pid
cache_effective_user dp-proxy
cache_effective_group dp-proxy
shutdown_lifetime 0 seconds
forwarded_for delete
via off
request_header_access Proxy-Authorization deny all
"@
[IO.File]::WriteAllText("$root/squid.conf", $configuration)
& /usr/bin/chmod 0700 $root
& /usr/bin/chmod 0600 "$root/ca.key"
& /usr/bin/chown -R 10002:10002 $root
& /usr/bin/setpriv --reuid=10002 --regid=10002 --clear-groups /usr/lib/squid/security_file_certgen -c -s "$root/certificates" -M 4MB
& /usr/bin/setpriv --reuid=10002 --regid=10002 --clear-groups /usr/sbin/squid -k parse -f "$root/squid.conf"
[IO.File]::WriteAllText("$root/prepared", 'prepared')
