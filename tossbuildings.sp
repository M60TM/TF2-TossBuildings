#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <smlib>
#include <vphysics>
#include <tf2utils>

#tryinclude <tf2hudmsg>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "22w22a"

public Plugin myinfo = {
	name = "[TF2] Toss Buildings",
	description = "Use your reload button to toss carried buildings",
	author = "reBane, zen",
	version = PLUGIN_VERSION,
	url = "N/A",
};

enum {
	BUILDING_INVALID_OBJECT = ((1<<8)-1), // s8_t:-1
	BUILDING_DISPENSER = 0,
	BUILDING_TELEPORTER,
	BUILDING_SENTRYGUN,
	BUILDING_ATTACHMENT_SAPPER,
}
enum {
	BS_IDLE,
	BS_SELECTING,
	BS_PLACING,
	BS_PLACING_INVALID,
};

bool g_bPlayerThrow[MAXPLAYERS+1];
Handle sdk_fnStartBuilding;
//Handle sdk_fnIsPlacementPosValid;
ArrayList g_aAirbornObjects;
float g_flClientLastBeep[MAXPLAYERS+1];
float g_flClientLastNotif[MAXPLAYERS+1]; //for hud notifs, as those make noise

#define TBLOCK_WFP (1<<0)
int g_iBlockFlags;
#define TBFLAG_DISPENSER (1<<BUILDING_DISPENSER)
#define TBFLAG_TELEPORTER (1<<BUILDING_TELEPORTER)
#define TBFLAG_SENTRYGUN (1<<BUILDING_SENTRYGUN)
int g_iBlockTypes;
float g_flThrowForce;

GlobalForward g_fwdToss, g_fwdTossPost, g_fwdLanded;

bool g_bDepHudMsg; //for fancy messages

public void OnPluginStart() {
	GameData data = new GameData("tbobj.games");
	if (data == null)
		SetFailState("Could not load gamedata: File is missing");
	
	StartPrepSDKCall(SDKCall_Entity); //weapon
	PrepSDKCall_SetFromConf(data, SDKConf_Signature, "StartBuilding");
	if ((sdk_fnStartBuilding = EndPrepSDKCall())==null)
		SetFailState("Could not load gamedata: StartBuilding Signature missing or outdated");
	
//	StartPrepSDKCall(SDKCall_Entity); //building
//	PrepSDKCall_SetFromConf(data, SDKConf_Virtual, "IsPlacementPosValid");
//	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
//	if ((sdk_fnIsPlacementPosValid = EndPrepSDKCall())==null)
//		SetFailState("Could not load gamedata: IsPlacementPosValid Offset missing or outdated");
	
	delete data;
	
	ConVar cvarTypes = CreateConVar("sm_toss_building_types", "dispenser teleporter sentrygun", "Space separated list of building names that can be tossed: Dispenser Teleporter Sentrygun");
	ConVar cvarForce = CreateConVar("sm_toss_building_force", "520", "Base force to use when throwing buildings", _, true, 100.0, true, 10000.0);
	cvarTypes.AddChangeHook(OnTossBuildingTypesChanged);
	cvarForce.AddChangeHook(OnTossBuildingForceChanged);
	//always load values on startup
	char buffer[128];
	cvarTypes.GetString(buffer, sizeof(buffer));
	OnTossBuildingTypesChanged(cvarTypes, buffer, buffer);
	OnTossBuildingForceChanged(cvarForce, NULL_STRING, NULL_STRING);//doesn't use passed string
	//load actual values from config
	AutoExecConfig();
	PrintToServer("Types: %i, Force: %f", g_iBlockTypes, g_flThrowForce);
	
	ConVar cvarVersion = CreateConVar("sm_toss_building_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	cvarVersion.AddChangeHook(LockConVar);
	cvarVersion.SetString(PLUGIN_VERSION);
	delete cvarVersion;
	
	HookEvent("player_carryobject", OnPlayerCarryObject);
	HookEvent("player_builtobject", OnPlayerBuiltObject);
	HookEvent("player_dropobject", OnPlayerBuiltObject);
	
	g_aAirbornObjects = new ArrayList(3); //phys parent, object, thrown angle (yaw)
	
	//let other plugins integrate :)
	g_fwdToss = CreateGlobalForward("TF2_OnTossBuilding", ET_Event, Param_Cell, Param_Cell, Param_Cell);
	g_fwdTossPost = CreateGlobalForward("TF2_OnTossBuildingPost", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	g_fwdLanded = CreateGlobalForward("TF2_OnBuildingLanded", ET_Ignore, Param_Cell, Param_Cell);
}
public void LockConVar(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!StrEqual(newValue, PLUGIN_VERSION)) convar.SetString(PLUGIN_VERSION);
}
public void OnTossBuildingTypesChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (StrContains(newValue, "dispenser", false)>=0) {
		g_iBlockTypes &=~ TBFLAG_DISPENSER;
	} else {
		g_iBlockTypes |= TBFLAG_DISPENSER;
	}
	if (StrContains(newValue, "teleporter", false)>=0) {
		g_iBlockTypes &=~ TBFLAG_TELEPORTER;
	} else {
		g_iBlockTypes |= TBFLAG_TELEPORTER;
	}
	if (StrContains(newValue, "sentry", false)>=0) {
		g_iBlockTypes &=~ TBFLAG_SENTRYGUN;
	} else {
		g_iBlockTypes |= TBFLAG_SENTRYGUN;
	}
}
public void OnTossBuildingForceChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_flThrowForce = convar.FloatValue;
}

