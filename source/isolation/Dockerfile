FROM mcr.microsoft.com/powershell@sha256:62300a213a9293916333df2b014cd3a8f22fb0b0b65f2bb446aaf436bcf8c868

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends squid-openssl iptables openssl curl git util-linux \
    && curl --fail --location --proto '=https' --tlsv1.2 https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/powershell-7.6.5-linux-x64.tar.gz --output /tmp/powershell.tar.gz

RUN echo 'b34ab3b19acac1d3d4d0d3cfdb02acf62f457b0b6a962ff008132033f7566844  /tmp/powershell.tar.gz' | sha256sum --check --strict \
    && rm -rf /opt/microsoft/powershell/7/* \
    && tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 \
    && chmod 0755 /opt/microsoft/powershell/7/pwsh \
    && groupadd --gid 10001 dp-command \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp dp-command \
    && groupadd --gid 10002 dp-proxy \
    && useradd --uid 10002 --gid 10002 --no-create-home --home-dir /run/deskpilot dp-proxy \
    && rm -rf /var/lib/apt/lists/* /tmp/powershell.tar.gz \
    && dpkg-query -W > /opt/deskpilot-packages.txt

COPY Start-DpProxy.ps1 /opt/deskpilot/Start-DpProxy.ps1
RUN chmod 0444 /opt/deskpilot/Start-DpProxy.ps1

ENV POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_EnableDiagnostics=0
USER 10001:10001
WORKDIR /tmp
ENTRYPOINT ["/opt/microsoft/powershell/7/pwsh", "-NoLogo", "-NoProfile", "-NonInteractive"]
