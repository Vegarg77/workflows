<#
.SYNOPSIS
  Put a GitHub repo on the shared setup: DeepSeek PR review + Dependabot.

.DESCRIPTION
  For the given repo:
    1. Installs the thin review caller (templates/deepseek-code-review.yml) on the default branch.
       A repo still carrying the old full copy of the review is switched over to the caller.
    2. Sets the DEEPSEEK_API_KEY Actions secret, if the repo doesn't have it.
    3. Turns on Dependabot alerts and Dependabot security-fix PRs.

  The API key is read from Windows Credential Manager (target below). The first run, or a run
  with -SetKey, prompts for it once in a hidden prompt and stores it there. It is piped to
  `gh secret set` on stdin, so it never appears on a command line, in a file or in output.

.EXAMPLE
  .\setup-repo.ps1 localplantcalendar
  .\setup-repo.ps1 Vegarg77/ai-rooms
  .\setup-repo.ps1 -SetKey          # store or replace the key only
#>
param(
    [Parameter(Position = 0)] [string] $Repo,
    [switch] $SetKey,
    # Overwrite a review workflow that is neither the caller nor the old full copy.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$Owner = 'Vegarg77'
$CredTarget = 'github-code-review:DEEPSEEK_API_KEY'
$WorkflowPath = '.github/workflows/deepseek-code-review.yml'
$Template = Join-Path $PSScriptRoot '..\templates\deepseek-code-review.yml'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CredStore {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL cred, int flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);

    const int CRED_TYPE_GENERIC = 1, CRED_PERSIST_LOCAL_MACHINE = 2;

    public static string Read(string target) {
        IntPtr p;
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out p)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            return c.CredentialBlobSize == 0 ? "" : Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2);
        } finally { CredFree(p); }
    }

    public static void Write(string target, string user, string secret) {
        byte[] b = Encoding.Unicode.GetBytes(secret);
        var c = new CREDENTIAL { Type = CRED_TYPE_GENERIC, TargetName = target, UserName = user,
                                 CredentialBlobSize = b.Length, Persist = CRED_PERSIST_LOCAL_MACHINE };
        c.CredentialBlob = Marshal.AllocHGlobal(b.Length);
        try {
            Marshal.Copy(b, 0, c.CredentialBlob, b.Length);
            if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(c.CredentialBlob); }
    }
}
'@

function Save-KeyFromPrompt {
    $secure = Read-Host 'Paste the DeepSeek API key (input is hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $plain) { throw 'No key entered.' }
    [CredStore]::Write($CredTarget, 'deepseek', $plain)
    Write-Host "Key stored in Windows Credential Manager as '$CredTarget'."
    return $plain
}

function Get-Key {
    $key = [CredStore]::Read($CredTarget)
    if ($key) { return $key }
    Write-Host "No key in Credential Manager yet ('$CredTarget')."
    return Save-KeyFromPrompt
}

# gh is a native exe: a failure sets $LASTEXITCODE rather than throwing.
function Assert-Gh([string] $what) {
    if ($LASTEXITCODE -ne 0) { throw "gh failed: $what" }
}

if ($SetKey) {
    Save-KeyFromPrompt | Out-Null
    if (-not $Repo) { return }
}
if (-not $Repo) { throw 'Give a repo name, e.g. .\setup-repo.ps1 localplantcalendar' }
if ($Repo -notmatch '/') { $Repo = "$Owner/$Repo" }

$branch = gh api "repos/$Repo" -q .default_branch
Assert-Gh "reading $Repo (does it exist?)"
Write-Host "== $Repo (default branch: $branch)"

# --- 1. Review caller ---
$caller = [IO.File]::ReadAllText((Resolve-Path $Template))
# A 404 here just means "not installed yet". Windows PowerShell 5.1 turns a native command's
# stderr into a terminating error under 'Stop', even with 2>$null, so relax it for this call.
$ErrorActionPreference = 'Continue'
$existingJson = gh api "repos/$Repo/contents/$($WorkflowPath)?ref=$branch" 2>$null
$found = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
$existing = if ($found -and $existingJson) { $existingJson | ConvertFrom-Json } else { $null }
$hasFile = [bool]($existing -and $existing.sha)

$current = $null
if ($hasFile) {
    $current = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($existing.content -replace '\s', '')))
}

if ($hasFile -and ($current -replace "`r", '') -eq ($caller -replace "`r", '')) {
    Write-Host 'Review caller: already installed.'
} elseif ($hasFile -and -not $Force -and $current -notmatch 'api\.deepseek\.com') {
    Write-Warning "Review: $WorkflowPath exists but is not the caller or the old full review. Left alone; re-run with -Force to replace it."
} else {
    $msg = if ($hasFile) { 'ci: run the shared DeepSeek review from Vegarg77/workflows' } else { 'ci: add the shared DeepSeek PR review' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($caller -replace "`r", '')))
    $args_ = @('api', '-X', 'PUT', "repos/$Repo/contents/$WorkflowPath",
               '-f', "message=$msg", '-f', "content=$b64", '-f', "branch=$branch", '-q', '.commit.sha')
    if ($hasFile) { $args_ += @('-f', "sha=$($existing.sha)") }
    $commit = & gh @args_
    Assert-Gh 'writing the review caller'
    Write-Host "Review caller: $(if ($hasFile) { 'replaced old full copy' } else { 'installed' }) (commit $($commit.Substring(0, 7)))."
}

# --- 2. API key secret ---
$secrets = gh secret list -R $Repo --json name -q '.[].name'
Assert-Gh 'listing secrets'
if ($secrets -contains 'DEEPSEEK_API_KEY') {
    Write-Host 'DEEPSEEK_API_KEY: already set.'
} else {
    Get-Key | gh secret set DEEPSEEK_API_KEY -R $Repo
    Assert-Gh 'setting DEEPSEEK_API_KEY'
    Write-Host 'DEEPSEEK_API_KEY: set.'
}

# --- 3. Dependabot ---
gh api -X PUT "repos/$Repo/vulnerability-alerts" --silent
Assert-Gh 'enabling Dependabot alerts'
gh api -X PUT "repos/$Repo/automated-security-fixes" --silent
Assert-Gh 'enabling Dependabot security updates'
Write-Host 'Dependabot: alerts and security-fix PRs on.'
