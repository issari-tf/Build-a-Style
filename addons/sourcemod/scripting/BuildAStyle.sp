#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <tf2_stocks>
#include <string>

#define PLUGIN_VERSION "1.0"

public Plugin myinfo =
{
  name        = "BuildAStyle",
  author      = "Aidan Sanders",
  description	= "Build A Style",
  version	    = PLUGIN_VERSION,
  url         = "",
};

// GraveStones:
#define DEATH_PHRASE_COUNT     5
// maximum length of death quote string
#define MAX_EPITAPH_LENGTH 	   96
// distance to raise annotations for epitaphs
#define ANNOTATION_HEIGHT      50.0
// distance to raise alert annotations
#define ANNOTATION_NAME_HEIGHT 20.0  
// distance to sink stones into the ground
#define OFFSET_HEIGHT          -2.0  

// contents mask to spawn stones on
#define MASK_PROP_SPAWN (CONTENTS_SOLID|CONTENTS_WINDOW|CONTENTS_GRATE)
// max distance to spawn stones beneath players
#define MAX_SPAWN_DISTANCE     1024.0  
// sound file to play for non-audible sounds
#define SOUND_NULL             "vo/null.wav" 
// how fast to tick updates to the hud
#define HUDUPDATERATE          0.5         

#define MODEL_RANDOM  7
#define MODEL_SNIPER  8
#define MODEL_PYRO    9
#define MODEL_SCOUT   10
#define MODEL_SOLDIER 11

// model path + scale of prop
static const char g_sGravestoneMDL[][][] = {
  {"models/props_manor/gravestone_01.mdl", "0.5"},
  {"models/props_manor/gravestone_02.mdl", "0.5"},
  {"models/props_manor/gravestone_04.mdl", "0.5"},

  {"models/props_manor/gravestone_03.mdl", "0.4"},
  {"models/props_manor/gravestone_05.mdl", "0.4"},

  {"models/props_manor/gravestone_06.mdl", "0.3"},
  {"models/props_manor/gravestone_07.mdl", "0.3"},
  {"models/props_manor/gravestone_08.mdl", "0.3"},
  
  {"models/props_gameplay/tombstone_crocostyle.mdl", "1.0"},
  {"models/props_gameplay/tombstone_gasjockey.mdl", "1.0"},
  {"models/props_gameplay/tombstone_specialdelivery.mdl", "1.0"},
  {"models/props_gameplay/tombstone_tankbuster.mdl", "1.0"}
};

// sound to play when spawning name annotation
static const char g_sSmallestViolin[][] = {
  "player/taunt_v01.wav",
  "player/taunt_v02.wav",
  "player/taunt_v05.wav",
  "player/taunt_v06.wav",
  "player/taunt_v07.wav",
  "misc/taps_02.wav",
  "misc/taps_03.wav"
};

enum struct GraveInfo 
{
  float flAlert;
  float flDistance;
  float flTime;
  int iEntity[MAXPLAYERS+1]; // model entity of the player's gravestone
  int iAnnotationEntity[MAXPLAYERS+1]; // model entity of the gravestone the player is looking at
  Handle hHUDtimer; // hud timer
}

GraveInfo g_Gravestone;





#define TEXT_TAG "\x079EC34F[BuildAStyle]\x01"

#define CONFIG_HATS            "configs/BuildAStyle/BuildingHats.cfg"
#define CONFIG_PARTICLES       "configs/BuildAStyle/BuildingParticles.cfg"
#define CONFIG_SPAWN_PARTICLES ""

// Engi Building Cookies
Cookie g_hCookieBuildHats;     // Building Hats
Cookie g_hCookieBuildColor;    // Building Colors
Cookie g_hCookieBuildParticle; // Building Particles

Cookie g_hCookiePlayerColor;      // Player Color
//Cookie g_hCookiePlayerParticle;   // Player Unusual Particles to self
Cookie g_hCookiePlayerGravestone; // Player Gravestone

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
  LoadTranslations("BuildAStyle.phrases");

  Config_Init();
  Command_Init();
  
  g_hCookieBuildHats = RegClientCookie("building_hats", "Enable Building Hats", CookieAccess_Private);
  g_hCookieBuildColor = RegClientCookie("building_color", "Stores Building Color", CookieAccess_Private);
  g_hCookieBuildParticle = RegClientCookie("building_particle", "Enables Building Particle", CookieAccess_Private);
  g_hCookiePlayerGravestone =  RegClientCookie("player_gravestone", "Enables Player Gravestone", CookieAccess_Private);
  g_hCookiePlayerColor = RegClientCookie("player_color", "Stores Player Color", CookieAccess_Private);

  // Set Default Values
  g_Gravestone.flAlert = 5.0;
  g_Gravestone.flDistance = 400.0;
  g_Gravestone.flTime = 600.0;

  // Building 
  HookEvent("player_builtobject",    Event_OnObjectBuilt);
  HookEvent("player_carryobject",    Event_OnObjectPickedUp);
  HookEvent("player_dropobject",     Event_OnObjectDropped);
  HookEvent("player_upgradedobject", Event_OnObjectUpgraded);

  // Colorize
  HookEvent("player_spawn", Event_PlayerSpawn);
  
  // Grave
  HookEvent("player_death", Event_OnPlayerDeath, EventHookMode_Post);
}

public void OnPluginEnd()
{
  RemoveAllGravestones();
}

void RemoveAllGravestones()
{
  int iEnt;
  for (int i = 1; i <= MaxClients; i++)
  {
    iEnt = EntRefToEntIndex(g_Gravestone.iEntity[i]);
    if (iEnt != INVALID_ENT_REFERENCE)
    {
      // if it is not resized, it will crash
      SetEntPropFloat(iEnt, Prop_Send, "m_flModelScale", 1.0);
      KillWithoutMayhem(iEnt);
    }
  }
}

