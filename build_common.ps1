# TODO:
# Kill xcomgame if the script is canceled since we longer send ctrl+c down the process tree when stopping from msbuild host
# Redirect and process shader compiler's output
# Inject warning/error repoting functions from msbuild host, check if they exist in script
# - https://docs.microsoft.com/en-us/powershell/scripting/developer/hosting/runspace10-sample?view=powershell-7.1
# - https://stackoverflow.com/questions/3919798/how-to-check-if-a-cmdlet-exists-in-powershell-at-runtime-via-script

# if ($false) {
# 	function TestFunc($message) {
# 		Write-Host "TestFunc"
# 	}
# }

Write-Host "Build Common Loading"

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$global:def_robocopy_args = @("/S", "/E", "/DCOPY:DA", "/COPY:DAT", "/PURGE", "/MIR", "/NP", "/R:1000000", "/W:30")
$global:buildCommonSelfPath = split-path -parent $MyInvocation.MyCommand.Definition
# list of all native script packages
$global:nativescriptpackages = @("XComGame", "Core", "Engine", "GFxUI", "AkAudio", "GameFramework", "UnrealEd", "GFxUIEditor", "IpDrv", "OnlineSubsystemPC", "OnlineSubsystemLive", "OnlineSubsystemSteamworks", "OnlineSubsystemPSN")

class BuildProject {
	[string] $modNameCanonical
	[string] $projectRoot
	[string] $sdkPath
	[string] $gamePath
	[string] $contentOptionsJsonPath
	[int] $publishID = -1
	[bool] $compileTest = $false
	[bool] $debug = $false
	[bool] $final_release = $false
	[string[]] $include = @()
	[string[]] $clean = @()
	[object[]] $preMakeHooks = @()

	# lazily set
	[string] $modSrcRoot
	[string] $devSrcRoot
	[string] $stagingPath
	[string] $commandletHostPath
	[string] $buildCachePath
	[string] $modcookdir
	[string[]] $thismodpackages
	[bool] $isHl
	[bool] $cookHL
	[PSCustomObject] $contentOptions
	[string] $defaultEnginePath
	[string] $defaultEngineContentOriginal
	[string] $assetsCookTfcSuffix


	BuildProject(
		[string]$mod,
		[string]$projectRoot,
		[string]$sdkPath,
		[string]$gamePath
	){
		$this.modNameCanonical = $mod
		$this.projectRoot = $projectRoot
		$this.sdkPath = $sdkPath
		$this.gamePath = $gamePath
	}

	[void]SetContentOptionsJsonPath($path) {
		if (!(Test-Path $path)) { ThrowFailure "ContentOptionsJsonPath $path doesn't exist" }
		$this.contentOptionsJsonPath = $path
	}

	[void]SetWorkshopID([int] $publishID) {
		if ($publishID -le 0) { ThrowFailure "publishID must be >0" }
		$this.publishID = $publishID
	}

	[void]EnableCompileTest() {
		$this.compileTest = $true
	}

	[void]EnableFinalRelease() {
		$this.final_release = $true
		$this._CheckFlags()
	}

	[void]EnableDebug() {
		$this.debug = $true
		$this._CheckFlags()
	}

	[void]AddPreMakeHook([Action[]] $action) {
		$this.preMakeHooks += $action
	}

	[void]AddToClean([string] $modName) {
		$this.clean += $modName
	}

	[void]IncludeSrc([string] $src) {
		if (!(Test-Path $src)) { ThrowFailure "include path $src doesn't exist" }
		$this.include += $src
	}

	[void]InvokeBuild() {
		try {
			# TestFunc("From TestFunc");
			$this._ConfirmPaths()
			$this._LoadContentOptions()
			$this._SetupUtils()
			$this._ValidateProjectFiles()
			$this._Clean()
			$this._CopyModToSdk()
			$this._ConvertLocalization()
			$this._CopyToSrc()
			$this._RunPreMakeHooks()
			$this._RunMakeBase()
			$this._RunMakeMod()
			if ($this.isHl) {
				if (-not $this.debug) {
					$this._RunCookHL()
				} else {
					Write-Host "Skipping cooking as debug build"
				}
			}
			$this._CopyScriptPackages()
			
			# The shader step needs to happen before cooking - precompiler gets confused by some inlined materials
			$this._PrecompileShaders()
	
			$this._RunCookAssets()
	
			# Do this last as there is no need for it earlier - the cooker obviously has access to the game assets
			# and precompiling shaders seems to do nothing (I assume they are included in the game's GlobalShaderCache)
			# TODO: test shaders that were not inlined into maps/SF packages
			$this._CopyMissingUncooked()
	
			$this._FinalCopy()

			SuccessMessage "*** SUCCESS! ***" $this.modNameCanonical
		}
		catch {
			[System.Media.SystemSounds]::Hand.Play()
			throw
		}
	}

	[void]_CheckFlags() {
		if ($this.debug -eq $true -and $this.final_release -eq $true)
		{
			ThrowFailure "-debug and -final_release cannot be used together"
		}
	}

