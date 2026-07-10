ScriptName WSFWIdentifier native hidden

Struct PowerGridStatistics
	Bool corrupted
	Bool checked
	Int existingNodes
	Int deletedNodes
	Int numCorruptedGrids
	Int totalNodes
	Int totalGrids
EndStruct

Struct RecipeComponent
	Form Object
	Int Count
EndStruct

; Cached form lookups to avoid hammering Game.GetFormFromFile in hot paths. Build once with GetWorkshopForms().
Struct WorkshopForms
	Keyword WorkshopItemKeyword
	Keyword WorkshopCanBePowered
	Keyword WorkshopPowerConnection
	ActorValue WorkshopPowerConnectionAV
	ActorValue WorkshopSnapPointRadiusAV
	ActorValue WorkshopSnapTransmitsPowerAV
	Form wireBase
EndStruct

; Cached visual-highlight EffectShader references. Standalone (no TransferSettlements.esp shader source)
; leaves all fields None and _Highlight* become no-ops - identical to TS running without TS installed.
Struct HighlightShaders
	EffectShader Red
	EffectShader Blue
	EffectShader Yellow
	EffectShader Green
	EffectShader Purple
	EffectShader White
EndStruct

Bool Function ArePowerGridStatisticsCorrupt(PowerGridStatistics pgs) global
	return pgs != None && pgs.corrupted
EndFunction

Int[] Function GetCorruptPowerGridIndices(ObjectReference akWorkshopRef) global
	return GetCorruptedPowerGridIndices(akWorkshopRef)
EndFunction

Int[] Function GetBadPowerGridIndices(ObjectReference akWorkshopRef) global
	return GetCorruptedPowerGridIndices(akWorkshopRef)
EndFunction

Int[] Function GetInvalidNodeFormIDs(ObjectReference akWorkshopRef) global
	return GetDeletedNodeFormIDs(akWorkshopRef)
EndFunction

String[] Function ScanForPowerGridCorruption(ObjectReference workshopRef, ObjectReference[] workshopObjects, Bool verboseToLog = True, Int maxTraverseCount = 8192, Bool requireValidIndex = True, Bool reconnectResidualGridFragments = False, Bool createNewGrids = False) global
	return FixConnectionIntegrityErrors(workshopRef, workshopObjects, verboseToLog, maxTraverseCount, requireValidIndex, reconnectResidualGridFragments, createNewGrids)
EndFunction

;-- Glossary ----------------------------------------

;- power grid					: An array of ObjectReference FormIDs stored internally on a Workshop as ExtraData
;								  that shows which objects share the same connection graph.
;								  Connections can be wired, snapped or wireless. A workshop can have any number of power grids.
;- power node					: A single element of a power grid.
;- deleted power node			: A node that has the FormID of an ObjectReference that no longer exists in the game. Usually happens
;								  when a powered settlement object gets deleted by a script, a console command or by uninstalling a mod
;								  in the middle of a playthrough. All of these three examples result in the lack of proper removal of
;								  the power node of the deleted object.
;								  This is the perfect gateway to the Scrap Crash bug as the engine recycles these FormIDs eventually,
;								  ending up with a corrupted power node that references an object that is most probably outside
;								  the settlement and has nothing to do with the workshop.
;- corrupted power node			: A deleted node that has its FormID already recycled by the engine and references an object
;								  that is most probably outside the settlement and has nothing to do with the workshop.
;								  A workshop that has at least one of these corrupted power nodes is subject to the Scrap Crash bug and
;								  is considered broken. Scrapping or storing any powered objects at such a broken settlement workshop
;								  would result in a crash to desktop (CTD), aka a Scrap Crash.
;- corrupted power grid			: A power grid with at least one deleted node.
;- orphaned wire				: A former wire connection that is no longer functional because one or both ends are not connected
;								  to an object anymore.
;- traverse group				: A group of actual game objects that are powered and their wired, snap or wireless connections create
;								  a single graph that can be traversed from any member of the group to any other member of the group.
;- residual power grid fragments: A power grid that has its power nodes separated into multiple traverse groups. Usually happens
;								  when a powered settlement object gets deleted by a script, a console command or by uninstalling a mod
;								  in the middle of a playthrough. All of these three examples result in the lack of proper removal of
;								  the power node of the deleted object.
;- connection integrity error	: There's no one-to-one mapping between a traverse group and a power grid.
;									Type-1: not all objects in a traverse group belong to the same power grid.
;									Type-2: not all nodes in a power grid reference objects from the same traverse group, resulting in
;											several residual power grid fragments.


;-- Functions ---------------------------------------

; Returns the ReferenceName of an object
; - akRef	: the object
string Function GetReferenceName( ObjectReference akRef ) global native

; Compares different types of name attributes of an ObjectReference in a MessageBox
; - akRef	: the object
Function MessageReferenceName( ObjectReference akRef ) global
	Debug.MessageBox( "akRef.GetName(): " + akRef.GetName() + "<br>akRef.GetBaseObject().GetName(): " + akRef.GetBaseObject().GetName() + "<br>akRef.GetDisplayName(): " + akRef.GetDisplayName() + "<br>GetReferenceName( akRef ): " + GetReferenceName( akRef ) )
EndFunction

; Uber function for convenience to call a sequence of methods necessary to remove corrupted or deleted power grid nodes,
; fix connection integrity errors and remove residual orphaned wires at a settlement. Returns array of message reports.
; - akWorkshopRef	: the settlement's workshop workbench reference
; LEGACY full 8-phase fix (kept for reference). Unstable power-refresh / grid-split / generator-toggle
; phases live here. The recommended entry point is FixScrapCrash() below (faithful TS phases 1-3).
String[] Function FixScrapCrashLegacy( ObjectReference akWorkshopRef, Int phase = -1 ) global

	Float fTime = Utility.GetCurrentRealTime()
	Float fCurrentTime = Utility.GetCurrentRealTime()
	Utility.Wait( 0.1 )
	
	String[] report = New String[0]
	String[] connectionIntegrityReport = New String[0]
	ObjectReference[] goodNodeRefs
	Int[] goodGridsHandled = New Int[0]
	String logMsg = ""
	ScriptObject TempGenerator

	Int i
	Int j
	
	Actor PlayerREF = Game.GetPlayer()
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	ActorValue PowerGeneratedAV = Game.GetFormFromFile( 0x0000032E, "Fallout4.esm") as ActorValue
	ObjectReference[] workshopObjects = akWorkshopRef.GetRefsLinkedToMe( WorkshopItemKeyword )
	
	logMsg = "[START]"
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	logMsg = "number of corrupted power grids before fix: " + GetCorruptedPowerGridIndices( akWorkshopRef ).Length
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	
	; -- temp
	goodNodeRefs = GetGoodNodeRefs( akWorkshopRef )
	i = 0
	While i < goodNodeRefs.Length
		If IsGoodNode( akWorkshopRef, goodNodeRefs[i], False, True )
			DebugLog( "FixScrapCrash", GetFormInfo(goodNodeRefs[i]) + " connected objects count: " + goodNodeRefs[i].GetConnectedObjects().Length )
		EndIf
		i += 1
	EndWhile
	
	If phase < 0 || phase == 1
	
		; removing ObjectReferences from the power grid that no longer exist in the game
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 1] checking ObjectReferences in the power grid that no longer exist in the game"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 1/8" )
		fTime = Utility.GetCurrentRealTime()
		Int[] removedDeletedNodeFormIDs = RemoveNodesFromPowerGrid( akWorkshopRef, GetDeletedNodeFormIDs( akWorkshopRef ) )
		String removedDeletedNodes = ""
		i = 0
		While i < removedDeletedNodeFormIDs.Length
			If i > 0
				removedDeletedNodes += ", "
			EndIf
			removedDeletedNodes += GetFormIDHex( removedDeletedNodeFormIDs[i] )
			i += 1
		EndWhile
		If i > 0
			logMsg = "former FormIDs of ObjectReferences in the power grid that no longer exist in the game, and now got removed from the grid as well: " + removedDeletedNodes
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		EndIf

		Utility.Wait( 0.1 )
	
	; -- temp
	goodNodeRefs = GetGoodNodeRefs( akWorkshopRef )
	i = 0
	While i < goodNodeRefs.Length
		If IsGoodNode( akWorkshopRef, goodNodeRefs[i], False, True )
			DebugLog( "FixScrapCrash", GetFormInfo(goodNodeRefs[i]) + " connected objects count: " + goodNodeRefs[i].GetConnectedObjects().Length )
		EndIf
		fCurrentTime = Utility.GetCurrentRealTime()
		If fCurrentTime - fTime > 10
			Debug.Notification( "fixing workshop 1/8" )
			fTime = fCurrentTime
		EndIf
		i += 1
	EndWhile
	
	EndIf
	
	If phase < 0 || phase == 2
	
		; removing corrupted ObjectReferences from the power grid that are not settlement objects
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 2] checking corrupted ObjectReferences in the power grid that are not settlement objects"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 2/8" )
		fTime = Utility.GetCurrentRealTime()
		Int[] removedCorruptedNodeFormIDs = RemoveNodesFromPowerGrid( akWorkshopRef, GetCorruptedNodeFormIDs( akWorkshopRef ) )
		String removedCorruptedNodes = ""
		i = 0
		While i < removedCorruptedNodeFormIDs.Length
			If i > 0
				removedCorruptedNodes += ", "
			EndIf
			ObjectReference removedCorruptedNodeRef = Game.GetForm( removedCorruptedNodeFormIDs[i] ) as ObjectReference
			String removedCorruptedNodeFormInfo = GetFormInfo( removedCorruptedNodeRef )
			removedCorruptedNodes += removedCorruptedNodeFormInfo
			i += 1
		EndWhile
		If i > 0
			logMsg = "corrupted ObjectReferences in the power grid that are not settlement objects, and now got removed from the grid: " + removedCorruptedNodes
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		EndIf

		Utility.Wait( 0.5 )
	
	; -- temp
	goodNodeRefs = GetGoodNodeRefs( akWorkshopRef )
	i = 0
	While i < goodNodeRefs.Length
		If IsGoodNode( akWorkshopRef, goodNodeRefs[i], False, True )
			DebugLog( "FixScrapCrash", GetFormInfo(goodNodeRefs[i]) + " connected objects count: " + goodNodeRefs[i].GetConnectedObjects().Length )
		EndIf
		fCurrentTime = Utility.GetCurrentRealTime()
		If fCurrentTime - fTime > 10
			Debug.Notification( "fixing workshop 2/8" )
			fTime = fCurrentTime
		EndIf
		i += 1
	EndWhile
	
	EndIf
	
	If phase < 0 || phase == 3
	
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 3] refreshing power connections after the removal of deleted and corrupted power nodes"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 3/8" )
		fTime = Utility.GetCurrentRealTime()
	
		If akWorkshopRef.GetFormID() == 0x0006F5C5 && 0
			i = 0
			While i < workshopObjects.Length
				If workshopObjects[i].GetValue( PowerGeneratedAV ) == 100.0
					logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Fusion Generator, testing power connection..."
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
					
					If RefreshPowerGrids( workshopObjects[i], akWorkshopRef )
						logMsg = "...success"
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
					Else
						logMsg = "...FAILED!"
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
					EndIf
				Endif
				i += 1
			EndWhile
		EndIf
	
		i = 0
		While i < workshopObjects.Length && 0
			If workshopObjects[i].GetValue( PowerGeneratedAV ) > 0.0
				logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Generator, deactivating it..."
				report = AddString( report, logMsg )
				DebugLog( "FixScrapCrash", logMsg )
				TempGenerator = workshopObjects[i].CastAs( "DLC06:WorkshopPowerbikeScript" )
				If !TempGenerator
					workshopObjects[i].Activate( PlayerREF )
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " deactivated"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				Else
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " is a power bike"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				EndIf
			Endif
			i += 1
		EndWhile
	
		i = 0
		While i < workshopObjects.Length && 0
			If workshopObjects[i].GetValue( PowerGeneratedAV ) > 0.0
				logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Generator, activating it..."
				report = AddString( report, logMsg )
				DebugLog( "FixScrapCrash", logMsg )
				TempGenerator = workshopObjects[i].CastAs( "DLC06:WorkshopPowerbikeScript" )
				If !TempGenerator
					workshopObjects[i].Activate( PlayerREF )
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " deactivated"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				Else
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " is a power bike"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				EndIf
			Endif
			i += 1
		EndWhile

		; refreshing power connections after the removal of deleted and corrupted power nodes
		goodNodeRefs = GetGoodNodeRefs( akWorkshopRef )
		i = 0
		While i < goodNodeRefs.Length
			If IsGoodNode( akWorkshopRef, goodNodeRefs[i], False, True, True )
				Int idx = GetPowerGridIndexForObject( akWorkshopRef, goodNodeRefs[i] )
				If !_HasInt( goodGridsHandled, idx )
					j = 0
					While j < goodNodeRefs.Length
						If j != i
							If IsGoodNode( akWorkshopRef, goodNodeRefs[j], False, True, True )
								Int idx2 = GetPowerGridIndexForObject( akWorkshopRef, goodNodeRefs[j] )
								If idx2 == idx
									logMsg = "refreshing power connections for grid #" + idx + " by temporarily connecting " + GetFormInfo( goodNodeRefs[i] ) + " and " + GetFormInfo( goodNodeRefs[j] ) + "..."
									report = AddString( report, logMsg )
									DebugLog( "FixScrapCrash", logMsg )
									If RefreshPowerGrids( goodNodeRefs[i], akWorkshopRef, goodNodeRefs[j] )
										logMsg = "...success"
										report = AddString( report, logMsg )
										DebugLog( "FixScrapCrash", logMsg )
										goodGridsHandled = AddInt( goodGridsHandled, idx )
										j = goodNodeRefs.Length
									Else
										logMsg = "...FAILED!"
										report = AddString( report, logMsg )
										DebugLog( "FixScrapCrash", logMsg )
									EndIf
								EndIf
							EndIf
						EndIf
						fCurrentTime = Utility.GetCurrentRealTime()
						If fCurrentTime - fTime > 10
							Debug.Notification( "fixing workshop 3/8" )
							fTime = fCurrentTime
						EndIf
						j += 1
					EndWhile
					If j == goodNodeRefs.Length && !_HasInt( goodGridsHandled, idx )
						logMsg = "refreshing power connections for grid #" + idx + " by temporarily connecting " + GetFormInfo( goodNodeRefs[i] ) + " to a temporary pylon..."
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
						If RefreshPowerGrids( goodNodeRefs[i], akWorkshopRef )
							logMsg = "...success"
							report = AddString( report, logMsg )
							DebugLog( "FixScrapCrash", logMsg )
							goodGridsHandled = AddInt( goodGridsHandled, idx )
						Else
							logMsg = "...FAILED!"
							report = AddString( report, logMsg )
							DebugLog( "FixScrapCrash", logMsg )
						EndIf
					EndIf
				EndIf
			EndIf
			fCurrentTime = Utility.GetCurrentRealTime()
			If fCurrentTime - fTime > 10
				Debug.Notification( "fixing workshop 3/8" )
				fTime = fCurrentTime
			EndIf
			i += 1
		EndWhile

		Utility.Wait( 0.5 )
	
	EndIf
	
	If phase < 0 || phase == 4
	
		; removing residual orphaned wires
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 4] checking residual orphaned wires"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 4/8" )
		fTime = Utility.GetCurrentRealTime()
		String removedOrphanedWires = RemoveOrphanedWires( akWorkshopRef )
		If removedOrphanedWires != ""
			logMsg = "former FormIDs of residual orphaned wires that got removed: " + removedOrphanedWires
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		Else
			logMsg = "no residual orphaned wires found"
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		EndIf

		Utility.Wait( 0.5 )
	
	EndIf
	
	If phase < 0 || phase == 5
	
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 5] refreshing power connections after removing orphaned wires"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 5/8" )
		fTime = Utility.GetCurrentRealTime()
	
		If akWorkshopRef.GetFormID() == 0x0006F5C5 && 0
			i = 0
			While i < workshopObjects.Length
				If workshopObjects[i].GetValue( PowerGeneratedAV ) == 100.0
					logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Fusion Generator, testing power connection..."
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
					If RefreshPowerGrids( workshopObjects[i], akWorkshopRef )
						logMsg = "...success"
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
					Else
						logMsg = "...FAILED!"
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
					EndIf
				Endif
				i += 1
			EndWhile
		EndIf
	
		i = 0
		While i < workshopObjects.Length && 0
			If workshopObjects[i].GetValue( PowerGeneratedAV ) > 0.0
				logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Generator, deactivating it..."
				report = AddString( report, logMsg )
				DebugLog( "FixScrapCrash", logMsg )
				TempGenerator = workshopObjects[i].CastAs( "DLC06:WorkshopPowerbikeScript" )
				If !TempGenerator
					workshopObjects[i].Activate( PlayerREF )
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " deactivated"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				Else
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " is a power bike"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				EndIf
			Endif
			i += 1
		EndWhile
	
		i = 0
		While i < workshopObjects.Length && 0
			If workshopObjects[i].GetValue( PowerGeneratedAV ) > 0.0
				logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Generator, activating it..."
				report = AddString( report, logMsg )
				DebugLog( "FixScrapCrash", logMsg )
				TempGenerator = workshopObjects[i].CastAs( "DLC06:WorkshopPowerbikeScript" )
				If !TempGenerator
					workshopObjects[i].Activate( PlayerREF )
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " deactivated"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				Else
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " is a power bike"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				EndIf
			Endif
			i += 1
		EndWhile

		; refreshing power connections after removing orphaned wires
		goodGridsHandled = New Int[0]
		goodNodeRefs = GetGoodNodeRefs( akWorkshopRef )
		i = 0
		While i < goodNodeRefs.Length
			If IsGoodNode( akWorkshopRef, goodNodeRefs[i], False, True, True )
				Int idx = GetPowerGridIndexForObject( akWorkshopRef, goodNodeRefs[i] )
				If !_HasInt( goodGridsHandled, idx )
					j = 0
					While j < goodNodeRefs.Length
						If j != i
							If IsGoodNode( akWorkshopRef, goodNodeRefs[j], False, True, True )
								Int idx2 = GetPowerGridIndexForObject( akWorkshopRef, goodNodeRefs[j] )
								If idx2 == idx
									logMsg = "refreshing power connections for grid #" + idx + " by temporarily connecting " + GetFormInfo( goodNodeRefs[i] ) + " and " + GetFormInfo( goodNodeRefs[j] ) + "..."
									report = AddString( report, logMsg )
									DebugLog( "FixScrapCrash", logMsg )
									If RefreshPowerGrids( goodNodeRefs[i], akWorkshopRef, goodNodeRefs[j] )
										logMsg = "...success"
										report = AddString( report, logMsg )
										DebugLog( "FixScrapCrash", logMsg )
										goodGridsHandled = AddInt( goodGridsHandled, idx )
										j = goodNodeRefs.Length
									Else
										logMsg = "...FAILED!"
										report = AddString( report, logMsg )
										DebugLog( "FixScrapCrash", logMsg )
									EndIf
								EndIf
							EndIf
						EndIf
						fCurrentTime = Utility.GetCurrentRealTime()
						If fCurrentTime - fTime > 10
							Debug.Notification( "fixing workshop 5/8" )
							fTime = fCurrentTime
						EndIf
						j += 1
					EndWhile
					If j == goodNodeRefs.Length && !_HasInt( goodGridsHandled, idx )
						logMsg = "refreshing power connections for grid #" + idx + " by temporarily connecting " + GetFormInfo( goodNodeRefs[i] ) + " to a temporary pylon..."
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
						If RefreshPowerGrids( goodNodeRefs[i], akWorkshopRef )
							logMsg = "...success"
							report = AddString( report, logMsg )
							DebugLog( "FixScrapCrash", logMsg )
							goodGridsHandled = AddInt( goodGridsHandled, idx )
						Else
							logMsg = "...FAILED!"
							report = AddString( report, logMsg )
							DebugLog( "FixScrapCrash", logMsg )
						EndIf
					EndIf
				EndIf
			EndIf
			fCurrentTime = Utility.GetCurrentRealTime()
			If fCurrentTime - fTime > 10
				Debug.Notification( "fixing workshop 5/8" )
				fTime = fCurrentTime
			EndIf
			i += 1
		EndWhile

		Utility.Wait( 0.5 )
	
	EndIf
	
	If phase < 0 || phase == 6
	
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 6] checking connection integrity errors, splitting residual power grid fragments into new individual power grids"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 6/8" )
		fTime = Utility.GetCurrentRealTime()
	
		; reconnecting residual power grid fragments
		;connectionIntegrityReport = FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192, True, True )
		
		; splitting residual power grid fragments into new individual power grids
		connectionIntegrityReport = FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192, True, False, True )

		Utility.Wait( 0.5 )
	
		i = 0
		While i < connectionIntegrityReport.Length
			logMsg = "connection integrity report first run: " + connectionIntegrityReport[i]
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
			i += 1
		EndWhile

		Utility.Wait( 0.5 )
	
	EndIf
	
	If phase < 0 || phase == 7
	
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 7] refreshing power connections after connection integrity fixes"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 7/8" )
		fTime = Utility.GetCurrentRealTime()
	
		If akWorkshopRef.GetFormID() == 0x0006F5C5 && 0
			i = 0
			While i < workshopObjects.Length
				If workshopObjects[i].GetValue( PowerGeneratedAV ) == 100.0
					logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Fusion Generator, testing power connection..."
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
					If RefreshPowerGrids( workshopObjects[i], akWorkshopRef )
						logMsg = "...success"
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
					Else
						logMsg = "...FAILED!"
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
					EndIf
				Endif
				i += 1
			EndWhile
		EndIf
	
		i = 0
		While i < workshopObjects.Length && 0
			If workshopObjects[i].GetValue( PowerGeneratedAV ) > 0.0
				logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Generator, deactivating it..."
				report = AddString( report, logMsg )
				DebugLog( "FixScrapCrash", logMsg )
				TempGenerator = workshopObjects[i].CastAs( "DLC06:WorkshopPowerbikeScript" )
				If !TempGenerator
					workshopObjects[i].Activate( PlayerREF )
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " deactivated"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				Else
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " is a power bike"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				EndIf
			Endif
			i += 1
		EndWhile
	
		i = 0
		While i < workshopObjects.Length && 0
			If workshopObjects[i].GetValue( PowerGeneratedAV ) > 0.0
				logMsg = "workshop item #" + i + " " + GetFormInfo( workshopObjects[i] ) + " is a Generator, activating it..."
				report = AddString( report, logMsg )
				DebugLog( "FixScrapCrash", logMsg )
				TempGenerator = workshopObjects[i].CastAs( "DLC06:WorkshopPowerbikeScript" )
				If !TempGenerator
					workshopObjects[i].Activate( PlayerREF )
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " deactivated"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				Else
					logMsg = "generator: " + GetFormInfo( workshopObjects[i] ) + " is a power bike"
					report = AddString( report, logMsg )
					DebugLog( "FixScrapCrash", logMsg )
				EndIf
			Endif
			i += 1
		EndWhile

		; refreshing power connections after connection integrity fixes
		goodGridsHandled = New Int[0]
		goodNodeRefs = GetGoodNodeRefs( akWorkshopRef )
		i = 0
		While i < goodNodeRefs.Length
			If IsGoodNode( akWorkshopRef, goodNodeRefs[i], False, True, True )
				Int idx = GetPowerGridIndexForObject( akWorkshopRef, goodNodeRefs[i] )
				If !_HasInt( goodGridsHandled, idx )
					j = 0
					While j < goodNodeRefs.Length
						If j != i
							If IsGoodNode( akWorkshopRef, goodNodeRefs[j], False, True, True )
								Int idx2 = GetPowerGridIndexForObject( akWorkshopRef, goodNodeRefs[j] )
								If idx2 == idx
									logMsg = "refreshing power connections for grid #" + idx + " by temporarily connecting " + GetFormInfo( goodNodeRefs[i] ) + " and " + GetFormInfo( goodNodeRefs[j] ) + "..."
									report = AddString( report, logMsg )
									DebugLog( "FixScrapCrash", logMsg )
									If RefreshPowerGrids( goodNodeRefs[i], akWorkshopRef, goodNodeRefs[j] )
										logMsg = "...success"
										report = AddString( report, logMsg )
										DebugLog( "FixScrapCrash", logMsg )
										goodGridsHandled = AddInt( goodGridsHandled, idx )
										j = goodNodeRefs.Length
									Else
										logMsg = "...FAILED!"
										report = AddString( report, logMsg )
										DebugLog( "FixScrapCrash", logMsg )
									EndIf
								EndIf
							EndIf
						EndIf
						fCurrentTime = Utility.GetCurrentRealTime()
						If fCurrentTime - fTime > 10
							Debug.Notification( "fixing workshop 7/8" )
							fTime = fCurrentTime
						EndIf
						j += 1
					EndWhile
					If j == goodNodeRefs.Length && !_HasInt( goodGridsHandled, idx )
						logMsg = "refreshing power connections for grid #" + idx + " by temporarily connecting " + GetFormInfo( goodNodeRefs[i] ) + " to a temporary pylon..."
						report = AddString( report, logMsg )
						DebugLog( "FixScrapCrash", logMsg )
						If RefreshPowerGrids( goodNodeRefs[i], akWorkshopRef )
							logMsg = "...success"
							report = AddString( report, logMsg )
							DebugLog( "FixScrapCrash", logMsg )
							goodGridsHandled = AddInt( goodGridsHandled, idx )
						Else
							logMsg = "...FAILED!"
							report = AddString( report, logMsg )
							DebugLog( "FixScrapCrash", logMsg )
						EndIf
					EndIf
				EndIf
			EndIf
			fCurrentTime = Utility.GetCurrentRealTime()
			If fCurrentTime - fTime > 10
				Debug.Notification( "fixing workshop 7/8" )
				fTime = fCurrentTime
			EndIf
			i += 1
		EndWhile
	
	EndIf
	
	If phase < 0 || phase == 8
	
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 8] checking connection integrity again"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		Debug.Notification( "fixing workshop 8/8" )
		fTime = Utility.GetCurrentRealTime()
	
		connectionIntegrityReport = FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192 )

		Utility.Wait( 0.5 )
		
		i = 0
		While i < connectionIntegrityReport.Length
			logMsg = "connection integrity report second run: " + connectionIntegrityReport[i]
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
			i += 1
		EndWhile

		Utility.Wait( 0.5 )
	
	EndIf
	
	DebugLog( "FixScrapCrash", "" )
	logMsg = "[END]"
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	
	logMsg = "number of corrupted power grids after fix: " + GetCorruptedPowerGridIndices( akWorkshopRef ).Length
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	
	return report
	
