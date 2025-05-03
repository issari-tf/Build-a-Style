#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <clientprefs>
#include <tf2_stocks>
#include <string>

#define PLUGIN_VERSION "1.0"

public Plugin myinfo =
{
  name        = "BuildAStyle",
  author      = "Aidan Sanders",
  description	= "Build A Engineer Style",
  version	    = PLUGIN_VERSION,
  url         = "",
};

#define CONFIG_HATS "configs/BuildAStyle/BuildingHats.cfg"
#define CONFIG_PARTICLES "configs/BuildAStyle/BuildingParticles.cfg"
#define CONFIG_SPAWN_PARTICLES ""

Cookie g_hCookieBuildHats;
Cookie g_hCookieBuildColor;
Cookie g_hCookieBuildParticle;

enum ParticleType
{
  PARTICLE_DISPENSER,
  PARTICLE_SENTRY,
  PARTICLE_MAX
};

int g_PlayerParticles[MAXPLAYERS + 1][PARTICLE_MAX];

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Config
//////////////////////////////////////////////////////////////////////////////////////////

methodmap ConfigHats < StringMap
{
	public ConfigHats()
	{
		return view_as<ConfigHats>(new StringMap());
	}

	public void LoadSection(KeyValues kv)
	{
		if (!kv.GotoFirstSubKey(false))
		{
			LogError("[ConfigHats] No entries found in section.");
			return;
		}

		do
		{
			char model[PLATFORM_MAX_PATH];
			if (!kv.GetString("modelpath", model, sizeof(model)))
				continue; // Skip if modelpath is missing

			StringMap hatData = new StringMap();

			char buffer[PLATFORM_MAX_PATH];
			if (kv.GetString("offset", buffer, sizeof(buffer)))
				hatData.SetString("offset", buffer);

			if (kv.GetString("modelscale", buffer, sizeof(buffer)))
				hatData.SetString("modelscale", buffer);

			if (kv.GetString("animation", buffer, sizeof(buffer)))
				hatData.SetString("animation", buffer);

			// Store hatData under model name
			this.SetValue(model, hatData);

		} while (kv.GotoNextKey(false));

		kv.GoBack();
	}

	public bool GetHatByModel(const char[] hatModel, float &modelOffset, float &modelScale)
	{
		StringMap hatData;
		if (!this.GetValue(hatModel, hatData) || hatData == null)
			return false;

		char strScale[16], strOffset[16];

		if (!hatData.GetString("modelscale", strScale, sizeof(strScale)))
			strScale = "1.0";
		if (!hatData.GetString("offset", strOffset, sizeof(strOffset)))
			strOffset = "0.0";

		modelScale = StringToFloat(strScale);
		modelOffset = StringToFloat(strOffset);
		return true;
	}

	public void Unload()
	{
		this.Clear();
	}

  public int GetNumHats()
	{
		return this.Size;
	}
}

// Building Particles Config
methodmap ConfigParticles < StringMap
{
	public ConfigParticles()
	{
		return view_as<ConfigParticles>(new StringMap());
	}

	public void LoadSection(KeyValues kv)
	{
    if (!kv.GotoFirstSubKey(false))
		{
			LogError("[ConfigHats] No entries found in section.");
			return;
		}

		do
		{
			char sParticleName[128];
			if (kv.GetString("name", sParticleName, sizeof(sParticleName)))
				this.SetString(sParticleName, sParticleName);
		} 
    while (kv.GotoNextKey(false));

		kv.GoBack();
	}
}

ConfigHats g_ConfigHats;
ConfigParticles g_ConfigParticles;

void Config_Init()
{	
	g_ConfigHats = new ConfigHats();
  g_ConfigParticles = new ConfigParticles();
}

void Config_Refresh() 
{
  g_ConfigHats.Clear(); // Clear Hats
  g_ConfigParticles.Clear(); // Clear Hat Particles

  // Load every hat
  KeyValues kv = Config_LoadFile(CONFIG_HATS);
	if (kv == null) return;
  g_ConfigHats.LoadSection(kv);
  delete kv;

  // Load every particle
  kv = Config_LoadFile(CONFIG_PARTICLES);
	if (kv == null) return;
  g_ConfigParticles.LoadSection(kv);
  delete kv;

  Config_PrecacheAllHats();
  Config_PrecacheAllParticles();
}