public void OnMapStart() {
	g_aAirbornObjects.Clear();
	CreateTimer(0.1, Timer_PlaceBuildings, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);	
}

public void OnClientDisconnect(int client) {
	g_bPlayerThrow[client] = false;
	g_flClientLastBeep[client] = 0.0;
	g_flClientLastNotif[client] = 0.0;
}

public void OnAllPluginsLoaded() {
	g_bDepHudMsg = LibraryExists("tf2hudmsg");
}
public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "tf2hudmsg")) g_bDepHudMsg = true;
}
public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "tf2hudmsg")) g_bDepHudMsg = false;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	if (!(1<=client<=MaxClients) || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Continue;
	if ((buttons & IN_RELOAD)!=0 && !g_bPlayerThrow[client]) {
		if ( IsThrowBlocked(client) ) {
			if (GetClientTime(client) - g_flClientLastNotif[client] >= 1.0) {
				g_flClientLastNotif[client] = GetClientTime(client);
				HudNotify(client, "You can't toss this building");
			}
		} else {
			//trigger force build and throw on Reload
			g_bPlayerThrow[client] = true;
			if (CheckThrowPos(client)) StartBuilding(client);
			g_bPlayerThrow[client] = false;
		}
	}
	return Plugin_Continue;
}

public void OnPlayerCarryObject(Event event, const char[] name, bool dontBroadcast) {
	int owner = GetClientOfUserId(event.GetInt("userid"));
	int objecttype = event.GetInt("object");
	int building = event.GetInt("index");
	if ((BUILDING_DISPENSER <= objecttype <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && ( g_iBlockTypes&(1<<objecttype) )==0) {
		HudNotify(owner, "Press [RELOAD] to toss the building");
	}
}
public void OnPlayerBuiltObject(Event event, const char[] name, bool dontBroadcast) {
	int owner = GetClientOfUserId(event.GetInt("userid"));
	int objecttype = event.GetInt("object");
	int building = event.GetInt("index");
	
	if ((BUILDING_DISPENSER <= objecttype <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && g_bPlayerThrow[owner]) {
		g_bPlayerThrow[owner] = false;
		RequestFrame(ThrowBuilding,EntIndexToEntRef(building));
	}
}

public void TF2_OnWaitingForPlayersStart() {
	g_iBlockFlags |= TBLOCK_WFP;
}
public void TF2_OnWaitingForPlayersEnd() {
	g_iBlockFlags &=~ TBLOCK_WFP;
}

public Action Timer_PlaceBuildings(Handle timer) {
	ValidateThrown();
}

public bool TEF_HitSelfFilter(int entity, int contentsMask, any data) {
	return entity > MaxClients && entity != data;
}
public void ThrowBuilding(any buildref) {
	int building = EntRefToEntIndex(buildref);
	if (building == INVALID_ENT_REFERENCE) return;
	int owner = GetEntPropEnt(building, Prop_Send, "m_hBuilder");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner)) return;
	int type = GetEntProp(building, Prop_Send, "m_iObjectType");
	
	if (g_fwdToss.FunctionCount>0) {
		Action result;
		Call_StartForward(g_fwdToss);
		Call_PushCell(building);
		Call_PushCell(type);
		Call_PushCell(owner);
		if (Call_Finish(result) != SP_ERROR_NONE || result != Plugin_Continue) {
			return;
		}
	}
	
	float eyes[3];
	float origin[3];
	float angles[3];
	float fwd[3];
	float velocity[3];
	GetClientEyePosition(owner, origin);
	eyes = origin;
	//set origin in front of player
	GetClientEyeAngles(owner, angles);
	angles[0]=angles[2]=0.0;
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 64.0);
	AddVectors(origin, fwd, origin);
	//get angles/velocity
	GetClientEyeAngles(owner, angles);
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, g_flThrowForce);
	fwd[2] += (g_flThrowForce/3.25);//bit more archy
	Entity_GetAbsVelocity(owner, velocity);
	AddVectors(velocity, fwd, velocity);
	
	int phys = CreateEntityByName("prop_physics_multiplayer");
	if (phys == INVALID_ENT_REFERENCE) return;
	
	char buffer[PLATFORM_MAX_PATH];
	switch (type) {
		case BUILDING_SENTRYGUN: DispatchKeyValue(phys, "model", "models/buildables/sentry1.mdl");
		case BUILDING_DISPENSER: DispatchKeyValue(phys, "model", "models/buildables/dispenser_light.mdl");
		case BUILDING_TELEPORTER: DispatchKeyValue(phys, "model", "models/buildables/teleporter_light.mdl");
	}
	DispatchKeyValue(phys, "physicsmode", "1");
	DispatchKeyValueVector(phys, "origin", origin);
	DispatchKeyValueVector(phys, "angles", angles);
	Format(buffer, sizeof(buffer), "%i", GetEntProp(building, Prop_Send, "m_nSkin"));
	DispatchKeyValue(phys, "skin", buffer);
	if (GetEntProp(building, Prop_Send, "m_bDisposableBuilding")) buffer = "0.66";
	else if (GetEntProp(building, Prop_Send, "m_bMiniBuilding")) buffer = "0.75";
	else buffer = "1.0";
	DispatchKeyValue(phys, "modelscale", buffer);//mini sentries are .75
	DispatchKeyValue(phys, "solid", "6");
	if (!DispatchSpawn(phys)) {
		PrintToChat(owner, "Failed to spawn sentry prop");
		return;
	}
	ActivateEntity(phys);
	
	SetEntProp(building, Prop_Send, "m_bDisabled", 1);
	Entity_SetSolidFlags(building, FSOLID_NOT_SOLID);
	SetEntityRenderMode(building, RENDER_NONE);
	TeleportEntity(building, origin, NULL_VECTOR, NULL_VECTOR);
	SetVariantString("!activator");
	AcceptEntityInput(building, "SetParent", phys);
	Phys_ApplyForceCenter(phys, velocity);// works best
	
	any onade[3];
	onade[0]=EntIndexToEntRef(phys);
	onade[1]=EntIndexToEntRef(building);
	onade[2]=angles[1];
	g_aAirbornObjects.PushArray(onade);
	
	if (g_fwdTossPost.FunctionCount>0) {
		Call_StartForward(g_fwdToss);
		Call_PushCell(building);
		Call_PushCell(type);
		Call_PushCell(owner);
		Call_Finish();
	}
}

