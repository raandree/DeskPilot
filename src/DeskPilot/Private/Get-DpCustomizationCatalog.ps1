function Get-DpCustomizationCatalog {
    <#
    .SYNOPSIS
        Returns the static catalog of Customization categories DeskPilot manages.
    .DESCRIPTION
        A Customization is a user-editable Markdown file that shapes the agent: an
        Agent, Skill, Instruction, or Prompt File. This catalog is the single
        source of truth for the four categories - their display label, the Settings
        key that holds their root folder(s), whether that key is a single path or
        an array, and how their files are recognised on disk:

        - flat categories (agent, instruction, prompt) match files directly under a
          root whose name ends with Suffix (for example '*.agent.md');
        - the nested category (skill) matches a fixed FileName ('SKILL.md') found in
          a sub-folder of a root, and takes its name from that sub-folder.

        Scaffold is the starter content New-DpCustomization writes for a new file
        (the literal '{0}' is replaced with the new Customization's name).
    .OUTPUTS
        System.Collections.Hashtable[] - one record per category, in display order.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    @(
        @{
            id          = 'agent'
            label       = 'Agents'
            rootSetting = 'agentsRoot'
            single      = $true
            nested      = $false
            suffix      = '.agent.md'
            fileName    = $null
            scaffold    = "---`nname: {0}`ndescription: A short description of what this agent does.`n---`n`n# {0}`n`nDescribe the persona, goals, and operating rules for this agent here.`n"
        }
        @{
            id          = 'skill'
            label       = 'Skills'
            rootSetting = 'skillRoots'
            single      = $false
            nested      = $true
            suffix      = $null
            fileName    = 'SKILL.md'
            scaffold    = "---`nname: {0}`ndescription: A short, trigger-rich description of when to use this skill.`n---`n`n# {0}`n`nStep-by-step instructions for the skill go here.`n"
        }
        @{
            id          = 'instruction'
            label       = 'Instructions'
            rootSetting = 'instructionRoots'
            single      = $false
            nested      = $false
            suffix      = '.instructions.md'
            fileName    = $null
            scaffold    = "---`napplyTo: `"**`"`ndescription: A short description of these instructions.`n---`n`n# {0}`n`nWrite the rules the agent should follow here.`n"
        }
        @{
            id          = 'prompt'
            label       = 'Prompt files'
            rootSetting = 'promptRoots'
            single      = $false
            nested      = $false
            suffix      = '.prompt.md'
            fileName    = $null
            scaffold    = "---`nmode: agent`ndescription: A short description of this prompt.`n---`n`nWrite the reusable prompt here.`n"
        }
    )
}