function ConvertTo-DpBrowserField {
    <#
    .SYNOPSIS
        Parses and bounds the field list the Model proposes to type into a page.
    .DESCRIPTION
        The values are the part of a form fill that matters, because they are
        what leaves the machine and what the approval card is judged on. So they
        are validated here, before an approval is even offered, and anything this
        cannot make sense of is refused rather than partially applied - a form
        half-filled from a rejected list would be an action nobody approved.

        Taken as JSON rather than a typed array because the Tool schema the Model
        fills in is derived from these parameters, and a nested array of objects
        is the shape it is least reliable at producing.

        No credential check happens here. A field name is what an attacker
        controls; the authoritative signal is the live input's own type, so the
        refusal is made in the supervisor against the real DOM.
    .PARAMETER Json
        A JSON array of objects with name and value.
    .OUTPUTS
        System.Collections.Hashtable with fields and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @{ fields = @(); error = 'The fields to fill in are required, as JSON like [{"name":"City","value":"Osorno"}].' }
    }
    if ($Json.Length -gt 20000) {
        return @{ fields = @(); error = 'That is more form data than DeskPilot will type into a page.' }
    }

    $parsed = $null
    try { $parsed = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { return @{ fields = @(); error = 'The fields were not valid JSON. Use [{"name":"City","value":"Osorno"}].' } }

    $rows = @($parsed)
    if ($rows.Count -eq 0) { return @{ fields = @(); error = 'No fields were given.' } }
    if ($rows.Count -gt 50) { return @{ fields = @(); error = 'At most 50 fields can be filled in at once.' } }

    $fields = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $rows) {
        $name = ([string](Get-DpPropertyValue -InputObject $row -Name @('name') -Default '')).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { return @{ fields = @(); error = 'Every field needs a name.' } }
        if ($name.Length -gt 200) { return @{ fields = @(); error = 'A field name that long is not a field name.' } }

        $value = [string](Get-DpPropertyValue -InputObject $row -Name @('value') -Default '')
        if ($value.Length -gt 5000) { return @{ fields = @(); error = "The value for '$name' is longer than DeskPilot will type into a page." } }

        $fields.Add(@{ name = $name; value = $value })
    }

    @{ fields = @($fields.ToArray()); error = '' }
}
