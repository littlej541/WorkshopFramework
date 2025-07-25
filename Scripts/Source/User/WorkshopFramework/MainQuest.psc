; ---------------------------------------------
; WorkshopFramework:MainQuest.psc - by kinggath
; ---------------------------------------------
; Reusage Rights ------------------------------
; You are free to use this script or portions of it in your own mods, provided you give me credit in your description and maintain this section of comments in any released source code (which includes the IMPORTED SCRIPT CREDIT section to give credit to anyone in the associated Import scripts below.
;
; Warning !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
; Do not directly recompile this script for redistribution without first renaming it to avoid compatibility issues issues with the mod this came from.
;
; IMPORTED SCRIPT CREDIT
; N/A
; ---------------------------------------------

Scriptname WorkshopFramework:MainQuest extends WorkshopFramework:Library:MasterQuest

import WorkshopFramework:Library:DataStructures
import WorkshopFramework:Library:UtilityFunctions
import WorkshopFramework:WorkshopFunctions

CustomEvent PlayerEnteredSettlement
CustomEvent PlayerExitedSettlement

; ---------------------------------------------
; Consts
; ---------------------------------------------

Int iTimerID_BuildableAreaCheck = 100 Const
Float fTimerLength_BuildableAreaCheck = 3.0 Const

Int iTimerID_BuildableAreaCheckForEntry = 150 Const
Float fTimerLength_BuildableAreaCheckForEntry = 3.0 Const 

Int iTimerID_BuildableAreaCheckForExit = 175 Const
Float fTimerLength_BuildableAreaCheckForExit = 3.0 Const 

Int iTimerID_WaitToSendExitEvent = 200 Const
Float fTimerLength_WaitToSendExitEvent = 5.0

Int iEntryExitStatus_Clear = 0 Const
Int iEntryExitStatus_EnterWaitingForBuildArea = 1 Const
Int iEntryExitStatus_In = 2 Const
Int iEntryExitStatus_ExitWaitingForBuildArea = 3 Const
Int iEntryExitStatus_ExitWaitingForTimer = 4 Const

; ---------------------------------------------
; Editor Properties
; ---------------------------------------------

Group Controllers
	WorkshopParentScript Property WorkshopParent Auto Const Mandatory
	WorkshopTutorialScript Property TutorialQuest Auto Const Mandatory
	{ 1.0.7 - Adding ability to control this quest }
	
	PluginInstalledGlobal[] Property PluginFlags Auto Const Mandatory
	WorkshopFramework:SettlementLayoutManager Property SettlementLayoutManager Auto Const Mandatory
	
	WorkshopFramework:F4SEManager Property F4SEManager Auto Const Mandatory
	
	WorkshopFramework:UIManager Property UIManager Auto Const Mandatory
	WorkshopFramework:WorkshopObjectManager Property WorkshopObjectManager Auto Const Mandatory
	WorkshopFramework:PlaceObjectManager Property PlaceObjectManager Auto Const Mandatory
	WorkshopFramework:NPCManager Property NPCManager Auto Const Mandatory
EndGroup

Group AVs
	ActorValue Property WorkshopMaxTriangles Auto Const Mandatory
	ActorValue Property WorkshopMaxDraws Auto Const Mandatory
	ActorValue Property WorkshopCurrentDraws Auto Const Mandatory
	ActorValue Property WorkshopCurrentTriangles Auto Const Mandatory
EndGroup

Group Globals
	GlobalVariable Property Setting_WorkshopTutorialsEnabled Auto Const Mandatory
	{ 1.0.7 - Toggle to track whether the tutorial messages were last turned on or off }
	
	GlobalVariable Property Setting_AutoRepairPowerGrids Auto Const Mandatory
	GlobalVariable Property Setting_AutoResetCorruptPowerGrid Auto Const Mandatory
EndGroup

Group Aliases
	ReferenceAlias Property LastWorkshopAlias Auto Const Mandatory
EndGroup

Group Assets
	Perk Property ActivationPerk Auto Const Mandatory
EndGroup

Group FormLists
	FormList Property WorkshopParentExcludeFromAssignmentRules Auto Const Mandatory
	{ Point to the same list as WorkshopParent.ParentExcludeFromAssignmentRules }
EndGroup


Group Keywords
	Keyword Property LocationTypeWorkshop Auto Const Mandatory
	Keyword Property LocationTypeSettlement Auto Const Mandatory
	Keyword Property IgnoreAccuracyBonusInUI Auto Const Mandatory
EndGroup

Group Messages
	; 1.0.4 - Adding new message to explain why ClaimSettlement isn't working
	Message Property CannotFindSettlement Auto Const Mandatory
	Message Property ManageSettlementMenu Auto Const Mandatory
	Message Property ScrapConfirmation Auto Const Mandatory
    Message Property IncreaseLimitsMenu Auto Const Mandatory
	Message Property RepairPowerGridConfirm Auto Const Mandatory
	Message Property AutoWireConfirm Auto Const Mandatory
	Message Property FauxPowerConfirm Auto Const Mandatory
	Message Property DestroyPowerGridConfirm Auto Const Mandatory
	Message Property ClaimSettlementConfirm  Auto Const Mandatory
	Message Property UnclaimSettlementConfirm  Auto Const Mandatory
	Message Property PowerToolsMenu Auto Const Mandatory
	Message Property PowerGridResetWarning Auto Const Mandatory
	Message Property PostResetPowerGridRebuildConfirm Auto Const Mandatory
	Message Property WorkshopScriptOverwriteWarning Auto Const Mandatory
EndGroup

; ---------------------------------------------
; Properties
; ---------------------------------------------

Bool Property bUseCBRChange = true Auto

Bool Property bFrameworkReady = false Auto Hidden
Bool Property bLastSettlementUnloaded = true Auto Hidden

Int Property iSaveFileMonitor Auto Hidden ; Important - only meant to be edited by our Nanny system!

Bool Property bCurrentSettlementNotSetYet = true Auto Hidden ; will be changed to false the first time a player enters a settlement and kCurrentSettlement is set

; ---------------------------------------------
; Vars
; ---------------------------------------------

workshopscript kCurrentSettlement = none ; will be set when the enter event is triggered and cleared when the exit event is triggered.
location kCurrentSettlementLocation = none ; will be set when the player enters a settlment location and cleared when leaving a settlement location

workshopscript kWaitingForSettlementExit = none  ; stores the workshop of a settlement that is waiting for the exit timer to complete before PlayerExitedSettlement is sent
workshopscript kInBuildableAreaWorkshop = none ; stores the workshop of the settlement being checked for buildable area before triggering enter or exit events

; ---------------------------------------------
; Events
; ---------------------------------------------

Event ObjectReference.OnCellLoad(ObjectReference akSender)
	WorkshopScript thisWorkshop = akSender as WorkshopScript
	
	UnregisterForRemoteEvent(akSender, "OnCellLoad")
	
	if(F4SEManager.IsF4SERunning && Setting_AutoRepairPowerGrids.GetValueInt() == 1)
		F4SEManager.WSFWID_CheckAndFixPowerGrid(thisWorkshop, abFixAndScan = true, abResetIfFixFails = Setting_AutoResetCorruptPowerGrid.GetValueInt() as Bool)
	endif
EndEvent

; Extending to fire off settlement enter/exit events
Event OnTimer(Int aiTimerID)
	Parent.OnTimer(aiTimerID)

	if(aiTimerID == LocationChangeTimerID)
		 ; if bUseCBRChange is set, alternate (experimental) code will be used to trigger enter and exit settlement events.
		if(bUseCBRChange)
			Location kPreviousLoc = PreviousLocation.GetLocation()
			Location kNewLoc = LatestLocation.GetLocation()
			WorkshopScript enteringWorkshop = None
			WorkshopScript leavingWorkshop = None
		
			if(kNewLoc != None)
				if(kNewLoc.HasKeyword(LocationTypeWorkshop))
					enteringWorkshop = WorkshopParent.GetWorkshopFromLocation(kNewLoc)
					
					if(F4SEManager.IsF4SERunning && Setting_AutoRepairPowerGrids.GetValueInt() == 1)
						if(enteringWorkshop.GetParentCell().IsLoaded())
							F4SEManager.WSFWID_CheckAndFixPowerGrid(enteringWorkshop, abFixAndScan = true, abResetIfFixFails = Setting_AutoResetCorruptPowerGrid.GetValueInt() as Bool)
						else
							RegisterForRemoteEvent(enteringWorkshop, "OnCellLoad")
						endif
					endif
				endif
			endif
		
			if(kPreviousLoc != None)
				if(kPreviousLoc.HasKeyword(LocationTypeWorkshop))
					leavingWorkshop = WorkshopParent.GetWorkshopFromLocation(kPreviousLoc)
				endif
			endif
		
			if(leavingWorkshop != none)
				 ; don't trigger an exit event if the corresponding enter event hasn't triggered (unless this is the first time using the changed code)
				if(kCurrentSettlement != none || bCurrentSettlementNotSetYet)
					 ; Cancel any enter build area check, as we will not be sending that entered settlement function
					CancelBuildAreaCheck()
					
					 ; check to see if the player is still in the buildable area of that workshop
					if(Self.IsWithinBuildableAreaEX(PlayerRef, leavingWorkshop))
						 ; they are, so don't call exit yet. Start a timer to check if they are out of the area.
						kInBuildableAreaWorkshop = leavingWorkshop
						Self.StartTimer(fTimerLength_BuildableAreaCheckForExit, iTimerID_BuildableAreaCheckForExit)
					else
						 ; they are not
						if(enteringWorkshop == none)
							 ; if the previous settlement is unloaded, run the exit event straight away (they probably fast travelled)
							 ; otherwise, start the exit timer
							
							if(!leavingWorkshop.mylocation.IsLoaded())
								SendPlayerExitedSettlementEvent(leavingWorkshop)
							else
								kWaitingForSettlementExit = leavingWorkshop
								Self.StartTimer(fTimerLength_WaitToSendExitEvent, iTimerID_WaitToSendExitEvent)
							endif
						else
							 ; the exit event will be run in the block below
						endif
					endif
				endif
			endif
		
			if(enteringWorkshop != none)
				 ; if the player is still registered as being in another settlement, trigger that exit event
				if(kCurrentSettlement != none && kCurrentSettlement != enteringWorkshop)
					SendPlayerExitedSettlementEvent(kCurrentSettlement)
				else
					 ; cancel any build area check
					CancelBuildAreaCheck()
				endif
				
				 ; do not trigger the enter event if it was already triggered previously and the exit event has not been triggered
				if(kCurrentSettlement != enteringWorkshop) 
					 ; check to see if they are in the buildable area yet. If not, start a timer to check for it.
					if(Self.IsWithinBuildableAreaEX(PlayerRef, enteringWorkshop))
						 ; run the enter event
						SendPlayerEnteredSettlementEvent(enteringWorkshop)
					else
						kInBuildableAreaWorkshop = enteringWorkshop
						 ; start the timer
						Self.StartTimer(fTimerLength_BuildableAreaCheckForEntry, iTimerID_BuildableAreaCheckForEntry) 
					endif
				endif
			endif
		else
		Location kPreviousLoc = PreviousLocation.GetLocation()
		Location kNewLoc = LatestLocation.GetLocation()
		Bool bEnteringWorkshopLocation = false
		Bool bLeavingWorkshopLocation = false
		WorkshopScript currentWorkshop = None
		
		if(kNewLoc != None)
			if(kNewLoc.HasKeyword(LocationTypeWorkshop))
				bEnteringWorkshopLocation = true
				currentWorkshop = WorkshopParent.GetWorkshopFromLocation(PlayerRef.GetCurrentLocation())
				
				if(F4SEManager.IsF4SERunning && Setting_AutoRepairPowerGrids.GetValueInt() == 1)
					if(currentWorkshop.GetParentCell().IsLoaded())
						F4SEManager.WSFWID_CheckAndFixPowerGrid(currentWorkshop, abFixAndScan = true, abResetIfFixFails = Setting_AutoResetCorruptPowerGrid.GetValueInt() as Bool)
					else
						RegisterForRemoteEvent(currentWorkshop, "OnCellLoad")
					endif
				endif
			endif
		endif

		if(kPreviousLoc != None)
			if(kPreviousLoc.HasKeyword(LocationTypeWorkshop))
				bLeavingWorkshopLocation = true
			endif
		endif

		if(bEnteringWorkshopLocation || bLeavingWorkshopLocation)
			Var[] kArgs

			; 1.0.4 - Added sanity check
			if( ! currentWorkshop || ! Self.IsWithinBuildableAreaEX(PlayerRef, currentWorkshop))
				; Check if player is in a different workshop - it can sometimes take a moment before WorkshopParent updates the CurrentWorkshop
				currentWorkshop = WorkshopFramework:WSFW_API.GetNearestWorkshop(PlayerRef)

				if(bLeavingWorkshopLocation && ! bEnteringWorkshopLocation && currentWorkshop && ! Self.IsWithinBuildableAreaEX(PlayerRef, currentWorkshop))
					currentWorkshop = None
				else
					if(currentWorkshop != None && currentWorkshop.myLocation != None)
						; Player is in limbo area - it is not flagged as part of a specific location (likely just the overworld location - ie. Commonwealth) and so another LocationChange event isn't likely to fire - so instead we'll do a 5 second repeating loop to check if they returned to the location tagged part of the settlement or are out of the build area
						StartTimer(fTimerLength_BuildableAreaCheck, iTimerID_BuildableAreaCheck)

						; Update Latest Location so the next change will correctly be aware the player was previously in a settlement
						LatestLocation.ForceLocationTo(currentWorkshop.myLocation)
					else
						; Player is not in limbo area
						CancelTimer(iTimerID_BuildableAreaCheck)
					endif
				endif
			endif

			WorkshopScript lastWorkshop = LastWorkshopAlias.GetRef() as WorkshopScript
			Bool bCurrentWorkshopRefFound = true
			if( ! currentWorkshop)
				bCurrentWorkshopRefFound = false
			endif

			Bool bLastWorkshopRefFound = true
			if( ! lastWorkshop)
				bLastWorkshopRefFound = false
			endif

			if( ! bLastWorkshopRefFound && bCurrentWorkshopRefFound) ; This should only happen once, after which there will always be a lastWorkshop stored in the alias
				LastWorkshopAlias.ForceRefTo(currentWorkshop)
			endif

			;Debug.Trace(">>>>>>>>>>>>>>>> bLastWorkshopRefFound: " + bLastWorkshopRefFound + ", kPreviousLoc: " + kPreviousLoc + ", kNewLoc: " + kNewLoc + ", lastWorkshop: " + lastWorkshop + ", currentWorkshop: " + currentWorkshop + ", bCurrentWorkshopRefFound: " + bCurrentWorkshopRefFound + ", bLastSettlementUnloaded: " + bLastSettlementUnloaded)
			if(bLastWorkshopRefFound)
				Bool bLastWorkshopLoaded = lastWorkshop.myLocation.IsLoaded()
				kArgs = new Var[2]
				kArgs[0] = lastWorkshop
				kArgs[1] = bLastWorkshopLoaded ; Scripts can use this to determine if the player has actually left or is maybe just hanging out around the edge of the settlement

				if(lastWorkshop != currentWorkshop && (bCurrentWorkshopRefFound || ! bLastSettlementUnloaded))
					; Workshop changed or they are no longer in a settlement
					if(bCurrentWorkshopRefFound)
						; Changed settlement - update our lastWorkshop record to store the currentWorkshop
						LastWorkshopAlias.ForceRefTo(currentWorkshop)
					endif

					if( ! bLastWorkshopLoaded)
						; Our previous settlement is no longer loaded in memory
						bLastSettlementUnloaded = true
					endif

					SendCustomEvent("PlayerExitedSettlement", kArgs)
				else
					; Player changed location but is still in same settlement - don't send event
				endif
			endif

			if(bCurrentWorkshopRefFound && bEnteringWorkshopLocation)
				; Workshop changed or previous settlement unloaded
				kArgs = new Var[3]
				kArgs[0] = currentWorkshop
				kArgs[1] = lastWorkshop
				kArgs[2] = bLastSettlementUnloaded ; If lastWorkshop == currentWorkshop && bLastSettlementUnloaded - it means the player traveled far enough to unload the last settlement, but never visited a new one in between
					
				;Debug.MessageBox("WSFW_Main sending PlayerEnteredSettlement event")
				SendCustomEvent("PlayerEnteredSettlement", kArgs)

				bLastSettlementUnloaded = false ; Since we've entered a settlement, the lastWorkshop is changing
			endif
		endif
		endif
	elseif(aiTimerID == iTimerID_BuildableAreaCheck)
		WorkshopScript currentWorkshop = WorkshopFramework:WSFW_API.GetNearestWorkshop(PlayerRef)
		Location PlayerLocation = PlayerRef.GetCurrentLocation()

		if(currentWorkshop && Self.IsWithinBuildableAreaEX(PlayerRef, currentWorkshop))
			if(currentWorkshop.myLocation && currentWorkshop.myLocation != PlayerLocation)
				; Player is in a limbo area of a settlement not flagged as part of the settlement - repeat this loop
				StartTimer(fTimerLength_BuildableAreaCheck, iTimerID_BuildableAreaCheck)
			endif
		else
			LatestLocation.ForceLocationTo(PlayerLocation)
			; Player probably exited settlement
			Bool bLastWorkshopLoaded = currentWorkshop.myLocation.IsLoaded()
			Var[] kArgs = new Var[2]
			kArgs[0] = currentWorkshop
			kArgs[1] = bLastWorkshopLoaded ; Scripts can use this to determine if the player has actually left or is maybe just hanging out around the edge of the settlement

			SendCustomEvent("PlayerExitedSettlement", kArgs)
		endif
	elseif(aiTimerID == iTimerID_BuildableAreaCheckForEntry)
		 ; part of CBRGamer code change
		 ; check to see if the player is in the Buildable area of the settlement. If they are not, repeat the timer. If they are, trigger the entrance event
		if(Self.IsWithinBuildableAreaEX(PlayerRef, kInBuildableAreaWorkshop))
			SendPlayerEnteredSettlementEvent(kInBuildableAreaWorkshop)
		else
			Self.StartTimer(fTimerLength_BuildableAreaCheckForEntry, iTimerID_BuildableAreaCheckForEntry)
		endif
	elseif(aiTimerID == iTimerID_BuildableAreaCheckForExit)
		 ; part of CBRGamer code change
		 ; check to see if the player is in the Buildable area of the settlement. If they are not, start the exit timer. If they are repeat this timer.
		if(Self.IsWithinBuildableAreaEX(PlayerRef, kInBuildableAreaWorkshop))
			Self.StartTimer(fTimerLength_BuildableAreaCheckForExit, iTimerID_BuildableAreaCheckForExit)
		else
			StartPlayerExitedSettlementWait(kInBuildableAreaWorkshop)
		endif
	elseif(aiTimerID == iTimerID_WaitToSendExitEvent)
		 ; part of CBRGamer code change
		 ; make sure the player has not gone back into the build area
		if(! Self.IsWithinBuildableAreaEX(PlayerRef, kWaitingForSettlementExit)) 
			SendPlayerExitedSettlementEvent(kWaitingForSettlementExit)
			kWaitingForSettlementExit = none
		else
			 ; restart the build area timer
			kInBuildableAreaWorkshop = kWaitingForSettlementExit
			Self.StartTimer(fTimerLength_BuildableAreaCheckForExit, iTimerID_BuildableAreaCheckForExit)
		endif
	endif
EndEvent


Event OnMenuOpenCloseEvent(string asMenuName, bool abOpening)
    if(asMenuName == "WorkshopMenu")
		if(abOpening)
			if(bUseCBRChange)
				if(kCurrentSettlement == none)
					 ; They are clearly actually in a settlement as they have entered workshop mode. Probably in a limbo area.
					Workshopscript currentWorkshop = WorkshopFramework:WSFW_API.GetNearestWorkshop(PlayerRef)
					 ; make sure this is the correct workshop (it really should be - just to be sure)
					if(Self.IsWithinBuildableAreaEX(PlayerRef, currentWorkshop))
						SendPlayerEnteredSettlementEvent(currentWorkshop)
					endif
				endif
				 ; we could also do a check to see if kCurrentSettlement is the build area the player is in, but this not being the case would be a rare edge case and would be corrected soon enough.
				 ; it could only happen if they player had exited another settlement and entered this build area all in the 5 seconds it takes for the exit to trigger.
				 ; After that, the next build mode entry, or going into the settlement location would trigger the enter event.
			
			else
			WorkshopScript currentWorkshop = WorkshopParent.CurrentWorkshop.GetRef() as WorkshopScript
			WorkshopScript lastWorkshop = LastWorkshopAlias.GetRef() as WorkshopScript

			if(lastWorkshop != currentWorkshop)
				 ; If this happens, there is likely some serious script lag happening - but since LastWorkshopAlias is used throughout our code, we don't ever want it to be incorrect, so use this opportunity to correct it
				 if(currentWorkshop == None || ! Self.IsWithinBuildableAreaEX(PlayerRef, currentWorkshop))
					; Check if player is in a different workshop - it can sometimes take a moment before WorkshopParent updates the CurrentWorkshop
					currentWorkshop = WorkshopFramework:WSFW_API.GetNearestWorkshop(PlayerRef)
				endif

				if(currentWorkshop)
					LastWorkshopAlias.ForceRefTo(currentWorkshop)
				endif
			endif
		endif
	endif
	endif
EndEvent


; 1.0.1 - Need to ensure FillWSFWVars is filled - will also update each time the game starts in case we needed to add additional properties
;/
1.1.0 - Removed this block as you can't override remote event blocks, instead we've switched to calling a handler function from the parent quest so we can override that
Event Quest.OnStageSet(Quest akSenderRef, Int auiStageID, Int auiItemID)
	if(akSenderRef == WorkshopParent)
		WorkshopParent.FillWSFWVars()
	endif
EndEvent
/;

; ---------------------------------------------
; Extended Handlers
; ---------------------------------------------

Function HandleInstallModChanges()
	Int iVersion2311 = 107
	if(iInstalledVersion < iVersion2311)
		FixPopulationRating()
	endif
	
	Int iVersion210 = 53
	if(iInstalledVersion < iVersion210)
		UIManager.Stop()
		Utility.Wait(1.0)
		UIManager.Start()
	endif
	
	if(iInstalledVersion < 26)
		PlayerRef.AddPerk(ActivationPerk)
	endif

	if(iInstalledVersion < 42)
		deduplicateAllVendorLists()
	endif
EndFunction



Function HandleGameLoaded()
	; Make sure our debug log is open
	WorkshopFramework:Library:UtilityFunctions.StartUserLog()

	ModTrace("[WSFW] >>>>>>>>>>>>>>>>> HandleGameLoaded called on WSFW MainQuest")

	if(WorkshopParent.IsRunning())
		WorkshopParent.FillWSFWVars() ; Patch 1.0.1 - Eliminating all vanilla form edits and switching to GetFormFromFile
	else
		RegisterForRemoteEvent(WorkshopParent as Quest, "OnStageSet")
	endif
	
	CheckForWorkshopScriptOverwrites()

	RegisterForMenuOpenCloseEvent("WorkshopMenu")
	UpdatePluginFlags()

	if( ! PlayerRef.HasPerk(ActivationPerk))
		PlayerRef.AddPerk(ActivationPerk) ; 1.2.0 - Allow for alternate activations
	endif

	StartQuests()
	
	ClearInWorkshopModeFlags()
	
	WorkshopParent.WSFW_CheckWorkshops()

	Parent.HandleGameLoaded()
EndFunction


Function HandleQuestInit()
	Parent.HandleQuestInit()
	
	FixPopulationRating()
EndFunction


Function HandleStageSet(Quest akQuestRef, int auiStageID, int auiItemID)
	ModTrace("[WSFW] >>>>>>>>>>>>>>>>>>> Quest event received on WSFW Main: " + akQuestRef + " reached stage " + auiStageID)
	if(akQuestRef == WorkshopParent)
		WorkshopParent.FillWSFWVars()
	endif

	Parent.HandleStageSet(akQuestRef, auiStageID, auiItemID)
EndFunction


; ---------------------------------------------
; Overrides
; ---------------------------------------------

Bool Function StartQuests()
	ModTrace("[WSFW] >>>>>>>>>>>>>>>>> WSFW MainQuest.StartQuests called.")
	bFrameworkReady = Parent.StartQuests()
	
	if(bFrameworkReady)
		SetStage(10) ; 2.3.16 - Give a stage for other quests to monitor for
	endif
	
	return bFrameworkReady
EndFunction

; Override parent function - to check for same location on the settlement type
Function HandleLocationChange(Location akNewLoc)
	Location lastParentLocation = LatestLocation.GetLocation()

	; Always proceed if buildable area check is running - as that indicates the player entered a limbo zone where they were within settlement bounds that were not tagged with the correct location
	if(akNewLoc == None || lastParentLocation == None || ! akNewLoc.IsSameLocation(lastParentLocation) || ! akNewLoc.IsSameLocation(lastParentLocation, LocationTypeSettlement))
		if(lastParentLocation == None)
			PreviousLocation.Clear() ; 1.1.9
		else
			PreviousLocation.ForceLocationTo(lastParentLocation) ; 1.1.7
		endif

		if(akNewLoc == None)
			LatestLocation.Clear()
		else
			LatestLocation.ForceLocationTo(akNewLoc)
		endif

		StartTimer(1.0, LocationChangeTimerID)
	endif
	
	WorkshopScript kWorkshopRef = WorkshopParent.GetWorkshopFromLocation(akNewLoc)
	
	if(kWorkshopRef != None && kWorkshopRef.bPowerGridRebuildOfferNeeded)
		OfferPostResetPowerGridRebuild(kWorkshopRef)
	endif
EndFunction


; ---------------------------------------------
; Functions
; ---------------------------------------------

 ; Part of CBRGamer code change
Function SendPlayerEnteredSettlementEvent(workshopscript akEnteringWorkshop)
	kCurrentSettlement = akEnteringWorkshop
	bCurrentSettlementNotSetYet = false
	
	 ; We can now cancel any build area check for entry
	Self.CancelTimer(iTimerID_BuildableAreaCheckForEntry)
	kInBuildableAreaWorkshop = none
	
	WorkshopScript lastWorkshop = LastWorkshopAlias.GetRef() as WorkshopScript
	bLastSettlementUnloaded = !lastWorkshop.myLocation.IsLoaded()
	
	Var[] kArgs = new Var[3]
	kArgs[0] = akEnteringWorkshop
	kArgs[1] = lastWorkshop
	kArgs[2] = bLastSettlementUnloaded 
	
	; This comment is in the original : 
	     ; If lastWorkshop == currentWorkshop && bLastSettlementUnloaded - it means the player traveled far enough to unload the last settlement, but never visited a new one in between
	; But even in the original, bLastSettlementUnloaded was only set when you entered a settlement - so if currentWorkshop was the same is the last workshop, the last workshop must be loaded because the current one is.
	
	SendCustomEvent("PlayerEnteredSettlement", kArgs)
	bLastSettlementUnloaded = false ; Since we've entered a settlement, the lastWorkshop is changing
	LastWorkshopAlias.ForceRefTo(akEnteringWorkshop)
EndFunction

 ; Part of CBRGamer code change
Function SendPlayerExitedSettlementEvent(workshopscript akLeavingWorkshop)
	kCurrentSettlement = none
	
	 ; We can now cancel any build area check for exit and any wait timer for exit
	Self.CancelTimer(iTimerID_BuildableAreaCheckForExit)
	kInBuildableAreaWorkshop = none
	Self.CancelTimer(iTimerID_WaitToSendExitEvent)
	kWaitingForSettlementExit = none
	
	WorkshopScript lastWorkshop = LastWorkshopAlias.GetRef() as WorkshopScript
	Bool bLastWorkshopLoaded = lastWorkshop.myLocation.IsLoaded()
	
	Var[] kArgs = new Var[2]
	kArgs[0] = akLeavingWorkshop
	kArgs[1] = bLastWorkshopLoaded ; Scripts can use this to determine if the player has actually left or is maybe just hanging out around the edge of the settlement
	
	SendCustomEvent("PlayerExitedSettlement", kArgs)
EndFunction

 ; Part of CBRGamer code change
Function StartPlayerExitedSettlementWait(workshopscript akWaitWorkshop)
	if(kWaitingForSettlementExit != none && akWaitWorkshop != kWaitingForSettlementExit)
		 ; while waiting to exit one workshop, another thinks it is exiting. So exit the first, then call the exit wait on the second.
		 ; This actually shouldn't happen, but just in case.
		SendPlayerExitedSettlementEvent(kWaitingForSettlementExit) 
	endif
	kWaitingForSettlementExit = akWaitWorkshop
	Self.StartTimer(fTimerLength_WaitToSendExitEvent, iTimerID_WaitToSendExitEvent)
EndFunction

 ; Part of CBRGamer code change
Function CancelBuildAreaCheck()
	CancelTimer(iTimerID_BuildableAreaCheckForEntry)
	CancelTimer(iTimerID_BuildableAreaCheckForExit)
	kInBuildableAreaWorkshop = None
EndFunction


Function ClearInWorkshopModeFlags()
	WorkshopScript[] Workshops = WorkshopParent.Workshops
	int i = 0
	while(i < Workshops.Length)
		if(Workshops[i] != None)
			Workshops[i].UFO4P_InWorkshopMode = false
		endif
		
		i += 1
	endwhile
EndFunction

; 1.2.0 - Adding a new manage pop-up menu to workbenches to avoid the player needing to use MCM or holotape for some things
Function PresentManageSettlementMenu(WorkshopScript akWorkshopRef)
	int iChoice = ManageSettlementMenu.Show()

	if(iChoice == 0)
		 ; build limits
        PresentIncreaseLimitsMenu(akWorkshopRef)
	elseif(iChoice == 1)
		PresentPowerToolsMenu(akWorkshopRef)
	elseif(iChoice == 2)
		; Scrap Settlement
		int iConfirm = ScrapConfirmation.Show()

		if(iConfirm == 1)
			; Clear all layouts
			int i = 0
			while(i < akWorkshopRef.AppliedLayouts.Length)
				akWorkshopRef.AppliedLayouts[i].Remove(akWorkshopRef)

				i += 1
			endWhile

			; Scrap entire settlement
			SettlementLayoutManager.ScrapSettlement(akWorkshopRef, abScrapLinkedAndCollectLootables = true)
		endif
	elseif(iChoice == 3)
		; PresentLayoutManagementMenu triggers a series of menus that loop, let's not get this main quest caught up in the thread - so instead trigger a new thread via CallFunctionNoWait
		Var[] kArgs = new Var[1]
		kArgs[0] = akWorkshopRef

		SettlementLayoutManager.CallFunctionNoWait("PresentLayoutManagementMenu", kArgs)
	elseif(iChoice == 4)
		PresentOwnershipMenu(akWorkshopRef)
	elseif(iChoice == 5)
		; Cancel
	endif
EndFunction


Function ShowPowerGridResetWarning(WorkshopScript akWorkshopRef)
	Location HoldLocation = PreviousLocation.GetLocation()
	
	PreviousLocation.ForceLocationTo(akWorkshopRef.myLocation)
	PowerGridResetWarning.Show()
	
	if(HoldLocation != None)
		PreviousLocation.ForceLocationTo(HoldLocation)
	else
		PreviousLocation.Clear()
	endif
EndFunction

Function OfferPostResetPowerGridRebuild(WorkshopScript akWorkshopRef)
	akWorkshopRef.bPowerGridRebuildOfferNeeded = false
	int iConfirm = PostResetPowerGridRebuildConfirm.Show()
	
	if(iConfirm == 0)
		; Cancel
	else
		WorkshopObjectManager.RewireSettlement(akWorkshopRef)
	endif
EndFunction


Function PresentPowerToolsMenu(WorkshopScript akWorkshopRef = None)
	if( ! akWorkshopRef)
		akWorkshopRef = GetNearestWorkshop(PlayerRef)
		
		if(akWorkshopRef == None)
			return
		endif
	endif
	
	Bool bReshowMenu = false
	
	int iConfirm = PowerToolsMenu.Show()
	
	if(iConfirm == 0)
		; cancel
	elseif(iConfirm == 1)
		; Auto Wire
		iConfirm = AutoWireConfirm.Show()
		if(iConfirm == 0)
			; Cancel
			bReshowMenu = true
		elseif(iConfirm == 1)
			WorkshopObjectManager.AutoWireSettlement(akWorkshopRef)
		endif
	elseif(iConfirm == 2)
		; Convert to Faux Powered
		iConfirm = FauxPowerConfirm.Show()
		if(iConfirm == 0)
			; Cancel
			bReshowMenu = true
		elseif(iConfirm == 1)
			WorkshopObjectManager.FauxPowerSettlement(akWorkshopRef)
		endif
	elseif(iConfirm == 3)
		; Rebuild Power Grid and Wiring
		if( ! WorkshopObjectManager.RewireSettlement(akWorkshopRef))
			bReshowMenu = true
		endif
	elseif(iConfirm == 4)
		; Repair Power Grid
		iConfirm = RepairPowerGridConfirm.Show()
		if(iConfirm == 0)
			; Cancel
			bReshowMenu = true
		elseif(iConfirm == 1)
			F4SEManager.WSFWID_CheckAndFixPowerGrid(akWorkshopRef, abFixAndScan = true, abResetIfFixFails = Setting_AutoResetCorruptPowerGrid.GetValueInt() as Bool)
		endif
	elseif(iConfirm == 5)
		; Destroy Power Grid
		iConfirm = DestroyPowerGridConfirm.Show()
		if(iConfirm == 0)
			; Cancel
			bReshowMenu = true
		elseif(iConfirm == 1)
			F4SEManager.WSFWID_ResetPowerGrid(akWorkshopRef)
		endif
	elseif(iConfirm == 6)
		; Destroy Wires
		if( ! WorkshopObjectManager.DestroyWires(akWorkshopRef))
			bReshowMenu = true
		endif
	endif
	
	if(bReshowMenu)
		Var[] kArgs = new Var[0]		
		kArgs.Add(akWorkshopRef)
		
		CallFunctionNoWait("PresentPowerToolsMenu", kArgs) ; Call async to avoid stack depth limit
	endif
EndFunction

Function PresentIncreaseLimitsMenu(WorkshopScript akWorkshopRef)	
    float defaultMaxTris  = akWorkshopRef.MaxTriangles
    float defaultMaxDraws = akWorkshopRef.MaxDraws

    float defaultCurTris = akWorkshopRef.CurrentTriangles
    float defaultCurDraws = akWorkshopRef.CurrentDraws
	
	float currentDraws = akWorkshopRef.getValue(WorkshopCurrentDraws)
	float currentTris  = akWorkshopRef.getValue(WorkshopCurrentTriangles)	
	
	; 2.4.1 - add current value check no matter if player adjusts or not.
	; something allows WorkshopCurrentDraws to be set to a negative value.
	if(currentDraws <= 0.0)
		currentDraws = 1.0
		akWorkshopRef.SetValue(WorkshopCurrentDraws, currentDraws)
	endif

	if(currentTris <= 0.0)
		currentTris = 1.0
		akWorkshopRef.SetValue(WorkshopCurrentTriangles, currentTris)
	endif

	; prevent division by zero: assume Sanctuary values
	if(defaultMaxTris <= 0)
		defaultMaxTris = 3000000
	endif

	if(defaultMaxDraws <= 0)
		defaultMaxDraws = 3000
	endif
	
    float curMaxTris  = akWorkshopRef.getValue(WorkshopMaxTriangles)
    float curMaxDraws = akWorkshopRef.getValue(WorkshopMaxDraws)
	
	if(curMaxTris <= 0)
		curMaxTris = defaultCurTris
		
		akWorkshopRef.setValue(WorkshopMaxTriangles, curMaxTris)
	endif
	
	if(curMaxDraws <= 0)
		curMaxDraws = defaultCurDraws
		
		akWorkshopRef.setValue(WorkshopMaxDraws, curMaxDraws)
	endif

    float percentTris  = 100 * curMaxTris / defaultMaxTris
    float percentDraws = 100 * curMaxDraws / defaultMaxDraws
    
    float percentDisplay = percentTris
    if(percentDraws > percentTris)
        percentDisplay = percentDraws
    endif

    float newTris  = curMaxTris
    float newDraws = curMaxDraws

    int iChoice = IncreaseLimitsMenu.show(percentDisplay)
    
    if(iChoice == 4)
        ; cancel
        return
    endif
    
    if(iChoice == 3) 
        ; reset
        akWorkshopRef.SetValue(WorkshopMaxDraws, Math.floor(defaultMaxDraws))
        akWorkshopRef.SetValue(WorkshopMaxTriangles, Math.floor(defaultMaxTris))
        return
    endif

    float factor = 1.0

    if(iChoice == 0)
        ; +25%
        factor = 0.25
    elseif(iChoice == 1)
        ; +50%
        factor = 0.5
    elseif(iChoice == 2)
        ; +100%
        factor = 1.0
    endif
    
    
    if(currentDraws > defaultMaxDraws || currentTris > defaultMaxTris)
        ; use percentage of current maximum
        akWorkshopRef.SetValue(WorkshopMaxTriangles, curMaxTris  + Math.floor(curMaxTris * factor))
        akWorkshopRef.SetValue(WorkshopMaxDraws, curMaxDraws + Math.floor(curMaxDraws * factor))
    else
        ; use percentage of default maximum
        akWorkshopRef.SetValue(WorkshopMaxTriangles, curMaxTris  + Math.floor(defaultMaxTris * factor))
        akWorkshopRef.SetValue(WorkshopMaxDraws, curMaxDraws + Math.floor(defaultMaxDraws * factor))
    endif
EndFunction


Function PresentOwnershipMenu(WorkshopScript akWorkshopRef = None)
	if( ! akWorkshopRef)
		akWorkshopRef = GetNearestWorkshop(PlayerRef)
	endif
	
	; We don't really need a menu yet - let's just offer to claim or unclaim
	if(akWorkshopRef.OwnedByPlayer)
		int iConfirm = UnclaimSettlementConfirm.Show()
		
		if(iConfirm == 0)
			; cancel
		else
			UnclaimSettlement(akWorkshopRef)
		endif
	else
		int iConfirm = ClaimSettlementConfirm.Show()
		if(iConfirm == 0)
			; cancel
		else
			ClaimSettlement(akWorkshopRef)
		endif
	endif
EndFunction


; 1.0.4 - Adding method for players to claim a settlement, this will help players recover after the bug from 1.0.3 that could cause happiness to tank
Function ClaimSettlement(WorkshopScript akWorkshopRef = None)
	if( ! akWorkshopRef)
		akWorkshopRef = GetNearestWorkshop(PlayerRef)
	endif
	
	if(akWorkshopRef.HasKeyword(IgnoreAccuracyBonusInUI))
		return
	endif

	if(akWorkshopRef)
		akWorkshopRef.SetOwnedByPlayer(true)
	else
		CannotFindSettlement.Show()
	endif
EndFunction

Function UnclaimSettlement(WorkshopScript akWorkshopRef = None)
	if( ! akWorkshopRef)
		akWorkshopRef = GetNearestWorkshop(PlayerRef)
	endif

	if(akWorkshopRef)
		akWorkshopRef.SetOwnedByPlayer(false)
	else
		CannotFindSettlement.Show()
	endif
EndFunction

; 1.0.7 - Adding option to toggle Workshop Tutorials
Function DisableWorkshopTutorials()
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopObjectBuilt")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopObjectMoved")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopObjectDestroyed")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopActorAssignedToWork")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopActorUnassigned")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopObjectDestructionStageChanged")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopObjectPowerStageChanged")
	TutorialQuest.UnregisterForCustomEvent(WorkshopParent, "WorkshopEnterMenu")

	; Stop any existing help messages
	int i = 0
	while(i < TutorialQuest.TutorialSteps.Length)
		if(TutorialQuest.TutorialSteps[i].HelpMessage)
			TutorialQuest.TutorialSteps[i].HelpMessage.UnshowAsHelpMessage()
		endif

		i += 1
	endWhile
