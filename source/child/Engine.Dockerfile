ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER 0:0
COPY ChildRuntime.dll Start-DpChildEngine.ps1 ChildTools.ps1 /opt/deskpilot-child/
COPY engine/ /opt/deskpilot-child/engine/
RUN mkdir -p /opt/deskpilot-child/home/.cache/powershell /opt/deskpilot-child/home/.config/powershell /opt/deskpilot-child/home/.local/share/powershell/Modules /opt/deskpilot-child/home/tmp
RUN find /opt/deskpilot-child -type d -exec chmod 0555 {} + && find /opt/deskpilot-child -type f -exec chmod 0444 {} +
USER 65534:65534
WORKDIR /