	[void]_ConfirmPaths() {
		Write-Host "SDK Path: $($this.sdkPath)"
		Write-Host "Game Path: $($this.gamePath)"
	
		# Check if the user config is set up correctly
		if (([string]::IsNullOrEmpty($this.sdkPath) -or $this.sdkPath -eq '${config:xcom.highlander.sdkroot}') -or ([string]::IsNullOrEmpty($this.gamePath) -or $this.gamePath -eq '${config:xcom.highlander.gameroot}'))
		{
			ThrowFailure "Please set up user config xcom.highlander.sdkroot and xcom.highlander.gameroot"
		}
		elseif (!(Test-Path $this.sdkPath)) # Verify the SDK and game paths exist before proceeding
		{
			ThrowFailure ("The path '{}' doesn't exist. Please adjust the xcom.highlander.sdkroot variable in your user config and retry." -f $this.sdkPath)
		}
		elseif (!(Test-Path $this.gamePath)) 
		{
			ThrowFailure ("The path '{}' doesn't exist. Please adjust the xcom.highlander.gameroot variable in your user config and retry." -f $this.gamePath)
		}
	}

	[void]_LoadContentOptions() {
		Write-Host "Preparing content options"

		if ([string]::IsNullOrEmpty($this.contentOptionsJsonPath))
		{
			$this.contentOptions = [PSCustomObject]@{}
		}
		else
		{
			$this.contentOptions = Get-Content $this.contentOptionsJsonPath | ConvertFrom-Json
			Write-Host "Loaded $($this.contentOptionsJsonPath)"
		}

		if (($this.contentOptions.PSobject.Properties | ForEach-Object {$_.Name}) -notcontains "missingUncooked")
		{
			Write-Host "No missing uncooked"
			$this.contentOptions | Add-Member -MemberType NoteProperty -Name 'missingUncooked' -Value @()
		}
		
		if (($this.contentOptions.PSobject.Properties | ForEach-Object {$_.Name}) -notcontains "packagesToMakeSF")
		{
			Write-Host "No packages to make SF"
			$this.contentOptions | Add-Member -MemberType NoteProperty -Name 'packagesToMakeSF' -Value @()
		}
		
		if (($this.contentOptions.PSobject.Properties | ForEach-Object {$_.Name}) -notcontains "umapsToCook")
		{
			Write-Host "No umaps to cook"
			$this.contentOptions | Add-Member -MemberType NoteProperty -Name 'umapsToCook' -Value @()
		}
	}

	[void]_SetupUtils() {
		$this.modSrcRoot = "$($this.projectRoot)\$($this.modNameCanonical)"
		$this.stagingPath = "$($this.sdkPath)\XComGame\Mods\$($this.modNameCanonical)"
		$this.devSrcRoot = "$($this.sdkPath)\Development\Src"
		$this.commandletHostPath = "$($this.sdkPath)/binaries/Win64/XComGame.com"

		# build package lists we'll need later and delete as appropriate
		# the mod's packages
		$this.thismodpackages = Get-ChildItem "$($this.modSrcRoot)/Src" -Directory

		$this.isHl = $this._HasNativePackages()
		$this.cookHL = $this.isHl -and -not $this.debug

		if (-not $this.isHl -and $this.final_release) {
			ThrowFailure "-final_release only makes sense if the mod in question is a Highlander"
		}

		$this.modcookdir = [io.path]::combine($this.sdkPath, 'XComGame', 'Published', 'CookedPCConsole')

		$this.buildCachePath = [io.path]::combine($this.projectRoot, 'BuildCache')
		if (!(Test-Path $this.buildCachePath))
		{
			New-Item -ItemType "directory" -Path $this.buildCachePath
		}
	}

	[void]_CopyModToSdk() {
		$xf = @("*.x2proj")
		if (-not $this.compileTest) {
			$xf += "*_Compiletest.uc"
		}
		
		Write-Host "Copying mod project to staging..."
		Robocopy.exe "$($this.modSrcRoot)" "$($this.sdkPath)\XComGame\Mods\$($this.modNameCanonical)" *.* $global:def_robocopy_args /XF @xf
		Write-Host "Copied project to staging."

		New-Item "$($this.stagingPath)/Script" -ItemType Directory

		# read mod metadata from the x2proj file
		Write-Host "Reading mod metadata from $($this.modSrcRoot)\$($this.modNameCanonical).x2proj..."
		[xml]$x2projXml = Get-Content -Path "$($this.modSrcRoot)\$($this.modNameCanonical).x2proj"
		$modProperties = $x2projXml.Project.PropertyGroup[0]
		$publishedId = $modProperties.SteamPublishID
		if ($this.publishID -ne -1) {
			$publishedId = $this.publishID
			Write-Host "Using override workshop ID of $publishedId"
		}
		$title = $modProperties.Name
		$description = $modProperties.Description
		Write-Host "Read."

		Write-Host "Writing mod metadata..."
		Set-Content "$($this.sdkPath)/XComGame/Mods/$($this.modNameCanonical)/$($this.modNameCanonical).XComMod" "[mod]`npublishedFileId=$publishedId`nTitle=$title`nDescription=$description`nRequiresXPACK=true"
		Write-Host "Written."

		# Create CookedPCConsole folder for the mod
		if ($this.cookHL) {
			New-Item "$($this.stagingPath)/CookedPCConsole" -ItemType Directory
		}
	}

