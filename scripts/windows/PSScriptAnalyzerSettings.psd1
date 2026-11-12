# PSScriptAnalyzer settings for xf.ps1, used by the lint workflow in
# .github/workflows/lint.yml. Every other rule runs at its default severity,
# and CI fails on any finding.
@{
    ExcludeRules = @(
        # xf.ps1 is an interactive console helper. Its messages are for the
        # person at the terminal and must NOT enter the pipeline: a function
        # that writes to the output stream returns those lines to its caller,
        # which is exactly the exit-code bug Invoke-Docker documents.
        'PSAvoidUsingWriteHost',

        # Set-EnvValue and New-Secret are private helpers called only by the
        # script's own setup command, never by a user directly, so -WhatIf /
        # -Confirm support would add nothing.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