public bool TEF_HitThrownFilter(int entity, int contentsMask, any data) {
	int edicts[3];
	g_aAirbornObjects.GetArray(data,edicts);
	return entity > MaxClients && entity != EntRefToEntIndex(edicts[0]) && entity != EntRefToEntIndex(edicts[1]);
}

void ValidateThrown() {
	for (int i=g_aAirbornObjects.Length-1; i>=0; i--) {
		any data[3];
		g_aAirbornObjects.GetArray(i,data);
		int phys = EntRefToEntIndex(data[0]);
		int obj = EntRefToEntIndex(data[1]);
		float yaw = data[2];
		//if at least one of the entities went away, something went wrong
		// -> remove and continue
		if (!IsValidEdict(phys)) {
			if (IsValidEdict(obj)) AcceptEntityInput(obj, "Kill");
			g_aAirbornObjects.Erase(i);
			PrintToServer("Phys entity invalid");
			continue;
		} else if (!IsValidEdict(obj)) {
			if (IsValidEdict(phys)) AcceptEntityInput(phys, "Kill");
			g_aAirbornObjects.Erase(i);
			PrintToServer("Building entity invalid");
			continue;
		}
		
		float pos[3], vec[3];
		Entity_GetAbsOrigin(phys, pos);
		vec = pos;
		vec[2] -= 16.0;
		pos[2] += 8.0;
		Handle trace = TR_TraceRayFilterEx(pos, vec, MASK_SOLID, RayType_EndPoint, TEF_HitThrownFilter, i);
		if (!TR_DidHit(trace)) {
			delete trace;
			continue; //no ground below (FL_ONGROUND failed?)
		} else {
			TR_GetEndPosition(pos, trace);
			TR_GetPlaneNormal(trace, vec); //vanilla is not checking this
			delete trace;
			//check surface slope
			float up[3]; up[2]=1.0;
			float slope = ArcCosine( GetVectorDotProduct(vec, up) ) * 180.0/3.1415927;
			if (slope > 35.0) {
				//this slope is too steep to place a building
				continue;
			}
			//construct angles by random direction, using standard right to get propper forward
			float angles[3];
			angles[1]=yaw;
			//clear parent
			AcceptEntityInput(obj, "ClearParent");
			//fix building
			float zeros[3];
			TeleportEntity(obj, pos, angles, zeros); //use 0-velocity to calm down bouncyness
			//restore other props
			SetEntProp(obj, Prop_Send, "m_bDisabled", 0);
			Entity_RemoveSolidFlags(obj, FSOLID_NOT_SOLID);
			SetEntityRenderMode(obj, RENDER_NORMAL);
			//check valid
			CreateTimer(0.1, ValidateBuilding, EntIndexToEntRef(obj), TIMER_FLAG_NO_MAPCHANGE);
		}
		RemoveEntity(phys);
		g_aAirbornObjects.Erase(i);
	}
}

