function New-DpTitlePrompt {
    <#
    .SYNOPSIS
        Builds the prompt that asks the Model for a short Conversation title.
    .DESCRIPTION
        Composes a single instruction that summarises the user's first prompt into
        a concise title of a few words, matching the auto-titling GitHub Copilot
        does for a new chat. The instruction is deliberately strict - only the
        title text, no quotes, no trailing punctuation, no Markdown - so
        ConvertFrom-DpTitleResult has little to clean up. The prompt is truncated
        so a very long first message (for example a pasted document) never bloats
        the title Turn.
    .PARAMETER Prompt
        The user's first prompt in the Conversation.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prompt
    )

    $text = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    $maxInput = 800
    if ($text.Length -gt $maxInput) { $text = $text.Substring(0, $maxInput) }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("Summarise the user's request below as a very short title of three to six words that captures its main topic.")
    [void]$sb.AppendLine("Respond with ONLY the title text: no quotation marks, no surrounding or trailing punctuation, no explanation, no Markdown, no code block.")
    [void]$sb.AppendLine("Write the title in the same language as the request. Do not begin with a label such as 'Title' or 'Request'.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Request:")
    [void]$sb.AppendLine('"""')
    [void]$sb.AppendLine($text)
    [void]$sb.AppendLine('"""')

    $sb.ToString()
}
