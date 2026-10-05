<#
.SYNOPSIS
    Produces the Word edition of a redline: two .docx files compared into a third, with
    Word's own tracked changes.

.DESCRIPTION
    `publish --diff` writes two redlines. The HTML one it renders itself and works everywhere;
    this is the other, and it is the one a working group marks up - comments, accept, reject,
    and a change bar in the margin, all of it Word's.

    Called by `publish --diff` as `<script> <baseline> <revised> <out>`, and runnable by hand
    on any two .docx files. Both inputs are opened read-only and neither is modified.

    It is a script in the repository rather than code in the tool on purpose. Comparing
    documents means driving Word through COM, which means Windows with Word installed;
    Opc.Ua.SpecificationPublisher is cross-platform and builds, renders and publishes a
    specification without Microsoft Office anywhere in the picture. Keeping the one step that
    needs Word out here is what preserves that - the same reason tools/office-to-svg.ps1 is a
    script and not a renderer compiled in.

    A comparison is only as useful as what goes into it. The tool renders the baseline STS to a
    .docx with the Word writer that is running now, rather than comparing against a committed
    .docx built by some earlier version: otherwise a change to the template or the writer shows
    up as a change to the document, which is the one thing a redline must not do.

.NOTES
    The Contents, Figures and Tables lists in the result are empty until Word paginates, the
    same as any generated edition: open it and press Ctrl+A then F9, or print-preview it.

    Requires Word. There is no cross-platform path and deliberately no attempt at one - the
    output is a .docx carrying w:ins and w:del that Word's review ribbon drives, and writing
    those by hand would be reimplementing the comparison engine this script borrows.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string] $Baseline,
    [Parameter(Mandatory = $true, Position = 1)][string] $Revised,
    [Parameter(Mandatory = $true, Position = 2)][string] $Out
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    throw 'Comparing documents needs Word, which runs on Windows only.'
}

$Baseline = (Resolve-Path -LiteralPath $Baseline).Path
$Revised = (Resolve-Path -LiteralPath $Revised).Path

# Absolute before anything else: SaveAs2 is COM, so it resolves a relative path against Word's
# own working directory rather than this script's, and the file lands somewhere nobody looks.
if (-not [System.IO.Path]::IsPathRooted($Out)) {
    $Out = Join-Path (Get-Location).Path $Out
}
$Out = [System.IO.Path]::GetFullPath($Out)

$outDirectory = Split-Path -Parent $Out
if ($outDirectory -and -not (Test-Path -LiteralPath $outDirectory)) {
    New-Item -ItemType Directory -Path $outDirectory -Force | Out-Null
}

# Word constants, named because the literals say nothing.
$wdAlertsNone = 0
$wdDoNotSaveChanges = 0
$wdCompareDestinationNew = 2
$wdGranularityWordLevel = 1
$wdFormatDocumentDefault = 16

# Close, Quit and SaveAs2 take their arguments by reference - they are declared `ref object` on
# the Word interface, and where the Office primary interop assemblies are installed PowerShell
# binds to that interface rather than late-binding through IDispatch. Passing a plain value then
# fails outright with "should be a System.Management.Automation.PSReference", so every argument
# to those three is wrapped. The [ref]s are made once here and reused.
$noSave = [ref] $wdDoNotSaveChanges
$docxFormat = [ref] $wdFormatDocumentDefault

$word = New-Object -ComObject Word.Application
try {
    $word.Visible = $false
    # One prompt nobody sees is an automated run that never returns.
    $word.DisplayAlerts = $wdAlertsNone

    # FileName, ConfirmConversions, ReadOnly, AddToRecentFiles. Read-only because neither input
    # is this script's to change, and off the recent list because a tool run is not something
    # the author opened.
    $original = $word.Documents.Open($Baseline, $false, $true, $false)
    try {
        $current = $word.Documents.Open($Revised, $false, $true, $false)
        try {
            # Word level rather than character level: a specification is read in sentences, and
            # a character-level comparison of renumbered prose is a page of single-letter marks.
            #
            # Formatting is compared, whitespace is not. A heading that became a note is a
            # change a reviewer has to see; a paragraph that gained a line break because the
            # markdown was rewrapped is not a change at all.
            $compared = $word.CompareDocuments(
                $original,
                $current,
                $wdCompareDestinationNew,
                $wdGranularityWordLevel,
                $true,      # CompareFormatting
                $true,      # CompareCaseChanges
                $false,     # CompareWhitespace
                $true,      # CompareTables
                $true,      # CompareHeaders
                $true,      # CompareFields
                $true,      # CompareFootnotes
                $true,      # CompareTextboxes
                'Draft',    # RevisedAuthor - what the marks are attributed to
                $true)      # IgnoreAllComparisonWarnings

            try {
                $compared.SaveAs2([ref] $Out, $docxFormat)
            }
            finally {
                $compared.Close($noSave)
            }
        }
        finally {
            $current.Close($noSave)
        }
    }
    finally {
        $original.Close($noSave)
    }
}
finally {
    $word.Quit($noSave)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null
}

if (-not (Test-Path -LiteralPath $Out)) {
    throw "The comparison reported success but wrote no $Out."
}

Write-Output ("wrote {0} ({1:N0} bytes)" -f $Out, (Get-Item -LiteralPath $Out).Length)