/** Invalid preconditions PASS! as this is used for message printing only */
bool IsThrowBlocked(int client) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return false;
	int weapon = Client_GetActiveWeapon(client);
	int item = IsValidEdict(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return false; //require builder
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return false; //currently not placing
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		RequestFrame(FixNoObjectBeingHeld, GetClientUserId(client));
		return false; //no object being buil!?
	}
	int type = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return false; //supported buildings, not always correct on weapon_builder
	
	return ( g_iBlockTypes&(1<<type) )!=0;
}

bool CheckThrowPos(int client) {
	if (g_iBlockFlags != 0) return false;
	float eyes[3];
	float origin[3];
	float angles[3];
	float fwd[3];
	GetClientEyePosition(client, origin);
	eyes = origin;
	//set origin in front of player
	GetClientEyeAngles(client, angles);
	angles[0]=angles[2]=0.0;
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 64.0);
	AddVectors(origin, fwd, origin);
	//ensure we see the target
	Handle trace = TR_TraceRayFilterEx(eyes, origin, MASK_SOLID, RayType_EndPoint, TEF_HitSelfFilter, client);
	bool hit = TR_DidHit(trace);
	delete trace;
	//can't see throw point (prevent through walls)? make noise
	if (hit) Beep(client);
	return !hit;
}