EndFunction

; 1.0.7 - Adding option to toggle Workshop Tutorials
Function EnableWorkshopTutorials()
	TutorialQuest.InitializeQuest()

	; Reset all of the tutorials
	int i = 0
	while(i < TutorialQuest.Tutorials.Length)
		TutorialQuest.RollBackTutorial(TutorialQuest.Tutorials[i])

		i += 1
	endWhile
EndFunction

; 1.1.11 - Setting up plugin installed globals
Function UpdatePluginFlags()
	int i = 0
	while(i < PluginFlags.Length)
		if(Game.IsPluginInstalled(PluginFlags[i].sPluginName))
			PluginFlags[i].GlobalForm.SetValueInt(1)
		else
			PluginFlags[i].GlobalForm.SetValueInt(0)
		endif

		i += 1
	endWhile
EndFunction

; 2.0.0 - New utility
Function ClaimAllSettlements()
	Int[] iHasBadMapMarkers = new Int[0]
	; For settlements with known bad map markers we can correct them here
	iHasBadMapMarkers.Add(0x001F0711) ; Hangman's Alley

	; Unlock all fast travel points
	WorkshopScript[] Workshops = WorkshopParent.Workshops
	int i = 0
	while(i < Workshops.Length)
		int iFormID = Workshops[i].GetFormID()

		if(Workshops[i].myMapMarker != None && iHasBadMapMarkers.Find(iFormID) < 0)
			Workshops[i].myMapMarker.Enable(false)
			Workshops[i].myMapMarker.AddToMap(true)
		else
			ObjectReference thisMapMarker = WorkshopFramework:WSFW_API.GetMapMarker(Workshops[i].myLocation)
			if(thisMapMarker)
				WOrkshops[i].myMapMarker = thisMapMarker
				thisMapMarker.Enable(false)
				thisMapMarker.AddToMap(true)
			endif
		endif
		
		ClaimSettlement(Workshops[i])

		i += 1
	endWhile

	; Reveal travel locations for NukaWorld and Far Harbor
	if(Game.IsPluginInstalled("DLCNukaWorld.esm"))
		ObjectReference kMapMarkerRef = Game.GetFormFromFile(0x00025515, "DLCNukaWorld.esm") as ObjectReference

		if(kMapMarkerRef)
			kMapMarkerRef.Enable(false)
			kMapMarkerRef.AddToMap(true)
		endif
	endif

	if(Game.IsPluginInstalled("DLCCoast.esm"))
		ObjectReference kEnableParent = Game.GetFormFromFile(0x0003FEE7, "DLCCoast.esm") as ObjectReference

		if(kEnableParent)
			kEnableParent.Enable(false)

			ObjectReference kMapMarkerRef = Game.GetFormFromFile(0x0003FEE5, "DLCCoast.esm") as ObjectReference

			if(kMapMarkerRef)
				kMapMarkerRef.AddToMap(true)
			endif
		endif
	endif
