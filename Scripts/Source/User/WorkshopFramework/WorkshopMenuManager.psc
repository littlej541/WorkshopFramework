; ---------------------------------------------
; WorkshopFramework:WorkshopMenuManager.psc - by kinggath
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

Scriptname WorkshopFramework:WorkshopMenuManager extends WorkshopFramework:Library:SlaveQuest
{ Handles injected workshop menus }


import WorkshopFramework:Library:DataStructures
import WorkshopFramework:Library:UtilityFunctions
import WorkshopFramework:WorkshopFunctions


; ---------------------------------------------
; Consts
; ---------------------------------------------

; ---------------------------------------------
; Editor Properties 
; ---------------------------------------------

Group Formlists
	Formlist Property WorkshopMenuMain Auto Const Mandatory
EndGroup

; ---------------------------------------------
; Vars
; ---------------------------------------------
Bool bMenuCleaningInProgress = false

WorkshopMenuInjection[] QueuedInjections01
WorkshopMenuInjection[] QueuedInjections02
WorkshopMenuInjection[] QueuedInjections03
WorkshopMenuInjection[] QueuedInjections04
WorkshopMenuInjection[] QueuedInjections05
WorkshopMenuInjection[] QueuedInjections06
WorkshopMenuInjection[] QueuedInjections07
WorkshopMenuInjection[] QueuedInjections08

; ---------------------------------------------
; Events
; ---------------------------------------------


; ---------------------------------------------
; Event Handlers
; ---------------------------------------------

Function HandleGameLoaded()
	Parent.HandleGameLoaded()
	
	CleanMenus()
	ProcessQueuedRegistrations()
EndFunction

; ---------------------------------------------
; Functions
; ---------------------------------------------

Function CleanMenus()
	if(bMenuCleaningInProgress)
		return
	endif
	
	bMenuCleaningInProgress = true
	
	CleanFormListRecursively(WorkshopMenuMain)
	
	bMenuCleaningInProgress = false
EndFunction


; ------------------------------
; RegisterWorkshopMenu
;
; Description: Allow mods to inject to workshop menu without being dependent.
;	aTargetMenu					- workshop menu to inject into
;	aInjectKeywordOrFormlist	- workshop recipe filter keyword or formlist menu to inject into aTargetMenu
;
; Usage: How to use without being dependent.
;	ScriptObject WorkshopMenuManager = Game.GetFormFromFile(0x0001143E, "WorkshopFramework.esm") as ScriptObject
;	Var[] args = new Var[2]
;	args[0] = TargetMenu				; TargetMenu being a FormList var in your script.
;	args[1] = InjectKeywordOrFormlist	; Keyword or FormList you want to inject into TargetMenu defined in your script.
;	WorkshopMenuManager.CallFunction("RegisterWorkshopMenu", args)
; ------------------------------
Function RegisterWorkshopMenu(Formlist aTargetMenu, Form aInjectKeywordOrFormlist)
	if(aTargetMenu == None || aInjectKeywordOrFormlist == None || (! aInjectKeywordOrFormlist as Keyword && ! aInjectKeywordOrFormlist as Formlist))
		; invalid or missing params
		return
	endif
	
	WorkshopMenuInjection MenuInjection = new WorkshopMenuInjection
	MenuInjection.TargetMenu = aTargetMenu
	MenuInjection.InjectKeywordOrFormlist = aInjectKeywordOrFormlist
	RegisterMenu(MenuInjection)
EndFunction


; ------------------------------
; UnregisterWorkshopMenu
;
; Description: Allow mods to remove previously injected workshop menu items without being dependent.
;	aTargetMenu					- workshop menu injected into
;	aInjectKeywordOrFormlist	- added workshop recipe filter keyword or formlist menu to remove from aTargetMenu
;
; Note: Forms not added via script can not be removed via script.
; See RegisterWorkshopMenu for use example.
; ------------------------------
Function UnregisterWorkshopMenu(Formlist aTargetMenu, Form aInjectKeywordOrFormlist)
	if(aTargetMenu == None || aInjectKeywordOrFormlist == None || (! aInjectKeywordOrFormlist as Keyword && ! aInjectKeywordOrFormlist as Formlist))
		; invalid or missing params
		return
	endif
	
	WorkshopMenuInjection MenuInjection = new WorkshopMenuInjection
	MenuInjection.TargetMenu = aTargetMenu
	MenuInjection.InjectKeywordOrFormlist = aInjectKeywordOrFormlist
	UnregisterMenu(MenuInjection)
