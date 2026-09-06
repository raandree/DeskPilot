ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER 0:0
COPY ChildRuntime.dll Start-DpChildSupervisor.ps1 Invoke-DpChildFile.ps1 /opt/deskpilot-child/
RUN chmod 0555 /opt/deskpilot-child && chmod 0444 /opt/deskpilot-child/*
WORKDIR /
