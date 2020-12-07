[CmdletBinding()]
param (
    [parameter (Mandatory = $true)][string]$TargetCollectionUrl,
    [parameter (Mandatory = $true)][string]$TargetTeamProject,
    [parameter (Mandatory = $false)][string]$PersonalAccessToken,
    [parameter (Mandatory = $true)][string]$RepoMigrationFile
)

function Invoke-RestCommand {
    param(
        [string]$uri,
        [string]$commandType,
        [string]$contentType = "application/json",
        [string]$jsonBody,
        [string]$personalAccessToken
    )
	
    if ($jsonBody -ne $null) {
        $jsonBody = $jsonBody.Replace("{{","{").Replace("}}","}")
    }

    try {
        if ([String]::IsNullOrEmpty($personalAccessToken)) {
            if ([String]::IsNullOrEmpty($jsonBody)) {
                $response = Invoke-RestMethod -Method $commandType -ContentType $contentType -Uri $uri -UseDefaultCredentials
            }
            else {
                $response = Invoke-RestMethod -Method $commandType -ContentType $contentType -Uri $uri -UseDefaultCredentials -Body $jsonBody
            }
        }
        else {
            $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f "", $personalAccessToken)))
            if ([String]::IsNullOrEmpty($jsonBody)) {            
                $response = Invoke-RestMethod -Method $commandType -ContentType $contentType -Uri $uri -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)}
            }
            else {
                $response = Invoke-RestMethod -Method $commandType -ContentType $contentType -Uri $uri -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)} -Body $jsonBody
            }
        }

	    if ($response.count) {
		    $response = $response.value
	    }

	    foreach ($r in $response) {
		    if ($r.code -eq "400" -or $r.code -eq "403" -or $r.code -eq "404" -or $r.code -eq "409" -or $r.code -eq "500") {
                Write-Error $_
			    Write-Error -Message "Problem occurred when trying to call rest method."
			    ConvertFrom-Json $r.body | Format-List
		    }
	    }

	    return $response
    }
    catch {
        $result = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd();
        Write-Error "Exception Type: $($_.Exception.GetType().FullName)"
        Write-Error $responseBody
        Write-Error $_
        Write-Error -Message "Exception thrown calling REST method."
	}
}

function Get-TeamProject {
    param
    (
        [string]$tfsUri,
        [string]$teamProject,
        [string]$personalAccessToken
    )

    $uri = "${tfsUri}/_apis/projects/${teamProject}?api-version=1.0"
    Write-Host $uri
  	Invoke-RestCommand -uri $uri -commandType "GET" -personalAccessToken $personalAccessToken
}

function Create-GitRepository {
    param
    (
        [string]$tfsUri,
        [string]$teamProjectId,
        [string]$gitRepoName,
        [string]$personalAccessToken
    )

        $jsonBody = @"
            {
            "name": "${gitRepoName}",
            "project": {
                "id": "${teamProjectId}"
            }
"@
    Write-Host $jsonBody
    $uri = "${tfsUri}/_apis/git/repositories?api-version=4.0"
    Write-Host $uri
  	Invoke-RestCommand -uri $uri -commandType "POST" -jsonBody $jsonBody -personalAccessToken $personalAccessToken
}

function Move-GitRepository {
    param
    (
        [string]$tfsUri,
        [string]$teamProject,
        [string]$oldGitUri,
        [string]$repoName
    )

    $newGitUri = "${tfsUri}/${teamProject}/_git/${repoName}" -replace " ","%20"

    $workingFolder = "${repoName}"

    rmdir -Recurse -Force $workingFolder -ErrorAction SilentlyContinue

    md $workingFolder -Force

    pushd $workingFolder

    git clone --bare $oldGitUri .git
    git config core.bare false
    git checkout

    git remote add newTfs $newGitUri

    git push newTfs --all

    git push newTfs --tags

    popd

    rmdir -Recurse -Force $workingFolder
}


$teamProjectRef = Get-TeamProject -tfsUri $TargetCollectionUrl -teamProject $TargetTeamProject -personalAccessToken $PersonalAccessToken
$reposToMigrate = Import-Csv $RepoMigrationFile


$workingFolder = Join-Path $PSScriptRoot "_tmp"
md $workingFolder -Force
pushd $workingFolder

foreach ($repo in $reposToMigrate) {
    Write-Host "Creating and migrating repo: $($repo.NewGitRepoName)"
    Create-GitRepository -tfsUri $TargetCollectionUrl -teamProjectId $($teamProjectRef.id) -gitRepoName $($repo.NewGitRepoName) -personalAccessToken $PersonalAccessToken

    Move-GitRepository -tfsUri $TargetCollectionUrl -teamProject $TargetTeamProject -oldGitUri $($repo.OldGitUri) -repoName $($repo.NewGitRepoName)
}

popd