public void OnMapStart()
{
  Config_Refresh();

  // Precache Models
  for (int i = 0; i < sizeof(g_sGravestoneMDL); i++)
    PrecacheModel(g_sGravestoneMDL[i][0], true);

  // Precache Sounds
  for (int i = 1; i < sizeof(g_sSmallestViolin); i++)
    PrecacheSound(g_sSmallestViolin[i]);
  PrecacheSound(SOUND_NULL, true);

  // Reset Gravestone Info
  for (int i = 1; i <= MaxClients; i++)
  {
    g_Gravestone.iEntity[i] = INVALID_ENT_REFERENCE; // better safe than sorry
    g_Gravestone.iAnnotationEntity[i] = -1; // this will make the annotation dissapear
  }

  g_Gravestone.hHUDtimer = CreateTimer(HUDUPDATERATE, Timer_UpdateHUD, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
  // Cleanup all Gravestones.
  RemoveAllGravestones();
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Colorize
//////////////////////////////////////////////////////////////////////////////////////////

StringMap gColorMap;

stock bool Colorize(int iClient, char[] buffer, RenderMode mode)
{
  ColorCheckMap();
  int iColor[3];
  StrToLower(buffer);
  if (!gColorMap.GetArray(buffer, iColor, 3))
    return false;
  
  ColorizeWearables(iClient, iColor, mode, "tf_wearable"/*, "CTFWearable"*/);
  ColorizeWearables(iClient, iColor, mode, "tf_wearable_demoshield"/*, "CTFWearableDemoShield"*/);

  SetEntityRenderMode(iClient, mode);
  SetEntityRenderColor(iClient, iColor[0], iColor[1], iColor[2]);
  return true;
}

stock void ColorizeWearables(int iClient, int iColor[3], RenderMode mode,
  char[] EntClass/*, char[] ServerClass*/)
{
  int iEnt = -1;
  while ((iEnt = FindEntityByClassname(iEnt, EntClass)) != -1)
  {
    if (IsValidEntity(iEnt))
    {
      if (GetEntPropEnt(iEnt, Prop_Send, "m_hOwnerEntity") == iClient)
      {
        SetEntityRenderMode(iEnt, mode);
        SetEntityRenderColor(iEnt, iColor[0], iColor[1], iColor[2]);
      }
    }
  }
}

/* morecolors.inc ColorMap */
stock void ColorCheckMap()
{
  if (gColorMap == null)
  {
    gColorMap = InitColorMap();
  }
}

stock StringMap InitColorMap()
{
  StringMap hMap = new StringMap();
  hMap.SetArray("aliceblue",            {240, 248, 255}, 3);
  hMap.SetArray("allies",               {77 , 121, 66},  3);
  hMap.SetArray("ancient",              {235, 75 , 75},  3);
  hMap.SetArray("antiquewhite",         {250, 235, 215}, 3);
  hMap.SetArray("aqua",                 {0  , 255, 255}, 3);
  hMap.SetArray("aquamarine",           {127, 255, 212}, 3);
  hMap.SetArray("arcana",               {173, 229, 92},  3);
  hMap.SetArray("axis",                 {255, 64 , 64},  3);
  hMap.SetArray("azure",                {0  , 127, 255}, 3);
  hMap.SetArray("beige",                {245, 245, 220}, 3);
  hMap.SetArray("bisque",               {255, 228, 196}, 3);
  hMap.SetArray("black",                {0  , 0  , 0},   3);
  hMap.SetArray("blanchedalmond",       {255, 235, 205}, 3);
  hMap.SetArray("blue",                 {153, 204, 255}, 3);
  hMap.SetArray("blueviolet",           {138, 43 , 226}, 3);
  hMap.SetArray("brown",                {165, 42 , 42},  3);
  hMap.SetArray("burlywood",            {222, 184, 135}, 3);
  hMap.SetArray("cadetblue",            {95 , 158, 160}, 3);
  hMap.SetArray("chartreuse",           {127, 255, 0},   3);
  hMap.SetArray("chocolate",            {210, 105, 30},  3);
  hMap.SetArray("collectors",           {170, 0  , 0},   3);
  hMap.SetArray("common",               {176, 195, 217}, 3);
  hMap.SetArray("community",            {112, 176, 74},  3);
  hMap.SetArray("coral",                {255, 127, 80},  3);
  hMap.SetArray("cornflowerblue",       {100, 149, 237}, 3);
  hMap.SetArray("cornsilk",             {255, 248, 220}, 3);
  hMap.SetArray("corrupted",            {163, 44 , 46},  3);
  hMap.SetArray("crimson",              {220, 20 , 60},  3);
  hMap.SetArray("cyan",                 {0  , 255, 255}, 3);
  hMap.SetArray("darkblue",             {0  , 0  , 139}, 3);
  hMap.SetArray("darkcyan",             {0  , 139, 139}, 3);
  hMap.SetArray("darkgoldenrod",        {184, 134, 11},  3);
  hMap.SetArray("darkgray",             {169, 169, 169}, 3);
  hMap.SetArray("darkgrey",             {169, 169, 169}, 3);
  hMap.SetArray("darkgreen",            {0  , 100, 0},   3);
  hMap.SetArray("darkkhaki",            {189, 184, 107}, 3);
  hMap.SetArray("darkmagenta",          {139, 0  , 139}, 3);
  hMap.SetArray("darkolivegreen",       {85 , 107, 47},  3);
  hMap.SetArray("darkorange",           {255, 140, 0},   3);
  hMap.SetArray("darkorchid",           {153, 50 , 204}, 3);
  hMap.SetArray("darkred",              {139, 0  , 0},   3);
  hMap.SetArray("darksalmon",           {233, 150, 122}, 3);
  hMap.SetArray("darkseagreen",         {143, 188, 143}, 3);
  hMap.SetArray("darkslateblue",        {72 , 61 , 139}, 3);
  hMap.SetArray("darkslategray",        {47 , 79 , 79},  3);
  hMap.SetArray("darkslategrey",        {47 , 79 , 79},  3);
  hMap.SetArray("darkturquoise",        {0  , 206, 209}, 3);
  hMap.SetArray("darkviolet",           {148, 0  , 211}, 3);
  hMap.SetArray("deeppink",             {255, 20 , 147}, 3);
  hMap.SetArray("deepskyblue",          {0  , 191, 255}, 3);
  hMap.SetArray("dimgray",              {105, 105, 105}, 3);
  hMap.SetArray("dimgrey",              {105, 105, 105}, 3);
  hMap.SetArray("dodgerblue",           {30 , 144, 255}, 3);
  hMap.SetArray("exalted",              {204, 204, 205}, 3);
  hMap.SetArray("firebrick",            {178, 34 , 34},  3);
  hMap.SetArray("floralwhite",          {255, 250, 240}, 3);
  hMap.SetArray("forestgreen",          {34 , 139, 34},  3);
  hMap.SetArray("frozen",               {73 , 131, 179}, 3);
  hMap.SetArray("fuchsia",              {255, 0  , 255}, 3);
  hMap.SetArray("fullblue",             {0  , 0  , 255}, 3);
  hMap.SetArray("fullred",              {255, 0  , 0},   3);
  hMap.SetArray("gainsboro",            {220, 220, 220}, 3);
  hMap.SetArray("genuine",              {77 , 116, 85},  3);
  hMap.SetArray("ghostwhite",           {248, 248, 255}, 3);
  hMap.SetArray("gold",                 {255, 215, 0},   3);
  hMap.SetArray("goldenrod",            {218, 165, 32},  3);
  hMap.SetArray("gray",                 {204, 204, 204}, 3);
  hMap.SetArray("grey",                 {204, 204, 204}, 3);
  hMap.SetArray("green",                {62 , 255, 62},  3);
  hMap.SetArray("greenyellow",          {173, 255, 47},  3);
  hMap.SetArray("haunted",              {56 , 243, 171}, 3);
  hMap.SetArray("honeydew",             {240, 255, 240}, 3);
  hMap.SetArray("hotpink",              {255, 105, 180}, 3);
  hMap.SetArray("immortal",             {228, 174, 51},  3);
  hMap.SetArray("indianred",            {205, 92 , 92},  3);
  hMap.SetArray("indigo",               {75 , 0  , 130}, 3);
  hMap.SetArray("ivory",                {255, 255, 240}, 3);
  hMap.SetArray("khaki",                {240, 230, 140}, 3);
  hMap.SetArray("lavender",             {230, 230, 250}, 3);
  hMap.SetArray("lavenderblush",        {255, 240, 245}, 3);
  hMap.SetArray("lawngreen",            {124, 252, 0},   3);
  hMap.SetArray("legendary",            {211, 44 , 230}, 3);
  hMap.SetArray("lemonchiffon",         {255, 250, 205}, 3);
  hMap.SetArray("lightblue",            {173, 216, 230}, 3);
  hMap.SetArray("lightcoral",           {240, 128, 128}, 3);
  hMap.SetArray("lightcyan",            {224, 255, 255}, 3);
  hMap.SetArray("lightgoldenrodyellow", {250, 250, 210}, 3);
  hMap.SetArray("lightgray",            {211, 211, 211}, 3);
  hMap.SetArray("lightgrey",            {211, 211, 211}, 3);
  hMap.SetArray("lightgreen",           {153, 255, 153}, 3);
  hMap.SetArray("lightpink",            {255, 182, 193}, 3);
  hMap.SetArray("lightsalmon",          {255, 160, 122}, 3);
  hMap.SetArray("lightseagreen",        {32 , 178, 170}, 3);
  hMap.SetArray("lightskyblue",         {135, 206, 250}, 3);
  hMap.SetArray("lightslategray",       {119, 136, 153}, 3);
  hMap.SetArray("lightslategrey",       {119, 136, 153}, 3);
  hMap.SetArray("lightsteelblue",       {176, 196, 222}, 3);
  hMap.SetArray("lightyellow",          {255, 255, 224}, 3);
  hMap.SetArray("lime",                 {0  , 255, 0},   3);
  hMap.SetArray("limegreen",            {50 , 205, 50},  3);
  hMap.SetArray("linen",                {250, 240, 230}, 3);
  hMap.SetArray("magenta",              {255, 0  , 255}, 3);
  hMap.SetArray("maroon",               {128, 0  , 0},   3);
  hMap.SetArray("mediumaquamarine",     {102, 205, 170}, 3);
  hMap.SetArray("mediumblue",           {0  , 0  , 205}, 3);
  hMap.SetArray("mediumorchid",         {186, 85 , 211}, 3);
  hMap.SetArray("mediumpurple",         {147, 112, 216}, 3);
  hMap.SetArray("mediumseagreen",       {60 , 179, 113}, 3);
  hMap.SetArray("mediumslateblue",      {123, 104, 238}, 3);
  hMap.SetArray("mediumspringgreen",    {0  , 250, 154}, 3);
  hMap.SetArray("mediumturquoise",      {72 , 209, 204}, 3);
  hMap.SetArray("mediumvioletred",      {199, 21 , 133}, 3);
  hMap.SetArray("midnightblue",         {25 , 25 , 112}, 3);
  hMap.SetArray("mintcream",            {245, 255, 250}, 3);
  hMap.SetArray("mistyrose",            {255, 228, 225}, 3);
  hMap.SetArray("moccasin",             {255, 228, 181}, 3);
  hMap.SetArray("mythical",             {136, 71 , 255}, 3);
  hMap.SetArray("navajowhite",          {255, 222, 173}, 3);
  hMap.SetArray("navy",                 {0  , 0  , 128}, 3);
  hMap.SetArray("normal",               {178, 178, 178}, 3);
  hMap.SetArray("oldlace",              {253, 245, 230}, 3);
  hMap.SetArray("olive",                {158, 195, 79},  3);
  hMap.SetArray("olivedrab",            {107, 142, 35},  3);
  hMap.SetArray("orange",               {255, 165, 0},   3);
  hMap.SetArray("orangered",            {255, 69 , 0},   3);
  hMap.SetArray("orchid",               {218, 112, 214}, 3);
  hMap.SetArray("palegoldenrod",        {238, 232, 170}, 3);
  hMap.SetArray("palegreen",            {152, 251, 152}, 3);
  hMap.SetArray("paleturquoise",        {175, 238, 238}, 3);
  hMap.SetArray("palevioletred",        {216, 112, 147}, 3);
  hMap.SetArray("papayawhip",           {255, 239, 213}, 3);
  hMap.SetArray("peachpuff",            {255, 218, 185}, 3);
  hMap.SetArray("peru",                 {205, 133, 63},  3);
  hMap.SetArray("pink",                 {255, 192, 203}, 3);
  hMap.SetArray("plum",                 {221, 160, 221}, 3);
  hMap.SetArray("powderblue",           {176, 224, 230}, 3);
  hMap.SetArray("purple",               {128, 0  , 128}, 3);
  hMap.SetArray("rare",                 {75 , 105, 255}, 3);
  hMap.SetArray("red",                  {255, 64 , 64},  3);
  hMap.SetArray("rosybrown",            {188, 143, 143}, 3);
  hMap.SetArray("royalblue",            {65 , 105, 225}, 3);
  hMap.SetArray("saddlebrown",          {139, 69 , 19},  3);
  hMap.SetArray("salmon",               {250, 128, 114}, 3);
  hMap.SetArray("sandybrown",           {244, 164, 96},  3);
  hMap.SetArray("seagreen",             {46 , 139, 87},  3);
  hMap.SetArray("seashell",             {255, 245, 238}, 3);
  hMap.SetArray("selfmade",             {112, 176, 74},  3);
  hMap.SetArray("sienna",               {160, 82 , 45},  3);
  hMap.SetArray("silver",               {192, 192, 192}, 3);
  hMap.SetArray("skyblue",              {135, 206, 235}, 3);
  hMap.SetArray("slateblue",            {106, 90, 205},  3);
  hMap.SetArray("slategray",            {112, 128, 144}, 3);
  hMap.SetArray("slategrey",            {112, 128, 144}, 3);
  hMap.SetArray("snow",                 {255, 250, 250}, 3);
  hMap.SetArray("springgreen",          {0  , 255, 127}, 3);
  hMap.SetArray("steelblue",            {70 , 130, 180}, 3);
  hMap.SetArray("strange",              {207, 106, 50},  3);
  hMap.SetArray("tan",                  {210, 180, 140}, 3);
  hMap.SetArray("teal",                 {0  , 128, 128}, 3);
  hMap.SetArray("thistle",              {216, 191, 216}, 3);
  hMap.SetArray("tomato",               {255, 99 , 71},  3);
  hMap.SetArray("turquoise",            {64 , 224, 208}, 3);
  hMap.SetArray("uncommon",             {176, 195, 217}, 3);
  hMap.SetArray("unique",               {255, 215, 0},   3);
  hMap.SetArray("unusual",              {134, 80 , 172}, 3);
  hMap.SetArray("valve",                {165, 15 , 121}, 3);
  hMap.SetArray("vintage",              {71 , 98 , 145}, 3);
  hMap.SetArray("violet",               {238, 130, 238}, 3);
  hMap.SetArray("wheat",                {245, 222, 179}, 3);
  hMap.SetArray("white",                {255, 255, 255}, 3);
  hMap.SetArray("whitesmoke",           {245, 245, 245}, 3);
  hMap.SetArray("yellow",               {255, 255, 0},   3);
  hMap.SetArray("yellowgreen",          {154, 205, 50},  3);
  return hMap;
}

stock void StrToLower(char[] buffer)
{
  int len = strlen(buffer);
  for(int i = 0; i < len; i++)
  {
    buffer[i] = CharToLower(buffer[i]);
  }
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
};

public void Command_Init()
{
  // Commands for everyone
  RegAdminCmd("style", Command_MainMenu, ADMFLAG_RESERVATION);
  
  Command_Create("menu", Command_MainMenu);
  
  // Building Hats commands
  Command_Create("hats", Command_BuildingHats);
  Command_Create("hat", Command_BuildingHats);
  
  // Building Color commands
  Command_Create("colors", Command_BuildingColors);
  Command_Create("color", Command_BuildingColors);
  
  // Building Particle commands
  Command_Create("spawn", Command_BuildingSpawn);
  Command_Create("particle", Command_BuildingSpawn);
  
  // ColorSelf commands
  Command_Create("colorize", Command_Colorize);
  Command_Create("colorme", Command_Colorize);
  Command_Create("colorself", Command_Colorize);
  
  // Gravestone commands
  Command_Create("gravestones", Command_Gravestone);
  Command_Create("gravestone", Command_Gravestone);
  Command_Create("grave", Command_Gravestone);
}

stock void Command_Create(const char[] sCommand, ConCmd callback)
{
  for (int i = 0; i < sizeof(g_strCommandPrefix); i++)
  {
    char sBuffer[256];
    Format(sBuffer, sizeof(sBuffer), "%s%s", g_strCommandPrefix[i], sCommand);
    RegAdminCmd(sBuffer, callback, ADMFLAG_RESERVATION);
  }
}

public Action Command_Gravestone(int iClient, int iArgs)
{
  if (!IsClientInGame(iClient))
    return Plugin_Handled;
  
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookiePlayerGravestone, sCookieValue, sizeof(sCookieValue));

  bool bEnabled = StrEqual(sCookieValue, "true");
  bEnabled = !bEnabled; // Toggle the value

  SetClientCookie(iClient, g_hCookiePlayerGravestone, bEnabled ? "true" : "false");
  PrintToChat(iClient, "%s Player Gravestone %s.", TEXT_TAG, bEnabled ? "enabled" : "disabled");
  return Plugin_Handled;
}

public Action Command_Colorize(int iClient, int iArgs)
{
  if (!IsClientInGame(iClient))
    return Plugin_Handled;

  char sColor[64];
  GetCmdArg(1, sColor, sizeof(sColor));
  if (!Colorize(iClient, sColor, RENDER_NORMAL))
  {
    ReplyToCommand(iClient, "[SM] Error: No such color");
    return Plugin_Handled;
  }
  
  return Plugin_Handled;
}


public Action Command_BuildingSpawn(int iClient, int iArgs)
{
  if (!IsClientInGame(iClient))
    return Plugin_Handled;

  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildParticle, sCookieValue, sizeof(sCookieValue));

  bool bEnabled = StrEqual(sCookieValue, "true");
  bEnabled = !bEnabled; // Toggle the value

  SetClientCookie(iClient, g_hCookieBuildParticle, bEnabled ? "true" : "false");

  PrintToChat(iClient, "%s Building Spawn Particle %s.", TEXT_TAG, bEnabled ? "enabled" : "disabled");
  return Plugin_Handled;
}

