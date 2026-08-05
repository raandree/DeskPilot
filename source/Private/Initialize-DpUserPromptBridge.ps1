function Initialize-DpUserPromptBridge {
    <#
    .SYNOPSIS
        Installs the Ask-User bridge in an Engine Runspace.
    .DESCRIPTION
        Creates a thread-safe rendezvous shared by the Host Server and Engine
        Runspace, then shadows Read-Host in that Runspace. During an active Turn,
        an Engine Read-Host call waits on the bridge until the Host Server submits
        the matching answer. Outside a Turn, secure input and ordinary Read-Host
        calls continue to use the native host implementation.
    .PARAMETER Runspace
        The long-lived Engine Runspace in which to install the adapter.
    .OUTPUTS
        DeskPilot.UserPromptBridge
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    $bridgeType = [System.Management.Automation.PSTypeName]'DeskPilot.UserPromptBridge'
    if (-not $bridgeType.Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;

namespace DeskPilot
{
    public sealed class UserPromptRequest
    {
        public UserPromptRequest(string id, string conversationId, string question)
        {
            Id = id;
            ConversationId = conversationId;
            Question = question;
        }

        public string Id { get; }
        public string ConversationId { get; }
        public string Question { get; }
    }

    public sealed class UserPromptBridge : IDisposable
    {
        private readonly object syncRoot = new object();
        private readonly ManualResetEventSlim answerReady = new ManualResetEventSlim(false);
        private bool enabled;
        private bool waiting;
        private bool cancelled;
        private bool emitted;
        private bool answerSubmitted;
        private string conversationId;
        private string questionId;
        private string question;
        private string questionCandidate;
        private string answer;

        public bool Enabled
        {
            get { lock (syncRoot) { return enabled; } }
        }

        public bool Waiting
        {
            get { lock (syncRoot) { return waiting; } }
        }

        public void BeginTurn(string activeConversationId)
        {
            if (String.IsNullOrWhiteSpace(activeConversationId))
            {
                throw new ArgumentException("A Conversation id is required.", nameof(activeConversationId));
            }

            lock (syncRoot)
            {
                if (waiting)
                {
                    throw new InvalidOperationException("A user prompt is already waiting for an answer.");
                }

                enabled = true;
                cancelled = false;
                emitted = false;
                answerSubmitted = false;
                conversationId = activeConversationId;
                questionId = null;
                question = null;
                questionCandidate = null;
                answer = null;
                answerReady.Reset();
            }
        }

        public void CaptureQuestion(string value)
        {
            if (String.IsNullOrWhiteSpace(value))
            {
                return;
            }

            lock (syncRoot)
            {
                if (!enabled)
                {
                    return;
                }

                questionCandidate = value.Trim();
                if (waiting && !emitted)
                {
                    question = questionCandidate;
                }
            }
        }

        public string RequestAnswer()
        {
            lock (syncRoot)
            {
                if (!enabled)
                {
                    throw new InvalidOperationException("The Ask-User bridge is not active.");
                }
                if (waiting)
                {
                    throw new InvalidOperationException("A user prompt is already waiting for an answer.");
                }

                waiting = true;
                cancelled = false;
                emitted = false;
                answerSubmitted = false;
                questionId = Guid.NewGuid().ToString("N");
                question = questionCandidate;
                questionCandidate = null;
                answer = null;
                answerReady.Reset();
            }

            answerReady.Wait();

            lock (syncRoot)
            {
                try
                {
                    if (cancelled)
                    {
                        throw new OperationCanceledException("The pending Ask-User request was cancelled.");
                    }

                    return answer ?? String.Empty;
                }
                finally
                {
                    waiting = false;
                    emitted = false;
                    answerSubmitted = false;
                    questionId = null;
                    question = null;
                    answer = null;
                    answerReady.Reset();
                }
            }
        }

        public UserPromptRequest GetPendingRequest()
        {
            lock (syncRoot)
            {
                if (!enabled || !waiting || emitted || String.IsNullOrWhiteSpace(question))
                {
                    return null;
                }

                emitted = true;
                return new UserPromptRequest(questionId, conversationId, question);
            }
        }

        public bool SubmitAnswer(string activeConversationId, string activeQuestionId, string value)
        {
            lock (syncRoot)
            {
                if (!enabled || !waiting || cancelled || answerSubmitted)
                {
                    return false;
                }
                if (!String.Equals(conversationId, activeConversationId, StringComparison.Ordinal) ||
                    !String.Equals(questionId, activeQuestionId, StringComparison.Ordinal))
                {
                    return false;
                }

                answer = value ?? String.Empty;
                answerSubmitted = true;
                answerReady.Set();
                return true;
            }
        }

        public void Cancel()
        {
            lock (syncRoot)
            {
                if (!waiting)
                {
                    return;
                }

                cancelled = true;
                answerReady.Set();
            }
        }

        public void EndTurn()
        {
            lock (syncRoot)
            {
                enabled = false;
                questionCandidate = null;
                conversationId = null;
                if (waiting)
                {
                    cancelled = true;
                    answerReady.Set();
                }
            }
        }

        public void Dispose()
        {
            EndTurn();
            answerReady.Dispose();
        }
    }
}
'@
    }

    $bridge = New-Object -TypeName 'DeskPilot.UserPromptBridge'
    $Runspace.SessionStateProxy.SetVariable('DeskPilotUserPromptBridge', $bridge)

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
function global:Read-Host {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(Position = 0)]
        [object]$Prompt,

        [Parameter(ParameterSetName = 'AsSecureString')]
        [switch]$AsSecureString,

        [Parameter(ParameterSetName = 'MaskInput')]
        [switch]$MaskInput
    )

    $bridge = $global:DeskPilotUserPromptBridge
    if ($null -eq $bridge -or -not $bridge.Enabled -or $AsSecureString -or $MaskInput) {
        return Microsoft.PowerShell.Utility\Read-Host @PSBoundParameters
    }

    $bridge.RequestAnswer()
}
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not install the Ask-User bridge.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $bridge
}
