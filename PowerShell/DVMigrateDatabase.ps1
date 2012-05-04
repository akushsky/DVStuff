##### Include all PowerShell files in current directory #####

$scriptName = split-path -leaf $MyInvocation.MyCommand.Definition
$rootPath = split-path -parent $MyInvocation.MyCommand.Definition
$scripts = gci -re $rootPath -in *.ps1 | ?{ $_.Name -ne $scriptName }
foreach ( $item in $scripts ) {
  . $item.FullName
}

##### Variables and structs #####

# Replace SDDL in each row only once 
$IDList = New-Object System.Collections.Generic.HashSet[Guid]

# Struct for log
add-type @"
public struct DVObject {
   public string ID;
   public string Description;
   public string Accounts;
}
"@

# List of all replaced SDDL
$DVObjectList =  New-GenericObject System.Collections.Generic.List DVObject

# Set new object to connect to sql database
$SqlConnection = new-object system.data.sqlclient.sqlconnection

# Connectiong string setting for local machine database with window authentication
$SqlConnection.ConnectionString = "server=" + $SQLServerName + ";database=" + $SQLDatabaseName + ";trusted_connection=True" 

Write-host "connection information:"

# List connection information
$SqlConnection

Write-host "connect to database successful."

# Connecting successful
$SqlConnection.open()

# Setting object to use sql commands
$SelectSqlCmd = New-Object System.Data.SqlClient.SqlCommand
$SelectSqlCmd.Connection = $SqlConnection

$UpdateSqlCmd = New-Object System.Data.SqlClient.SqlCommand
$UpdateSqlCmd.Connection = $SqlConnection

##### Get data and start replace #####

# Select query for all objects of system
$SqlQuery = 
"SELECT I.InstanceID, I.Description, S.ID, S.SecurityDesc
FROM [DV-BASE].[dbo].[dvsys_security] S
LEFT JOIN [DV-BASE].[dbo].[dvsys_instances] I
ON I.SDID = S.ID"

# Execute query on server
$SelectSqlCmd.CommandText = $SqlQuery
$SqlDataReader = $SelectSqlCmd.ExecuteReader()

# Get all data from server
$DataTable = New-Object System.Data.DataTable
$DataTable.Load($SqlDataReader)

# Close reading transaction
$SqlDataReader.Close()

# Then explore each row and replace SID
foreach ($row in $DataTable)
{
	# We need only one SQL-request for each ID
	if ($IDList.Contains($row["ID"])) {continue}
	else {$isOk = $IDList.Add($row["ID"])}
	
	# Convert SDDL from Base64 to binary form
	$ObjectWithSDDL = ([wmiclass]"Win32_SecurityDescriptorHelper").BinarySDToSDDL([System.Convert]::FromBase64String($row["SecurityDesc"]))
	$sddl = $ObjectWithSDDL.SDDL
	
	# Update only if something replaced
	$replaceComplete = $false
	
	# Init new object with info
	$dvobject = New-Object DVObject
	$dvobject.ID = $row["ID"]
	$dvobject.Description = $row["Description"]	
	
	##### Replace all SIDs in current SDDL #####
	
	# Match all SIDs and replace
    [regex]::Matches($sddl,"(S(-\d+){2,8})") | sort index -desc | % {
		if ($SIDReplacement.ContainsKey($_.ToString()))
		{	
			# Translate NT account name to SID
			$objUser = New-Object System.Security.Principal.NTAccount($SIDReplacement[$_.ToString()])
			$strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
		
			# Replace it in SDDL
			$sddl = $sddl.Remove($_.index,$_.length)
			$sddl = $sddl.Insert($_.index,$strSID.Value)
			
			# Add to list of current object accounts
			$dvobject.Accounts += $SIDReplacement[$_.ToString()]
			$dvobject.Accounts += "`n"
			
			# Set replace completed
			$replaceComplete = $true
		}
	}
	
	if ($replaceComplete)
	{
		# Add current info object to list
		$DVObjectList.Add($dvobject)
		
		$binarySDDL = ([wmiclass]"Win32_SecurityDescriptorHelper").SDDLToBinarySD($sddl).BinarySD
		$ret = [System.Convert]::ToBase64String($binarySDDL)
		
		##### Update database #####
		
		# Update query for currently replaced SDDL
		$SqlQuery = 
		"UPDATE [dbo].[dvsys_security]
		 SET Hash = '" + $binarySDDL.GetHashCode() + "', SecurityDesc = '" + $ret + "'
		 WHERE ID = CONVERT(uniqueidentifier, '" + $row["ID"] + "')"
		 
		# Attach query to command
		$UpdateSqlCmd.CommandText = $SqlQuery
		
		# Execute update query
		if ($UpdateSqlCmd.ExecuteNonQuery())
		{
			Write-host "Update true for ID: " $row["ID"]
		}
		else
		{
			Write-host "Update false for ID: " $row["ID"]
		}
	}
}

# Write log to file
$DVObjectList `
	| Format-Table -Wrap `
	| Out-String `
	| Out-File MigrateDB.txt

# Close SQL connection
$SqlConnection.Close()