KeyValues Config_LoadFile(const char[] sConfigFile)
{
	char sConfigPath[PLATFORM_MAX_PATH];
	
	BuildPath(Path_SM, sConfigPath, sizeof(sConfigPath), sConfigFile);
	if (!FileExists(sConfigPath))
	{
		LogMessage("Failed to load BuildAStyle config file (file missing): %s!", sConfigPath);
		return null;
	}
	
	KeyValues kv = new KeyValues("BuildAStyle");
	kv.SetEscapeSequences(true);

	if(!kv.ImportFromFile(sConfigPath))
	{
		LogMessage("Failed to parse vsh config file: %s!", sConfigPath);
		delete kv;
		return null;
	}
	
	return kv;
}


//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Core
//////////////////////////////////////////////////////////////////////////////////////////

public void OnPluginStart()
{
  Config_Init();
  Command_Init();
  
  g_hCookieBuildHats = RegClientCookie("building_hats", "Enable Building Hats", CookieAccess_Private);
  g_hCookieBuildColor = RegClientCookie("building_color", "Stores Color", CookieAccess_Private);
  g_hCookieBuildParticle = RegClientCookie("building_particle", "Enables Building Particle", CookieAccess_Private);

  HookEvent("player_builtobject",    Event_OnObjectBuilt);
  HookEvent("player_carryobject",    Event_OnObjectPickedUp);
  HookEvent("player_dropobject",     Event_OnObjectDropped);
  HookEvent("player_upgradedobject", Event_OnObjectUpgraded);
}

public void OnMapStart()
{
  Config_Refresh();
}

public void OnMapEnd()
{
  
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Commands
//////////////////////////////////////////////////////////////////////////////////////////
// List of Commands:
// style        | style_menu
// style_hats
// style_colors | style_theme
// style_spawn  | style_build

static char g_strCommandPrefix[][] = {
	"style",
	"style_",
  "build",
  "build_"
};

public void Command_Init()
{
	// Commands for everyone
	RegConsoleCmd("style", Command_MainMenu);
	
	Command_Create("menu", Command_MainMenu);
	Command_Create("hats", Command_BuildingHats);
  Command_Create("colors", Command_BuildingColors);
  Command_Create("spawn", Command_BuildingSpawn);
}

stock void Command_Create(const char[] sCommand, ConCmd callback)
{
	for (int i = 0; i < sizeof(g_strCommandPrefix); i++)
	{
		char sBuffer[256];
		Format(sBuffer, sizeof(sBuffer), "%s%s", g_strCommandPrefix[i], sCommand);
		RegConsoleCmd(sBuffer, callback);
	}
}

public Action Command_BuildingSpawn(int iClient, int iArgs)
{
  if (!IsClientInGame(iClient) || !IsClientAuthorized(iClient))
    return Plugin_Handled;

  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildParticle, sCookieValue, sizeof(sCookieValue));

  bool bEnabled = StrEqual(sCookieValue, "true");
  bEnabled = !bEnabled; // Toggle the value

  SetClientCookie(iClient, g_hCookieBuildParticle, bEnabled ? "true" : "false");

  PrintToChat(iClient, "[BuildingHats] Building Spawn Particle %s.", bEnabled ? "enabled" : "disabled");
  return Plugin_Handled;
}

public Action Command_MainMenu(int iClient, int iArgs)
{
  if (!IsClientInGame(iClient) || !IsClientAuthorized(iClient))
    return Plugin_Handled;

  Menu menu = new Menu(BuildAStyleMenuHandler);
  menu.SetTitle("BuildAStyle Menu");
  menu.AddItem("hats", "Toggle Building Hats");
  menu.AddItem("particle", "Toggle Building Particle");
  menu.AddItem("color", "Set Color");
  menu.AddItem("exit", "Exit");
  menu.Display(iClient, MENU_TIME_FOREVER);
  return Plugin_Handled;
}