EndFunction

; Recommended standalone Scrap Crash Fix. Faithful port of the Transfer Settlements 2.21 "recommended"
; path (phases 1-3): 1=remove deleted nodes, 2=remove corrupted (non-settlement) nodes, 3=delete orphaned
; wires. The legacy full run's unstable power-refresh / grid-split / generator-toggle phases (4-6) are
; intentionally NOT included here (see FixScrapCrashLegacy). Progress uses the same ShowProgress* helpers
; as TS; with no HUDFramework they emit ~8s-cooldown Debug.Notification heartbeats carrying the phase +
; within-phase percent. No HUDFramework / no .esp required (shaders no-op without a shader source, exactly
; as in TS when TransferSettlements is not installed).
; - akWorkshopRef		: the settlement's workshop workbench reference
; - phaseFrom / phaseTo	: phase range, run in order (1=deleted, 2=corrupted, 3=orphaned wires). "mandatory"=1..2, "recommended"=1..3.
String[] Function FixScrapCrash( ObjectReference akWorkshopRef, Int phaseFrom = 1, Int phaseTo = 3 ) global

	Float fTime = Utility.GetCurrentRealTime()
	Utility.Wait( 0.1 )

	String[] report = New String[0]
	String logMsg = ""
	Int i

	Bool ProgressBarAvailable = False

	; Removed-counts captured during the phases, shown in the end-of-run result MessageBox.
	Int deletedNodesRemoved = 0
	Int corruptedNodesRemoved = 0
	Int orphanedWiresRemoved = 0

	; Cache workshop-related forms + highlight shaders once for the whole fix.
	WorkshopForms forms = GetWorkshopForms()
	HighlightShaders shaders = GetHighlightShaders()
	Keyword WorkshopItemKeyword = forms.WorkshopItemKeyword
	ObjectReference[] workshopObjects = akWorkshopRef.GetRefsLinkedToMe( WorkshopItemKeyword )

	logMsg = "[START]"
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	logMsg = "[note] running phases " + phaseFrom + ".." + phaseTo
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	logMsg = "grids before fix: total=" + GetPowerGridCount( akWorkshopRef ) + ", good=" + GetGoodPowerGridIndices( akWorkshopRef ).Length + ", corrupted=" + GetCorruptedPowerGridIndices( akWorkshopRef ).Length
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )

	ProgressBarAvailable = IsHUDFrameworkAvailable()

	; -- PHASE 1: remove power nodes whose ObjectReference no longer exists in the game --
	If phaseFrom <= 1 && 1 <= phaseTo
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 1] checking ObjectReferences in the power grid that no longer exist in the game"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		fTime = ShowProgressPhase( ProgressBarAvailable, "fixing workshop 1/" + phaseTo + ": fixing deleted nodes" )
		Int[] removedDeletedNodeFormIDs = RemoveNodesFromPowerGrid( akWorkshopRef, GetDeletedNodeFormIDs( akWorkshopRef ) )
		deletedNodesRemoved = removedDeletedNodeFormIDs.Length
		String removedDeletedNodes = ""
		i = 0
		While i < removedDeletedNodeFormIDs.Length
			If i > 0
				removedDeletedNodes += ", "
			EndIf
			removedDeletedNodes += GetFormIDHex( removedDeletedNodeFormIDs[i] )
			i += 1
		EndWhile
		If i > 0
			logMsg = "former FormIDs of ObjectReferences that no longer exist and got removed from the grid: " + removedDeletedNodes
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		EndIf
		Utility.Wait( 0.1 )
	EndIf

	logMsg = "grids after phase 1: total=" + GetPowerGridCount( akWorkshopRef ) + ", good=" + GetGoodPowerGridIndices( akWorkshopRef ).Length + ", corrupted=" + GetCorruptedPowerGridIndices( akWorkshopRef ).Length
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )

	; -- PHASE 2: remove corrupted power nodes that reference non-settlement objects --
	If phaseFrom <= 2 && 2 <= phaseTo
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 2] checking corrupted ObjectReferences in the power grid that are not settlement objects"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		fTime = ShowProgressPhase( ProgressBarAvailable, "fixing workshop 2/" + phaseTo + ": fixing corrupted nodes" )
		Int[] corruptedNodeFIDsToRemove = GetCorruptedNodeFormIDs( akWorkshopRef, True, "fixing workshop 2/" + phaseTo + ": corrupted nodes" )
		_HighlightFormIDs( corruptedNodeFIDsToRemove, shaders.Red )
		Int[] removedCorruptedNodeFormIDs = RemoveNodesFromPowerGrid( akWorkshopRef, corruptedNodeFIDsToRemove )
		corruptedNodesRemoved = removedCorruptedNodeFormIDs.Length
		String removedCorruptedNodes = ""
		i = 0
		While i < removedCorruptedNodeFormIDs.Length
			If i > 0
				removedCorruptedNodes += ", "
			EndIf
			ObjectReference removedCorruptedNodeRef = Game.GetForm( removedCorruptedNodeFormIDs[i] ) as ObjectReference
			removedCorruptedNodes += GetFormInfo( removedCorruptedNodeRef )
			i += 1
		EndWhile
		If i > 0
			logMsg = "corrupted ObjectReferences that are not settlement objects and got removed from the grid: " + removedCorruptedNodes
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		EndIf
		Utility.Wait( 0.5 )
	EndIf

	logMsg = "grids after phase 2: total=" + GetPowerGridCount( akWorkshopRef ) + ", good=" + GetGoodPowerGridIndices( akWorkshopRef ).Length + ", corrupted=" + GetCorruptedPowerGridIndices( akWorkshopRef ).Length
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )

	; -- PHASE 3: remove residual orphaned wires (a wire with fewer than 2 valid settlement endpoints) --
	If phaseFrom <= 3 && 3 <= phaseTo
		DebugLog( "FixScrapCrash", "" )
		logMsg = "[PHASE 3] checking residual orphaned wires"
		report = AddString( report, logMsg )
		DebugLog( "FixScrapCrash", logMsg )
		fTime = ShowProgressPhase( ProgressBarAvailable, "fixing workshop 3/" + phaseTo + ": removing orphaned wires" )
		Int[] removedOrphanedWireFIDs = _RemoveOrphanedWiresCore( akWorkshopRef, workshopObjects, True, "fixing workshop 3/" + phaseTo + ": orphaned wires" )
		orphanedWiresRemoved = removedOrphanedWireFIDs.Length
		If orphanedWiresRemoved > 0
			logMsg = "removed " + orphanedWiresRemoved + " residual orphaned wire(s)"
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		Else
			logMsg = "no residual orphaned wires found"
			report = AddString( report, logMsg )
			DebugLog( "FixScrapCrash", logMsg )
		EndIf
		Utility.Wait( 0.5 )
	EndIf

	DebugLog( "FixScrapCrash", "" )
	logMsg = "[END]"
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )
	logMsg = "grids after fix: total=" + GetPowerGridCount( akWorkshopRef ) + ", good=" + GetGoodPowerGridIndices( akWorkshopRef ).Length + ", corrupted=" + GetCorruptedPowerGridIndices( akWorkshopRef ).Length
	report = AddString( report, logMsg )
	DebugLog( "FixScrapCrash", logMsg )

	; End-of-run result message, reproducing the Transfer Settlements holotape format (PowerGridFixedMessage /
	; PowerGridFixFailedMessage MESG records) via Debug.MessageBox (no .esp). Selection mirrors the TS
	; "stat.checked && !stat.broken" check (here !stat.corrupted, after the broken->corrupted struct fix).
	PowerGridStatistics stat = CheckAndFixPowerGrid( akWorkshopRef, 0 )
	If stat.checked && !stat.corrupted
		Debug.MessageBox( "<u>POWER GRID FIXED SUCCESSFULLY!</u><br>Power Grid Tools / Scrap Crash Fix from Workshop Framework fixed your settlement's power grid successfully.<br>total number of grids: " + stat.totalGrids + "<br>broken grids: " + stat.numCorruptedGrids + "<br>total number of nodes: " + stat.totalNodes + "<br>invalid nodes: " + stat.deletedNodes + "<br>--- removed this run ---<br>deleted nodes removed: " + deletedNodesRemoved + "<br>corrupted nodes removed: " + corruptedNodesRemoved + "<br>orphaned wires removed: " + orphanedWiresRemoved )
	Else
		Debug.MessageBox( "<u>FIXING POWER GRID FAILED!</u><br>Power Grid Tools / Scrap Crash Fix from Workshop Framework failed to fix your settlement's power grid.<br>total number of grids: " + stat.totalGrids + "<br>broken grids: " + stat.numCorruptedGrids + "<br>total number of nodes: " + stat.totalNodes + "<br>invalid nodes: " + stat.deletedNodes + "<br>--- removed this run ---<br>deleted nodes removed: " + deletedNodesRemoved + "<br>corrupted nodes removed: " + corruptedNodesRemoved + "<br>orphaned wires removed: " + orphanedWiresRemoved )
	EndIf

	return report