	# This function verifies that all project files in the mod subdirectories actually exist in the .x2proj file
	# The exception are the Content files since those have no reason to be listed in the modbuddy project
	[void]_ValidateProjectFiles()
	{
		Write-Host "Checking for missing entries in .x2proj file..."
		$projFilepath = "$($this.modSrcRoot)\$($this.modNameCanonical).x2proj"
		if(Test-Path $projFilepath)
		{
			$missingFiles = New-Object System.Collections.Generic.List[System.Object]
			$projContent = Get-Content $projFilepath
			# Loop through all files in subdirectories and fail the build if any filenames are missing inside the project file
			Get-ChildItem $this.modSrcRoot -Directory | Get-ChildItem -File -Recurse |
			ForEach-Object {
				# Compiletest file is allowed to be missing because it's not commited and manually edited
				if ($_.Name -Match "_Compiletest\.uc$") {
					return
				}

				# This catches both [Mod]/Content/ and [Mod]/ContentForCook/
				if ($_.FullName.Contains("$($this.modNameCanonical)\Content")) {
					return
				}

				if ($projContent | Select-String -Pattern $_.Name) {
					return
				}

				$missingFiles.Add($_.Name)
			}

			if ($missingFiles.Count -gt 0)
			{
				$strFiles = $missingFiles -join "`r`n`t"
				ThrowFailure "Filenames missing in the .x2proj file:`n`t$strFiles"
			}
		}
		else
		{
			ThrowFailure "The project file '$projFilepath' doesn't exist"
		}
	}

	
	[void]_Clean() {
		Write-Host "Cleaning mod project at $($this.stagingPath)..."
		if (Test-Path $this.stagingPath) {
			Remove-Item $this.stagingPath -Recurse -WarningAction SilentlyContinue
		}
		Write-Host "Cleaned."

		Write-Host "Cleaning additional mods..."
		# clean
		foreach ($modName in $this.clean) {
			$cleanDir = "$($this.sdkPath)/XComGame/Mods/$($modName)"
    		if (Test-Path $cleanDir) {
				Write-Host "Cleaning $($modName)..."
				Remove-Item -Recurse -Force $cleanDir
			}
    	}
		Write-Host "Cleaned."
	}

	[void]_ConvertLocalization() {
		Write-Host "Converting the localization file encoding..."
		Get-ChildItem "$($this.stagingPath)\Localization" -Recurse -File | 
		Foreach-Object {
			$content = Get-Content $_.FullName -Encoding UTF8
			$content | Out-File $_.FullName -Encoding Unicode
		}
	}

	[void]_CopyToSrc() {
		# mirror the SDK's SrcOrig to its Src
		Write-Host "Mirroring SrcOrig to Src..."
		Robocopy.exe "$($this.sdkPath)\Development\SrcOrig" "$($this.devSrcRoot)" *.uc *.uci $global:def_robocopy_args
		Write-Host "Mirrored SrcOrig to Src."

		# Copy dependencies
		Write-Host "Copying dependency sources to Src..."
		foreach ($depfolder in $this.include) {
			Get-ChildItem "$($depfolder)" -Directory -Name | Write-Host
			$this._CopySrcFolder($depfolder)
		}
		Write-Host "Copied dependency sources to Src."

		# copying the mod's scripts to the script staging location
		Write-Host "Copying the mod's sources to Src..."
		$this._CopySrcFolder("$($this.stagingPath)\Src")
		Write-Host "Copied mod sources to Src."
	}

	[void]_CopySrcFolder([string] $includeDir) {
		Copy-Item "$($includeDir)\*" "$($this.devSrcRoot)\" -Force -Recurse -WarningAction SilentlyContinue
		if (Test-Path "$($includeDir)\extra_globals.uci") {
			# append extra_globals.uci to globals.uci
			Get-Content "$($includeDir)\extra_globals.uci" | Add-Content "$($this.devSrcRoot)\Core\Globals.uci"
		}
	}

	[void]_RunPreMakeHooks() {
		Write-Host "Invoking pre-Make hooks"
		foreach ($hook in $this.preMakeHooks) {
			$hook.Invoke()
		}
	}

	[void]_RunMakeBase() {
		# build the base game scripts
		Write-Host "Compiling base game scripts..."
		$scriptsMakeArguments = "make -nopause -unattended"
		if ($this.final_release -eq $true)
		{
			$scriptsMakeArguments = "$scriptsMakeArguments -final_release"
		}
		if ($this.debug -eq $true)
		{
			$scriptsMakeArguments = "$scriptsMakeArguments -debug"
		}
		Invoke-Make $this.commandletHostPath $scriptsMakeArguments $this.sdkPath $this.modSrcRoot
		if ($LASTEXITCODE -ne 0)
		{
			ThrowFailure "Failed to compile base game scripts!"
		}
		Write-Host "Compiled base game scripts."

		# If we build in final release, we must build the normal scripts too
		if ($this.final_release -eq $true)
		{
			Write-Host "Compiling base game scripts without final_release..."
			Invoke-Make $this.commandletHostPath "make -nopause -unattended" $this.sdkPath $this.modSrcRoot
			if ($LASTEXITCODE -ne 0)
			{
				ThrowFailure "Failed to compile base game scripts without final_release!"
			}
		}
	}

	[void]_RunMakeMod() {
		# build the mod's scripts
		Write-Host "Compiling mod scripts..."
		$scriptsMakeArguments = "make -nopause -mods $($this.modNameCanonical) $($this.stagingPath)"
		if ($this.debug -eq $true)
		{
			$scriptsMakeArguments = "$scriptsMakeArguments -debug"
		}
		Invoke-Make $this.commandletHostPath $scriptsMakeArguments $this.sdkPath $this.modSrcRoot
		if ($LASTEXITCODE -ne 0)
		{
			ThrowFailure "Failed to compile mod scripts!"
		}
		Write-Host "Compiled mod scripts."
	}