public Action Command_MainMenu(int iClient, int iArgs)
{
  if (!IsClientInGame(iClient))
    return Plugin_Handled;

  Menu menu = new Menu(BuildAStyleMenuHandler);
  menu.SetTitle("BuildAStyle Menu");
  menu.AddItem("hats", "Toggle Building Hats");
  menu.AddItem("particle", "Toggle Building Particle");
  menu.AddItem("color", "Set Building Color");

  menu.AddItem("colorme", "Set Your Color");
  menu.AddItem("gravestone", "Toggle Your Gravestone");

  menu.AddItem("exit", "Exit");
  menu.Display(iClient, MENU_TIME_FOREVER);
  return Plugin_Handled;
}

bool ToggleCookie(int iClient, Cookie hCookie)
{
  char sCookieValue[8];
  GetClientCookie(iClient, hCookie, sCookieValue, sizeof(sCookieValue));

  bool bEnabled = StrEqual(sCookieValue, "true");
  bEnabled = !bEnabled; // Toggle the value

  SetClientCookie(iClient, hCookie, bEnabled ? "true" : "false");
  return bEnabled;
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
      bool bEnabled = ToggleCookie(iClient, g_hCookieBuildHats);
      PrintToChat(iClient, "%s Building hats %s.", TEXT_TAG, bEnabled ? "enabled" : "disabled");
    }
    else if (StrEqual(info, "particle"))
    {
      bool bEnabled = ToggleCookie(iClient, g_hCookieBuildParticle);
      PrintToChat(iClient, "%s Building Spawn Particle %s.", TEXT_TAG, bEnabled ? "enabled" : "disabled");
    }
    else if (StrEqual(info, "color"))
    {
      ShowColorMenu(iClient); // Show sub-menu
    }
    else if (StrEqual(info, "colorme"))
    {
      ShowColorizeMenu(iClient); // Show sub-menu
    }
    else if (StrEqual(info, "gravestone"))
    {
      bool bEnabled = ToggleCookie(iClient, g_hCookiePlayerGravestone);
      PrintToChat(iClient, "%s Player Gravestone %s.", TEXT_TAG, bEnabled ? "enabled" : "disabled");
    }
  }

  return 0;
}

