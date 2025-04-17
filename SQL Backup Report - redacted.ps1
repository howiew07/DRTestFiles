<#
.SYNOPSIS 
    Checks for missing and outdated SQL backups.

.DESCRIPTION
	The script loops through the database names for each SQL server and creates a collection of 
    filenames in the backup folder that match the database name.

    When there are several matching filenames in the backup folder, the script splits the filenames
    on their underscores and rejoins the parts to determine if there's an exact match. The reason
    for this is the naming convention of bak files is not consistent, and the database name may be
    contained within other parts of the file name such as 'backup' or the date the backup was taken.
    
    If a match is confirmed, the script checks the last write time of the bak file and adds it to
    the output if it's older than the RPO value. When there is one matching file bak file in the 
    backup folder, the script checks it's last write time and compares RPO. If there are no matching
    bak files, the database is output as having a missing backup.
    
    The Fixed_databases section is special processing for database names that are fully contained
    inside other database names. These db names break the logic above since there will be multiple
    matches, and they are processed separately. When #3 is processed, it has a separate loop as
    it has a secondary backup drive.

    HTML for the email is created by reading in the style and logo from a base HTML file, then adding
    $TableData which is all of the script output.

.PARAMETER DatabaseInformation
    Refers to $DatabaseInformation.csv which should be updated when databases are added/removed for DR.
    
.PARAMETER OutputFile
    Creates a local copy of the HTML in a Logs subfolder, if needed for troubleshooting.
    
.PARAMETER RPO
    Calculates a date/time 48 hours earlier.

.PARAMETER TableData    
    Holds all of the script output - HTML rows and cells of databases with missing backups, as well as 
    outdated backups and their last backup date.  

.PARAMETER Bakfiles
    A collection of all bak files in the backup folder that wildcard match the database name.

.NOTES
    AUTHOR: H. Weinfeld - v1.0 11/19/2020
    LASTEDIT: 3/6/2025  
#>



clear-host
$SQLServers = @()
$DatabaseInformation = "$PSScriptRoot\DatabaseInformation.csv"
$LogDate = (get-date).ToString("MM.dd.yy_HH.mm.ss")
Start-Transcript -Path "$PSScriptRoot\Logs\Backup Report $LogDate.txt" | Out-Null

Get-ChildItem "$PSScriptRoot\Logs" -Recurse -File | Where CreationTime -lt (Get-Date).AddDays(-14) | Remove-Item -Force
$OutputFile = "$PSScriptRoot\Logs\Missing and Outdated SQL Backups $LogDate.html"
New-Item $OutputFile -ItemType File -Force | Out-Null
$RPO = (get-date).addhours(-24)

$DatabasesFor3 = Import-Csv -Path $DatabaseInformation | Select $SQLServer | Where-Object {$_.$SQLServer -ne ''}
$PrimaryDrive = ''
$SecondDrive = ''
$DifferentialFolder = ''
$TotalCount = $DatabasesFor1.Count
$VerifiedCount = $DatabasesFor2.Count

$SmtpServer = ""
$MailFrom = ""
$MailTo = ""
$Message = New-Object System.Net.Mail.MailMessage $MailFrom,$MailTo
$Message.ReplyTo = ""
$Message.Subject = ""
$Message.IsBodyHTML = $true
$Message.Body = ""
$TableData = ''



# Adding Feature Addition Here



Write-Output "`nMissing and Outdated SQL Backups`n`n"