EndFunction


; MCM Can't send None, so we're adding a wrapper
Function MCM_ClaimSettlement()
	ClaimSettlement(None)
EndFunction


; MCM Wrapper
Function MCM_PresentManageSettlementMenu()
	WorkshopScript thisWorkshop = WorkshopFramework:WSFW_API.GetNearestWorkshop(PlayerRef)

	if(thisWorkshop)
		PresentManageSettlementMenu(thisWorkshop)
	else
		CannotFindSettlement.Show()
	endif
EndFunction


Function MCM_ToggleWorkshopTutorials()
	if(Setting_WorkshopTutorialsEnabled.GetValue() == 1.0)
		EnableWorkshopTutorials()
	else
		DisableWorkshopTutorials()
	endif
EndFunction


function deduplicateAllVendorLists()
	ModTrace("[WSFW] List deduplication BEGIN")
	; iterate all workshop
	WorkshopScript[] Workshops = WorkshopParent.Workshops
	int i = 0
	while(i < Workshops.Length)
		deduplicateVendorListsForWorkshop(Workshops[i])
		i += 1
	endWhile
	ModTrace("[WSFW] List deduplication END")
endFunction

function deduplicateVendorListsForWorkshop(WorkshopScript ws)
	; vanilla
	ws.VendorContainersMisc 	= deduplicateObjectReferenceArray(ws.VendorContainersMisc)
	ws.VendorContainersArmor 	= deduplicateObjectReferenceArray(ws.VendorContainersArmor)
	ws.VendorContainersWeapons 	= deduplicateObjectReferenceArray(ws.VendorContainersWeapons)
	ws.VendorContainersBar 		= deduplicateObjectReferenceArray(ws.VendorContainersBar)
	ws.VendorContainersClinic 	= deduplicateObjectReferenceArray(ws.VendorContainersClinic)
	ws.VendorContainersClothing = deduplicateObjectReferenceArray(ws.VendorContainersClothing)

	; IN THEORY, this a) shouldn't be possible for custom ones and b) I don't think this can be done safely