EndFunction

; Builds the cached vanilla workshop forms used across the fix. No mod dependency.
WorkshopForms Function GetWorkshopForms() global
	WorkshopForms forms = New WorkshopForms
	forms.WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	forms.WorkshopCanBePowered = Game.GetFormFromFile( 0x0003037E, "Fallout4.esm") as Keyword
	forms.WorkshopPowerConnection = Game.GetFormFromFile( 0x00054BA4, "Fallout4.esm") as Keyword
	forms.WorkshopPowerConnectionAV = Game.GetFormFromFile( 0x000002D0, "Fallout4.esm") as ActorValue
	forms.WorkshopSnapPointRadiusAV = Game.GetFormFromFile( 0x0000033E, "Fallout4.esm") as ActorValue
	forms.WorkshopSnapTransmitsPowerAV = Game.GetFormFromFile( 0x00000354, "Fallout4.esm") as ActorValue
	forms.wireBase = Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
	return forms
EndFunction

; Standalone highlight shaders sourced from vanilla Fallout4.esm EffectShaders (NO .esp dependency).
; The recommended path uses Red (phase 2 - corrupted nodes) and Yellow (phase 3 - orphaned wires).
; The other 4 stay None (only the dropped phases 4-6 used them); _Highlight* is None-tolerant.
HighlightShaders Function GetHighlightShaders() global
	HighlightShaders shaders = New HighlightShaders
	shaders.Red    = Game.GetFormFromFile( 0x0022517C, "Fallout4.esm" ) as EffectShader	; DetectLifeFXS (red glow)
	shaders.Yellow = Game.GetFormFromFile( 0x0006F125, "Fallout4.esm" ) as EffectShader	; RadDamageFXS (yellow glow)
	return shaders
EndFunction

; Safe shader-apply helper. None-tolerant on both args (no shader source -> no-op). EffectShader.Play is
; non-blocking, so this is safe inline in hot loops. afDuration in seconds (3.0 = ~3s then auto-stops).
Function _Highlight( ObjectReference akRef, EffectShader akShader, Float afDuration = 3.0 ) global
	; Is3DLoaded() gate: a ref not in a loaded cell (e.g. a corrupted/recycled node pointing outside the
	; settlement) errors on EffectShader.Play "is not in a loaded cell and cannot have an effect shader
	; played on it." Skip those - you can't see them anyway.
	If akRef != None && akShader != None && akRef.Is3DLoaded()
		akShader.Play( akRef, afDuration )
	EndIf
EndFunction

; FormID-array variant: lookup each FormID via Game.GetForm() and apply the shader. None-tolerant.
Function _HighlightFormIDs( Int[] aiFormIDs, EffectShader akShader, Float afDuration = 3.0 ) global
	If aiFormIDs == None || akShader == None
		return
	EndIf
	Int i = 0
	While i < aiFormIDs.Length
		ObjectReference ref = Game.GetForm( aiFormIDs[i] ) as ObjectReference
		; Is3DLoaded() gate: corrupted nodes are recycled FormIDs pointing to objects outside the settlement
		; (unloaded cell). EffectShader.Play on them errors; skip them.
		If ref != None && ref.Is3DLoaded()
			akShader.Play( ref, afDuration )
		EndIf
		i += 1
	EndWhile
EndFunction

; HUDFramework availability. Round-1 standalone: notification-only -> returns False, so the ShowProgress*
; helpers fall through to the Debug.Notification heartbeat path. Outcome matches TS running with no
; HUDFramework. (Future: detect HUDFramework directly, with no .esp coupling.)
Bool Function IsHUDFrameworkAvailable() global
	return False
EndFunction

; Phase-boundary progress indicator. No HUDFramework: shows asNotifText immediately (visible ~2s).
; Returns the timestamp to seed the following ShowProgressTick() calls.
Float Function ShowProgressPhase( Bool abProgressBarAvailable, String asNotifText ) global
	If !abProgressBarAvailable
		Debug.Notification( asNotifText )
	EndIf
	return Utility.GetCurrentRealTime()
EndFunction

; In-loop heartbeat. No HUDFramework: cooldown-throttled Debug.Notification carrying within-phase percent
; + count (information-equivalent to the HUDFramework widget). Returns the new timestamp when shown.
Float Function ShowProgressTick( Bool abProgressBarAvailable, Int aiCurrent, Int aiTotal, String asNotifText, Float afLastShown, Float afCooldownSec = 8.0 ) global
	If abProgressBarAvailable
		return afLastShown
	EndIf
	Float fNow = Utility.GetCurrentRealTime()
	If fNow - afLastShown >= afCooldownSec
		Int pct = 0
		If aiTotal > 0
			pct = ( aiCurrent * 100 ) / aiTotal
		EndIf
		Debug.Notification( asNotifText + " " + pct + "% (" + aiCurrent + "/" + aiTotal + ")" )
		return fNow
	EndIf
	return afLastShown
EndFunction

; Completely deletes all power grids of a settlement. Returns true on success.
; Recommended to use for settlements that are to be scrapped entirely.
; - akWorkshopRef	: the settlement's workshop workbench reference
Bool Function ResetPowerGrid( ObjectReference akWorkshopRef ) global native

; Checks and optionally fixes errors of settlement power grids. Takes an array of power grid indices as a filter parameter.
; Returns statistics data in PowerGridStatistics struct. Logs results.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - aiFixErrors		: 0, 1 or 2
; 		aiFixErrors = 0 - check settlement for power grid errors, but don't fix anything
; 		aiFixErrors = 1 - check settlement for power grid errors, and fix errors by removing corrupted power grids entirely (not recommended legacy feature)
; 		aiFixErrors = 2 - check settlement for power grid errors, and fix errors by cleaning corrupted power grids by removing deleted power nodes only (recommended)
; - aiGridFilter	: an array of power grid indices as a filter parameter
PowerGridStatistics Function CheckAndFixPowerGridWithFilter( ObjectReference akWorkshopRef, Int aiFixErrors, Int[] aiGridFilter ) global native

; Checks and optionally fixes errors of settlement power grids. Returns statistics data in PowerGridStatistics struct. Logs results.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - aiFixErrors		: 0, 1 or 2
; 		aiFixErrors = 0 - check settlement for power grid errors, but don't fix anything
; 		aiFixErrors = 1 - check settlement for power grid errors, and fix errors by removing corrupted power grids entirely (not recommended legacy feature)
; 		aiFixErrors = 2 - check settlement for power grid errors, and fix errors by cleaning corrupted power grids by removing deleted power nodes only (recommended)
PowerGridStatistics Function CheckAndFixPowerGrid( ObjectReference akWorkshopRef, Int aiFixErrors ) global

	Int[] emptyArray = New Int[0]
	return CheckAndFixPowerGridWithFilter( akWorkshopRef, aiFixErrors, emptyArray )

EndFunction

; Checks errors of settlement power grids. Takes an array of power grid indices as a filter parameter.
; Returns true if the scan was successful. Logs results.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - aiGridFilter	: an array of power grid indices as a filter parameter
Bool Function ScanPowerGridWithFilter( ObjectReference akWorkshopRef, Int[] aiGridFilter ) global native

; Checks errors of settlement power grids. Returns true if the scan was successful. Logs results.
; - akWorkshopRef	: the settlement's workshop workbench reference
Bool Function ScanPowerGrid( ObjectReference akWorkshopRef ) global

	Int[] emptyArray = New Int[0]
	return ScanPowerGridWithFilter( akWorkshopRef, emptyArray )

EndFunction

; Returns the number of power grids in a settlement.
; - akWorkshopRef	: the settlement's workshop workbench reference
Int Function GetPowerGridCount( ObjectReference akWorkshopRef ) global native

; Returns the array of indices of good power grids in a settlement.
; - akWorkshopRef	: the settlement's workshop workbench reference
Int[] Function GetGoodPowerGridIndices( ObjectReference akWorkshopRef ) global native

; Returns the array of indices of corrupted power grids in a settlement.
; - akWorkshopRef	: the settlement's workshop workbench reference
Int[] Function GetCorruptedPowerGridIndices( ObjectReference akWorkshopRef ) global native

; Returns the array of FormIDs of all deleted power nodes.
; - akWorkshopRef	: the settlement's workshop workbench reference
Int[] Function GetDeletedNodeFormIDs( ObjectReference akWorkshopRef ) global native

; Returns the array of FormIDs of all existing power nodes.
; - akWorkshopRef	: the settlement's workshop workbench reference
Int[] Function GetExistingNodeFormIDs( ObjectReference akWorkshopRef ) global native

; Removes power nodes from all power grids by an array of FormIDs. Returns FormIDs successfully removed from any grid.
; Note that the reason it takes FormIDs instead of an array of ObjectReferences is because most of the time these objects don't exist in the game anymore.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - aiFormIDs		: array of power node FormIDs
Int[] Function RemoveNodesFromPowerGrid( ObjectReference akWorkshopRef, Int[] aiFormIDs ) global native

; Removes the power node of an existing settlement object from all power grids. Returns true if it was successfully removed from any grid.
; This is mostly for testing purposes.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - akRefToRemove	: the existing settlement object to remove
Bool Function RemoveExistingObjectFromPowerGrid( ObjectReference akWorkshopRef, ObjectReference akRefToRemove ) global
	
	Int[] formIDs = New Int[1]
	formIDs[0] = akRefToRemove.GetFormID()
	return RemoveNodesFromPowerGrid( akWorkshopRef, formIDs ).Length > 0
	
EndFunction

; Gets the index of the power grid of an existing settlement object. Returns a negative number on errors.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - akObjectRef		: the existing settlement object
Int Function GetPowerGridIndexForObject( ObjectReference akWorkshopRef, ObjectReference akObjectRef ) global native

; Creates a new power grid from existing settlement objects. Returns the index of the newly created grid.
; - akWorkshopRef			: the settlement's workshop workbench reference
; - akObjectRefs			: the existing settlement objects
; - abRemoveFromOtherGrids	: should these objects be removed from other grids
Int Function CreatePowerGridFromRefs( ObjectReference akWorkshopRef, ObjectReference[] akObjectRefs, Bool abRemoveFromOtherGrids ) global native

; Adds existing settlement objects as new nodes to an existing power grid. Returns true on success.
; - akWorkshopRef			: the settlement's workshop workbench reference
; - aiGridIndex				: the index of an existing power grid
; - akObjectRefs			: the existing settlement objects
; - abRemoveFromOtherGrids	: should these objects be removed from other grids
Bool Function AddRefsToPowerGrid( ObjectReference akWorkshopRef, Int aiGridIndex, ObjectReference[] akObjectRefs, Bool abRemoveFromOtherGrids ) global native

; Deletes a settlement object and also removes its node from any power grid if it was part of one.
; Returns true if the object existed and was successfully removed from any grid.
; - akRefToRemove	: the existing settlement object to delete and remove
Bool Function SafeDelete( ObjectReference akRefToRemove ) global

	Bool res = False
	If akRefToRemove
		Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
		ObjectReference workshopRef = akRefToRemove.GetLinkedRef( WorkshopItemKeyword )
		Int[] tmpNodeFormID = New Int[1]
		If workshopRef
			tmpNodeFormID[0] = akRefToRemove.GetFormID()
		EndIf
		akRefToRemove.Disable()
		akRefToRemove.Delete()
		If workshopRef
			res = RemoveNodesFromPowerGrid( workshopRef, tmpNodeFormID )
		EndIf
	EndIf
	
	return res
	
EndFunction