public int BuildAStyleMenuHandler(Menu menu, MenuAction action, int iClient, int item)
{
  if (action == MenuAction_End)
  {
    delete menu;
  }
  else if (action == MenuAction_Select)
  {
    char info[32];
    menu.GetItem(item, info, sizeof(info));

    if (StrEqual(info, "hats"))
    {
      char sCookieValue[8];
      GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));

      bool bEnabled = StrEqual(sCookieValue, "true");
      bEnabled = !bEnabled; // Toggle the value

      SetClientCookie(iClient, g_hCookieBuildHats, bEnabled ? "true" : "false");

      PrintToChat(iClient, "[BuildingHats] Building hats %s.", bEnabled ? "enabled" : "disabled");
    }
    else if (StrEqual(info, "particle"))
    {
       char sCookieValue[8];
        GetClientCookie(iClient, g_hCookieBuildParticle, sCookieValue, sizeof(sCookieValue));

        bool bEnabled = StrEqual(sCookieValue, "true");
        bEnabled = !bEnabled; // Toggle the value

        SetClientCookie(iClient, g_hCookieBuildParticle, bEnabled ? "true" : "false");

        PrintToChat(iClient, "[BuildingHats] Building Spawn Particle %s.", bEnabled ? "enabled" : "disabled");
    }
    else if (StrEqual(info, "color"))
    {
      ShowColorMenu(iClient); // Show sub-menu
    }
    else if (StrEqual(info, "exit"))
    {
      // Optional: feedback on exit
      PrintToChat(iClient, "[BuildingHats] Menu closed.");
    }
  }

  return 0;
}

void ShowColorMenu(int client)
{
  Menu hMenu = new Menu(ColorMenuHandler);
  hMenu.SetTitle("Select a Color");
  hMenu.AddItem("#FFFFFF", "Default");
  hMenu.AddItem("#FF0000", "Red");
  hMenu.AddItem("#00FF00", "Green");
  hMenu.AddItem("#0000FF", "Blue");
  hMenu.AddItem("#FFFF00", "Yellow");
  hMenu.AddItem("#00FFFF", "Cyan");
  hMenu.AddItem("#FF00FF", "Magenta");
  hMenu.AddItem("back", "Back");
  hMenu.Display(client, MENU_TIME_FOREVER);
}

public int ColorMenuHandler(Menu menu, MenuAction action, int client, int item)
{
  if (action == MenuAction_End)
  {
    delete menu;
  }
  else if (action == MenuAction_Select)
  {
    char info[32];
    menu.GetItem(item, info, sizeof(info));

    if (StrEqual(info, "back"))
    {
      Command_MainMenu(client, 0); // Go back to main menu
    }
    else
    {
      // Handle color setting using existing logic
      int r, g, b;
      HexToRGB(info, r, g, b);

      int packed = (r << 16) | (g << 8) | b;
      char packedStr[16];
      IntToString(packed, packedStr, sizeof(packedStr));
      SetClientCookie(client, g_hCookieBuildColor, packedStr);

      PrintToChat(client, "[BuildingHats] Color set to RGB(%d, %d, %d).", r, g, b);
    }
  }

  return 0;
}

void HexToRGB(const char[] hex, int &r, int &g, int &b)
{
  char rStr[3], gStr[3], bStr[3];
  strcopy(rStr, sizeof(rStr), hex[1]);
  rStr[2] = '\0';
  strcopy(gStr, sizeof(gStr), hex[3]);
  gStr[2] = '\0';
  strcopy(bStr, sizeof(bStr), hex[5]);
  bStr[2] = '\0';

  StringToIntEx(rStr, r, 16);
  StringToIntEx(gStr, g, 16);
  StringToIntEx(bStr, b, 16);
}


public Action Command_BuildingHats(int iClient, int iArgs) 
{
  if (!IsClientInGame(iClient) || !IsClientAuthorized(iClient))
    return Plugin_Handled;

  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));

  bool bEnabled = StrEqual(sCookieValue, "true");
  bEnabled = !bEnabled; // Toggle the value

  SetClientCookie(iClient, g_hCookieBuildHats, bEnabled ? "true" : "false");

  PrintToChat(iClient, "[BuildingHats] Building hats %s.", bEnabled ? "enabled" : "disabled");
  return Plugin_Continue;
}