bool StartBuilding(int client) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return false;
	int weapon = Client_GetActiveWeapon(client);
	int item = IsValidEdict(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return false; //require builder
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return false; //currently not placing
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		RequestFrame(FixNoObjectBeingHeld, GetClientUserId(client));
		return false; //no object being buil!?
	}
	int type = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return false; //supported buildings, not always correct on weapon_builder
	
	SetEntPropEnt(weapon, Prop_Send, "m_hOwner", client);
	SetEntProp(weapon, Prop_Send, "m_iBuildState", BS_PLACING); //if placing_invalid
	SDKCall(sdk_fnStartBuilding, weapon);
	return true;
}

void FixNoObjectBeingHeld(int user) {
	//go through all validation again
	int client = GetClientOfUserId(user);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	int weapon = Client_GetActiveWeapon(client);
	int item = IsValidEdict(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return; //weapon switched
	int type = GetEntProp(weapon, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return; //unsupported building
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return; //not in a glitched state
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		//holding empty box, try to find another weapon to switch to
		for (int i=2;i>=0;i-=1) {
			weapon = Client_GetWeaponBySlot(client, i);
			if (weapon != INVALID_ENT_REFERENCE) {
				Client_SetActiveWeapon(client, weapon);
			}
		}
	}
}

//crashes, idk why
//bool IsPlacementPosValid(int building) {
//	char classname[64];
//	if (!IsValidEdict(building)
//	|| !GetEntityClassname(building, classname, sizeof(classname))
//	|| !(StrEqual(classname, "obj_sentrygun")
//	   || StrEqual(classname, "obj_teleporter")
//	   || StrEqual(classname, "obj_dispenser")
//	   ))
//		ThrowError("Entity is not a building");
//	return SDKCall(sdk_fnIsPlacementPosValid, building);
//}

public Action ValidateBuilding(Handle timer, any building) {
	int obj = EntRefToEntIndex(building);
	if (obj == INVALID_ENT_REFERENCE) return Plugin_Stop;
	
	float mins[3],maxs[3],origin[3];
	float four[3];
	four[0]=four[1]=four[2]=4.0;
	Entity_GetAbsOrigin(obj,origin);
	Entity_GetMinSize(obj,mins);
	Entity_GetMaxSize(obj,maxs);
	AddVectors(mins,four,mins);
	SubtractVectors(maxs,four,maxs);
	
	Handle trace = TR_TraceHullFilterEx(origin, origin, mins, maxs, MASK_SOLID, TEF_HitSelfFilter, obj);
	bool invalid = TR_DidHit(trace) || TF2Util_IsPointInRespawnRoom(origin, obj);
	delete trace;
	if (invalid) {
		SetVariantInt(1000);
		AcceptEntityInput(obj, "RemoveHealth");
	}
	if (g_fwdLanded.FunctionCount>0) {
		Call_StartForward(g_fwdLanded);
		Call_PushCell(building);
		Call_PushCell(!invalid);
		Call_Finish();
	}
	return Plugin_Stop;
}

void Beep(int client) {
	if (!(1<=client<=MaxClients) || !IsClientInGame(client) || IsFakeClient(client)) return;
	if (GetClientTime(client) - g_flClientLastBeep[client] >= 1.0) {
		g_flClientLastBeep[client] = GetClientTime(client);
		EmitSoundToClient(client, "common/wpn_denyselect.wav");//should aready be precached by game
	}
}

void HudNotify(int client, const char[] format, any ...) {
	char buffer[128];
	VFormat(buffer, sizeof(buffer), format, 3);
#if defined _inc_tf2hudmsg
	if (g_bDepHudMsg)
//		TF2_HudNotificationCustom(client, "obj_status_icon_wrench", TFTeam_Red, _, "%s", buffer);
		TF2_HudNotificationCustom(client, "ico_build", TFTeam_Red, _, "%s", buffer);
	else
		PrintHintText(client, "%s", buffer);
#else
	PrintHintText(client, "%s", buffer);
#endif
}