; Scraps a settlement object adding any components to the Player taking perks, componment rarity and scrap scalars into account.
; Also removes the node of the object from any power grid if it was part of one.
; Optionally removes residual orphaned wires. Optionally calls OnWorkshopObjectDestroyed events.
; - akRefToScrap			: the existing settlement object to scrap
; - abRemoveOrphanedWires	: should residual orphaned wires be removed
; - abCallDestroyedEvent	: should OnWorkshopObjectDestroyed event be called
; - abPlaySound				: should scrap sound be played
Function SafeScrap( ObjectReference akRefToScrap, Bool abRemoveOrphanedWires = True, Bool abCallDestroyedEvent = True, Bool abPlaySound = True ) global

	Int i
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	Sound FXScrap = Game.GetFormFromFile( 0x001926A1, "Fallout4.esm" ) as Sound
	Int instanceID
	ObjectReference workshopRef = akRefToScrap.GetLinkedRef( WorkshopItemKeyword )
	Int[] tmpNodeFormID = New Int[1]
	Actor PlayerREF = Game.GetPlayer()
	If workshopRef
		tmpNodeFormID[0] = akRefToScrap.GetFormID()
	EndIf
	
	String akRefToScrapFormInfo = GetFormInfo( akRefToScrap )
	
	ObjectReference[] connected = akRefToScrap.GetConnectedObjects()
	
	If akRefToScrap.GetBaseObject() is MiscObject
		MiscObject:MiscComponent[] miscComponents = (akRefToScrap.GetBaseObject() as MiscObject).GetMiscComponents()
		
		DebugLog( "SafeScrap", akRefToScrapFormInfo + " components:" )
	
		If miscComponents.Length
			If abPlaySound
				instanceID = FXScrap.Play( akRefToScrap )
				Sound.SetInstanceVolume( instanceID, 1.0 )
			EndIf
			i = 0
			While i < miscComponents.Length
				Form comp = miscComponents[i].Object as Form
				Int baseCount = miscComponents[i].Count
				
				Int pay = ComputePayout( comp, baseCount, False, PlayerREF )
				If pay > 0
					PlayerREF.AddItem( miscComponents[i].Object.GetScrapItem(), pay, False )
				EndIf

				String componentFormInfo = GetFormInfo( comp )
				DebugLog( "SafeScrap", "	" + baseCount + " x " + componentFormInfo )
				DebugLog( "SafeScrap", "		Scrapper rank: " + GetScrapperRank( PlayerREF ) )
				String rarity = "Common"
				If IsZeroYield( comp )
					rarity = "Zero yield"
				ElseIf IsRare( comp )
					rarity = "Rare"
				ElseIf IsUncommon( comp )
					rarity = "Uncommon"
				EndIf
				DebugLog( "SafeScrap", "		rarity: " + rarity )
				DebugLog( "SafeScrap", "		scalar: " + miscComponents[i].Object.GetScrapScalar().GetValue() )
				DebugLog( "SafeScrap", "		type: Junk" )
				DebugLog( "SafeScrap", "		player gets " + pay + " x " + componentFormInfo )
				
				i += 1
			EndWhile
		Else
			String refBaseObjectFormInfo = GetFormInfo( akRefToScrap.GetBaseObject() )
			DebugLog( "SafeScrap", "	no misc object components found, " + refBaseObjectFormInfo + " added to the Player without breaking it down to components" )
			PlayerREF.AddItem( akRefToScrap, 1, False )
		EndIf
	Else
		RecipeComponent[] recipeComponents = GetRefRecipeComponents( akRefToScrap )
		
		DebugLog( "SafeScrap", akRefToScrapFormInfo + " components:" )
	
		If recipeComponents.Length
			If abPlaySound
				instanceID = FXScrap.Play( akRefToScrap )
				Sound.SetInstanceVolume( instanceID, 1.0 )
			EndIf
			i = 0
			While i < recipeComponents.Length
				Float scalar = 0.0
				Form comp = recipeComponents[i].Object as Form
				Int recipeCount = recipeComponents[i].Count
				Int pay = 0
				If comp
					If comp is MiscObject
						scalar = 1.0
						pay = recipeCount
					ElseIf comp is Component
						scalar = (comp as Component).GetScrapScalar().GetValue()
						pay = ComputePayout( comp, recipeCount, True, PlayerREF )
					EndIf
				EndIf

				If pay > 0
					If comp is MiscObject
						PlayerREF.AddItem( comp, pay, False )
					ElseIf comp is Component
						PlayerREF.AddItem( (comp as Component).GetScrapItem(), pay, False )
					EndIf
				EndIf
				
				String componentFormInfo = GetFormInfo( comp )
				DebugLog( "SafeScrap", "	" + recipeCount + " x " + componentFormInfo )
				DebugLog( "SafeScrap", "		Scrapper rank: " + GetScrapperRank( PlayerREF ) )
				String rarity = "Common"
				If IsZeroYield( comp )
					rarity = "Zero yield"
				ElseIf IsRare( comp )
					rarity = "Rare"
				ElseIf IsUncommon( comp )
					rarity = "Uncommon"
				EndIf
				DebugLog( "SafeScrap", "		rarity: " + rarity )
				DebugLog( "SafeScrap", "		scalar: " + scalar )
				DebugLog( "SafeScrap", "		type: Recipe based" )
				DebugLog( "SafeScrap", "		player gets " + pay + " x " + componentFormInfo )
				i += 1
			EndWhile
		Else
			String refBaseObjectFormInfo = GetFormInfo( akRefToScrap.GetBaseObject() )
			If !akRefToScrap.GetBaseObject() is Activator && !akRefToScrap.GetBaseObject() is Container && !akRefToScrap.GetBaseObject() is Door && !akRefToScrap.GetBaseObject() is Explosion && !akRefToScrap.GetBaseObject() is Hazard && !akRefToScrap.GetBaseObject() is IdleMarker && !akRefToScrap.GetBaseObject() is Light && !akRefToScrap.GetBaseObject() is Static && !akRefToScrap.GetBaseObject() is Terminal && akRefToScrap.GetBaseObject() != Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
				DebugLog( "SafeScrap", "	no recipe found, " + refBaseObjectFormInfo + " added to the Player without breaking it down to components" )
				PlayerREF.AddItem( akRefToScrap, 1, False )
			Else
				DebugLog( "SafeScrap", "	no recipe found, " + refBaseObjectFormInfo + " cannot be added to the Player without breaking it down to components, deleted without storing anything" )
			EndIf
		EndIf
		
		If akRefToScrap.GetBaseObject() is Armor || akRefToScrap.GetBaseObject() is Weapon
			ObjectMod[] omods = akRefToScrap.GetAllMods()
			
			Int k = 0
			While k < omods.Length
				RecipeComponent[] omodComponents = GetRecipeComponents( GetRecipe( omods[k] ) )

				String omodToRemoveFormInfo = GetFormInfo( omods[k] )
				DebugLog( "SafeScrap", "	" + omodToRemoveFormInfo + " components:" )
			
				If omodComponents.Length
					If abPlaySound
						instanceID = FXScrap.Play( akRefToScrap )
						Sound.SetInstanceVolume( instanceID, 1.0 )
					EndIf
					i = 0
					While i < omodComponents.Length
						Float scalar = 0.0
						Form comp = omodComponents[i].Object as Form
						Int recipeCount = omodComponents[i].Count
						Int pay = 0
						If comp
							If comp is MiscObject
								scalar = 1.0
								pay = recipeCount
							ElseIf comp is Component
								scalar = (comp as Component).GetScrapScalar().GetValue()
								pay = ComputePayout( comp, recipeCount, True, PlayerREF )
							EndIf
						EndIf

						If pay > 0
							If comp is MiscObject
								PlayerREF.AddItem( comp, pay, False )
							ElseIf comp is Component
								PlayerREF.AddItem( (comp as Component).GetScrapItem(), pay, False )
							EndIf
						EndIf
						
						String componentFormInfo = GetFormInfo( comp )
						DebugLog( "SafeScrap", "		" + recipeCount + " x " + componentFormInfo )
						DebugLog( "SafeScrap", "			Scrapper rank: " + GetScrapperRank( PlayerREF ) )
						String rarity = "Common"
						If IsZeroYield( comp )
							rarity = "Zero yield"
						ElseIf IsRare( comp )
							rarity = "Rare"
						ElseIf IsUncommon( comp )
							rarity = "Uncommon"
						EndIf
						DebugLog( "SafeScrap", "			rarity: " + rarity )
						DebugLog( "SafeScrap", "			scalar: " + scalar )
						DebugLog( "SafeScrap", "			type: Recipe based" )
						DebugLog( "SafeScrap", "			player gets " + pay + " x " + componentFormInfo )
						i += 1
					EndWhile
				Else
					String omodLooseModFormInfo = GetFormInfo( omods[k].GetLooseMod() )
					DebugLog( "SafeScrap", "		no recipe found, " + omodLooseModFormInfo + " added to the Player without breaking it down to components" )
					PlayerREF.AddItem( omods[k].GetLooseMod(), 1, False )
				EndIf
				
				k += 1
			EndWhile
		EndIf
		
	EndIf
	
	If akRefToScrap
		If workshopRef && abCallDestroyedEvent
			akRefToScrap.OnWorkshopObjectDestroyed( workshopRef )
			workshopRef.OnWorkshopObjectDestroyed( akRefToScrap )
			Var[] params1 = New Var[1]
			params1[0] = workshopRef
			CallFunctionOnAllAttachedScripts( akRefToScrap, "OnWorkshopObjectDestroyed", params1 )
		EndIf
		akRefToScrap.Disable()
		akRefToScrap.Delete()
	EndIf
	If workshopRef
		RemoveNodesFromPowerGrid( workshopRef, tmpNodeFormID )
	EndIf
	
	If abRemoveOrphanedWires
		i = 0
		While i < connected.Length
			If connected[i].GetBaseObject() == Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
				SafeScrap( connected[i], False, abCallDestroyedEvent, False )
			EndIf
			i += 1
		EndWhile
	EndIf
	
EndFunction

; Convenience function to entirely scrap a settlement adding any components to the Player taking perks,
; componment rarity and scrap scalars into account. Also removes the nodes of the objects from any power grids,
; removes any residual orphaned wires and optionally calls proper OnWorkshopObjectDestroyed events on each object.
; Very slow though.
; - akWorkshopRef	: the settlement's workshop workbench reference
; - abCallDestroyedEvent	: should OnWorkshopObjectDestroyed event be called
Function SafeScrapAll( ObjectReference akWorkshopRef, Bool abCallDestroyedEvents = True ) global

	Int i
	ActorBase ActorForm
	Class ActorClass
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	Class TurretTripodClass = Game.GetFormFromFile( 0x00123E22, "Fallout4.esm" ) as Class
	Class TurretBubbleClass = Game.GetFormFromFile( 0x00123E18, "Fallout4.esm" ) as Class
	Keyword ArmorRackKWD = Game.GetFormFromFile( 0x0005240A, "Fallout4.esm" ) as Keyword
	Actor[] workshopActors = akWorkshopRef.GetActorsLinkedToMe( WorkshopItemKeyword )
	ObjectReference[] workshopObjects = akWorkshopRef.GetRefsLinkedToMe( WorkshopItemKeyword )
	
	If abCallDestroyedEvents
		BuildScriptInfoForActorArray( workshopActors, False )
		BuildScriptInfoForRefArray( workshopObjects, False )
	EndIf
	
	i = 0
	While i < workshopActors.Length
		If workshopActors[i]
			ActorForm = workshopActors[i].GetActorBase()
			ActorClass = ActorForm.GetClass()
			If ActorClass == TurretTripodClass || ActorClass == TurretBubbleClass || ActorForm.HasKeyword( ArmorRackKWD )
				SafeScrap( workshopActors[i], True, abCallDestroyedEvents )
			EndIf
		EndIf
		i += 1
	EndWhile
	
	i = 0
	While i < workshopObjects.Length
		If workshopObjects[i] && !(workshopObjects[i] is Actor)
			SafeScrap( workshopObjects[i], True, abCallDestroyedEvents )
		EndIf
		i += 1
	EndWhile

EndFunction

; Detects if there's no one-to-one mapping between a connection traverse group and a power grid, either because not all
; objects in a traverse group belong to the same power grid (Type-1), or because not all nodes in a power grid reference objects
; from the same traverse group (Type-2). Optionally fixes Type-1 errors by removing objects from the wrong power grids, and
; placing them into the ones that they physically belong to. Optionally fixes Type-2 errors by either reconnecting residual power grid
; fragments by physical pylons and wire connections, or creating entirely new power grids from these fragments.
; Returns array of message reports.
; - akWorkshopRef					: the settlement's workshop workbench reference
; - akWorkshopObjects				: all workshop-placed objects in this settlement
; - abVerboseToLog					: if true, emits Debug.Trace lines as well as returning message reports
; - aiMaxTraverseCount				: safety cap passed through to TraversePowerGrid
; - abFixMixedGridIndicesInGroups	: should objects from the wrong power grids be removed, and placed into the ones that they physically belong to
; - abReconnectResidualGridFragments: should residual power grid fragments be reconnected by physical pylons and wire connections
; - abCreateNewGrids				: should new power grids be created from residual power grid fragments
String[] Function FixConnectionIntegrityErrors( ObjectReference akWorkshopRef, ObjectReference[] akWorkshopObjects, Bool abVerboseToLog = True, Int aiMaxTraverseCount = 8192, Bool abFixMixedGridIndicesInGroups = False, Bool abReconnectResidualGridFragments = False, Bool abCreateNewGrids = False ) global
	String[] messages = New String[0]

	If akWorkshopRef == None || akWorkshopObjects == None
		messages = AddString( messages, "[Error] Missing akWorkshopRef, akWorkshopObjects." )
		return messages
	EndIf

	Form wireBase = Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")

	; track coverage of non-wire members we've already grouped
	ObjectReference[] globalSeen = New ObjectReference[0]
	
	ObjectReference[] firstSeedForGroup = New ObjectReference[0]
	ObjectReference[] finalPairsToConnect = New ObjectReference[0]
	Int[] handledGroupIds = New Int[0]

	; Type-2 map: internalIndex -> first groupId seen
	Int[] indicesSeen = New Int[0]
	String indicesSeenStr = ""
	Int[] firstGroupForIndex = New Int[0]
	String firstGroupForIndexStr = ""
	Int[] indexForGroup = New Int[0]
	String indexForGroupStr = ""

	Int groupId = 0
	Int i = 0
	While i < akWorkshopObjects.Length
		ObjectReference seed = akWorkshopObjects[i]

		; guard chain instead of continue
		Bool ok = True
		If seed == None
			ok = False
		EndIf
		If ok
			ObjectReference[] neigh = seed.GetConnectedObjects()
			If neigh == None || neigh.Length == 0
				ok = False
			EndIf
		EndIf
		If ok
			If _IsWire( seed, wireBase )
				ok = False ; don't seed on wires
			EndIf
		EndIf
		If ok
			If _HasRef( globalSeen, seed )
				ok = False ; already covered by a previous group
			EndIf
		EndIf

		If ok
			; build the connectivity group (non-wires only)
			ObjectReference[] group_ = TraversePowerGrid( akWorkshopRef, seed, False, aiMaxTraverseCount )
			If group_ != None && group_.Length > 0

				; check if this whole group is already accounted for
				Bool allSeen = True
				Int j = 0
				While j < group_.Length
					If !_HasRef( globalSeen, group_[j] )
						allSeen = False
					EndIf
					j += 1
				EndWhile

				If !allSeen
					; mark group covered
					firstSeedForGroup = AddObjectReference( firstSeedForGroup, seed )
					j = 0
					While j < group_.Length
						If !_HasRef( globalSeen, group_[j] )
							globalSeen = AddObjectReference( globalSeen, group_[j] )
						EndIf
						j += 1
					EndWhile

					; collect unique internal indices for this group
					Int[] uniqueIdx = New Int[0]
					String uniqueIdxStr = ""
					Int[] nonUniqueIdx = New Int[0]
					String nonUniqueIdxStr = ""
					j = 0
					While j < group_.Length
						Int idx = GetPowerGridIndexForObject( akWorkshopRef, group_[j] )
						If idx >= 0
							If _AddUniqueInt( uniqueIdx, idx )
								uniqueIdxStr += idx + " "
							EndIf
							nonUniqueIdx = AddInt( nonUniqueIdx, idx )
							nonUniqueIdxStr += idx + " "
						EndIf
						j += 1
					EndWhile
					
					Int mostFrequentIndex = MostFrequentInt( nonUniqueIdx, -1 )
					indexForGroup = AddInt( indexForGroup, mostFrequentIndex )

					If abVerboseToLog
						DebugLog( "FixConnectionIntegrityErrors", "[PowerScan] Group " + groupId + " size=" + group_.Length + " idx=" + uniqueIdxStr )
					EndIf

					; Type-1: mixed indices inside one traverse group
					If uniqueIdx.Length > 1
						messages = AddString( messages, "[Type1] Group #" + groupId + " has mixed InternalIndices: " + uniqueIdxStr )
						If abVerboseToLog
							DebugLog( "FixConnectionIntegrityErrors", "[PowerScan] Type1: group " + groupId + " mixed indices " + uniqueIdxStr )
						EndIf
						;DebugLog( "FixConnectionIntegrityErrors", "group #" + groupId + " refs and grid indices:" )
						;j = 0
						;While j < group_.Length
						;	Int idx = GetPowerGridIndexForObject( akWorkshopRef, group_[j] )
						;	DebugLog( "FixConnectionIntegrityErrors", "	" + GetFormInfo( group_[j] ) + " -> grid index: " + idx )
						;	j += 1
						;EndWhile
						If abFixMixedGridIndicesInGroups
							j = 0
							While j < group_.Length
								Int idx = GetPowerGridIndexForObject( akWorkshopRef, group_[j] )
								If idx != mostFrequentIndex
									ObjectReference[] misplacedRefs = New ObjectReference[1]
									misplacedRefs[0] = group_[j]
									If AddRefsToPowerGrid( akWorkshopRef, mostFrequentIndex, misplacedRefs, True )
										messages = AddString( messages, GetFormInfo( group_[j] ) + " in Group #" + groupId + " has been successfully moved from grid #" + idx + " to grid #" + mostFrequentIndex )
										If abVerboseToLog
											DebugLog( "FixConnectionIntegrityErrors", GetFormInfo( group_[j] ) + " in Group #" + groupId + " moved: grid #" + idx + " -> grid #" + mostFrequentIndex )
										EndIf
									Else
										messages = AddString( messages, "failed to move " + GetFormInfo( group_[j] ) + " in Group #" + groupId + " from grid #" + idx + " to grid #" + mostFrequentIndex )
										If abVerboseToLog
											DebugLog( "FixConnectionIntegrityErrors", "failed to move " + GetFormInfo( group_[j] ) + " in Group #" + groupId + ": grid #" + idx + " -> grid #" + mostFrequentIndex )
										EndIf
									EndIf
								EndIf
								j += 1
							EndWhile
						EndIf
					EndIf

					; Type-2: same internal index appears in >1 distinct traverse group
					indexForGroupStr += mostFrequentIndex + " "
					Int pos = _IndexOfInt( indicesSeen, mostFrequentIndex )
					If pos == -1
						indicesSeen = AddInt( indicesSeen, mostFrequentIndex )
						indicesSeenStr += mostFrequentIndex + " "
						firstGroupForIndex = AddInt( firstGroupForIndex, groupId )
						firstGroupForIndexStr += groupId + " "
						String groupWithNewIndexPowerGridNodes = ""
						j = 0
						While j < group_.Length
							If j > 0
								groupWithNewIndexPowerGridNodes += ", "
							EndIf
							String groupWithNewIndexPowerGridNodeFormInfo = GetFormInfo( group_[j] )
							groupWithNewIndexPowerGridNodes += groupWithNewIndexPowerGridNodeFormInfo + "[" + GetPowerGridIndexForObject( akWorkshopRef, group_[j] ) + "]"
							j += 1
						EndWhile
						;Debug.MessageBox( "group#" + groupId + "WithNewIndex(" + mostFrequentIndex + ")PowerGridNodes[gridIndex]: " + groupWithNewIndexPowerGridNodes )
					Else
						messages = AddString( messages, "[Type2] InternalIndex " + mostFrequentIndex + " occurs in multiple Traverse groups (first seen in #" + firstGroupForIndex[pos] + ", also in #" + groupId + ")" )
						If abVerboseToLog
							DebugLog( "FixConnectionIntegrityErrors", "[PowerScan] Type2: index " + mostFrequentIndex + " in groups " + firstGroupForIndex[pos] + " and " + groupId )
						EndIf
						String groupWithSameIndexPowerGridNodes = ""
						j = 0
						While j < group_.Length
							If j > 0
								groupWithSameIndexPowerGridNodes += ", "
							EndIf
							String groupWithSameIndexPowerGridNodeFormInfo = GetFormInfo( group_[j] )
							groupWithSameIndexPowerGridNodes += groupWithSameIndexPowerGridNodeFormInfo + "[" + GetPowerGridIndexForObject( akWorkshopRef, group_[j] ) + "]"
							j += 1
						EndWhile
						;Debug.MessageBox( "group#" + groupId + "WithSameIndex(" + mostFrequentIndex + ")PowerGridNodes[gridIndex]: " + groupWithSameIndexPowerGridNodes )
					EndIf

					groupId += 1
				EndIf
			EndIf
		EndIf

		i += 1
	EndWhile

	If messages.Length == 0
		messages = AddString( messages, "[OK] No Type1/Type2 power grid index inconsistencies detected. (groups built: " + groupId + ")" )
	EndIf
	
	If abCreateNewGrids
		i = 0
		While i < groupId
			Int idx1
			ObjectReference[] group1
			idx1 = indexForGroup[i]
			Int j = i + 1
			While j < groupId
				Int idx2 = indexForGroup[j]
				If idx2 == idx1
					;DebugLog( "FixConnectionIntegrityErrors", "multiple groups (" + i + " and " + j + ") exist with grid index " + idx1 )
					;group1 = TraversePowerGrid( akWorkshopRef, firstSeedForGroup[i], False, aiMaxTraverseCount )
					;DebugLog( "FixConnectionIntegrityErrors", "group #" + i + " refs:" )
					;Int k = 0
					;While k < group1.Length
					;	DebugLog( "FixConnectionIntegrityErrors", "	" + GetFormInfo( group1[k] ) )
					;	k += 1
					;EndWhile
					ObjectReference[] group2 = TraversePowerGrid( akWorkshopRef, firstSeedForGroup[j], False, aiMaxTraverseCount )
					;DebugLog( "FixConnectionIntegrityErrors", "group #" + j + " refs:" )
					;k = 0
					;While k < group2.Length
					;	DebugLog( "FixConnectionIntegrityErrors", "	" + GetFormInfo( group2[k] ) )
					;	k += 1
					;EndWhile
					If group2.Length > 1
						indexForGroup[j] = CreatePowerGridFromRefs( akWorkshopRef, group2, True )
						DebugLog( "FixConnectionIntegrityErrors", "group #" + i + " and group #" + j + " had the same index: " + idx1 + " -> group #" + j + " got new grid with index " + indexForGroup[j] )
					ElseIf group2.Length == 1
						If RemoveExistingObjectFromPowerGrid( akWorkshopRef, group2[0] )
							DebugLog( "FixConnectionIntegrityErrors", "group #" + j + " is only a single object -> removed from grid with index: " + idx1 )
						Else
							DebugLog( "FixConnectionIntegrityErrors", "group #" + j + " is only a single object -> FAILED to remove from grid with index: " + idx1 )
						EndIf
					Else
						DebugLog( "FixConnectionIntegrityErrors", "group #" + j + " is EMPTY" )
					EndIf
				EndIf
				j += 1
			EndWhile
			i += 1
		EndWhile
	EndIf
	
	If abReconnectResidualGridFragments
		Int[] groupIds = New Int[groupId]
		i = 0
		While i < groupId
			groupIds[i] = i
			i += 1
		EndWhile
		Int[] plan = ComputeWirePlan( akWorkshopRef, groupIds, indexForGroup, firstSeedForGroup, aiMaxTraverseCount, 0.0 ) ; set >0 to cap max wire length

		int k = 0
		While k < plan.Length
				ObjectReference[] group1 = TraversePowerGrid( akWorkshopRef, firstSeedForGroup[plan[k]], False, aiMaxTraverseCount )
				ObjectReference[] group2 = TraversePowerGrid( akWorkshopRef, firstSeedForGroup[plan[k + 1]], False, aiMaxTraverseCount )
				ObjectReference[] pair = ClosestPair3D( group1, group2, False, aiMaxTraverseCount)
				ConnectRefsWithPylons( pair, akWorkshopRef, plan[k], plan[k + 1], 1100.0 )
			k += 2
		EndWhile
	EndIf

	return messages