public Action Command_BuildingColors(int client, int args) 
{
  if (!IsClientInGame(client) || !IsClientAuthorized(client))
    return Plugin_Handled;

  if (args < 1)
  {
    PrintToChat(client, "[BuildingHats] Usage: !buildcolor #RRGGBB");
    return Plugin_Handled;
  }

  char sColor[32];
  GetCmdArg(1, sColor, sizeof(sColor));
  TrimString(sColor);

  if (sColor[0] != '#' || strlen(sColor) != 7)
  {
    PrintToChat(client, "[BuildingHats] Invalid format. Use #RRGGBB.");
    return Plugin_Handled;
  }

  // Extract color components
  char rStr[3], gStr[3], bStr[3];
  strcopy(rStr, sizeof(rStr), sColor[1]); rStr[2] = '\0';
  strcopy(gStr, sizeof(gStr), sColor[3]); gStr[2] = '\0';
  strcopy(bStr, sizeof(bStr), sColor[5]); bStr[2] = '\0';

  int r, g, b;
  if (!StringToIntEx(rStr, r, 16) || !StringToIntEx(gStr, g, 16) || !StringToIntEx(bStr, b, 16))
  {
    PrintToChat(client, "[BuildingHats] Failed to parse hex values.");
    return Plugin_Handled;
  }

  int packedColor = (r << 16) | (g << 8) | b;

  char sPacked[16];
  IntToString(packedColor, sPacked, sizeof(sPacked));
  SetClientCookie(client, g_hCookieBuildColor, sPacked);

  PrintToChat(client, "[BuildingHats] Color set to RGB(%d, %d, %d). (%i)", r, g, b, packedColor);
  return Plugin_Continue;
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Events
//////////////////////////////////////////////////////////////////////////////////////////

public Action Event_OnObjectBuilt(Event hEvent, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;
  
  // Get Client Object, if this object already has a hat, we don't want to attach another
  int iObjectEntity = hEvent.GetInt("index");
  if (!IsHattableObject(TF2_GetObjectType(iObjectEntity)) || IsValidEntity(GetObjectHat(iObjectEntity)))
    return Plugin_Handled;

  // Set Color Building
  char sColorCookieValue[16];
	GetClientCookie(iClient, g_hCookieBuildColor, sColorCookieValue, sizeof(sColorCookieValue));

  int packedColor = StringToInt(sColorCookieValue);
  int r, g, b;
  r = (packedColor >> 16) & 0xFF;
  g = (packedColor >> 8) & 0xFF;
  b = packedColor & 0xFF;
  SetEntityRenderColor(iObjectEntity, r, g, b, _);
  
  // Set Build Particle
  char sParticleCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildParticle, sParticleCookieValue, sizeof(sParticleCookieValue));
  if (StrEqual(sParticleCookieValue, "true")) 
    CreateTimer(3.0, RemoveEnt, EntIndexToEntRef(AttachParticle(iObjectEntity, "ghost_appearation", _, false)));
  
  // Does Client Have Hats Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  // Get Random Hat and Load from Config
  int iHatIndex = GetRandomInt(0, g_ConfigHats.GetNumHats() - 1);
  char sHatModel[PLATFORM_MAX_PATH];
  float flModelScale, flModelOffset;
  Config_GetHat(iHatIndex, sHatModel, flModelScale, flModelOffset);

  // Give Object Hat
  int iHatProp = CreateEntityByName("prop_dynamic_override");
  if (IsValidEntity(iHatProp))
  {
    SetEntityModel(iHatProp, sHatModel);
    DispatchSpawn(iHatProp);

    AcceptEntityInput(iHatProp, "DisableCollision");
    AcceptEntityInput(iHatProp, "DisableShadow");

    // Set the Parent's Hat
    ParentHat(iHatProp, iObjectEntity);
  }

  if (TF2_GetObjectType(iObjectEntity) == TFObject_Sentry && GetEntProp(iObjectEntity, Prop_Send, "m_bMiniBuilding"))
  {
    SetVariantInt(2);
    AcceptEntityInput(iObjectEntity, "SetBodyGroup");
    SDKHook(iObjectEntity, SDKHook_GetMaxHealth, SDK_ThinkLightsOff);
  }
  return Plugin_Continue;
}