	[bool]_HasNativePackages() {
		# Check if this is a Highlander and we need to cook things
		$anynative = $false
		foreach ($name in $this.thismodpackages) 
		{
			if ($global:nativescriptpackages.Contains($name)) {
				$anynative = $true
				break
			}
		}
		return $anynative
	}

	[void]_CopyScriptPackages() {
		# copy packages to staging
		Write-Host "Copying the compiled or cooked packages to staging..."
		foreach ($name in $this.thismodpackages) {
			if ($this.cookHL -and $global:nativescriptpackages.Contains($name))
			{
				# This is a native (cooked) script package -- copy important upks
				Copy-Item "$($this.modcookdir)\$name.upk" "$($this.stagingPath)\CookedPCConsole" -Force -WarningAction SilentlyContinue
				Copy-Item "$($this.modcookdir)\$name.upk.uncompressed_size" "$($this.stagingPath)\CookedPCConsole" -Force -WarningAction SilentlyContinue
				Write-Host "$($this.modcookdir)\$name.upk"
			}
			else
			{
				# Or this is a non-native package
				Copy-Item "$($this.sdkPath)\XComGame\Script\$name.u" "$($this.stagingPath)\Script" -Force -WarningAction SilentlyContinue
				Write-Host "$($this.sdkPath)\XComGame\Script\$name.u"        
			}
		}
		Write-Host "Copied compiled and cooked script packages."
	}

	[void]_PrecompileShaders() {
		Write-Host "Checking the need to PrecompileShaders"
		$contentfiles = @()

		if (Test-Path "$($this.modSrcRoot)/Content")
		{
			$contentfiles = $contentfiles + (Get-ChildItem "$($this.modSrcRoot)/Content" -Include *.upk, *.umap -Recurse -File)
		}
		
		if (Test-Path "$($this.modSrcRoot)/ContentForCook")
		{
			$contentfiles = $contentfiles + (Get-ChildItem "$($this.modSrcRoot)/ContentForCook" -Include *.upk, *.umap -Recurse -File)
		}

		if ($contentfiles.length -eq 0) {
			Write-Host "No content files, skipping PrecompileShaders."
			return
		}

		# for ($i = 0; $i -lt $contentfiles.Length; $i++) {
		# 	Write-Host $contentfiles[$i]
		# }

		$need_shader_precompile = $false
		$shaderCacheName = "$($this.modNameCanonical)_ModShaderCache.upk"
		$cachedShaderCachePath = "$($this.buildCachePath)/$($shaderCacheName)"
		
		# Try to find a reason to precompile the shaders
		# TODO: Deleting a content file currently does not trigger re-precompile
		if (!(Test-Path -Path $cachedShaderCachePath))
		{
			$need_shader_precompile = $true
		} 
		elseif ($contentfiles.length -gt 0)
		{
			$shader_cache = Get-Item $cachedShaderCachePath
			
			foreach ($file in $contentfiles)
			{
				if ($file.LastWriteTime -gt $shader_cache.LastWriteTime -Or $file.CreationTime -gt $shader_cache.LastWriteTime)
				{
					$need_shader_precompile = $true
					break
				}
			}
		}
		
		if ($need_shader_precompile)
		{
			# build the mod's shader cache
			# TODO: Commandlet can crash and the exit code will still be 0 - need to treat as proper failure (see script compiler and cooker)
			Write-Host "Precompiling Shaders..."
			&"$($this.commandletHostPath)" precompileshaders -nopause platform=pc_sm4 DLC=$($this.modNameCanonical)
			if ($LASTEXITCODE -ne 0)
			{
				ThrowFailure "Failed to compile mod shader cache!"
			}
			Write-Host "Generated Shader Cache."

			Copy-Item -Path "$($this.stagingPath)/Content/$shaderCacheName" -Destination $this.buildCachePath
		}
		else
		{
			Write-Host "No reason to precompile shaders, using existing"
			Copy-Item -Path $cachedShaderCachePath -Destination "$($this.stagingPath)/Content"
		}
	}