endFunction

ObjectReference[] function deduplicateObjectReferenceArray(ObjectReference[] list)
	if(list == none || list.length == 0)
		return list
	endif

	ObjectReference[] result = new ObjectReference[0]

	int i=0
	while(i<list.length)
		ObjectReference thisRef = list[i]
		if(result.length == 0 || result.Find(thisRef) < 0)
			result.add(thisRef)
		endif
		i += 1
	endwhile

	ModTrace("[WSFW] List deduplication: before: "+list.length+", after: "+result.length)
	return result
endFunction



Function CheckForWorkshopScriptOverwrites()
	Bool bOverwriteFound = false
	
	ModTrace("Checking for workshop script overwrites...")
	
	WorkshopScript kSanctuaryRef = Game.GetFormFromFile(0x000250FE, "Fallout4.esm") as WorkshopScript
	
	
	; Make sure vars had a chance to fill
		; If WSFW version is installed, kSanctuaryRef.OnInit() will call FillWSFWVars() on it and WorkshopParent which will ensure the rest of our tests can work correctly
	kSanctuaryRef.OnInit() 
		
	; Check WorkshopParent
	var WorkshopParentCheck = WorkshopParent.GetPropertyValue("WSFW_Setting_AutoAssignBeds")
	if( ! (WorkshopParentCheck as GlobalVariable))
		ModTrace("   WorkshopParentScript: Overwritten!")
		bOverwriteFound = true
	else
		ModTrace("   WorkshopParentScript: Passed.")
	endif
	
	; Check WorkshopScript
	var WorkshopScriptCheck = kSanctuaryRef.GetPropertyValue("WSFW_Setting_minProductivity")
	if( ! (WorkshopScriptCheck as GlobalVariable))
		ModTrace("   WorkshopScript: Overwritten!")
		bOverwriteFound = true
	else
		ModTrace("   WorkshopScript: Passed.")
	endif
	
	; Check WorkshopObjectScript
	Form ScavStation = Game.GetFormFromFile(0x0008674C, "Fallout4.esm") as Form
	WorkshopObjectScript kTempRef = kSanctuaryRef.PlaceAtMe(ScavStation) as WorkshopObjectScript
	
	var WorkshopObjectScriptCheck = kTempRef.GetPropertyValue("WSFWOverwriteCheck")
	if( ! (WorkshopObjectScriptCheck as Quest))
		ModTrace("   WorkshopObjectScript: Overwritten!")
		bOverwriteFound = true
	else
		ModTrace("   WorkshopObjectScript: Passed.")
	endif
	
	; Check WorkshopNPCScript
	WorkshopNPCScript kTempNPC = NPCManager.CreateNPC(NPCManager.SettlerActorBase, kTempRef) as WorkshopNPCScript
	
	var WorkshopNPCScriptCheck = kTempRef.GetPropertyValue("WSFWOverwriteCheck")
	if( ! (WorkshopNPCScriptCheck as Quest))
		ModTrace("   WorkshopNPCScript: Overwritten!")
		bOverwriteFound = true
	else
		ModTrace("   WorkshopNPCScript: Passed.")
	endif
	
	kTempRef.Disable(false)
	kTempRef.Delete()
	
	kTempNPC.Disable(false)
	kTempNPC.Delete()
	
	if(bOverwriteFound)
		WorkshopScriptOverwriteWarning.Show()
	endif
	
	ModTrace("Completed check for workshop script overwrites. Overwrites found?: " + bOverwriteFound)