EndFunction


Function RegisterMenu(WorkshopMenuInjection aMenuInjection)
	if(aMenuInjection.TargetMenu != None && ((aMenuInjection.InjectKeywordOrFormlist as Keyword != None) || (aMenuInjection.InjectKeywordOrFormlist as Formlist != None)))
		if( ! aMenuInjection.TargetMenu.HasForm(aMenuInjection.InjectKeywordOrFormlist))
			if(bMenuCleaningInProgress)
				QueueMenuRegistration(aMenuInjection)
			else
				aMenuInjection.TargetMenu.AddForm(aMenuInjection.InjectKeywordOrFormlist)
			endif
		endif
	endif
EndFunction


Function UnregisterMenu(WorkshopMenuInjection aMenuInjection)
	if(aMenuInjection.TargetMenu != None && ((aMenuInjection.InjectKeywordOrFormlist as Keyword != None) || (aMenuInjection.InjectKeywordOrFormlist as Formlist != None)))
		if(aMenuInjection.TargetMenu.HasForm(aMenuInjection.InjectKeywordOrFormlist))
			aMenuInjection.TargetMenu.RemoveAddedForm(aMenuInjection.InjectKeywordOrFormlist)
		endif
	endif
EndFunction


Function ProcessQueuedRegistrations()
	int i = 0
	while(i < QueuedInjections01.Length)
		RegisterMenu(QueuedInjections01[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections02.Length)
		RegisterMenu(QueuedInjections02[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections03.Length)
		RegisterMenu(QueuedInjections03[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections04.Length)
		RegisterMenu(QueuedInjections04[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections05.Length)
		RegisterMenu(QueuedInjections05[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections06.Length)
		RegisterMenu(QueuedInjections06[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections07.Length)
		RegisterMenu(QueuedInjections07[i])
		
		i += 1
	endWhile
	
	i = 0
	while(i < QueuedInjections08.Length)
		RegisterMenu(QueuedInjections08[i])
		
		i += 1
	endWhile
EndFunction


Function QueueMenuRegistration(WorkshopMenuInjection aMenuInjection)
	; Block 01
	if(QueuedInjections01 == None || QueuedInjections01.Length == 0)
		QueuedInjections01 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections01.Length < 128)
		QueuedInjections01.Add(aMenuInjection)
		return
	endif
	
	; Block 02
	if(QueuedInjections02 == None || QueuedInjections02.Length == 0)
		QueuedInjections02 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections02.Length < 128)
		QueuedInjections02.Add(aMenuInjection)
		return
	endif
	
	; Block 03
	if(QueuedInjections03 == None || QueuedInjections03.Length == 0)
		QueuedInjections03 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections03.Length < 128)
		QueuedInjections03.Add(aMenuInjection)
		return
	endif
		
	; Block 04
	if(QueuedInjections04 == None || QueuedInjections04.Length == 0)
		QueuedInjections04 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections04.Length < 128)
		QueuedInjections04.Add(aMenuInjection)
		return
	endif
		
	; Block 05
	if(QueuedInjections05 == None || QueuedInjections05.Length == 0)
		QueuedInjections05 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections05.Length < 128)
		QueuedInjections05.Add(aMenuInjection)
		return
	endif
		
	; Block 06
	if(QueuedInjections06 == None || QueuedInjections06.Length == 0)
		QueuedInjections06 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections06.Length < 128)
		QueuedInjections06.Add(aMenuInjection)
		return
	endif
	
	; Block 07
	if(QueuedInjections07 == None || QueuedInjections07.Length == 0)
		QueuedInjections07 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections07.Length < 128)
		QueuedInjections07.Add(aMenuInjection)
		return
	endif
	
	; Block 08
	if(QueuedInjections08 == None || QueuedInjections08.Length == 0)
		QueuedInjections08 = new WorkshopMenuInjection[0]
	endif
	
	if(QueuedInjections08.Length < 128)
		QueuedInjections08.Add(aMenuInjection)
		return
	endif
EndFunction