EndFunction

; Removes residual wire connections where either end of the spline is not connected to an object. Returns string with comma separated FormIDs of former wires.
; - akWorkshopRef	: the settlement's workshop workbench reference
; Core worker: removes orphaned wires (a wire with fewer than 2 valid settlement endpoints) and returns
; the array of removed wire FormIDs. Count = .Length; FormID hex list = join via GetFormIDHex. The String
; wrapper RemoveOrphanedWires() below preserves the original FormID-list-string contract for callers that
; want the list; callers that want the count call this core directly and use .Length.
Int[] Function _RemoveOrphanedWiresCore( ObjectReference akWorkshopRef, ObjectReference[] akWorkshopObjects = None, Bool abShowProgress = False, String asHeartbeatText = "fixing workshop 3: orphaned wires" ) global

	WorkshopForms forms = GetWorkshopForms()
	HighlightShaders shaders = GetHighlightShaders()
	Keyword WorkshopItemKeyword = forms.WorkshopItemKeyword
	Form wireBase = forms.wireBase
	If akWorkshopObjects == None
		akWorkshopObjects = akWorkshopRef.GetRefsLinkedToMe( WorkshopItemKeyword )
	EndIf

	Bool ProgressBarAvailable = abShowProgress && IsHUDFrameworkAvailable()
	Float fTime = Utility.GetCurrentRealTime()

	; Per-wire: identify an orphan, highlight it (no-op without a shader source), then Disable+Delete +
	; RemoveNodesFromPowerGrid. The grid-record cleanup is CRITICAL: without it each deleted wire leaves a
	; zombie FormID in the power-grid records.
	Int[] removedWireFormIDs = New Int[0]
	Int i = 0
	While i < akWorkshopObjects.Length
		; Guard against deleted/disabled refs from phase 1/2 cleanup: GetBaseObject on a deleted ref can CTD.
		If akWorkshopObjects[i] != None && !akWorkshopObjects[i].IsDeleted() && !akWorkshopObjects[i].IsDisabled() && akWorkshopObjects[i].GetBaseObject() == wireBase
			ObjectReference[] ConnectedObjects = akWorkshopObjects[i].GetConnectedObjects()
			Int connectedObjectsLength = 0
			Int ios = 0
			While ios < ConnectedObjects.Length
				If ConnectedObjects[ios] != None && !ConnectedObjects[ios].IsDeleted() && !ConnectedObjects[ios].IsDisabled() && ConnectedObjects[ios].GetLinkedRef( WorkshopItemKeyword ) == akWorkshopRef
					connectedObjectsLength += 1
				EndIf
				ios += 1
			EndWhile
			If connectedObjectsLength < 2
				ObjectReference orphanWire = akWorkshopObjects[i]
				Int wireFormID = orphanWire.GetFormID()
				Int[] wireFormIDArr = New Int[1]
				wireFormIDArr[0] = wireFormID
				_Highlight( orphanWire, shaders.Yellow )
				If shaders.Yellow != None
					Utility.Wait( 1.0 )
				EndIf
				orphanWire.Disable()
				orphanWire.Delete()
				RemoveNodesFromPowerGrid( akWorkshopRef, wireFormIDArr )
				removedWireFormIDs = AddInt( removedWireFormIDs, wireFormID )
			EndIf
		EndIf
		i += 1
		If abShowProgress
			fTime = ShowProgressTick( ProgressBarAvailable, i, akWorkshopObjects.Length, asHeartbeatText, fTime )
		EndIf
	EndWhile

	return removedWireFormIDs

EndFunction

; Public wrapper (ORIGINAL String contract, unchanged signature/return): returns a comma-separated hex
; FormID list of the removed orphaned wires ("" if none). Delegates the work to _RemoveOrphanedWiresCore.
String Function RemoveOrphanedWires( ObjectReference akWorkshopRef, ObjectReference[] akWorkshopObjects = None, Bool abShowProgress = False, String asHeartbeatText = "fixing workshop 3: orphaned wires" ) global

	Int[] removed = _RemoveOrphanedWiresCore( akWorkshopRef, akWorkshopObjects, abShowProgress, asHeartbeatText )
	String csv = ""
	Int i = 0
	While i < removed.Length
		If i > 0
			csv += ", "
		EndIf
		csv += GetFormIDHex( removed[i] )
		i += 1
	EndWhile
	return csv

EndFunction


Function TestPowerGridFunctions( ObjectReference akWorkshopRef, ObjectReference akRefToRemove ) global

	Int i
	PowerGridStatistics pgs
	
	Int powerGridCount = GetPowerGridCount( akWorkshopRef )
	Int[] goodPowerGridIndices = GetGoodPowerGridIndices( akWorkshopRef )
	String goodPowerGrids = ""
	i = 0
	While i < goodPowerGridIndices.Length
		If i > 0
			goodPowerGrids += ", "
		EndIf
		goodPowerGrids += goodPowerGridIndices[i]
		i += 1
	EndWhile
	Int[] corruptedPowerGridIndices = GetCorruptedPowerGridIndices( akWorkshopRef )
	String corruptedPowerGrids = ""
	i = 0
	While i < corruptedPowerGridIndices.Length
		If i > 0
			corruptedPowerGrids += ", "
		EndIf
		corruptedPowerGrids += corruptedPowerGridIndices[i]
		i += 1
	EndWhile
	Debug.MessageBox( "powerGridCount: " + powerGridCount + "<br>" + "goodPowerGridIndices: " + goodPowerGrids + "<br>" + "corruptedPowerGridIndices: " + corruptedPowerGrids )
	Utility.Wait( 0.5 )
	
	ScanPowerGrid( akWorkshopRef )
	Debug.MessageBox( "power grids scanned" )
	Utility.Wait( 0.5 )
	
	ScanPowerGridWithFilter( akWorkshopRef, goodPowerGridIndices )
	Debug.MessageBox( "good power grids scanned" )
	Utility.Wait( 0.5 )
	
	ScanPowerGridWithFilter( akWorkshopRef, corruptedPowerGridIndices )
	Debug.MessageBox( "corrupted power grids scanned" )
	Utility.Wait( 0.5 )
	
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	ObjectReference[] workshopObjects = akWorkshopRef.GetRefsLinkedToMe( WorkshopItemKeyword )
	
	String[] report = FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192 )
	i = 0
	While i < report.Length
		Debug.MessageBox( report[i] ) ; or dump to a log UI
		i += 1
	EndWhile
	Utility.Wait( 0.5 )
	
	pgs = CheckAndFixPowerGrid( akWorkshopRef, 0 )
	Debug.MessageBox( "power grids checked" + "<br>" + "corrupted: " + pgs.corrupted + "<br>" + "checked: " + pgs.checked + "<br>" + "existingNodes: " + pgs.existingNodes + "<br>" + "deletedNodes: " + pgs.deletedNodes + "<br>" + "numCorruptedGrids: " + pgs.numCorruptedGrids + "<br>" + "totalNodes: " + pgs.totalNodes + "<br>" + "totalGrids: " + pgs.totalGrids )
	Utility.Wait( 0.5 )
	
	pgs = CheckAndFixPowerGridWithFilter( akWorkshopRef, 0, goodPowerGridIndices )
	Debug.MessageBox( "good power grids checked" + "<br>" + "corrupted: " + pgs.corrupted + "<br>" + "checked: " + pgs.checked + "<br>" + "existingNodes: " + pgs.existingNodes + "<br>" + "deletedNodes: " + pgs.deletedNodes + "<br>" + "numCorruptedGrids: " + pgs.numCorruptedGrids + "<br>" + "totalNodes: " + pgs.totalNodes + "<br>" + "totalGrids: " + pgs.totalGrids )
	Utility.Wait( 0.5 )
	
	pgs = CheckAndFixPowerGridWithFilter( akWorkshopRef, 0, CorruptedPowerGridIndices )
	Debug.MessageBox( "corrupted power grids checked" + "<br>" + "corrupted: " + pgs.corrupted + "<br>" + "checked: " + pgs.checked + "<br>" + "existingNodes: " + pgs.existingNodes + "<br>" + "deletedNodes: " + pgs.deletedNodes + "<br>" + "numCorruptedGrids: " + pgs.numCorruptedGrids + "<br>" + "totalNodes: " + pgs.totalNodes + "<br>" + "totalGrids: " + pgs.totalGrids )
	Utility.Wait( 0.5 )
	
	Int[] deletedNodeFormIDs = GetDeletedNodeFormIDs( akWorkshopRef )
	String deletedNodes = ""
	i = 0
	While i < deletedNodeFormIDs.Length
		If i > 0
			deletedNodes += ", "
		EndIf
		deletedNodes += GetFormIDHex( deletedNodeFormIDs[i] )
		i += 1
	EndWhile
	Debug.MessageBox( "deletedNodes: " + deletedNodes )
	Utility.Wait( 0.5 )
	
	Keyword WorkshopCanBePowered = Game.GetFormFromFile( 0x0003037E, "Fallout4.esm") as Keyword
	Keyword WorkshopPowerConnection = Game.GetFormFromFile( 0x00054BA4, "Fallout4.esm") as Keyword
	Int[] existingNodeFormIDs = GetExistingNodeFormIDs( akWorkshopRef )
	Int[] corruptedNodeFormIDs = New Int[0]
	Int[] goodNodeFormIDs = New Int[0]
	ObjectReference lastGoodNode
	String existingNodes = ""
	String corruptedNodes = ""
	String goodNodes = ""
	i = 0
	While i < existingNodeFormIDs.Length
		ObjectReference existingNodeRef = Game.GetForm( existingNodeFormIDs[i] ) as ObjectReference
		String existingNodeFormInfo = GetFormInfo( existingNodeRef )
		If i > 0
			existingNodes += ", "
		EndIf
		existingNodes += existingNodeFormInfo
		If existingNodeRef.GetLinkedRef( WorkshopItemKeyword ) == None || !existingNodeRef.IsWithinBuildableArea( akWorkshopRef )
			If corruptedNodeFormIDs.Length > 0
				corruptedNodes += ", "
			EndIf
			corruptedNodeFormIDs = AddInt( corruptedNodeFormIDs, existingNodeFormIDs[i] )
			corruptedNodes += existingNodeFormInfo
			corruptedNodes += "[0,0]"
			existingNodes += "[0,0]"
		Else
			If existingNodeRef.GetBaseObject().HasKeyword( WorkshopCanBePowered ) || existingNodeRef.GetBaseObject().HasKeyword( WorkshopPowerConnection )
				ObjectReference[] ConnectedObjects
				ObjectReference[] ConnectedWires = existingNodeRef.GetConnectedObjects()
				Int connectedObjectsLength = 0
				Int iws = 0
				While iws < ConnectedWires.Length
					ConnectedObjects = ConnectedWires[iws].GetConnectedObjects()
					Int ios = 0
					While ios < ConnectedObjects.Length
						If ConnectedObjects[ios] != existingNodeRef
							connectedObjectsLength += 1
						EndIf
						ios += 1
					EndWhile
					iws += 1
				EndWhile
				If goodNodeFormIDs.Length > 0
					goodNodes += ", "
				EndIf
				goodNodeFormIDs = AddInt( goodNodeFormIDs, existingNodeFormIDs[i] )
				goodNodes += existingNodeFormInfo
				goodNodes += "[" + ConnectedWires.Length + "," + connectedObjectsLength + "]"
				lastGoodNode = Game.GetForm( existingNodeFormIDs[i] ) as ObjectReference
				existingNodes += "[" + ConnectedWires.Length + "," + connectedObjectsLength + "]"
			Else
				If corruptedNodeFormIDs.Length > 0
					corruptedNodes += ", "
				EndIf
				corruptedNodeFormIDs = AddInt( corruptedNodeFormIDs, existingNodeFormIDs[i] )
				corruptedNodes += existingNodeFormInfo
				corruptedNodes += "[0,0]"
				existingNodes += "[0,0]"
			EndIf
		EndIf
		i += 1
	EndWhile
	Debug.MessageBox( "existingNodes[wires,neighbors]: " + existingNodes )
	Debug.MessageBox( "corruptedNodes[wires,neighbors]: " + corruptedNodes )
	Debug.MessageBox( "goodNodes[wires,neighbors]: " + goodNodes )
	Utility.Wait( 0.5 )
	
	String orphanedWires = ""
	Int orphanedWiresCount = 0
	i = 0
	While i < workshopObjects.Length
		If workshopObjects[i].GetBaseObject() == Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
			ObjectReference[] ConnectedObjects = workshopObjects[i].GetConnectedObjects()
			ObjectReference validConnectedObject
			Int connectedObjectsLength = 0
			Int ios = 0
			While ios < ConnectedObjects.Length
				If ConnectedObjects[ios] is ObjectReference
					validConnectedObject = ConnectedObjects[ios]
					connectedObjectsLength += 1
				EndIf
				ios += 1
			EndWhile
			If connectedObjectsLength < 2
				If orphanedWiresCount > 0
					orphanedWires += ", "
				EndIf
				orphanedWires += GetFormIDHex( workshopObjects[i].GetFormID() )
				orphanedWiresCount += 1
			EndIf
		EndIf
		i += 1
	EndWhile
	Debug.MessageBox( "orphanedWires: " + orphanedWires )
	Utility.Wait( 0.5 )
	
	Int[] removedDeletedNodeFormIDs = RemoveNodesFromPowerGrid( akWorkshopRef, deletedNodeFormIDs )
	If lastGoodNode
		RefreshPowerGrids( lastGoodNode, akWorkshopRef )
	EndIf
	String removedDeletedNodes = ""
	i = 0
	While i < removedDeletedNodeFormIDs.Length
		If i > 0
			removedDeletedNodes += ", "
		EndIf
		removedDeletedNodes += GetFormIDHex( removedDeletedNodeFormIDs[i] )
		i += 1
	EndWhile
	Debug.MessageBox( "removedDeletedNodes: " + removedDeletedNodes )
	Utility.Wait( 0.5 )
	
	Int[] removedCorruptedNodeFormIDs = RemoveNodesFromPowerGrid( akWorkshopRef, corruptedNodeFormIDs )
	If lastGoodNode
		RefreshPowerGrids( lastGoodNode, akWorkshopRef )
	EndIf
	String removedCorruptedNodes = ""
	i = 0
	While i < removedCorruptedNodeFormIDs.Length
		If i > 0
			removedCorruptedNodes += ", "
		EndIf
		ObjectReference removedCorruptedNodeRef = Game.GetForm( removedCorruptedNodeFormIDs[i] ) as ObjectReference
		String removedCorruptedNodeFormInfo = GetFormInfo( removedCorruptedNodeRef )
		removedCorruptedNodes += removedCorruptedNodeFormInfo
		i += 1
	EndWhile
	Debug.MessageBox( "removedCorruptedNodes: " + removedCorruptedNodes )
	Utility.Wait( 0.5 )
	
	; remove orphaned wires
	Debug.MessageBox( "removedOrphanedWires: " + RemoveOrphanedWires( akWorkshopRef ) )
	Utility.Wait( 0.5 )
	
	; reconnect residual power grid fragments
	FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192, True, True )
	Utility.Wait( 0.5 )
	
	; split residual grid fragments into new individual grids
	;FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192, True, False, True )
	;Utility.Wait( 0.5 )
	
	report = FixConnectionIntegrityErrors( akWorkshopRef, workshopObjects, False, 8192 )
	i = 0
	While i < report.Length
		Debug.MessageBox( report[i] ) ; or dump to a log UI
		i += 1
	EndWhile
	Utility.Wait( 0.5 )
	
	pgs = CheckAndFixPowerGrid( akWorkshopRef, 0 )
	Debug.MessageBox( "power grids checked" + "<br>" + "corrupted: " + pgs.corrupted + "<br>" + "checked: " + pgs.checked + "<br>" + "existingNodes: " + pgs.existingNodes + "<br>" + "deletedNodes: " + pgs.deletedNodes + "<br>" + "numCorruptedGrids: " + pgs.numCorruptedGrids + "<br>" + "totalNodes: " + pgs.totalNodes + "<br>" + "totalGrids: " + pgs.totalGrids )
	Utility.Wait( 0.5 )
	
	Int gridIndex
	
	gridIndex = GetPowerGridIndexForObject( akWorkshopRef, akWorkshopRef )
	
	If gridIndex > -1
		Debug.MessageBox( "object " + GetFormIDHex( akWorkshopRef.GetFormID() ) + " is in power grid #" + gridIndex )
	Else
		Debug.MessageBox( "object " + GetFormIDHex( akWorkshopRef.GetFormID() ) + " is not part of any power grid" )
	EndIf
	Utility.Wait( 0.5 )
	
	gridIndex = GetPowerGridIndexForObject( akWorkshopRef, akRefToRemove )
	
	If gridIndex > -1
		Debug.MessageBox( "object " + GetFormIDHex( akRefToRemove.GetFormID() ) + " is in power grid #" + gridIndex )
	Else
		Debug.MessageBox( "object " + GetFormIDHex( akRefToRemove.GetFormID() ) + " is not part of any power grid" )
	EndIf
	Utility.Wait( 0.5 )
	
	Debug.MessageBox( "object " + GetFormIDHex( akRefToRemove.GetFormID() ) + " removed: " + RemoveExistingObjectFromPowerGrid( akWorkshopRef, akRefToRemove ) )
	Utility.Wait( 0.5 )
	
	gridIndex = GetPowerGridIndexForObject( akWorkshopRef, akRefToRemove )
	
	If gridIndex > -1
		Debug.MessageBox( "object " + GetFormIDHex( akRefToRemove.GetFormID() ) + " is in power grid #" + gridIndex )
	Else
		Debug.MessageBox( "object " + GetFormIDHex( akRefToRemove.GetFormID() ) + " is not part of any power grid" )
	EndIf