void ShowColorMenu(int client)
{
  ColorCheckMap();

  StringMapSnapshot snapshot = gColorMap.Snapshot();

  int count = snapshot.Length;
  // sHex, Enough to store "#RRGGBB" + null terminator
  char sKey[64], sHex[8];
  int rgb[3];

  Menu hMenu = new Menu(ColorMenuHandler);
  hMenu.SetTitle("Select a Color");

  for (int i = 0; i < count; i++)
  {
    snapshot.GetKey(i, sKey, sizeof(sKey));
    if (gColorMap.GetArray(sKey, rgb, sizeof(rgb)))
    {
      Format(sHex, sizeof(sHex), "#%02X%02X%02X", rgb[0], rgb[1], rgb[2]);
      hMenu.AddItem(sHex, sKey);
    }
    else
    {
      PrintToServer("%s: <Failed to retrieve RGB values>", sKey);
    }
  }

  delete snapshot;
  hMenu.AddItem("back", "Back");
  hMenu.Display(client, MENU_TIME_FOREVER);
}

void ShowColorizeMenu(int client)
{
  ColorCheckMap();

  StringMapSnapshot snapshot = gColorMap.Snapshot();

  int count = snapshot.Length;
  char sKey[64];
  int rgb[3];

  Menu hMenu = new Menu(ColorizeMenuHandler);
  hMenu.SetTitle("Select a Color");

  for (int i = 0; i < count; i++)
  {
    snapshot.GetKey(i, sKey, sizeof(sKey));
    if (gColorMap.GetArray(sKey, rgb, sizeof(rgb)))
    {
      hMenu.AddItem(sKey, sKey);
    }
    else
    {
      PrintToServer("%s: <Failed to retrieve RGB values>", sKey);
    }
  }

  delete snapshot;
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

      PrintToChat(client, "%s Your Color is set to %s", TEXT_TAG, info);
    }
  }

  return 0;
}