foreach ($SQLServer in $SQLServers) 
{ 
    $DatabasesPerServer = Import-Csv -Path $DatabaseInformation | Select $SQLServer | Where-Object {$_.$SQLServer -ne ''}
	$BackupLocation = Import-Csv -Path $DatabaseInformation | where-object { $_.'Server' -eq $SQLServer}

    [int]$InitialServerDBCount = ''
    [int]$ServerDBTotalCount = ''
    $InitialServerDBCount += $DatabasesPerServer.Count
    $ServerDBTotalCount += $DatabasesPerServer.Count
 
    Write-Output "`n`n====== $SQLServer ======`n"
    $TableData += "<table><tr><th>$SQLServer</th><th>Newest Backup</th><th>RPO</th><th>Status</th></tr>" 
       
    foreach ($Database in $DatabasesPerServer.$SQLServer)
    {
        $BakFiles = (get-childitem -Path $BackupLocation.ProdFolderPath -Include *$database*.bak -Exclude *_Log_* -Recurse).Name

        if ($BakFiles.Count -gt 1) 
        {       
            $MultiBakRPOCheck = @()
            $MultiBreachedBaks = @()
            [int]$BakPieceTotal = ''
            [int]$DBPieceCount = 0

            foreach ($bak in $bakfiles)
            {
                $bakminusextension = $bak.Substring(0,$bak.Length-4)
                $BakNameSplitOnUnderScores = $bakminusextension -split "_"
                $combined = ''
                $DBNameSplitOnUnderscores = $database -split "_"

                
                # Bak files go through this loop when the database name has underscores in it, and the backup is multiple files

                if ($DBNameSplitOnUnderscores.Count -gt 1) 
                {
                    for ($i = 0; $i -lt $DBNameSplitOnUnderscores.Count; $i++) 
                    {
                        $combined+=$BakNameSplitOnUnderScores[$i]
                       
                        if ($combined -eq $database) 
                        {
                            $parentfolder = (get-childitem -Path $BackupLocation.ProdFolderPath -Include "$bak" -Recurse).DirectoryName
                            $MultiBakFileInfo = dir "$parentfolder\$bak"
                            $MultiBakLastWriteTime = $MultiBakFileInfo.LastWriteTime.ToString("MM/dd/yy")
                            $MultiBakTimeDiff = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($MultiBakFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan
                            $DBPieceCount += 1

                            if (($MultiBakTimeDiff.Days -eq 0) -xor ($MultiBakTimeDiff.Days -ge 2)) {$days = "Days"}
                            if (($MultiBakTimeDiff.Hours -eq 0) -xor ($MultiBakTimeDiff.Hours -ge 2)) {$hours = "Hours"}
                            if ($MultiBakTimeDiff.Days -eq 1)  {$days = "Day"}
                            if ($MultiBakTimeDiff.Hours -eq 1) {$hours = "Hour"}

                            if ($MultiBakTimeDiff.Days -eq 0) {$MultiBakRPOCheck += "Valid"}

                            if ($MultiBakTimeDiff.Days -ge 1)
                            {
                                $MultiBakRPOCheck += "Breached"
                                $BreachedBakLastWriteTime = (dir "$parentfolder\$bak").LastWriteTime.ToString("MM/dd/yy")
                                $RPOForOutdateBakPiece = "$($MultiBakTimeDiff.Days) $days, $($MultiBakTimeDiff.Hours) $hours"
                                $MultiBreachedBaks += "$bak - $RPOForOutdateBakPiece"
                            }  
                        }
                        $combined=$combined+"_"
                    }
                }
                        
                
                       
                # Bak files go through this loop when the database name is one word with no underscores, and the backup is split into multiple pieces 
                
                foreach ($BakNamePiece in $BakNameSplitOnUnderScores) 
                {
                    if ($BakNamePiece -eq $Database)
                    {
                        $parentfolder = (get-childitem -Path $BackupLocation.ProdFolderPath -Include "$bak" -Recurse).DirectoryName
                        $MultiBakFileInfo = dir "$parentfolder\$bak"
                        $MultiBakLastWriteTime = $MultiBakFileInfo.LastWriteTime.ToString("MM/dd/yy")
                        $MultiBakTimeDiff = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($MultiBakFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan

                        if (($MultiBakTimeDiff.Days -eq 0) -xor ($MultiBakTimeDiff.Days -ge 2)) {$days = "Days"}
                        if (($MultiBakTimeDiff.Hours -eq 0) -xor ($MultiBakTimeDiff.Hours -ge 2)) {$hours = "Hours"}
                        if ($MultiBakTimeDiff.Days -eq 1)  {$days = "Day"}
                        if ($MultiBakTimeDiff.Hours -eq 1) {$hours = "Hour"}
                        
                        if ($MultiBakTimeDiff.Days -eq 0)
                        {
                            $MultiBakRPOCheck += "Valid"
                            if ($Database -eq 'DASH') {$DBPieceCount += 1}                      
                        }

                        if ($MultiBakTimeDiff.Days -ge 1)
                        {
                            $MultiBakRPOCheck += "Breached"
                            $BreachedBakLastWriteTime = (dir "$parentfolder\$bak").LastWriteTime.ToString("MM/dd/yy")
                            $RPOForOutdateBakPiece = "$($MultiBakTimeDiff.Days) $days, $($MultiBakTimeDiff.Hours) $hours"
                            $MultiBreachedBaks += "$bak - $RPOForOutdateBakPiece"
                        } 
                        
                        if ($Database -ne 'BizTalkMsgBoxDb' -and $Database -ne 'DASH') {$DBPieceCount += 1}
                    }
                }
            } 



            # When there are breached pieces and missing pieces of a multi-part backup - mark it as missing

            if ($MultiBakRPOCheck -contains 'Breached' -and $DBPieceCount -lt $BakPieceTotal -and $Database -ne 'DASH')
            {
                $MultiBreachedBaks
                $NumBaksMissing = $BakPieceTotal - $DBPieceCount
                Write-Output "$Database has $NumBaksMissing piece(s) missing"
                $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>N/A</td><td class='rpoerror'>N/A</td><td class='statuserror'>Pieces are missing from split backup</td></tr>"
                $ServerDBTotalCount -= 1
            }

            
            # When there are breached pieces and no missing pieces of a multi-part backup - mark it as a breach

            if ($MultiBakRPOCheck -contains 'Breached' -and $DBPieceCount -eq $BakPieceTotal -and $Database -ne 'DASH')
            {
                $MultiBreachedBaks
                $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>$BreachedBakLastWriteTime</td><td class='rpoerror'>$RPOForOutdateBakPiece</td><td class='statuserror'>RPO breached</td></tr>"
                $ServerDBTotalCount -= 1
            }

            
            # When there are no breached pieces but there are missing pieces of a multi-part backup - mark it as missing

            if ($MultiBakRPOCheck -notcontains 'Breached' -and $MultiBakRPOCheck.Count -ne 0 -and $DBPieceCount -lt $BakPieceTotal -and $Database -ne 'DASH')
            {
                $NumBaksMissing = $BakPieceTotal - $DBPieceCount
                Write-Output "$Database has $NumBaksMissing piece(s) missing"
                $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>N/A</td><td class='rpoerror'>N/A</td><td class='statuserror'>Pieces are missing from split backup</td></tr>"
                $ServerDBTotalCount -= 1
            }
                        
            
            # When there are no breached pieces and no missing pieces of a multi-part backup - mark it as protected

            if ($MultiBakRPOCheck -notcontains 'Breached' -and $MultiBakRPOCheck.Count -ne 0 -and $DBPieceCount -eq $BakPieceTotal -and $Database -ne 'DASH')
            {
                $TableData += "<tr><td class='name'>$Database</td><td class='backup'>$MultiBakLastWriteTime</td><td class='rpo'>$($MultiBakTimeDiff.Hours) $hours</td><td class='status'>Protected</td></tr>" 
            }



            # Special handling for DASH, to ensure it sees the RPO as valid when there are 20 valid pieces

            if ($Database -eq 'DASH')
            {

                # When there's 20 valid pieces, and any number of breached pieces

                if ($DBPieceCount -ge $BakPieceTotal)
                {
                    $TableData += "<tr><td class='name'>$Database</td><td class='backup'>$MultiBakLastWriteTime</td><td class='rpo'>$($MultiBakTimeDiff.Hours) $hours</td><td class='status'>Protected</td></tr>"
                }


                # When there's less than 20 valid pieces, but more than 20 total pieces
                
                if ($DBPieceCount -lt $BakPieceTotal -and $MultiBakRPOCheck.Count -ge $BakPieceTotal)
                {
                    $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>$BreachedBakLastWriteTime</td><td class='rpoerror'>$RPOForOutdateBakPiece</td><td class='statuserror'>RPO Breached</td></tr>"
                    $ServerDBTotalCount -= 1
                }


                # When there's less than 20 valid pieces, and less than 20 total pieces

                if ($DBPieceCount -lt $BakPieceTotal -and $MultiBakRPOCheck.Count -lt $BakPieceTotal)
                {
                    $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>N/A</td><td class='rpoerror'>N/A</td><td class='statuserror'>Pieces are missing from split backup</td></tr>"
                    $ServerDBTotalCount -= 1
                }
            }
        }

        
        if ($BakFiles.Count -eq 1) 
        {
            $parentfolder = (get-childitem -Path $BackupLocation.ProdFolderPath -Include "$bakfiles" -Recurse).DirectoryName
            $BakFileInfo = dir "$parentfolder\$bakfiles"
            $BakLastWriteTime = $BakFileInfo.LastWriteTime.ToString("MM/dd/yy")

            $BakTimeDiff = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($BakFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan

            if (($BakTimeDiff.Days -eq 0) -xor ($BakTimeDiff.Days -ge 2)) {$days = "Days"}
            if (($BakTimeDiff.Hours -eq 0) -xor ($BakTimeDiff.Hours -ge 2)) {$hours = "Hours"}
            if ($BakTimeDiff.Days -eq 1)  {$days = "Day"}
            if ($BakTimeDiff.Hours -eq 1) {$hours = "Hour"}

            if ($BakTimeDiff.Days -eq 0) {$TableData += "<tr><td class='name'>$Database</td><td class='backup'>$BakLastWriteTime</td><td class='rpo'>$($BakTimeDiff.Hours) $hours</td><td class='status'>Protected</td></tr>"}
            
            if ($BakTimeDiff.Days -ge 1)
            {
                $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>$BakLastWriteTime</td><td class='rpoerror'>$($BakTimeDiff.Days) $days, $($BakTimeDiff.Hours) $hours</td><td class='statuserror'>RPO breached</td></tr>"
                Write-Output "$Database - $($BakTimeDiff.Days) $days, $($BakTimeDiff.Hours) $hours"
                $ServerDBTotalCount -= 1
            }
        }


        if ($BakFiles.Count -eq 0) 
        {
            $ServerDBTotalCount -= 1
            $TableData += "<tr><td class='name'>$Database</td><td class='backuperror'>N/A</td><td class='rpoerror'>N/A</td><td class='statuserror'>Backup not found</td></tr>"
            Write-Output "$Database -- backup missing"
        }
    }

    Write-Output "`n$ServerDBTotalCount/$InitialServerDBCount backups within RPO`n`n"
    $TableData += "<tr><td class='name'><b>$ServerDBTotalCount/$InitialServerDBCount backups within RPO</b></td><td class='backup'></td><td class='rpo'></td><td class='status'></td></tr></table><br><br><br>"
}


########################################################


Write-Output "`n======= $Server ======="
$TableData += "<table><tr><th>$SQLServer</th><th>Newest Full Backup</th><th>Newest Differential</th><th>RPO</th><th>Status</th></tr>" 

foreach ($Database in $DatabasesFor3.$SQLServer)
{
    $Database_search = $Database + '_backup'
    $BakFile = (get-childitem -Path $PrimaryDrive,$SecondDrive -Include *$Database_search*.bak -Exclude *_Log_* -Recurse | Sort-Object -Descending -Property LastWriteTime | Select -First 1)

    if ($BakFile.Count -eq 1) 
    {
        $BakFileInfo = dir $Bakfile
        $BakLastWriteTime = $BakFileInfo.LastWriteTime.ToString("MM/dd/yy")

        $NewestDiff = ''
        $DiffTimeDifference = ''
        $FullTimeDifferenceforDiff = ''
        $DiffLastWriteTime = ''

        $NewestDiff = (Get-ChildItem -Path $DifferentialFolder -Include *$Database_search*.bak -Exclude *_Log_* -Recurse | Sort-Object -Descending -Property LastWriteTime | Select -First 1)
        $DiffCount = $NewestDiff.count
 
        #When diffentials are missing 

        if ($DiffCount -eq 0) 
        {
            $FullTimeDifferenceNoDiff = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($BakFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan
            $FullNoDiffRPODays = $FullTimeDifferenceNoDiff.Days
            $FullNoDiffRPOHours = $FullTimeDifferenceNoDiff.Hours

            if ($FullNoDiffRPODays -eq 0)  {$days = "Days"}
            if ($FullNoDiffRPODays -eq 1)  {$days = "Day"}
            if ($FullNoDiffRPODays -ge 2)  {$days = "Days"}
            if ($FullNoDiffRPOHours -eq 0) {$hours = "Hours"}
            if ($FullNoDiffRPOHours -eq 1) {$hours = "Hour"}
            if ($FullNoDiffRPOHours -ge 2) {$hours = "Hours"}
                
            if ($FullNoDiffRPODays -eq 0) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackup'>$BakLastWriteTime</td><td class='spdbdiff'>N/A</td><td class='spdbrpo'>$FullNoDiffRPOHours $hours</td><td class='spdbstatus'>Protected</td></tr>"}
            if ($FullNoDiffRPODays -ge 1) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackuperror'>$BakLastWriteTime</td><td class='spdbdifferror'>N/A</td><td class='spdbrpoerror'>$FullNoDiffRPODays $days, $FullNoDiffRPOHours $hours</td><td class='spdbstatuserror'>Differential backup not found<br>RPO breached</td></tr>"}
            if ($FullNoDiffRPODays -ge 1) {Write-Output "$Database - $FullNoDiffRPODays $days, $FullNoDiffRPOHours $hours"
                $VerifiedCount -= 1}
        }
        
        if ($DiffCount -eq 1) {
            
            $DiffFileInfo = dir $NewestDiff
            $DiffLastWriteTime = $DiffFileInfo.LastWriteTime.ToString("MM/dd/yy")

            #When differential backup is newer than full 

            if ((get-date $BakFileInfo.LastWriteTime) -lt (get-date $DiffFileInfo.LastWriteTime)) 
            {
                $DiffTimeDifference = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($DiffFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan
                $FullTimeDifferenceforDiff = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($BakFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan    
                $FullforDiffRPODays = $FullTimeDifferenceforDiff.Days
                $DiffRPODays = $DiffTimeDifference.Days
                $DiffRPOHours = $DiffTimeDifference.Hours

                if ($DiffRPODays -eq 0) {$days = "Days"}
                if ($DiffRPODays -eq 1) {$days = "Day"}
                if ($DiffRPODays -ge 2) {$days = "Days"}
                if ($DiffRPOHours -eq 0) {$hours = "Hours"}
                if ($DiffRPOHours -eq 1) {$hours = "Hour"}
                if ($DiffRPOHours -ge 2) {$hours = "Hours"}
                
                if (($DiffRPODays -eq 0) -and ($FullforDiffRPODays -lt 7)) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackup'>$BakLastWriteTime</td><td class='spdbdiff'>$DiffLastWriteTime</td><td class='spdbrpo'>$DiffRPOHours $hours</td><td class='spdbstatus'>Protected</td></tr>"}
                if (($DiffRPODays -ge 1) -and ($FullforDiffRPODays -lt 7)) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackuperror'>$BakLastWriteTime</td><td class='spdbdifferror'>$DiffLastWriteTime</td><td class='spdbrpoerror'>$DiffRPODays $days, $DiffRPOHours $hours</td><td class='spdbstatuserror'>RPO breached</td></tr>"}
                if (($DiffRPODays -eq 0) -and ($FullforDiffRPODays -ge 7)) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackuperror'>$BakLastWriteTime</td><td class='spdbdifferror'>$DiffLastWriteTime</td><td class='spdbrpoerror'>$DiffRPOHours $hours</td><td class='spdbstatuserror'>Previous full weekly backup failed</td></tr>"}
                if (($DiffRPODays -ge 1) -and ($FullforDiffRPODays -ge 7)) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackuperror'>$BakLastWriteTime</td><td class='spdbdifferror'>$DiffLastWriteTime</td><td class='spdbrpoerror'>$DiffRPODays $days, $DiffRPOHours $hours</td><td class='spdbstatuserror'>Previous full weekly backup failed<br> - RPO breached</td></tr>"}
           
                if (($DiffRPODays -ge 1) -and ($FullforDiffRPODays -lt 7)) {Write-Output "$Database - $DiffRPODays $days, $DiffRPOHours $hours" 
                    $VerifiedCount -= 1}
                if (($DiffRPODays -eq 0) -and ($FullforDiffRPODays -ge 7)) {Write-Output "$Database - $DiffRPOHours $hours - Previous weekly full backup failed"
                    $VerifiedCount -= 1}
                if (($DiffRPODays -ge 1) -and ($FullforDiffRPODays -ge 7)) {Write-Output "$Database - $DiffRPODays $days, $DiffRPOHours $hours"
                    $VerifiedCount -= 1}
            }
            
            #When full backup is newer than differential

            if ((get-date $BakFileInfo.LastWriteTime) -gt (get-date $DiffFileInfo.LastWriteTime)) 
            {
                $FullTimeDifference = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(($BakFileInfo.LastWriteTime), 'Eastern Standard Time') | New-TimeSpan
                $FullRPODays = $FullTimeDifference.Days
                $FullRPOHours = $FullTimeDifference.Hours

                if ($FullRPODays -eq 0)  {$days = "Days"}
                if ($FullRPODays -eq 1)  {$days = "Day"}
                if ($FullRPODays -ge 2)  {$days = "Days"}
                if ($FullRPOHours -eq 0) {$hours = "Hours"}
                if ($FullRPOHours -eq 1) {$hours = "Hour"}
                if ($FullRPOHours -ge 2) {$hours = "Hours"}
                
                if ($FullRPODays -eq 0) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackup'>$BakLastWriteTime</td><td class='spdbdiff'>$DiffLastWriteTime</td><td class='spdbrpo'>$FullRPOHours $hours</td><td class='spdbstatus'>Protected</td></tr>"}
                if ($FullRPODays -ge 1) {$TableData += "<tr><td class='name'>$Database</td><td class='spdbbackuperror'>$BakLastWriteTime</td><td class='spdbdifferror'>$DiffLastWriteTime</td><td class='spdbrpoerror'>$FullRPODays $days, $FullRPOHours $hours</td><td class='spdbstatuserror'>RPO breached</td></tr>"}
                if ($FullRPODays -ge 1) {Write-Output "$Database - $FullRPODays $days, $FullRPOHours $hours"
                    $VerifiedCount -= 1}
            }
        }
    }

    if ($BakFile.Count -eq 0) 
    {
        $TableData += "<tr><td class='name'>$Database</td><td class='spdbbackuperror'>N/A</td><td class='spdbdifferror'>N/A</td><td class='spdbrpoerror'>N/A</td><td class='spdbstatuserror'>Full backup not found</td></tr>"
        Write-Output "-----$database BACKUP FILE IS MISSING"
        $VerifiedCount -= 1
    }
}

Write-Output "`n`n$VerifiedCount/$TotalCount backups within RPO`n`n`n`n"
$TableData += "<tr><td class='name'><b>$VerifiedCount/$TotalCount backups within RPO</b></td><td class='spdbbackup'></td><td class='spdbdiff'></td><td class='spdbrpo'></td><td class='spdbstatus'></td></tr></table><br><br><br>"
#>

########################################################


<# Needed to change the image in the future
$imagefile = "C:\Users\weinfhow\Documents\Docs\Scripts\HTML formatted missing backup report\Realogy_logo.png"
$ImageBits = [Convert]::ToBase64String((Get-Content $imagefile -Encoding Byte))
$ImageHTML = "<img src=data:image/png;base64,$($ImageBits) alt='Realogy Logo'/>"
#>


$Message.Body = Get-Content "$PSScriptRoot\Base HTML for missing backup report.txt"
$Message.Body += "<br><br><br><br><br><br><br></head><body><h4>SQL backup status:</h4><br><br>"
$Message.Body += $TableData
$Message.Body += "</body></html>"
$Message.Body | Out-File -FilePath $Outputfile -Append
#Invoke-Item $outputfile

$Smtp = New-Object Net.Mail.SmtpClient($SmtpServer)


$maxretry = 3

while ($true -and $maxretry -gt 0)
{
    $Smtp.Send($Message)
    
    if ($?)
    {
        "`n`nEmail sent!`n`n`n"
        break
    }
    
    else 
    {
        $maxretry -= 1
        Write-Output "Email failed to send. Retrying $maxretry more time(s).`n`n" 
    }
}


Stop-Transcript | Out-Null