	[void]_RunCookAssets() {
		if (($this.contentOptions.packagesToMakeSF.Length -lt 1) -and ($this.contentOptions.umapsToCook.Length -lt 1)) {
			Write-Host "No asset cooking is requested, skipping"
			return
		}

		if (-not(Test-Path "$($this.modSrcRoot)/ContentForCook"))
		{
			ThrowFailure "Asset cooking is requested, but no ContentForCook folder is present"
		}

		Write-Host "Starting assets cooking"

		# Step 0. Basic preparation
		
		$this.assetsCookTfcSuffix = "_$($this.modNameCanonical)_"
		$projectCookCacheDir = [io.path]::combine($this.buildCachePath, 'PublishedCookedPCConsole')
		
		$this.defaultEnginePath = "$($this.sdkPath)/XComGame/Config/DefaultEngine.ini"
		$this.defaultEngineContentOriginal = Get-Content $this.defaultEnginePath | Out-String
		
		$cookOutputDir = [io.path]::combine($this.sdkPath, 'XComGame', 'Published', 'CookedPCConsole')
		$sdkModsContentDir = [io.path]::combine($this.sdkPath, 'XComGame', 'Content', 'Mods')
		
		# First, we need to check that everything is ready for us to do these shenanigans
		# This doesn't use locks, so it can break if multiple builds are running at the same time,
		# so let's hope that mod devs are smart enough to not run simultanoues builds
		
		if ($this.defaultEngineContentOriginal.Contains("HACKS FOR MOD ASSETS COOKING"))
		{
			ThrowFailure "Another cook is already in progress (DefaultEngine.ini)"
		}

		if (Test-Path "$sdkModsContentDir\*")
		{
			ThrowFailure "$sdkModsContentDir is not empty"
		}

		# Prepare the cook output folder
		# TODO: Switch HL cook to junctions as well?
		$previousCookOutputDirPath = $null
		if (Test-Path $cookOutputDir)
		{
			$previousCookOutputDirName = "Pre_$($this.modNameCanonical)_Cook_CookedPCConsole"
			$previousCookOutputDirPath = [io.path]::combine($this.sdkPath, 'XComGame', 'Published', $previousCookOutputDirName)
			
			Rename-Item $cookOutputDir $previousCookOutputDirName
		} 

		# Make sure our local cache folder exists
		$firstModCook = $false
		if (!(Test-Path $projectCookCacheDir))
		{
			New-Item -ItemType "directory" -Path $projectCookCacheDir
			$firstModCook = $true
		}

		if (!$firstModCook) {
			# Even if the directory exists, we need to make sure that the cooker will not attempt to cook gfxCommon_SF
			# This could happen if the preceding first mod cook was interrupted
			if ((!(Test-Path "$projectCookCacheDir\GlobalPersistentCookerData.upk")) -or (!(Test-Path "$projectCookCacheDir\gfxCommon_SF.upk"))) {
				$firstModCook = $true
			}
		}

		# Backup the DefaultEngine.ini
		Copy-Item $this.defaultEnginePath "$($this.sdkPath)/XComGame/Config/DefaultEngine.ini.bak_PRE_ASSET_COOKING"

		try {
			# Redirect all the cook output to our local cache
			# This allows us to not recook everything when switching between projects (e.g. CHL)
			New-Junction $cookOutputDir $projectCookCacheDir

			# "Inject" our assets into the SDK to make them visible to the cooker
			Remove-Item $sdkModsContentDir
			New-Junction $sdkModsContentDir "$($this.modSrcRoot)\ContentForCook"

			if ($firstModCook) {
				# First do a cook without our assets since gfxCommon.upk still get included in the cook, polluting the TFCs, depsite the config hacks

				Write-Host "Running first time mod assets cook"
				$this._InvokeAssetCooker(@(), @())

				# Now delete the polluted TFCs
				Get-ChildItem -Path $projectCookCacheDir -Filter "*$($this.assetsCookTfcSuffix).tfc" | Remove-Item

				Write-Host "First time cook done, proceeding with normal"
			}

			$this._InvokeAssetCooker($this.contentOptions.packagesToMakeSF, $this.contentOptions.umapsToCook)
		}
		finally {
			Write-Host "Cleaninig up the asset cooking hacks"

			# Revert ini
			try {
				$this.defaultEngineContentOriginal | Set-Content $this.defaultEnginePath -NoNewline;
				Write-Host "Reverted $($this.defaultEnginePath)"	
			}
			catch {
				FailureMessage "Failed to revert $($this.defaultEnginePath)"
				FailureMessage $_
			}
			

			# Revert junctions

			try {
				Remove-Junction $cookOutputDir
				Write-Host "Removed $cookOutputDir junction"
			}
			catch {
				FailureMessage "Failed to remove $cookOutputDir junction"
				FailureMessage $_
			}
			

			if (![string]::IsNullOrEmpty($previousCookOutputDirPath))
			{
				try {
					if (Test-Path $cookOutputDir) {
						ThrowFailure "$cookOutputDir still exists, cannot restore previous"
					}

					Rename-Item $previousCookOutputDirPath "CookedPCConsole"
					Write-Host "Restored previous $cookOutputDir"	
				}
				catch {
					FailureMessage "Failed to restore previous $cookOutputDir"
					FailureMessage $_
				}
				
			}
			
			try {
				Remove-Junction $sdkModsContentDir
				New-Item -Path $sdkModsContentDir -ItemType Directory
				Write-Host "Restored $sdkModsContentDir"
			}
			catch {
				FailureMessage "Failed to restore $sdkModsContentDir"
				FailureMessage $_
			}
		}

		# Prepare the folder for cooked stuff
		$stagingCookedDir = [io.path]::combine($this.stagingPath, 'CookedPCConsole')
		New-Item -ItemType "directory" -Path $stagingCookedDir
		
		# Copy over the TFC files
		Get-ChildItem -Path $projectCookCacheDir -Filter "*$($this.assetsCookTfcSuffix).tfc" | Copy-Item -Destination $stagingCookedDir
		
		# Copy over the maps
		for ($i = 0; $i -lt $this.contentOptions.umapsToCook.Length; $i++) 
		{
			$umap = $this.contentOptions.umapsToCook[$i];
			Copy-Item "$projectCookCacheDir\$umap.upk" -Destination $stagingCookedDir
		}
		
		# Copy over the SF packages
		for ($i = 0; $i -lt $this.contentOptions.packagesToMakeSF.Length; $i++) 
		{
			$package = $this.contentOptions.packagesToMakeSF[$i];
            $dest = [io.path]::Combine($stagingCookedDir, "${package}.upk");
			
			# Mod assets for some reason refuse to load with the _SF suffix
			Copy-Item "$projectCookCacheDir\${package}_SF.upk" -Destination $dest
		}

        # No need for the ContentForCook directory anymore
        Remove-Item "$($this.stagingPath)/ContentForCook" -Recurse

		Write-Host "Assets cook completed"
	}