public int ColorizeMenuHandler(Menu menu, MenuAction action, int client, int item)
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
      SetClientCookie(client, g_hCookiePlayerColor, info);
      Colorize(client, info, RENDER_NORMAL);

      PrintToChat(client, "%s You set your Player Color to %s.", TEXT_TAG, info);
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
  if (!IsClientInGame(iClient))
    return Plugin_Handled;

  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));

  bool bEnabled = StrEqual(sCookieValue, "true");
  bEnabled = !bEnabled; // Toggle the value

  SetClientCookie(iClient, g_hCookieBuildHats, bEnabled ? "true" : "false");

  PrintToChat(iClient, "%s Building hats %s.", TEXT_TAG, bEnabled ? "enabled" : "disabled");
  return Plugin_Continue;
}

public Action Command_BuildingColors(int client, int args) 
{
  if (!IsClientInGame(client))
    return Plugin_Handled;

  if (args < 1)
  {
    PrintToChat(client, "%s Usage: !buildcolor #RRGGBB", TEXT_TAG);
    return Plugin_Handled;
  }

  char sColor[32];
  GetCmdArg(1, sColor, sizeof(sColor));
  TrimString(sColor);

  if (sColor[0] != '#' || strlen(sColor) != 7)
  {
    PrintToChat(client, "%s Invalid format. Use #RRGGBB.", TEXT_TAG);
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
    PrintToChat(client, "%s Failed to parse hex values.", TEXT_TAG);
    return Plugin_Handled;
  }

  int packedColor = (r << 16) | (g << 8) | b;

  char sPacked[16];
  IntToString(packedColor, sPacked, sizeof(sPacked));
  SetClientCookie(client, g_hCookieBuildColor, sPacked);

  PrintToChat(client, "%s Color set to RGB(%d, %d, %d).", TEXT_TAG, r, g, b);
  return Plugin_Continue;
}