public Action Event_OnObjectPickedUp(Event hEvent, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;

  // Does Client Have Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  int iObjectEntity = hEvent.GetInt("index");
  if (!IsHattableObject(TF2_GetObjectType(iObjectEntity)))
    return Plugin_Handled;

  int iHatProp = GetObjectHat(iObjectEntity);
  if (IsValidEntity(iHatProp))
    AcceptEntityInput(iHatProp, "TurnOff");
  
  return Plugin_Continue;
}

public Action Event_OnObjectDropped(Event hEvent, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;

  int iObjectEntity = hEvent.GetInt("index");
  if (!IsHattableObject(TF2_GetObjectType(iObjectEntity)))
    return Plugin_Handled;

  // Set Build Particle
  char sParticleCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildParticle, sParticleCookieValue, sizeof(sParticleCookieValue));
  if (StrEqual(sParticleCookieValue, "true")) 
    CreateTimer(3.0, RemoveEnt, EntIndexToEntRef(AttachParticle(iObjectEntity, "ghost_appearation", _, false)));
  
  // Does Client Have Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  int iHatProp = GetObjectHat(iObjectEntity);
  if (IsValidEntity(iHatProp))
  {
    AcceptEntityInput(iHatProp, "TurnOn");
    if(TF2_GetObjectType(iObjectEntity) == TFObject_Sentry && GetEntProp(iObjectEntity, Prop_Send, "m_bMiniBuilding"))
    {
      SetVariantInt(2);
      AcceptEntityInput(iObjectEntity, "SetBodyGroup");
      SDKHook(iObjectEntity, SDKHook_GetMaxHealth, SDK_ThinkLightsOff);
    }
  }
  return Plugin_Continue;
}