EndFunction


Function RelinkLocalSettlers()
	WorkshopScript currentWorkshop = WorkshopFramework:WSFW_API.GetNearestWorkshop(PlayerRef)
	
	if(currentWorkshop == None)
		return
	endif
	
	currentWorkshop.RelinkWorkshopActors()
endFunction

Function FixPopulationRating()
	ActorValue WorkshopRatingPopulation = Game.GetFormFromFile(0x0012723E, "Fallout4.esm") as ActorValue
	Actor CodsworthRef = Game.GetFormFromFile(0x0001CA7D, "Fallout4.esm") as Actor
	Actor NickRef = Game.GetFormFromFile(0x00002F25, "Fallout4.esm") as Actor
	
	if(CodsworthRef != None)
		CodsworthRef.SetValue(WorkshopRatingPopulation, 1.0)
	endif
	
	if(NickRef != None)
		NickRef.SetValue(WorkshopRatingPopulation, 1.0)
	endif
EndFunction

; Note: vanilla IsWithinBuildableArea will return true if akRef1 or akWorkshop is unloaded.
bool Function IsWithinBuildableAreaEX(ObjectReference akRef, ObjectReference akWorkshop)
{ return true if akRef is loaded and within settlement boundary }
	if ( akRef == none || \
		akWorkshop == none || \
		Self.IsCellLoaded(akRef.GetParentCell()) == false || \
		Self.IsCellLoaded(akWorkshop.GetParentCell()) == false )
		return false
	endif
	
	return akRef.IsWithinBuildableArea(akWorkshop)
EndFunction


bool Function IsCellLoaded(Cell aCell)
	return aCell != none && aCell.IsLoaded()
EndFunction

;
; Test Functions
;

Function CountOwnedSettlements(Bool abIncludeOutposts = true, Bool abIncludeVassals = false, Bool abIncludeVirtual = false)
	WorkshopScript[] Owned = WorkshopFramework:WorkshopFunctions.GetPlayerOwnedSettlements(abIncludeOutposts, abIncludeVassals, abIncludeVirtual)
	
	Debug.MessageBox("You own " + Owned.Length + " settlements.")
EndFunction


Function DumpWorkshops()
	ModTrace("DumpWorkshops()")
	WorkshopScript[] Workshops = WorkshopParent.Workshops
	int i = 0
	while(i < Workshops.Length)
		ModTrace("    " + Workshops[i])
		
		i += 1
	endwhile
	ModTrace("DumpWorkshops() complete.")
EndFunction