//////////////////////////////////////////////////////////////////////////////////////////
/// TF2 Events
//////////////////////////////////////////////////////////////////////////////////////////

public Action Event_OnObjectBuilt(Event event, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(event.GetInt("userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;
  
  int iObjectEntity = event.GetInt("index");

  // Get Color Building
  char sColorCookieValue[16];
  GetClientCookie(iClient, g_hCookieBuildColor, sColorCookieValue, sizeof(sColorCookieValue));
  if (sColorCookieValue[0] != '\0')
  {
    int packedColor = StringToInt(sColorCookieValue);
    int r, g, b;
    r = (packedColor >> 16) & 0xFF;
    g = (packedColor >> 8) & 0xFF;
    b = packedColor & 0xFF;
    SetEntityRenderColor(iObjectEntity, r, g, b, _);
  }
  
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

  // Get Client Object, if this object already has a hat, we don't want to attach another
  if (!IsHattableObject(TF2_GetObjectType(iObjectEntity)) || IsValidEntity(GetObjectHat(iObjectEntity)))
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

public Action Event_OnObjectPickedUp(Event event, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(event.GetInt("userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;

  // Does Client Have Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  int iObjectEntity = event.GetInt("index");
  if (!IsHattableObject(TF2_GetObjectType(iObjectEntity)))
    return Plugin_Handled;

  int iHatProp = GetObjectHat(iObjectEntity);
  if (IsValidEntity(iHatProp))
    AcceptEntityInput(iHatProp, "TurnOff");
  
  return Plugin_Continue;
}

public Action Event_OnObjectDropped(Event event, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(event.GetInt("userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;

  int iObjectEntity = event.GetInt("index");
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


public Action Event_OnObjectUpgraded(Event event, const char[] sName, bool bDontBroadcast)
{
  // Get Client
  int iClient = GetClientOfUserId(event.GetInt("userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;

  // Does Client Have Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookieBuildHats, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  int iObjectEntity = event.GetInt("index");
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

public Action Event_PlayerSpawn(Event event, const char[] sName, bool bDontBroadcast)
{
  int iClient = GetClientOfUserId(event.GetInt("userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;
  
  // Does Client Have Cookie
  char sCookieValue[32];
  GetClientCookie(iClient, g_hCookiePlayerColor, sCookieValue, sizeof(sCookieValue));
  if (sCookieValue[0] != '\0')
    Colorize(iClient, sCookieValue, RENDER_NORMAL);
  
  return Plugin_Continue;
}

public Action Event_OnPlayerDeath(Event event, const char[] sName, bool bDontBroadcast)
{
  if (event.GetInt("death_flags") & TF_DEATHFLAG_DEADRINGER)
    return Plugin_Handled;

  // Get Client
  int iClient = GetClientOfUserId(event.GetInt("userid"));
  if (!IsClientInGame(iClient) || !AreClientCookiesCached(iClient))
    return Plugin_Handled;
  
  // Does Client Have Cookie
  char sCookieValue[8];
  GetClientCookie(iClient, g_hCookiePlayerGravestone, sCookieValue, sizeof(sCookieValue));
  if (!StrEqual(sCookieValue, "true"))
    return Plugin_Handled;

  SpawnGrave(iClient);
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

void SpawnGrave(int iClient)
{
  float flStartOrigin[3];
  float flAngles[3] = {90.0, 0.0, 0.0}; // down
  GetClientEyePosition(iClient, flStartOrigin);

  Handle hTraceRay = TR_TraceRayFilterEx(flStartOrigin, flAngles, 
                                         MASK_PROP_SPAWN, RayType_Infinite, 
                                         TraceRayProp);
  
  if (TR_DidHit(hTraceRay))
  {
    float flEndOrigin[3];
    TR_GetEndPosition(flEndOrigin, hTraceRay);

    float flDistance = GetVectorDistance(flStartOrigin, flEndOrigin);
    if (flDistance < MAX_SPAWN_DISTANCE)
    {
      int iEnt = CreateEntityByName("prop_physics_override");
      if (iEnt != -1)
      {
        int iIndex;
        float flNormal[3];
        float flNormalAng[3];
        TR_GetPlaneNormal(hTraceRay, flNormal);

        // Offset spawn point
        flEndOrigin[0] += flNormal[0] * OFFSET_HEIGHT;
        flEndOrigin[1] += flNormal[1] * OFFSET_HEIGHT;
        flEndOrigin[2] += flNormal[2] * OFFSET_HEIGHT;

        GetClientEyeAngles(iClient, flAngles);
        GetVectorAngles(flNormal, flNormalAng);

        flAngles[0] = flNormalAng[0] - 270.0;
        if (flNormalAng[0] != 270.0)
          flAngles[1] = flNormalAng[1];
                
        switch (TF2_GetPlayerClass(iClient))
        {
          case TFClass_Sniper:  iIndex = GetRandomInt(0, 1) ? GetRandomInt(0, MODEL_RANDOM) : MODEL_SNIPER;
          case TFClass_Pyro:    iIndex = GetRandomInt(0, 1) ? GetRandomInt(0, MODEL_RANDOM) : MODEL_PYRO;
          case TFClass_Scout:   iIndex = GetRandomInt(0, 1) ? GetRandomInt(0, MODEL_RANDOM) : MODEL_SCOUT;
          case TFClass_Soldier: iIndex = GetRandomInt(0, 1) ? GetRandomInt(0, MODEL_RANDOM) : MODEL_SOLDIER;
          default:              iIndex = GetRandomInt(0, MODEL_RANDOM);
        }

        char sClientName[64];
        GetClientName(iClient, sClientName, sizeof(sClientName));

        int iRandom = GetRandomInt(1, DEATH_PHRASE_COUNT);
        char sPhraseKey[32];
        Format(sPhraseKey, sizeof(sPhraseKey), "death_phrase_%d", iRandom);

        char sFormatted[256];
        SetGlobalTransTarget(iClient);
        Format(sFormatted, sizeof(sFormatted), "%t", sPhraseKey, sClientName);

        if (g_Gravestone.flAlert)
        {
          int iBitString = BuildBitString(flEndOrigin);
          if (iBitString)
          {
            Event hEvent = CreateEvent("show_annotation");
            if (hEvent != null)
            {
              SetEventFloat(hEvent, "worldPosX", flEndOrigin[0] + flNormal[0] * ANNOTATION_NAME_HEIGHT);
              SetEventFloat(hEvent, "worldPosY", flEndOrigin[1] + flNormal[1] * ANNOTATION_NAME_HEIGHT);
              SetEventFloat(hEvent, "worldPosZ", flEndOrigin[2] + flNormal[2] * ANNOTATION_NAME_HEIGHT);
              SetEventFloat(hEvent, "lifetime", g_Gravestone.flAlert);
              SetEventInt(hEvent, "id", iEnt);
              SetEventString(hEvent, "text", sFormatted);
              SetEventInt(hEvent, "visibilityBitfield", iBitString);
              SetEventString(hEvent, "play_sound", g_sSmallestViolin[GetRandomInt(0, sizeof(g_sSmallestViolin) - 1)]);
              FireEvent(hEvent);
            }
          }
        }

        ReplaceString(sClientName, sizeof(sClientName), ";", ":");

        //char sEpitaphIndex[4];
        //IntToString(GetRandomInt(0, g_EpitaphSize - 1), sEpitaphIndex, sizeof(sEpitaphIndex));
        //StrCat(sClientName, sizeof(sClientName), ";");
        //StrCat(sClientName, sizeof(sClientName), sEpitaphIndex);

        DispatchKeyValue(iEnt, "targetname", sClientName);
        DispatchKeyValue(iEnt, "solid", "0");
        DispatchKeyValue(iEnt, "model", g_sGravestoneMDL[iIndex][0]);
        DispatchKeyValue(iEnt, "disableshadows", "1");
        DispatchKeyValue(iEnt, "physdamagescale", "0.0");

        DispatchKeyValueVector(iEnt, "origin", flEndOrigin);
        DispatchKeyValueVector(iEnt, "angles", flAngles);

        DispatchSpawn(iEnt);

        float flScale = StringToFloat(g_sGravestoneMDL[iIndex][1]);
        if (flScale != 1.0)
          SetEntPropFloat(iEnt, Prop_Send, "m_flModelScale", flScale);

        SetEntProp(iEnt, Prop_Send, "m_CollisionGroup", 2); // debris trigger
        SetEntProp(iEnt, Prop_Send, "m_usSolidFlags", 0);   // disable default collision

        ActivateEntity(iEnt);
        AcceptEntityInput(iEnt, "DisableMotion");

        int iOldEntity = EntRefToEntIndex(g_Gravestone.iEntity[iClient]);
        if (iOldEntity != INVALID_ENT_REFERENCE)
        {
          // undo scale to prevent crash
          SetEntPropFloat(iOldEntity, Prop_Send, "m_flModelScale", 1.0);
          KillWithoutMayhem(iOldEntity);
        }

        g_Gravestone.iEntity[iClient] = EntIndexToEntRef(iEnt);

        CreateTimer(g_Gravestone.flTime, Timer_RemoveGravestone, g_Gravestone.iEntity[iClient], TIMER_FLAG_NO_MAPCHANGE);
      }
    }
  }

  CloseHandle(hTraceRay);
}

public Action Timer_RemoveGravestone(Handle hTimer, int iRef)
{
  int iEnt = EntRefToEntIndex(iRef);
  if (iEnt != INVALID_ENT_REFERENCE)
  {
    SetEntPropFloat(iEnt, Prop_Send, "m_flModelScale", 1.0);
    KillWithoutMayhem(iEnt);
  }
  return Plugin_Continue;
}

public int BuildBitString(float flPosition[3])
{
  int iBitString;
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientInGame(i))
    {
      float flEyePos[3];
      GetClientEyePosition(i, flEyePos);
      if (GetVectorDistance(flPosition, flEyePos) < g_Gravestone.flDistance)
        iBitString |= 1 << i;
    }
  }
  return iBitString;
}

public bool TraceRayProp(int iEntityHit, int iMask)
{
  // Hit terrain, no models or debris
  if (iEntityHit == 0)
    return true;

  return false;
}

stock int GetObject(int iClient)
{
  float flClientEyePos[3];
  float flClientEyeAng[3];

  GetClientEyePosition(iClient, flClientEyePos);
  GetClientEyeAngles(iClient, flClientEyeAng);

  TR_TraceRayFilter(flClientEyePos, flClientEyeAng, MASK_PLAYERSOLID, 
                    RayType_Infinite, DontHitSelf, iClient);

  if (TR_DidHit(INVALID_HANDLE))
  {
    int iEnt = TR_GetEntityIndex(INVALID_HANDLE);
    if (iEnt > 0)
      for (int i = 1; i <= MaxClients; i++)
        if (EntRefToEntIndex(g_Gravestone.iEntity[i]) == iEnt)
          return iEnt;
  }

  return -1;
}

public bool DontHitSelf(int entity, int mask, int client)
{
  return (client != entity);
}

stock void KillWithoutMayhem(int iEntity)
{
  float flRandomVec[3];
  flRandomVec[0] = GetRandomFloat(-5000.0,5000.0);
  flRandomVec[1] = GetRandomFloat(-5000.0,5000.0);
  flRandomVec[2] = -5000.0;
  
  TeleportEntity(iEntity, flRandomVec, NULL_VECTOR, NULL_VECTOR); 
  SetEntProp(iEntity, Prop_Send, "m_CollisionGroup", 0);
    
  AcceptEntityInput(iEntity, "Kill");
}

public Action Timer_UpdateHUD(Handle hTimer){
  float flClientPos[3], flPropPos[3];
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientInGame(i) && !IsFakeClient(i))
    {
      int iEnt = GetObject(i);
      if (iEnt != -1 && GetClientButtons(i) & IN_ATTACK2)
      {
        GetEntPropVector(iEnt, Prop_Send, "m_vecOrigin", flPropPos);
        GetEntPropVector(i, Prop_Send, "m_vecOrigin", flClientPos);

        if (GetVectorDistance(flClientPos, flPropPos) < g_Gravestone.flDistance)
        {
          if (g_Gravestone.iAnnotationEntity[i] != iEnt)
          {
            Handle hEvent = CreateEvent("show_annotation");
            if (hEvent != INVALID_HANDLE)
            {
              //GetEntPropString(ent, Prop_Data, "m_iName", sBuffer, 36);
              //ExplodeString(sBuffer, ";", segment, 2, 32);					// name;index
              //GetArrayString(g_hEpitaph, StringToInt(segment[1]), sBuffer, MAX_EPITAPH_LENGTH+32);
              //ReplaceString(sBuffer, MAX_EPITAPH_LENGTH, "*", segment[0]);

              float flPropAng[3], flUpVec[3];
              GetEntPropVector(iEnt, Prop_Send, "m_angRotation", flPropAng);
              GetAngleVectors(flPropAng, NULL_VECTOR, NULL_VECTOR, flUpVec);

              SetEventFloat(hEvent, "worldPosX", flPropPos[0] + (flUpVec[0] * ANNOTATION_HEIGHT));
              SetEventFloat(hEvent, "worldPosY", flPropPos[1] + (flUpVec[1] * ANNOTATION_HEIGHT));
              SetEventFloat(hEvent, "worldPosZ", flPropPos[2] + (flUpVec[2] * ANNOTATION_HEIGHT));
              SetEventFloat(hEvent, "lifetime", 999999.0); // arbitrarily long
              SetEventInt(hEvent, "id", i);
              SetEventString(hEvent, "text", "Rip");
              SetEventInt(hEvent, "visibilityBitfield", 1 << i);
              SetEventString(hEvent, "play_sound", SOUND_NULL);
              FireEvent(hEvent);
              g_Gravestone.iAnnotationEntity[i] = iEnt;
            }
          }
        }
      }
      else if (g_Gravestone.iAnnotationEntity[i] != -1)
      {
        Handle hEvent = CreateEvent("show_annotation");
        if (hEvent != INVALID_HANDLE)
        {
          SetEventFloat(hEvent, "lifetime", 0.00001); // arbitrarily short
          SetEventInt(hEvent, "id", i);
          SetEventString(hEvent, "text", " ");
          SetEventInt(hEvent, "visibilityBitfield", 1 << i);
          SetEventInt(hEvent, "follow_entindex", iEnt); // follow the client, they won't see it anyway
          SetEventString(hEvent, "play_sound", SOUND_NULL);
          FireEvent(hEvent);
        }
        g_Gravestone.iAnnotationEntity[i] = -1;
      }
    }
  }
  return Plugin_Continue;
}


















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
  //int count = g_ConfigHats.Size;
  //PrintToServer("[ConfigHats] Precaching %d Hat(s)...", count);

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
      //PrintToServer("  [%d] Precaching Hat Model: %s", i, model);
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
  //int count = g_ConfigParticles.Size;
  //PrintToServer("[ConfigParticles] Precaching %d Particle(s)...", count);

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
      //PrintToServer("  [%d] Precaching Particle: %s", i, particleName);
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