public Action Event_OnObjectUpgraded(Event hEvent, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;

  // Does Client Have Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  int iObjectEntity = hEvent.GetInt("index");
  if (!IsHattableObject(TF2_GetObjectType(iObjectEntity)))
    return Plugin_Handled;

  // don't need to re-parent hat if we're sitting on a level 1 
  // dispenser as the attachment point doesn't move
  if (TF2_GetObjectType(iObjectEntity) == TFObject_Dispenser && GetEntProp(iObjectEntity, Prop_Send, "m_iUpgradeLevel") == 1)
    return Plugin_Handled;

  int iHatProp = GetObjectHat(iObjectEntity);
  if (IsValidEntity(iHatProp))
  {
    if (TF2_GetObjectType(iObjectEntity) == TFObject_Dispenser)
      RemoveParticle(iClient, PARTICLE_DISPENSER);
    else 
      RemoveParticle(iClient, PARTICLE_SENTRY);
      
    // hide the hat while we re-parent it to the new model
    AcceptEntityInput(iHatProp, "TurnOff");

    // need to delay some time for the upgrade animation to complete
    CreateTimer(2.0, Timer_ReparentHat, iHatProp, TIMER_FLAG_NO_MAPCHANGE);
  }
  return Plugin_Continue;
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 SDK
//////////////////////////////////////////////////////////////////////////////////////////

public Action SDK_ThinkLightsOff(int iEntity)
{
  float flPercentageConstructed = GetEntPropFloat(iEntity, Prop_Send, "m_flPercentageConstructed");
  if (flPercentageConstructed >= 1.0)
  {
    SDKUnhook(iEntity, SDKHook_GetMaxHealth, SDK_ThinkLightsOff);
    RequestFrame(SDK_TurnOffLight, iEntity);	//One more frame
  }
  return Plugin_Continue;
}

public void SDK_TurnOffLight(int iEntity)
{
  SetVariantInt(2);
  AcceptEntityInput(iEntity, "SetBodyGroup");
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Timers
//////////////////////////////////////////////////////////////////////////////////////////

public Action Timer_ReparentHat(Handle hTimer, int iData)
{
  int iHatProp = iData;
  if (!IsValidEntity(iHatProp)) // Hat prop disappeared
    return Plugin_Handled;

  int iObjectEntity = GetEntPropEnt(iHatProp, Prop_Data, "m_hMoveParent");
  if (!IsValidEntity(iObjectEntity))
    return Plugin_Handled;

  ParentHat(iHatProp, iObjectEntity);

  // display the hat again
  AcceptEntityInput(iHatProp, "TurnOn");

  return Plugin_Continue;
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Stocks
//////////////////////////////////////////////////////////////////////////////////////////

stock void RemoveParticle(int client, ParticleType type)
{
    int ref = g_PlayerParticles[client][type];
    int ent = EntRefToEntIndex(ref);

    if (IsValidEntity(ent))
    {
        AcceptEntityInput(ent, "Stop");
        AcceptEntityInput(ent, "Kill");
        g_PlayerParticles[client][type] = INVALID_ENT_REFERENCE;
    }
}

stock void GiveObjectHat(int objectEnt, const char hatModel[PLATFORM_MAX_PATH])
{
  int hatProp = CreateEntityByName("prop_dynamic_override");

  if (IsValidEntity(hatProp))
  {
    SetEntityModel(hatProp, hatModel);
    DispatchSpawn(hatProp);

    AcceptEntityInput(hatProp, "DisableCollision");
    AcceptEntityInput(hatProp, "DisableShadow");

    ParentHat(hatProp, objectEnt);
  }
}

stock int GetObjectHat(int objectEnt)
{
  int ent = -1;

  while((ent = FindEntityByClassname(ent, "prop_dynamic")) != -1)
  {
    int parent = GetEntPropEnt(ent, Prop_Data, "m_hMoveParent");

    if (parent == objectEnt)
    {
      // prop is parented to our object, so it's most likely our hat
      return ent;
    }
  }

  return -1;
}

public Action RemoveEnt(Handle timer, any entid) {
	int ent = EntRefToEntIndex(entid);
	if( ent > 0 && IsValidEntity(ent) ) {
		AcceptEntityInput(ent, "Kill");
	}
	return Plugin_Continue;
}

stock int AttachParticle(const int ent, const char[] particleType, float offset = 0.0, bool battach = true) {
  
  int particle = CreateEntityByName("info_particle_system");

  float pos[3], rot[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
  pos[2] += offset;
  OffsetAttachmentPosition(ent, pos, rot);

  TeleportEntity(particle, pos, NULL_VECTOR, NULL_VECTOR);
    
  char tName[32];
  Format(tName, sizeof(tName), "target%i", ent);
  DispatchKeyValue(ent, "targetname", tName);
  DispatchKeyValue(particle, "targetname", "tf2particle");
  DispatchKeyValue(particle, "parentname", tName);
  DispatchKeyValue(particle, "effect_name", particleType);
  DispatchSpawn(particle);
  SetVariantString(tName);
  if( battach ) {
    char attachmentName[128];
    GetAttachmentName(ent, attachmentName, sizeof(attachmentName));

    SetVariantString("!activator");
    AcceptEntityInput(particle, "SetParent", ent);

    SetVariantString(attachmentName);
    AcceptEntityInput(particle, "SetParentAttachment", ent);
  }
  ActivateEntity(particle);
  AcceptEntityInput(particle, "start");

  return particle;
}

stock void ParentHat(int hatProp, int objectEnt)
{
  char hatModel[PLATFORM_MAX_PATH];
  GetEntPropString(hatProp, Prop_Data, "m_ModelName", hatModel, sizeof(hatModel));

  float modelScale = 1.0;
  float modelOffset = 0.0;

  if (!g_ConfigHats.GetHatByModel(hatModel, modelOffset, modelScale))//Config_GetHatByModel(hatModel, modelOffset, modelScale))
  {
    LogError("Unable to find hat config for hat: %s", hatModel);
    return;
  }
    
  // Get a random particle name from ConfigParticles
  StringMapSnapshot snapshot = g_ConfigParticles.Snapshot();
  if (snapshot == null)
  {
    PrintToServer("[ConfigHats] Failed to get snapshot.");
    return;
  }
  char sParticleName[128];
  int iParticleIndex = GetRandomInt(0, g_ConfigParticles.Size - 1);
  snapshot.GetKey(iParticleIndex, sParticleName, sizeof(sParticleName));
  int particle = AttachParticle(objectEnt, sParticleName, modelOffset);

  int builder = GetEntPropEnt(objectEnt, Prop_Send, "m_hBuilder");
  if (TF2_GetObjectType(objectEnt) == TFObject_Dispenser)
    g_PlayerParticles[builder][PARTICLE_DISPENSER] = EntIndexToEntRef(particle);
  else 
    g_PlayerParticles[builder][PARTICLE_SENTRY] = EntIndexToEntRef(particle);


  SetEntProp(hatProp, Prop_Send, "m_nSkin", GetClientTeam(builder) - 2);
  SetEntPropFloat(hatProp, Prop_Send, "m_flModelScale", modelScale);

  char attachmentName[128];
  GetAttachmentName(objectEnt, attachmentName, sizeof(attachmentName));

  SetVariantString("!activator");
  AcceptEntityInput(hatProp, "SetParent", objectEnt);

  SetVariantString(attachmentName);
  AcceptEntityInput(hatProp, "SetParentAttachment", objectEnt);

  float pos[3], rot[3];
  GetEntPropVector(hatProp, Prop_Send, "m_vecOrigin", pos);
  GetEntPropVector(hatProp, Prop_Send, "m_angRotation", rot);

  pos[2] += modelOffset;

  OffsetAttachmentPosition(objectEnt, pos, rot);
  TeleportEntity(hatProp, pos, rot, NULL_VECTOR);
}

stock void GetAttachmentName(int objectEnt, char[] attachmentBuffer, int maxBuffer)
{
  switch (TF2_GetObjectType(objectEnt))
  {
    case TFObject_Dispenser:
      strcopy(attachmentBuffer, maxBuffer, "build_point_0");

    case TFObject_Sentry:
    {
      if (GetEntProp(objectEnt, Prop_Send, "m_iUpgradeLevel") < 3)
      {
        strcopy(attachmentBuffer, maxBuffer, "build_point_0");
      }
      else
      {
        // for level 3 sentries we can use the rocket launcher attachment
        strcopy(attachmentBuffer, maxBuffer, "rocket_r");
      }
    }
  }
}

stock void OffsetAttachmentPosition(int objectEnt, float pos[3], float ang[3])
{
  switch (TF2_GetObjectType(objectEnt))
  {
    case TFObject_Dispenser:
    {
      pos[2] += 13.0; // build_point_0 is a little low on the dispenser, bring it up
      ang[1] += 180.0; // turn the hat around to face the builder

      if (GetEntProp(objectEnt, Prop_Send, "m_iUpgradeLevel") == 3)
        pos[2] += 8.0; // level 3 dispenser is even taller
    }

    case TFObject_Sentry:
    {
      if (GetEntProp(objectEnt, Prop_Send, "m_iUpgradeLevel") == 3)
      {
        pos[2] += 6.5;
        pos[0] -= 11.0;
      }
    }
  }
}

stock bool IsHattableObject(TFObjectType objectEnt)
{
  // only parent hats to sentries and dispensers
  return objectEnt == TFObject_Sentry || objectEnt == TFObject_Dispenser;
}

stock void Config_PrintAllHats()
{
	int count = g_ConfigHats.Size;
	PrintToServer("[ConfigHats] Loaded Hat Count: %d", count);

	StringMapSnapshot snapshot = g_ConfigHats.Snapshot();
	if (snapshot == null)
	{
		PrintToServer("[ConfigHats] Failed to get snapshot.");
		return;
	}

	for (int i = 0; i < snapshot.Length; i++)
	{
		char model[PLATFORM_MAX_PATH];
		snapshot.GetKey(i, model, sizeof(model));

		StringMap hatData;
		if (!g_ConfigHats.GetValue(model, hatData) || hatData == null)
		{
			PrintToServer("  [%d] %s: NULL HatData", i, model);
			continue;
		}

		char offset[32], scale[32], anim[PLATFORM_MAX_PATH];

		bool hasOffset = hatData.GetString("offset", offset, sizeof(offset));
		bool hasScale = hatData.GetString("modelscale", scale, sizeof(scale));
		bool hasAnim  = hatData.GetString("animation", anim, sizeof(anim));

		PrintToServer("  Hat [%d] Model: %s", i, model);
		PrintToServer("    offset    : %s", hasOffset ? offset : "N/A");
		PrintToServer("    modelscale: %s", hasScale ? scale : "N/A");
		PrintToServer("    animation : %s", hasAnim  ? anim  : "N/A");
	}

	delete snapshot;
}

// Get Random Hat From Config by index into snapshot list
stock void Config_GetHat(int iHatIndex, char sHatModel[PLATFORM_MAX_PATH], float &flModelScale, float &flModelOffset)
{
	StringMapSnapshot snapshot = g_ConfigHats.Snapshot();
	if (snapshot == null || iHatIndex < 0 || iHatIndex >= snapshot.Length)
	{
		PrintToServer("[ConfigHats] Invalid hat index: %d", iHatIndex);
		LogError("[ConfigHats] Invalid hat index: %d", iHatIndex);
		sHatModel[0] = '\0';
		flModelScale = 0.0;
		flModelOffset = 0.0;
		return;
	}

	char sModel[PLATFORM_MAX_PATH];
	snapshot.GetKey(iHatIndex, sModel, sizeof(sModel));

	StringMap hHatData;
	if (!g_ConfigHats.GetValue(sModel, hHatData) || hHatData == null)
	{
		PrintToServer("[ConfigHats] Failed to retrieve data for hat model: %s", sModel);
		sHatModel[0] = '\0';
		flModelScale = 0.0;
		flModelOffset = 0.0;
		delete snapshot;
		return;
	}

	char sScale[16], sOffset[16];

	if (!hHatData.GetString("modelscale", sScale, sizeof(sScale)))
		strcopy(sScale, sizeof(sScale), "1.0");

	if (!hHatData.GetString("offset", sOffset, sizeof(sOffset)))
		strcopy(sOffset, sizeof(sOffset), "0.0");

	strcopy(sHatModel, PLATFORM_MAX_PATH, sModel);
	flModelScale = StringToFloat(sScale);
	flModelOffset = StringToFloat(sOffset);

	delete snapshot;
}

stock void Config_PrecacheAllHats()
{
	int count = g_ConfigHats.Size;
	PrintToServer("[ConfigHats] Precaching %d Hat(s)...", count);

	StringMapSnapshot snapshot = g_ConfigHats.Snapshot();
	if (snapshot == null)
	{
		LogError("[ConfigHats] Failed to create snapshot for precache.");
		return;
	}

	for (int i = 0; i < snapshot.Length; i++)
	{
		char model[PLATFORM_MAX_PATH];
		snapshot.GetKey(i, model, sizeof(model));

		StringMap hatData;
		if (!g_ConfigHats.GetValue(model, hatData) || hatData == null)
		{
			LogError("  [%d] %s: NULL HatData", i, model);
			continue;
		}

		// The model string is the actual path to the model to precache
		if (model[0] != '\0')
		{
			PrecacheModel(model, true);
			PrintToServer("  [%d] Precaching Hat Model: %s", i, model);
		}
		else
		{
			LogError("  [%d] Empty model string for hat", i);
		}
	}

	delete snapshot;
}

stock void Config_PrecacheAllParticles()
{
	int count = g_ConfigParticles.Size;
	PrintToServer("[ConfigParticles] Precaching %d Particle(s)...", count);

	StringMapSnapshot snapshot = g_ConfigParticles.Snapshot();
	if (snapshot == null)
	{
		LogError("[ConfigParticles] Failed to create snapshot for precaching.");
		return;
	}

	for (int i = 0; i < snapshot.Length; i++)
	{
		char particleName[128];
		if (snapshot.GetKey(i, particleName, sizeof(particleName)))
		{
			// Assuming you have a function to precache particles
			PrecacheModel(particleName);

			// Print out the precache info
			PrintToServer("  [%d] Precaching Particle: %s", i, particleName);
		}
	}

	delete snapshot;
}


stock void Config_PrintAllParticles()
{
	int count = g_ConfigParticles.Size;
	PrintToServer("[ConfigParticles] Loaded Particle Count: %d", count);

	StringMapSnapshot snapshot = g_ConfigParticles.Snapshot();
	if (snapshot == null)
	{
		LogError("[ConfigParticles] Failed to create snapshot for printing.");
		return;
	}

	for (int i = 0; i < snapshot.Length; i++)
	{
		char particleName[128];
		if (snapshot.GetKey(i, particleName, sizeof(particleName)))
		{
			PrintToServer("  [%d] Particle Name: %s", i, particleName);
		}
	}

	delete snapshot;
}