EndFunction


; -- helper functions --

; Returns the ConstructibleObject of a Form if it exists.
; - akBaseForm	: the Form
ConstructibleObject Function GetRecipe( Form akBaseForm ) global native

; Returns the ConstructibleObject of an object if it exists.
; - akObjectRef	: the object
ConstructibleObject Function GetRefRecipe( ObjectReference akObjectRef ) global

	return GetRecipe( akObjectRef.GetBaseObject() )

EndFunction

; Returns the components of a ConstructibleObject as RecipeComponents.
; This had to be implemented because it works better than GetConstructibleComponents from F4SE as this can return any type of form as RecipeComponent.Object.
; If it's not a Component type form then for example it can return a MiscObject which is very common for scrap recipes.
; - akRecipe	: the ConstructibleObject
RecipeComponent[] Function GetRecipeComponents( ConstructibleObject akRecipe ) global native

; Returns the components of the ConstructibleObject of an object as RecipeComponents if exists.
; - akObjectRef	: the object
RecipeComponent[] Function GetRefRecipeComponents( ObjectReference akObjectRef ) global

	RecipeComponent[] res = New RecipeComponent[0]
	ConstructibleObject recipe = GetRecipe( akObjectRef.GetBaseObject() )
	If recipe
		res = GetRecipeComponents( recipe )
	EndIf
	return res

EndFunction

; Returns all VMAD scripts attached to an object. Needs BuildScriptInfoForRefArray or BuildScriptInfoForActorArray called first.
; - akRef	: the object
String[] Function GetAllScriptsForForm( ObjectReference akRef ) global native

; Builds attached VMAD script cache for an array of objects to be used by GetAllScriptsForForm. Needs to be called once per object array iteration.
; - akRefs			: the array of objects
; - abAdditional	: if true then adds the new objects to the last cache instead of creating a new one
String[] Function BuildScriptInfoForRefArray( ObjectReference[] akRefs, Bool abAdditional ) global native

; Builds attached VMAD script cache for an array of actors to be used by GetAllScriptsForForm. Needs to be called once per actor array iteration.
; - akActors		: the array of actors
; - abAdditional	: if true then adds the new actors to the last cache instead of creating a new one
String[] Function BuildScriptInfoForActorArray( Actor[] akActors, Bool abAdditional ) global native

; Calls the same function on an object in the context of each attached VMAD script.
; This way it's possible to call for example any custom OnWorkshopObjectDestroyed() or OnWorkshopObjectPlaced() event of any attached scripts on the object.
; - akRef			: the object
; - asFunctionName	: the name of the function or event being called
; - avParams		: the input parameters of the function or event being called
Function CallFunctionOnAllAttachedScripts( ObjectReference akRef, String asFunctionName, Var[] avParams ) global

	String akRefFormInfo = GetFormInfo( akRef )
	String[] attachedScripts = GetAllScriptsForForm( akRef )
	Int i = 0
	While i < attachedScripts.Length
		If attachedScripts[i] != "ObjectReference" && attachedScripts[i] != "Actor" && attachedScripts[i] != "WorkshopChildScript" && attachedScripts[i] != "WorkshopLightboxScript" && attachedScripts[i] != "WorkshopNPCScript" && (attachedScripts[i] != "WorkshopObjectScript" || asFunctionName == "OnWorkshopObjectGrabbed" || asFunctionName == "OnWorkshopObjectMoved") && (attachedScripts[i] != "WorkshopObjectActorScript" || asFunctionName == "OnWorkshopObjectPlaced")
			ScriptObject refScript = akRef.CastAs( attachedScripts[i] )
			If refScript
				DebugLog( "CallFunctionOnAllAttachedScripts", "calling " + attachedScripts[i] + "." + asFunctionName + " on " + akRefFormInfo )
				refScript.CallFunction( asFunctionName, avParams )
			EndIf
		EndIf
		i += 1
	EndWhile
	
EndFunction


Bool Function IsCorruptedNode( ObjectReference akWorkshopRef, ObjectReference akNodeRef ) global
	
	Bool res = False
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	If akNodeRef.GetLinkedRef( WorkshopItemKeyword ) != akWorkshopRef || !akNodeRef.IsWithinBuildableArea( akWorkshopRef )
		res = True
		;If akNodeRef.GetLinkedRef( WorkshopItemKeyword ) != akWorkshopRef && !akNodeRef.IsWithinBuildableArea( akWorkshopRef )
		;	DebugLog( "IsCorruptedNode", GetFormInfo( akNodeRef ) + " is considered corrupted because it's not within the buildable area and GetLinkedRef( WorkshopItemKeyword ) is not " + GetFormInfo( akWorkshopRef ) )
		;ElseIf akNodeRef.GetLinkedRef( WorkshopItemKeyword ) != akWorkshopRef
		;	DebugLog( "IsCorruptedNode", GetFormInfo( akNodeRef ) + " is considered corrupted because GetLinkedRef( WorkshopItemKeyword ) is not " + GetFormInfo( akWorkshopRef ) )
		;ElseIf !akNodeRef.IsWithinBuildableArea( akWorkshopRef )
		;	DebugLog( "IsCorruptedNode", GetFormInfo( akNodeRef ) + " is considered corrupted because it's not within the buildable area" )
		;EndIf
	EndIf
	
	return res
	
EndFunction


Int[] Function GetCorruptedNodeFormIDs( ObjectReference akWorkshopRef, Bool abShowProgress = False, String asHeartbeatText = "fixing workshop 2: corrupted nodes" ) global

	Int[] existingNodeFormIDs = GetExistingNodeFormIDs( akWorkshopRef )
	Int[] corruptedNodeFormIDs = New Int[0]
	Bool ProgressBarAvailable = abShowProgress && IsHUDFrameworkAvailable()
	Float fTime = Utility.GetCurrentRealTime()
	Int i = 0
	While i < existingNodeFormIDs.Length
		ObjectReference existingNodeRef = Game.GetForm( existingNodeFormIDs[i] ) as ObjectReference
		If IsCorruptedNode( akWorkshopRef, existingNodeRef )
			AddInt( corruptedNodeFormIDs, existingNodeFormIDs[i] )
		EndIf
		i += 1
		If abShowProgress
			fTime = ShowProgressTick( ProgressBarAvailable, i, existingNodeFormIDs.Length, asHeartbeatText, fTime )
		EndIf
	EndWhile

	return corruptedNodeFormIDs

EndFunction


Bool Function IsGoodNode( ObjectReference akWorkshopRef, ObjectReference akNodeRef, Bool abIncludeWires = False, Bool abHasWireConnection = False, Bool abNoOrphanedWiresConnected = False ) global
	
	Bool res = False
	String falseReason = ""
	String trueReason = ""
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	Keyword WorkshopCanBePowered = Game.GetFormFromFile( 0x0003037E, "Fallout4.esm") as Keyword
	Keyword WorkshopPowerConnection = Game.GetFormFromFile( 0x00054BA4, "Fallout4.esm") as Keyword
	ActorValue WorkshopPowerConnectionAV = Game.GetFormFromFile( 0x000002D0, "Fallout4.esm") as ActorValue
	ActorValue WorkshopSnapPointRadiusAV = Game.GetFormFromFile( 0x0000033E, "Fallout4.esm") as ActorValue
	ActorValue WorkshopSnapTransmitsPowerAV = Game.GetFormFromFile( 0x00000354, "Fallout4.esm") as ActorValue
	Form wireBase = Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
	If akNodeRef
		If abNoOrphanedWiresConnected && !_IsWire( akNodeRef, wireBase )
			ObjectReference[] connectedWires = akNodeRef.GetConnectedObjects()
			Int i = 0
			While i < connectedWires.Length
				If _IsWire( connectedWires[i], wireBase )
					If connectedWires[i].GetConnectedObjects().Length < 2
						DebugLog( "IsGoodNode", GetFormInfo( akNodeRef ) + " is NOT considered good because it has orphaned wire connected" )
						return False
					EndIf
				EndIf
				i += 1
			EndWhile
		EndIf
		If akNodeRef.GetLinkedRef( WorkshopItemKeyword ) == akWorkshopRef && akNodeRef.IsWithinBuildableArea( akWorkshopRef ) && abHasWireConnection && akNodeRef.GetConnectPoints()
			res = True
		ElseIf akNodeRef.GetLinkedRef( WorkshopItemKeyword ) == akWorkshopRef && akNodeRef.IsWithinBuildableArea( akWorkshopRef ) && !abHasWireConnection && (akNodeRef.GetBaseObject().HasKeyword( WorkshopCanBePowered ) || akNodeRef.GetBaseObject().HasKeyword( WorkshopPowerConnection ) || akNodeRef.GetValue( WorkshopPowerConnectionAV ) > 0.0 || akNodeRef.GetValue( WorkshopSnapPointRadiusAV ) > 0.0 || akNodeRef.GetValue( WorkshopSnapTransmitsPowerAV ) > 0.0)
			res = True
			If 0
			If akNodeRef.GetBaseObject().HasKeyword( WorkshopCanBePowered )
				If trueReason != ""
					trueReason += " and "
				EndIf
				trueReason += "has the keyword WorkshopCanBePowered"
			EndIf
			If akNodeRef.GetBaseObject().HasKeyword( WorkshopPowerConnection )
				If trueReason != ""
					trueReason += " and "
				EndIf
				trueReason += "has the keyword WorkshopPowerConnection"
			EndIf
			If akNodeRef.GetValue( WorkshopPowerConnectionAV ) > 0.0
				If trueReason != ""
					trueReason += " and "
				EndIf
				trueReason += "has its actor value WorkshopPowerConnectionAV set to " + akNodeRef.GetValue( WorkshopPowerConnectionAV )
			EndIf
			If akNodeRef.GetValue( WorkshopSnapPointRadiusAV ) > 0.0
				If trueReason != ""
					trueReason += " and "
				EndIf
				trueReason += "has its actor value WorkshopSnapPointRadiusAV set to " + akNodeRef.GetValue( WorkshopSnapPointRadiusAV )
			EndIf
			If akNodeRef.GetValue( WorkshopSnapTransmitsPowerAV ) > 0.0
				If trueReason != ""
					trueReason += " and "
				EndIf
				trueReason += "has its actor value WorkshopSnapTransmitsPowerAV set to " + akNodeRef.GetValue( WorkshopSnapTransmitsPowerAV )
			EndIf
			EndIf
		ElseIf akNodeRef.GetLinkedRef( WorkshopItemKeyword ) == akWorkshopRef && akNodeRef.IsWithinBuildableArea( akWorkshopRef ) && !abHasWireConnection && abIncludeWires && _IsWire( akNodeRef, wireBase )
			res = True
			;DebugLog( "IsGoodNode", GetFormInfo( akNodeRef ) + " is considered good because GetLinkedRef( WorkshopItemKeyword ) is " + GetFormInfo( akWorkshopRef ) + " and it's within the buildable area and it's a wire" )
		Else
			If 0
			If akNodeRef.GetLinkedRef( WorkshopItemKeyword ) != akWorkshopRef
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "GetLinkedRef( WorkshopItemKeyword ) is NOT " + GetFormInfo( akWorkshopRef ) + ", it is " + GetFormInfo( akNodeRef.GetLinkedRef( WorkshopItemKeyword ) )
			EndIf
			If !akNodeRef.IsWithinBuildableArea( akWorkshopRef )
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "it's NOT within the buildable area"
			EndIf
			If !akNodeRef.GetBaseObject().HasKeyword( WorkshopCanBePowered )
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "it doesn't have the keyword WorkshopCanBePowered"
			EndIf
			If !akNodeRef.GetBaseObject().HasKeyword( WorkshopPowerConnection )
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "it doesn't have the keyword WorkshopPowerConnection"
			EndIf
			If !(akNodeRef.GetValue( WorkshopPowerConnectionAV ) > 0.0)
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "doesn't have set actor value for WorkshopPowerConnectionAV"
			EndIf
			If !(akNodeRef.GetValue( WorkshopSnapPointRadiusAV ) > 0.0)
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "doesn't have set actor value for WorkshopSnapPointRadiusAV"
			EndIf
			If !(akNodeRef.GetValue( WorkshopSnapTransmitsPowerAV ) > 0.0)
				If falseReason != ""
					falseReason += " and "
				EndIf
				falseReason += "doesn't have set actor value for WorkshopSnapTransmitsPowerAV"
			EndIf
			EndIf
		EndIf
	;Else
	;	If falseReason != ""
	;		falseReason += " and "
	;	EndIf
	;	falseReason += "it does not exist"
	EndIf

	If falseReason != ""
		DebugLog( "IsGoodNode", GetFormInfo( akNodeRef ) + " is NOT considered good because " + falseReason )
	EndIf

	If trueReason != ""
		DebugLog( "IsGoodNode", GetFormInfo( akNodeRef ) + " is considered good because GetLinkedRef( WorkshopItemKeyword ) is " + GetFormInfo( akWorkshopRef ) + " and it's within the buildable area and " + trueReason )
	EndIf
	
	return res
	