	[void]_InvokeAssetCooker ([string[]] $packagesToMakeSF, [string[]] $umapsToCook) {
		$defaultEngineContentNew = $this.defaultEngineContentOriginal
		$defaultEngineContentNew = "$defaultEngineContentNew`n; HACKS FOR MOD ASSETS COOKING - $($this.modNameCanonical)"

		# Remove various default always seek free packages
		# This will trump the rest of file content as it's all the way at the bottom
		$defaultEngineContentNew = "$defaultEngineContentNew`n[Engine.ScriptPackages]`n!EngineNativePackages=Empty`n!NetNativePackages=Empty`n!NativePackages=Empty"
		$defaultEngineContentNew = "$defaultEngineContentNew`n[Engine.StartupPackages]`n!Package=Empty"
		$defaultEngineContentNew = "$defaultEngineContentNew`n[Engine.PackagesToAlwaysCook]`n!SeekFreePackage=Empty"

		# Add our standalone seek free packages
		for ($i = 0; $i -lt $packagesToMakeSF.Length; $i++) 
		{
			$package = $packagesToMakeSF[$i];
			$defaultEngineContentNew = "$defaultEngineContentNew`n+SeekFreePackage=$package"
		}

		$defaultEngineContentNew | Set-Content $this.defaultEnginePath -NoNewline;
		
		# Invoke cooker
		
		$mapsString = ""
		for ($i = 0; $i -lt $umapsToCook.Length; $i++) 
		{
			$umap = $umapsToCook[$i];
			$mapsString = "$mapsString $umap.umap "
		}
		
		$pinfo = New-Object System.Diagnostics.ProcessStartInfo
		$pinfo.FileName = $this.commandletHostPath
		$pinfo.RedirectStandardOutput = $true
    	$pinfo.RedirectStandardError = $true
		$pinfo.UseShellExecute = $false
		$pinfo.Arguments = "CookPackages $mapsString -platform=pcconsole -skipmaps -modcook -TFCSUFFIX=$($this.assetsCookTfcSuffix) -singlethread -unattended -usermode"
		$pinfo.WorkingDirectory = $this.commandletHostPath | Split-Path

		$messageData = New-Object psobject -property @{
			foundNativeScriptError = $false
			foundRelevantError = $false

			lastLineWasAdding = $false
			permitAdditional = $false

			crashDetected = $false
		}

		# An action for handling data written to stdout
		$outAction = {
			$outTxt = $Event.SourceEventArgs.Data
			$permitLine = $true # Default to true in case there is something we don't handle

			if ($outTxt.StartsWith("Adding package") -or $outTxt.StartsWith("Adding level") -or $outTxt.StartsWith("Adding script") -or $outTxt.StartsWith("GFx movie package")) {
				if ($outTxt.Contains("\Mods\")) {
					$permitLine = $true
				} else {
					$permitLine = $false

					if (!$event.MessageData.lastLineWasAdding) {
						Write-Host "[Adding sdk assets ...]"
					}
				}

				$event.MessageData.lastLineWasAdding = !$permitLine
				$event.MessageData.permitAdditional = $permitLine
			} elseif ($outTxt.StartsWith("Adding additional")) {
				$permitLine = $event.MessageData.permitAdditional
			} else {
				$event.MessageData.lastLineWasAdding = $false
				$permitLine = $true
			}

			if ($permitLine) {
				Write-Host $outTxt
			}

			if ($outTxt.StartsWith("Error")) {
        		# * OnlineSubsystemSteamworks and AkAudio cannot be removed from cook and generate 4 errors when mod is built in debug - needs to be ignored
				if ($outTxt.Contains("AkAudio") -or $outTxt.Contains("OnlineSubsystemSteamworks")) {
					$event.MessageData.foundNativeScriptError = $true
				} else {
					$event.MessageData.foundRelevantError = $true
				}
			}

			if ($outTxt.StartsWith("Crash Detected")) {
				$event.MessageData.crashDetected = $true
			}
		}
		
		# An action for handling data written to stderr
		$errAction = {
			# TODO: Check if anything of value gets written here when something goes wrong
			# (when the only problem is "script compiled in debug" nothing gets printed here)
			$errTxt = $Event.SourceEventArgs.Data
			Write-Host $errTxt
		}

		# Set the exited flag on our exit object on process exit.
		$exitData = New-Object psobject -property @{ exited = $false }
		$exitAction = {
			$event.MessageData.exited = $true
		}

		# Create the process and register for the various events we care about.
		$process = New-Object System.Diagnostics.Process
		Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outAction -MessageData $messageData | Out-Null
		Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errAction | Out-Null
		Register-ObjectEvent -InputObject $process -EventName Exited -Action $exitAction -MessageData $exitData | Out-Null
		$process.StartInfo = $pinfo

		# All systems go!
		$process.Start() | Out-Null
		$process.BeginOutputReadLine()
		$process.BeginErrorReadLine()

		# Wait for the process to exit. This is horrible, but using $process.WaitForExit() blocks
		# the powershell thread so we get no output from make echoed to the screen until the process finishes.
		# By polling we get regular output as it goes.
		try {
			while (!$exitData.exited) {
				# Just spin, otherwise we spend 3 minutes processing all the "Adding [...]" lines
				# Start-Sleep -m 50
			}
		}
		finally {
			# If we are stopping MSBuild hosted build, we need to kill the editor manually
			if (!$exitData.exited) {
				Write-Host "Killing cooker tree"
				KillProcessTree $process.Id
			}
		}

		if ($messageData.crashDetected) {
			ThrowFailure "Cooker crash detected"
		}

		if ($messageData.foundNativeScriptError) {
			Write-Host ""
			Write-Host "Detected errors about AkAudio and/or OnlineSubsystemSteamworks - these are safe to ignore."
			Write-Host "If you want to get rid of them, you would need to build the mod in non-debug mode"
			Write-Host "at least once - the errors will then go away (until the BuildCache folder is cleared/deleted)"
			Write-Host ""
		}

		if ($messageData.foundRelevantError) {
			ThrowFailure "Found a relevant error while cooking assets"
		}

		# Backup in case our output parsing didn't catch something
		if ((!$messageData.foundNativeScriptError) -and ($process.ExitCode -ne 0)) {
			ThrowFailure "Cooker exited with non-0 exit code"
		}
	}

	[void]_RunCookHL() {
		# Cook it
		# Normally, the mod tools create a symlink in the SDK directory to the game CookedPCConsole directory,
		# but we'll just be using the game one to make it more robust
		$cookedpcconsoledir = [io.path]::combine($this.gamePath, 'XComGame', 'CookedPCConsole')
		if(-not(Test-Path $this.modcookdir))
		{
			Write-Host "Creating Published/CookedPCConsole directory..."
			New-Item $this.modcookdir -ItemType Directory
		}

		[System.String[]]$files = "GuidCache.upk", "GlobalPersistentCookerData.upk", "PersistentCookerShaderData.bin"
		foreach ($name in $files) {
			if(-not(Test-Path ([io.path]::combine($this.modcookdir, $name))))
			{
				Write-Host "Copying $name..."
				Copy-Item ([io.path]::combine($cookedpcconsoledir, $name)) $this.modcookdir
			}
		}

		# Ideally, the cooking process wouldn't modify the big *.tfc files, but it does, so we don't overwrite existing ones (/XC /XN /XO)
		# In order to "reset" the cooking direcory, just delete it and let the script recreate them
		Write-Host "Copying Texture File Caches..."
		Robocopy.exe "$cookedpcconsoledir" "$($this.modcookdir)" *.tfc /NJH /XC /XN /XO
		Write-Host "Copied Texture File Caches."

		# Cook it!
		# The CookPackages commandlet generally is super unhelpful. The output is basically always the same and errors
		# don't occur -- it rather just crashes the game. Hence, we just pipe the output to $null
		Write-Host "Invoking CookPackages (this may take a while)"
		$cook_args = @("-platform=pcconsole", "-quickanddirty", "-modcook", "-sha", "-multilanguagecook=INT+FRA+ITA+DEU+RUS+POL+KOR+ESN", "-singlethread", "-nopause")
		if ($this.final_release -eq $true)
		{
			$cook_args += "-final_release"
		}
		
		& "$($this.commandletHostPath)" CookPackages @cook_args >$null 2>&1

		if ($LASTEXITCODE -ne 0)
		{
			ThrowFailure "Failed to cook native script packages!"
		}

		Write-Host "Cooked native script packages."
	}

	[void]_CopyMissingUncooked() {
		if ($this.contentOptions.missingUncooked.Length -lt 1)
		{
			Write-Host "Skipping Missing Uncooked logic"
			return
		}

		Write-Host "Including MissingUncooked"

		$missingUncookedPath = [io.path]::Combine($this.stagingPath, "Content", "MissingUncooked")
		$sdkContentPath = [io.path]::Combine($this.sdkPath, "XComGame", "Content")

		if (!(Test-Path $missingUncookedPath))
		{
			New-Item -ItemType "directory" -Path $missingUncookedPath
		}

		foreach ($fileName in $this.contentOptions.missingUncooked)
		{
			(Get-ChildItem -Path $sdkContentPath -Filter $fileName -Recurse).FullName | Copy-Item -Destination $missingUncookedPath
		}
	}

	[void]_FinalCopy() {
		$finalModPath = "$($this.gamePath)\XComGame\Mods\$($this.modNameCanonical)"

		# Delete the actual game's mod's folder
		# This ensures that files that were deleted in the project will also get deleted in the deployed version
		if (Test-Path $finalModPath)
		{
			Write-Host "Deleting existing deployed mod folder"
			Remove-Item $finalModPath -Force -Recurse
		}

		# copy all staged files to the actual game's mods folder
		# TODO: Is the string interpolation required in the robocopy calls?
		Write-Host "Copying all staging files to production..."
		Robocopy.exe "$($this.stagingPath)" "$($finalModPath)" *.* $global:def_robocopy_args
		Write-Host "Copied mod to game directory."
	}
}

# Helper for invoking the make cmdlet. Captures stdout/stderr and rewrites error and warning lines to fix up the
# source paths. Since make operates on a copy of the sources copied to the SDK folder, diagnostics print the paths
# to the copies. If you try to jump to these files (e.g. by tying this output to the build commands in your editor)
# you'll be editting the copies, which will then be overwritten the next time you build with the sources in your mod folder
# that haven't been changed.
function Invoke-Make([string] $makeCmd, [string] $makeFlags, [string] $sdkPath, [string] $modSrcRoot) {
    # Create a ProcessStartInfo object to hold the details of the make command, its arguments, and set up
    # stdout/stderr redirection.
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $makeCmd
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.Arguments = $makeFlags

    # Create an object to hold the paths we want to rewrite: the path to the SDK 'Development' folder
    # and the 'modSrcRoot' (the directory that holds the .x2proj file). This is needed because the output
    # is read in an action block that is a separate scope and has no access to local vars/parameters of this
    # function.
    $developmentDirectory = Join-Path -Path $sdkPath 'Development'
    $messageData = New-Object psobject -property @{
        developmentDirectory = $developmentDirectory
        modSrcRoot = $modSrcRoot
		crashDetected = $false
    }

    # We need another object for the Exited event to set a flag we can monitor from this function.
    $exitData = New-Object psobject -property @{ exited = $false }

    # An action for handling data written to stdout. The make cmdlet writes all warning and error info to
    # stdout, so we look for it here.
    $outAction = {
        $outTxt = $Event.SourceEventArgs.Data
        # Match warning/error lines
        $messagePattern = "^(.*)\(([0-9]*)\) : (.*)$"
        if (($outTxt -Match "Error|Warning") -And ($outTxt -Match $messagePattern)) {
            # And just do a regex replace on the sdk Development directory with the mod src directory.
            # The pattern needs escaping to avoid backslashes in the path being interpreted as regex escapes, etc.
            $pattern = [regex]::Escape($event.MessageData.developmentDirectory)
            # n.b. -Replace is case insensitive
            $replacementTxt = $outtxt -Replace $pattern, $event.MessageData.modSrcRoot
            $outTxt = $replacementTxt -Replace $messagePattern, '$1:$2 : $3'
        }

        $summPattern = "^(Success|Failure) - ([0-9]+) error\(s\), ([0-9]+) warning\(s\) \(([0-9]+) Unique Errors, ([0-9]+) Unique Warnings\)"
        if (-Not ($outTxt -Match "Warning/Error Summary") -And $outTxt -Match "Warning|Error") {
            if ($outTxt -Match $summPattern) {
                $numErr = $outTxt -Replace $summPattern, '$2'
                $numWarn = $outTxt -Replace $summPattern, '$3'
                if (([int]$numErr) -gt 0) {
                    $clr = "Red"
                } elseif (([int]$numWarn) -gt 0) {
                    $clr = "Yellow"
                } else {
                    $clr = "Green"
                }
            } else {
                if ($outTxt -Match "Error") {
                    $clr = "Red"
                } else {
                    $clr = "Yellow"
                }
            }
            Write-Host $outTxt -ForegroundColor $clr
        } else {
            Write-Host $outTxt
        }

		if ($outTxt.StartsWith("Crash Detected")) {
			$event.MessageData.crashDetected = $true
		}
    }

    # An action for handling data written to stderr. The make cmdlet doesn't seem to write anything here,
    # or at least not diagnostics, so we can just pass it through.
    $errAction = {
        $errTxt = $Event.SourceEventArgs.Data
        Write-Host $errTxt
    }

    # Set the exited flag on our exit object on process exit.
    $exitAction = {
        $event.MessageData.exited = $true
    }

    # Create the process and register for the various events we care about.
    $process = New-Object System.Diagnostics.Process
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outAction -MessageData $messageData | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errAction | Out-Null
    Register-ObjectEvent -InputObject $process -EventName Exited -Action $exitAction -MessageData $exitData | Out-Null
    $process.StartInfo = $pinfo

    # All systems go!
    $process.Start() | Out-Null
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Wait for the process to exit. This is horrible, but using $process.WaitForExit() blocks
    # the powershell thread so we get no output from make echoed to the screen until the process finishes.
    # By polling we get regular output as it goes.
	try {
		while (!$exitData.exited) {
			Start-Sleep -m 50
		}	
	}
	finally {
		# If we are stopping MSBuild hosted build, we need to kill the editor manually
		if (!$exitData.exited) {
			Write-Host "Killing script compiler tree"
			KillProcessTree $process.Id
		}
	}

	$exitCode = $process.ExitCode

	if ($messageData.crashDetected -and ($exitCode -eq 0)) {
		# If the commandlet crashes, it can still exit with 0, causing us to happily continue the build
		# To prevent so, fake an error exit code
		$exitCode = 1
	}

	# Explicitly set LASTEXITCODE from the process exit code so the rest of the script
    # doesn't need to care if we launched the process in the background or via "&".
    $global:LASTEXITCODE = $exitCode
}


function FailureMessage($message)
{
	[System.Media.SystemSounds]::Hand.Play()
	Write-Host $message -ForegroundColor "Red"
}

function ThrowFailure($message)
{
	throw $message
}

function SuccessMessage($message, $modNameCanonical)
{
    [System.Media.SystemSounds]::Asterisk.Play()
    Write-Host $message -ForegroundColor "Green"
    Write-Host "$modNameCanonical ready to run." -ForegroundColor "Green"
}

function New-Junction ([string] $source, [string] $destination) {
	&"$global:buildCommonSelfPath\junction.exe" -nobanner -accepteula "$source" "$destination"
}

function Remove-Junction ([string] $path) {
	&"$global:buildCommonSelfPath\junction.exe" -nobanner -accepteula -d "$path"
}

# https://stackoverflow.com/a/55942155/2588539
# $process.Kill() works but we really need to kill the child as well, since it's the one which is actually doing work
# Unfotunately, $process.Kill($true) does nothing 
function KillProcessTree ([int] $ppid) {
    Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ppid } | ForEach-Object { KillProcessTree $_.ProcessId }
    Stop-Process -Id $ppid
}