EndFunction


ObjectReference[] Function GetGoodNodeRefs( ObjectReference akWorkshopRef ) global

	Int[] existingNodeFormIDs = GetExistingNodeFormIDs( akWorkshopRef )
	ObjectReference[] goodNodeRefs = New ObjectReference[0]
	Int i = 0
	While i < existingNodeFormIDs.Length
		ObjectReference existingNodeRef = Game.GetForm( existingNodeFormIDs[i] ) as ObjectReference
		If IsGoodNode( akWorkshopRef, existingNodeRef )
			AddObjectReference( goodNodeRefs, existingNodeRef )
		EndIf
		i += 1
	EndWhile
	
	return goodNodeRefs
	
EndFunction

; Public entry point.
; - akWorkshopRef: the settlement's workshop workbench reference
; - startRef: any power-connected workshop object (or a wire)
; - includeWires: if true, output will contain wire refs too; otherwise they're only traversed through
; - maxCount: safety cap to avoid runaway recursion on strange setups
ObjectReference[] Function TraversePowerGrid( ObjectReference akWorkshopRef, ObjectReference startRef, Bool includeWires = False, Int maxCount = 8192 ) global
	If startRef == None
		return New ObjectReference[0]
	EndIf

	Form WireBase = Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")

	ObjectReference[] seen = New ObjectReference[0]   ; loop prevention (wires AND non-wires)
	ObjectReference[] result = New ObjectReference[0] ; what we return (optionally excluding wires)

	_DFS_Grid( akWorkshopRef, startRef, None, includeWires, maxCount, seen, result )
	return result
EndFunction


; --- Internal recursive DFS ---
Function _DFS_Grid( ObjectReference akWorkshopRef, ObjectReference node, ObjectReference cameFrom, Bool includeWires, Int maxCount, ObjectReference[] seen, ObjectReference[] result ) global
	If node == None
		return
	EndIf

	; Safety cap
	If seen.Length >= maxCount
		return
	EndIf

	; Already processed?
	If _ArrHas( seen, node )
		return
	EndIf

	; Mark as seen for loop prevention (regardless of wire or not).
	seen = AddObjectReference( seen, node )

	Form wireBase = Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
	ActorValue WorkshopSnapTransmitsPower = Game.GetFormFromFile( 0x00000354, "Fallout4.esm" ) as ActorValue
	ActorValue PowerRadiation = Game.GetFormFromFile( 0x0000032F, "Fallout4.esm" ) as ActorValue
	Keyword WorkshopCanBePowered = Game.GetFormFromFile( 0x0003037E, "Fallout4.esm") as Keyword
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	Bool isWire = _IsWire( node, wireBase )

	; Add to output only if requested (wires optional).
	If includeWires || !isWire
		result = AddObjectReference( result, node )
	EndIf

	; Get neighbors using the F4SE extension
	ObjectReference[] neighbors = node.GetConnectedObjects()
	ObjectReference:ConnectPoint[] connectPoints = node.GetConnectPoints()
	ObjectReference[] wireless
	ObjectReference[] wireless_
	; TODO: wireless?
	If node.GetValue( PowerRadiation ) > 0.0 && 0
		wireless = node.FindAllReferencesWithKeyword( WorkshopCanBePowered, node.GetValue( PowerRadiation ) )
		wireless_ = New ObjectReference[0]
		Int i = 0
		While i < wireless.Length
			String wirelessPowerGridNodeFormInfo = GetFormInfo( wireless[i] )
			DebugLog( "_DFS_Grid", "wireless connection " + (i + 1) + " / " + wireless.Length + ": " + wirelessPowerGridNodeFormInfo + " " + GetFormIDHex( wireless[i].GetBaseObject().GetFormID() ) )
			ObjectReference n = wireless[i]
			Bool hasWireConnection = False
			ObjectReference[] connections = n.GetConnectedObjects()
			If connections
				hasWireConnection = True
				DebugLog( "_DFS_Grid", "	" + wirelessPowerGridNodeFormInfo + " connected to " + connections.Length + " wires" )
			Else
				ObjectReference:ConnectPoint[] neighborConnectPoints = n.GetConnectPoints()
				If neighborConnectPoints
					Int j = 0
					While j < neighborConnectPoints.Length && !hasWireConnection
						DebugLog( "_DFS_Grid", "	" + wirelessPowerGridNodeFormInfo + " connect point " + (j + 1) + " / " + neighborConnectPoints.Length + ": " + neighborConnectPoints[j].name )
						If neighborConnectPoints[j].name == "P-WS-Snap" || neighborConnectPoints[j].name == "P-WS-Input" || neighborConnectPoints[j].name == "P-WS-Output"
							hasWireConnection = True
						EndIf
						j += 1
					EndWhile
				EndIf
			EndIf
			If !hasWireConnection
				wireless_ = AddObjectReference( wireless_, n )
			EndIf
			i += 1
		EndWhile
	EndIf
	
	If neighbors == None && connectPoints == None && (wireless_ == None || wireless_.Length == 0)
		return
	EndIf
	
	Int i = 0
	If node.GetValue( PowerRadiation ) > 0.0 && 0
		While i < wireless_.Length
			ObjectReference n = wireless_[i]
			; Skip invalid and trivial back-edge
			If n != cameFrom
				If IsGoodNode( akWorkshopRef, n, True )
					; Recurse to every neighbor. Loop prevention is handled by 'seen'.
					_DFS_Grid( akWorkshopRef, n, node, includeWires, maxCount, seen, result )
				EndIf
			EndIf
			i += 1
		EndWhile
	EndIf
	
	i = 0
	If node.GetValue( WorkshopSnapTransmitsPower ) > 0.0
		While i < connectPoints.Length
			ObjectReference n = connectPoints[i].object
			; Skip invalid and trivial back-edge
			If n != cameFrom
				If IsGoodNode( akWorkshopRef, n, True )
					If n.GetValue( WorkshopSnapTransmitsPower ) > 0.0
						; Recurse to every neighbor. Loop prevention is handled by 'seen'.
						_DFS_Grid( akWorkshopRef, n, node, includeWires, maxCount, seen, result )
					EndIf
				EndIf
			EndIf
			i += 1
		EndWhile
	EndIf

	i = 0
	While i < neighbors.Length
		ObjectReference n = neighbors[i]
		; Skip invalid and trivial back-edge
		If n != cameFrom
			If IsGoodNode( akWorkshopRef, n, True )
				; Recurse to every neighbor. Loop prevention is handled by 'seen'.
				_DFS_Grid( akWorkshopRef, n, node, includeWires, maxCount, seen, result )
			EndIf
		EndIf
		i += 1
	EndWhile
EndFunction


Int[] Function ComputeWirePlan( ObjectReference akWorkshopRef, Int[] groupIds, Int[] indexForGroup, ObjectReference[] firstSeedForGroup, Int maxTraverseCount, float maxWireLength = 0.0 ) Global
	int[] gridIndices = _GetUniqueIndices( groupIds, indexForGroup )

	Int[] allPairs = New Int[0]

	int i = 0
	While i < gridIndices.Length
		Int[] groupSet = _FilterByIndex( groupIds, gridIndices[i], indexForGroup )
		If groupSet.Length >= 2
			Int[] mst = _PrimMST( akWorkshopRef, groupSet, maxWireLength, firstSeedForGroup, maxTraverseCount )
			int j = 0
			While j < mst.Length
				allPairs = AddInt( allPairs, mst[j] )
				j += 1
			EndWhile
		EndIf
		i += 1
	EndWhile

	return allPairs
EndFunction


Int[] Function _PrimMST( ObjectReference akWorkshopRef, Int[] g, float maxWireLength, ObjectReference[] firstSeedForGroup, Int maxTraverseCount ) Global
	int n = g.Length
	bool[] inTree = New bool[n]
	inTree[0] = true

	Int[] result = New Int[0]
	int edgesAdded = 0

	While edgesAdded < (n - 1)
		float bestD = 0.0
		int bestI = -1
		int bestJ = -1

		int i = 0
		While i < n
			If inTree[i]
				int j = 0
				While j < n
					If !inTree[j] && j != i
						ObjectReference[] group1 = TraversePowerGrid( akWorkshopRef, firstSeedForGroup[g[i]], False, maxTraverseCount )
						ObjectReference[] group2 = TraversePowerGrid( akWorkshopRef, firstSeedForGroup[g[j]], False, maxTraverseCount )
						ObjectReference[] closestPair = ClosestPair3D( group1, group2, False, maxTraverseCount)
						float d = closestPair[0].GetDistance( closestPair[1] ) ; <-- Papyrus native
						If bestI < 0 || d < bestD
							If maxWireLength <= 0.0 || d <= maxWireLength
								bestD = d
								bestI = i
								bestJ = j
							EndIf
						EndIf
					EndIf
					j += 1
				EndWhile
			EndIf
			i += 1
		EndWhile

		If bestI < 0
			; No permissible edge (likely due to maxWireLength). Stop this group.
		else
			result = AddInt( result, g[bestI] )
			result = AddInt( result, g[bestJ] )

			inTree[bestJ] = true
			edgesAdded += 1
		EndIf
	EndWhile

	return result
EndFunction


Int[] Function _FilterByIndex( Int[] groupIds, int index, Int[] indexForGroup ) Global
	Int[] outArr = New Int[0]
	int i = 0
	While i < groupIds.Length
		If indexForGroup[groupIds[i]] == index
			outArr = AddInt( outArr, groupIds[i] )
		EndIf
		i += 1
	EndWhile
	return outArr
EndFunction


int[] Function _GetUniqueIndices( Int[] groupIds, Int[] indexForGroup ) Global
	int[] indices = New int[0]
	int i = 0
	While i < groupIds.Length
		int idx = indexForGroup[groupIds[i]]
		If !_HasInt( indices, idx )
			indices = AddInt( indices, idx )
		EndIf
		i += 1
	EndWhile
	return indices
EndFunction


Function _DFS_Group( Int newId, Int[] aiGroupIds, Int[] handled, Int maxId, Int[] indexForGroup, ObjectReference[] firstSeedForGroup, Int maxTraverseCount, ObjectReference workshopRef, ObjectReference[] finalPairsToConnect ) global
	If aiGroupIds.Length > 0
		_AddUniqueInt( handled, aiGroupIds[aiGroupIds.Length - 1] )
	EndIf
	_AddUniqueInt( aiGroupIds, newId )
	Int idx1
	ObjectReference[] group1
	ObjectReference[] group1final
	Float closestDistance = 9999999.9
	Int groupIdFinal
	Int closestGroup = -1
	Int i = 0
	While i < aiGroupIds.Length
		idx1 = indexForGroup[i]
		group1 = TraversePowerGrid( workshopRef, firstSeedForGroup[i], False, maxTraverseCount )
		Int j = 0
		While j < maxId
			If j != i && !_HasInt( handled, j )
				Int idx2 = indexForGroup[i]
				If idx2 == idx1
					ObjectReference[] group2 = TraversePowerGrid( workshopRef, firstSeedForGroup[j], False, maxTraverseCount )
					ObjectReference[] closestPair = ClosestPair3D( group1, group2, False, maxTraverseCount)
					Float distance = closestPair[0].GetDistance( closestPair[1] )
					If distance < closestDistance
						closestDistance = distance
						closestGroup = j
						groupIdFinal = i
						group1final = group1
					EndIf
				EndIf
			EndIf
			j += 1
		EndWhile
		i += 1
	EndWhile
	If closestGroup > -1
		ObjectReference[] group2 = TraversePowerGrid( workshopRef, firstSeedForGroup[closestGroup], False, maxTraverseCount )
		ObjectReference[] closestPair = ClosestPair3D( group1final, group2, False, maxTraverseCount)
		finalPairsToConnect = AddObjectReference( finalPairsToConnect, closestPair[0] )
		finalPairsToConnect = AddObjectReference( finalPairsToConnect, closestPair[1] )
		_DFS_Group( closestGroup, aiGroupIds, handled, maxId, indexForGroup, firstSeedForGroup, maxTraverseCount, workshopRef, finalPairsToConnect )
	EndIf
EndFunction


Function ConnectRefsWithPylons( ObjectReference[] closestPair, ObjectReference workshopRef, Int groupId1, Int groupId2, Float maxDistance = 1100.0 ) global
	Form powerPylon = Game.GetFormFromFile( 0x0015D76F, "Fallout4.esm" )
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	Form wireBase = Game.GetFormFromFile( 0x0001D971, "Fallout4.esm")
	Actor PlayerREF = Game.GetPlayer()
	
	String closestPairFirstFormInfo = GetFormInfo( closestPair[0] )
	String closestPairSecondFormInfo = GetFormInfo( closestPair[1] )
	
	Float distance = closestPair[0].GetDistance( closestPair[1] )
	If distance <= maxDistance
		Debug.MessageBox( "creating " + distance + " long wire between group #" + groupId1 + " and group #" + groupId2 + "<br>closestPair: group #" + groupId1 + " " + closestPairFirstFormInfo + ", group #" + groupId2 + " " + closestPairSecondFormInfo )
		closestPair[0].CreateWire( closestPair[1], wireBase )
	Else
		Int numberOfPylons = Math.Floor( distance / maxDistance )
		Float pylonDistance = distance / (numberOfPylons + 1)
		;Debug.MessageBox( "distance: " + distance + "<br>fPowerConnectionMaxLength: " + Game.GetGameSettingFloat( "fPowerConnectionMaxLength" ) + "numberOfPylons: " + numberOfPylons + "<br>pylonDistance: " + pylonDistance )
		ObjectReference node1
		ObjectReference node2
		Int k = 0
		While k < numberOfPylons + 1
			If k == 0
				node1 = closestPair[0]
			Else
				node1 = node2
			EndIf
			If k < numberOfPylons
				node2 = PlayerREF.PlaceAtMe( powerPylon, 1, False, True, False )
				Float[] coordinates = GetPointInDirection( closestPair[0], closestPair[1], pylonDistance * (k + 1) )
				node2.SetPosition( coordinates[0], coordinates[1], coordinates[2] )
				node2.Enable()
				Utility.Wait( 0.5 )
				node2.MoveToNearestNavmeshLocation()
				node2.SetLinkedRef( workshopRef, WorkshopItemKeyword )
				Utility.Wait( 0.5 )
			Else
				node2 = closestPair[1]
			EndIf
			String node1FormInfo = GetFormInfo( node1 )
			String node2FormInfo = GetFormInfo( node2 )
			If k == 0
				Debug.MessageBox( "creating " + pylonDistance + " long wire between group #" + groupId1 + " " + node1FormInfo + " and injected pylon #" + (k + 1) + " " + node2FormInfo )
			ElseIf k < numberOfPylons
				Debug.MessageBox( "creating " + pylonDistance + " long wire between injected pylon #" + k + " " + node1FormInfo + " and injected pylon #" + (k + 1) + " " + node2FormInfo )
			Else
				Debug.MessageBox( "creating " + pylonDistance + " long wire between injected pylon #" + k + " " + node1FormInfo + " and group #" + groupId2 + " " + node2FormInfo )
			EndIf
			node1.CreateWire( node2, wireBase )
			k += 1
		EndWhile
	EndIf
EndFunction


; inCount   = source count before rank gated filtering
; bFromRecipe = true if this came from COBJ (built object), false if from MiscObject junk split
Int Function ComputePayout( Form comp, Int inCount, Bool bFromRecipe, Actor akPlayer ) global
	If inCount <= 0
		return 0
	EndIf
	
	If comp && comp is Component
	Else
		return 0
	EndIf
	
	Float recipeScalar = (comp as Component).GetScrapScalar().GetValue()
	If recipeScalar <= 0.0
		recipeScalar = 0.25 ; fallback to vanilla default
	EndIf

	; 1) Start from base count (apply COBJ scalar if needed)
	Int count = inCount
	If bFromRecipe
		count = Math.Floor( inCount * recipeScalar )
		If count < 0
			count = 0
		EndIf
	EndIf

	; 2) Zero-yield is always zero
	If IsZeroYield( comp )
		return 0
	EndIf

	Int rank = GetScrapperRank( akPlayer )

	; 3) Rarity gating by rank
	If IsRare( comp )
		If rank < 2
			return 0
		EndIf
	ElseIf IsUncommon( comp )
		If rank < 1
			return 0
		EndIf
	; Common → no gate
	EndIf

	; 4) Rank 3 “double (or double+1)”
	If rank >= 3
		; mirrors “approximately doubles (double or double+1)” described on wiki
		count = count * 2 + (count % 2)
	EndIf
	
	If count < 0
		count = 0
	EndIf

	return count
EndFunction


Int Function GetScrapperRank( Actor ak ) global

	Perk Scrapper01 = Game.GetFormFromFile( 0x00065E65, "Fallout4.esm" ) as Perk
	Perk Scrapper02 = Game.GetFormFromFile( 0x001D2483, "Fallout4.esm" ) as Perk
	Perk Scrapper03
	If Game.IsPluginInstalled( "DLCCoast.esm" )
		Scrapper03 = Game.GetFormFromFile( 0x030423A5, "DLCCoast.esm" ) as Perk
	EndIf
	
	If ak.HasPerk( Scrapper03 )
		return 3
	ElseIf ak.HasPerk( Scrapper02 )
		return 2
	ElseIf ak.HasPerk( Scrapper01 )
		return 1
	EndIf
	return 0

EndFunction


Bool Function IsZeroYield( Form comp ) global   ; adhesive & oil never returned
	
	Form[] ZeroYieldComponents = New Form[0]
	ZeroYieldComponents.Add( Game.GetFormFromFile( 0x0001FAA5, "Fallout4.esm" ) )	; c_Adhesive "Adhesive" [CMPO:0001FAA5]
	ZeroYieldComponents.Add( Game.GetFormFromFile( 0x0001FAB4, "Fallout4.esm" ) )	; c_Oil "Oil" [CMPO:0001FAB4]
	
	return ZeroYieldComponents.Find( comp ) >= 0

EndFunction


Bool Function IsRare( Form comp ) global
	
	Form[] RareComponents = New Form[0]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FA8C, "Fallout4.esm" ) )	; c_Acid "Acid" [CMPO:0001FA8C]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FA96, "Fallout4.esm" ) )	; c_Antiseptic "Antiseptic" [CMPO:0001FA96]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FA97, "Fallout4.esm" ) )	; c_Asbestos "Asbestos" [CMPO:0001FA97]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FA94, "Fallout4.esm" ) )	; c_AntiBallisticFiber "Ballistic Fiber" [CMPO:0001FA94]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FA9B, "Fallout4.esm" ) )	; c_Circuitry "Circuitry" [CMPO:0001FA9B]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FA9F, "Fallout4.esm" ) )	; c_Crystal "Crystal" [CMPO:0001FA9F]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FAA0, "Fallout4.esm" ) )	; c_FiberOptics "Fiber Optics" [CMPO:0001FAA0]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FAA6, "Fallout4.esm" ) )	; c_Gold "Gold" [CMPO:0001FAA6]
	RareComponents.Add( Game.GetFormFromFile( 0x0001FAB3, "Fallout4.esm" ) )	; c_NuclearMaterial "Nuclear Material" [CMPO:0001FAB3]
	
	return RareComponents.Find( comp ) >= 0

EndFunction


Bool Function IsUncommon( Form comp ) global
	
	Form[] UncommonComponents = New Form[0]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FA91, "Fallout4.esm" ) )	; c_Aluminum "Aluminum" [CMPO:0001FA91]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FA9C, "Fallout4.esm" ) )	; c_Copper "Copper" [CMPO:0001FA9C]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FA9D, "Fallout4.esm" ) )	; c_Cork "Cork" [CMPO:0001FA9D]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0005A0C7, "Fallout4.esm" ) )	; c_Fertilizer "Fertilizer" [CMPO:0005A0C7]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FAA1, "Fallout4.esm" ) )	; c_Fiberglass "Fiberglass" [CMPO:0001FAA1]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FAB0, "Fallout4.esm" ) )	; c_Gears "Gear" [CMPO:0001FAB0]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FAA4, "Fallout4.esm" ) )	; c_Glass "Glass" [CMPO:0001FAA4]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FAAD, "Fallout4.esm" ) )	; c_Lead "Lead" [CMPO:0001FAAD]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0003D294, "Fallout4.esm" ) )	; c_Screws "Screw" [CMPO:0003D294]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FABB, "Fallout4.esm" ) )	; c_Silver "Silver" [CMPO:0001FABB]
	UncommonComponents.Add( Game.GetFormFromFile( 0x0001FABC, "Fallout4.esm" ) )	; c_Springs "Spring" [CMPO:0001FABC]
	
	return UncommonComponents.Find( comp ) >= 0

EndFunction


; Convenience funcition to quickly attach a new ref to a grid and then remove it so internal changes to a power grid get applied
Bool Function RefreshPowerGrids( ObjectReference akNodeRef, ObjectReference akWorkshopRef, ObjectReference akNode2Ref = None ) global
	;DebugLog( "RefreshPowerGrids", "node1: " + GetFormInfo( akNodeRef ) )
	Form powerPylon = Game.GetFormFromFile( 0x0015D76F, "Fallout4.esm" )
	Keyword WorkshopItemKeyword = Game.GetFormFromFile( 0x00054BA6, "Fallout4.esm") as Keyword
	ObjectReference node2Ref
	If akNode2Ref
		node2Ref = akNode2Ref
	Else
		node2Ref = Game.GetPlayer().PlaceAtMe( powerPylon, 1, False, True, False )
		node2Ref.MoveTo( akNodeRef, Utility.RandomFloat( 50.0, 200.0 ), Utility.RandomFloat( 50.0, 200.0 ) )
		node2Ref.Enable()
		Utility.Wait( 0.5 )
		node2Ref.MoveToNearestNavmeshLocation()
		node2Ref.SetLinkedRef( akWorkshopRef, WorkshopItemKeyword )
	EndIf
	Int[] node2FormID = New Int[1]
	node2FormID[0] = node2Ref.GetFormID()
	;DebugLog( "RefreshPowerGrids", "node2: " + GetFormInfo( node2Ref ) )
	Utility.Wait( 0.5 )
	ObjectReference wireRef = akNodeRef.CreateWire( node2Ref )
	Utility.Wait( 0.5 )
	;DebugLog( "RefreshPowerGrids", "wire: " + GetFormInfo( wireRef ) )
	If !akNode2Ref
		If node2Ref
			node2Ref.Disable()
			node2Ref.Delete()
		Else
	;DebugLog( "RefreshPowerGrids", "node2: " + GetFormInfo( node2Ref ) + " does not exist" )
		EndIf
		RemoveNodesFromPowerGrid( akWorkshopRef, node2FormID )
	EndIf
	If wireRef
		wireRef.Disable()
		wireRef.Delete()
		return True
	Else
	;DebugLog( "RefreshPowerGrids", "wire: " + GetFormInfo( wireRef ) + " does not exist" )
		return False
	EndIf
EndFunction


; Find the closest pair between two groups.
; - excludeSame: if True, won't match the same ref when it appears in both arrays.
; - requireEnabled: if True, skips disabled refs.
; Returns [bestRef1, bestRef2]. If no valid pair, returns [None, None].
ObjectReference[] Function ClosestPair3D( ObjectReference[] groupA, ObjectReference[] groupB, Bool excludeSame = True, Bool requireEnabled = False ) global
	ObjectReference[] result = New ObjectReference[2]
	result[0] = None
	result[1] = None

	If groupA == None || groupB == None || groupA.Length == 0 || groupB.Length == 0
		return result
	EndIf

	Float bestD2 = -1.0

	Int i = 0
	While i < groupA.Length
		ObjectReference a = groupA[i]

		Bool aOk = (a != None)
		If aOk && requireEnabled
			If a.IsDisabled()
				aOk = False
			EndIf
		EndIf

		If aOk
			Float ax = a.GetPositionX()
			Float ay = a.GetPositionY()
			Float az = a.GetPositionZ()

			Int j = 0
			While j < groupB.Length
				ObjectReference b = groupB[j]

				Bool bOk = (b != None)
				If bOk && requireEnabled
					If b.IsDisabled()
						bOk = False
					EndIf
				EndIf
				If bOk
					If !(excludeSame && (a == b))
						; squared distance for speed (no sqrt)
						Float dx = ax - b.GetPositionX()
						Float dy = ay - b.GetPositionY()
						Float dz = az - b.GetPositionZ()
						Float d2 = dx*dx + dy*dy + dz*dz

						; pick strictly smaller, or if equal keep the earlier pair (tie -> lower indices)
						If bestD2 < 0.0 || d2 < bestD2
							bestD2 = d2
							result[0] = a
							result[1] = b
						EndIf
					EndIf
				EndIf
				j += 1
			EndWhile
		EndIf

		i += 1
	EndWhile

	return result
EndFunction


; Get 3D coordinate of a point in the direction of a ref from another ref in a certain distance
Float[] Function GetPointInDirection( ObjectReference refA, ObjectReference refB, Float d ) global
	Float[] result = New Float[3]
    
	Float dx = refB.GetPositionX() - refA.GetPositionX()
    Float dy = refB.GetPositionY() - refA.GetPositionY()
    Float dz = refB.GetPositionZ() - refA.GetPositionZ()

    Float len = Math.Sqrt( dx*dx + dy*dy + dz*dz )
    If len <= 0.0
		result[0] = refA.GetPositionX()
		result[1] = refA.GetPositionY()
		result[2] = refA.GetPositionZ()
		Return result
    EndIf

    Float nx = dx / len
    Float ny = dy / len
    Float nz = dz / len

	result[0] = refA.GetPositionX() + nx * d
	result[1] = refA.GetPositionY() + ny * d
	result[2] = refA.GetPositionZ() + nz * d

    Return result
EndFunction


Bool Function _AddUniqueInt( Int[] arr, Int v ) global
	Int i = 0
	While i < arr.Length
		If arr[i] == v
			return False
		EndIf
		i += 1
	EndWhile
	arr = AddInt( arr, v )
	return True
EndFunction


Bool Function _HasInt( Int[] arr, Int v ) global
	If arr == None
		return False
	EndIf
	Int i = 0
	While i < arr.Length
		If arr[i] == v
			return True
		EndIf
		i += 1
	EndWhile
	return False
EndFunction


Bool Function _HasRef( ObjectReference[] arr, ObjectReference r ) global
	If arr == None || r == None
		return False
	EndIf
	Int i = 0
	While i < arr.Length
		If arr[i] == r
			return True
		EndIf
		i += 1
	EndWhile
	return False
EndFunction


Int Function _IndexOfInt( Int[] arr, Int v ) global
	If arr == None
		return -1
	EndIf
	Int i = 0
	While i < arr.Length
		If arr[i] == v
			return i
		EndIf
		i += 1
	EndWhile
	return -1
EndFunction


Int Function MostFrequentInt( Int[] arr, Int fallback = 0 ) global
	If arr == None || arr.Length == 0
		return fallback
	EndIf

	; Build unique values + counts + first-occurrence indices
	Int[] values   = New Int[0]
	Int[] counts   = New Int[0]
	Int[] firstIdx = New Int[0]

	Int i = 0
	While i < arr.Length
		Int v = arr[i]
		Int pos = _IndexOfInt( values, v )
		If pos == -1
			values = AddInt( values, v )
			counts = AddInt( counts, 1 )
			firstIdx = AddInt( firstIdx, i )
		Else
			counts[pos] = counts[pos] + 1
		EndIf
		i += 1
	EndWhile

	; Pick best by (count desc, firstIdx asc)
	Int bestVal   = values[0]
	Int bestCount = counts[0]
	Int bestFirst = firstIdx[0]

	i = 1
	While i < values.Length
		Int c = counts[i]
		If c > bestCount
			bestVal   = values[i]
			bestCount = c
			bestFirst = firstIdx[i]
		Else
			If c == bestCount
				If firstIdx[i] < bestFirst
					bestVal   = values[i]
					bestFirst = firstIdx[i]
				EndIf
			EndIf
		EndIf
		i += 1
	EndWhile

	return bestVal
EndFunction


Bool Function _IsWire( ObjectReference r, Form wireBase ) global
	If r == None || wireBase == None
		return False
	EndIf
	return r.GetBaseObject() == wireBase
EndFunction


Bool Function _ArrHas( ObjectReference[] arr, ObjectReference x ) global
	If arr == None || x == None
		return False
	EndIf
	Int i = 0
	While i < arr.Length
		If arr[i] == x
			return True
		EndIf
		i += 1
	EndWhile
	return False
EndFunction


String Function GetFormIDHex( Int thisFormID, Bool lightMaster = False ) global

	If !lightMaster
		Int ModIndexInt = GetModIndex( thisFormID )
		String ModIndexHex = DecToHex( ModIndexInt, 2 )
		Int StrippedFormIDInt = thisFormID - ModIndexInt * 0x1000000
		String StrippedFormIDHex = DecToHex( StrippedFormIDInt, 6 )
		
		return ModIndexHex + StrippedFormIDHex
	Else
		Int ModIndexInt = GetModIndex( thisFormID, True )
		String ModIndexHex = DecToHex( ModIndexInt, 3 )
		Int StrippedFormIDInt = thisFormID - ModIndexInt * 0x1000
		String StrippedFormIDHex = DecToHex( StrippedFormIDInt, 3 )
		
		return "FE" + ModIndexHex + StrippedFormIDHex
	EndIf
	
EndFunction


Int Function GetModIndex( Int aiFormID, Bool lightMaster = False ) global
    
	Int n
	
	If !lightMaster
		n = aiFormID
		If n < 0
			return 255 - ((n + 1) / -16777216)
		Else
			return (n / 0x1000000)
		EndIf
	Else
		n = aiFormID
		If n < 0
			return (255 - ((n + 1) / -4096)) - 0xFE
		Else
			return (n / 0x1000) - 0xFE
		EndIf
	EndIf
	
EndFunction


String Function DecToHex( Int n, Int lngth = 8 ) global

	String res = ""

	String[] hexaValues = New String[16]
	hexaValues[0] = "0"
	hexaValues[1] = "1"
	hexaValues[2] = "2"
	hexaValues[3] = "3"
	hexaValues[4] = "4"
	hexaValues[5] = "5"
	hexaValues[6] = "6"
	hexaValues[7] = "7"
	hexaValues[8] = "8"
	hexaValues[9] = "9"
	hexaValues[10] = "A"
	hexaValues[11] = "B"
	hexaValues[12] = "C"
	hexaValues[13] = "D"
	hexaValues[14] = "E"
	hexaValues[15] = "F"
	
	String[] hexaDeciNum = New String[lngth]
     
    Int i = 0
    While n != 0

        Int temp = 0
         
        temp = Mod( n, 16 )
         
		hexaDeciNum[i] = hexaValues[temp]
		i +=1 
		
        n = ( n / 16 )
    EndWhile
     
	Int k = i
	While lngth - k > 0
		res += "0"
		k += 1
	EndWhile
	
	Int j = i - 1
	While j >= 0
        res += hexaDeciNum[j]
		j -= 1
	EndWhile
	
	return res

EndFunction


Int Function Mod( Int a, Int b ) global

	Float x = a / b
	Int y = Math.Floor( x )
	
	return a - (b * y)

EndFunction


Int[] Function IntArrayPush( Int[] arr, Int val ) global native

Int[] Function AddInt( Int[] arr, Int val ) global

	If arr.Length < 128
		arr.Add( val )
		return arr
	Else
		return IntArrayPush( arr, val )
	EndIf

EndFunction


String[] Function StringArrayPush( String[] arr, String val ) global native

String[] Function AddString( String[] arr, String val ) global

	If arr.Length < 128
		arr.Add( val )
		return arr
	Else
		return StringArrayPush( arr, val )
	EndIf

EndFunction


ObjectReference[] Function ObjectReferenceArrayPush( ObjectReference[] arr, ObjectReference val ) global native

ObjectReference[] Function AddObjectReference( ObjectReference[] arr, ObjectReference val ) global

	If arr.Length < 128
		arr.Add( val )
		return arr
	Else
		return ObjectReferenceArrayPush( arr, val )
	EndIf

EndFunction

; convenience function to delete a reference from console to create a corrupted power node for testing purposes -- cgf "wsfwidentifier.delete" refId
Function Delete( ObjectReference akRefToRemove ) global
	
	akRefToRemove.Disable()
	akRefToRemove.Delete()
	
EndFunction


String Function GetFormInfo( Form akForm ) global
	
	Var[] params2 = New Var[2]
	params2[0] = "WSFW"
	params2[1] = akForm
	
	If akForm && akForm is ObjectReference
		return (Utility.CallGlobalFunction( "WSFW_Utility", "GetFormInfo", params2 ) as String) + " (" + GetFormIDHex( (akForm as ObjectReference).GetBaseObject().GetFormID() ) + ")"
	Else
		return Utility.CallGlobalFunction( "WSFW_Utility", "GetFormInfo", params2 ) as String
	EndIf

EndFunction


Function DebugLog( String asFunctionName, String asMessage ) global

	Debug.Trace( "WSFWIdentifier::" + asFunctionName + " " + asMessage )

EndFunction
