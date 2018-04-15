-- Server and client both need this for scoring event logs

function ScoreInit()
   local tmp = {}
   
   for _, v in pairs(GetWinRoles()) do
      tmp[v.team] = 0
   end

   return {
      deaths = 0,
      suicides = 0,
      r = ROLES.INNOCENT.index,
      k = 0,
      tk = 0,
      roles = tmp,
      bonus = 0 -- non-kill points to add
   }
end

function ScoreEvent(e, scores, rolesTbl)
   if e.id == EVENT_KILL then
      local aid = e.att.sid
      local vid = e.vic.sid

      -- make sure a score table exists for this person
      -- he might have disconnected by now
      if scores[vid] == nil then
         scores[vid] = ScoreInit()
      end
      
      -- normally we have the ply:GetTraitor stuff to base this on, but that
      -- won't do for disconnected players
      
      if scores[aid] == nil then
         scores[aid] = ScoreInit()
      end
      
      for role, sidTbl in pairs(rolesTbl) do
         local t = 0
         
         for _, sid in pairs(sidTbl) do
            if sid == e.att.sid then
               scores[aid].r = role
               t = t + 1
            elseif sid == e.vic.sid then
               scores[vid].r = role
               t = t + 1
            end
            
            if t == 2 then
               break
            end
         end
            
         if t == 2 then
            break
         end
      end
      
      if scores[vid].r == scores[aid].r then
         scores[aid].tk = scores[aid].tk + 1
      end

      scores[vid].deaths = scores[vid].deaths + 1

      if aid == vid then
         scores[vid].suicides = scores[vid].suicides + 1
      elseif aid ~= -1 then
         local roleData = GetRoleByIndex(scores[vid].r)
         
         scores[aid].roles[roleData.team] = scores[aid].roles[roleData.team] + 1
         scores[aid].k = scores[aid].k + 1
      end
   elseif e.id == EVENT_BODYFOUND then 
      local sid = e.sid
      
      if scores[sid] == nil then return end
      
      if GetRoleByIndex(scores[sid].r).team == TEAM_TRAITOR then return end

      local find_bonus = 0
      
      for _, v in pairs(ROLES) do
         if v.team ~= TEAM_TRAITOR and v.shop then
            find_bonus = scores[sid].r == v.index and 3 or 1
         end
      end
      
      scores[sid].bonus = scores[sid].bonus + find_bonus
   end
end

-- events should be event log as generated by scoring.lua
-- scores should be table with SteamIDs as keys
-- The method of finding these IDs differs between server and client
function ScoreEventLog(events, scores, rolesTbl)  
   for k, s in pairs(scores) do
      scores[k] = ScoreInit()
   end

   local tmp = nil
   
   for _, e in pairs(events) do
      ScoreEvent(e, scores, rolesTbl)
   end

   return scores
end

function ScoreTeamBonus(scores, wintype, winrole)
   -- TODO: whats with 'winrole' ?

   local alive = {}
   local dead = {}
   
   local winRoles = GetWinRoles()
   
   for _, v in pairs(winRoles) do
      alive[v.team] = 0
      dead[v.team] = 0
   end

   for _, sc in pairs(scores) do
      local state = (sc.deaths == 0) and alive or dead
      local team = GetRoleByIndex(sc.r).team
      
      state[team] = state[team] + 1
   end

   local bonus = {}
   
   for _, v in pairs(winRoles) do
      local others = 0
      
      for k, x in pairs(dead) do
         if k ~= v.team then
            others = others + x
         end
      end
   
      bonus[v.team] = alive[v.team] * 1
      if v.surviveBonus ~= nil then -- theoretically not necessary
         bonus[v.team] = bonus[v.team] + math.ceil(others * (v.surviveBonus or 0))
      end
      
      -- running down the clock must never be beneficial for traitors
      if wintype == WIN_TIMELIMIT then
         local alive_not_traitors = 0
         local dead_not_traitors = 0
         
         for k, x in pairs(alive) do
            if k ~= TEAM_TRAITOR then
               alive_not_traitors = alive_not_traitors + x
            end
         end
         
         for k, x in pairs(dead) do
            if k ~= TEAM_TRAITOR then
               dead_not_traitors = dead_not_traitors + x
            end
         end
         
         bonus[TEAM_TRAITOR] = math.floor(alive_not_traitors * -0.5) + math.ceil(dead_not_traitors * 0.5)
      end
   end

   return bonus
end

-- Scores were initially calculated as points immediately, but not anymore, so
-- we can convert them using this fn
function KillsToPoints(score)
   local roleData = GetRoleByIndex(score.r)
   return ((score.suicides * -1)
           + score.bonus
           + score.tk * roleData.scoreTeamKillsMultiplier
           + score.k * roleData.scoreKillsMultiplier
           + (score.deaths == 0 and 1 or 0)) --effectively 2 due to team bonus
                                             --for your own survival
end

---- Weapon AMMO_ enum stuff, used only in score.lua/cl_score.lua these days

-- Not actually ammo identifiers anymore, but still weapon identifiers. Used
-- only in round report (score.lua) to save bandwidth because we can't use
-- pooled strings there. Custom SWEPs are sent as classname string and don't
-- need to bother with these.
AMMO_DEAGLE = 2
AMMO_PISTOL = 3
AMMO_MAC10 = 4
AMMO_RIFLE = 5
AMMO_SHOTGUN = 7
-- Following are custom, intentionally out of ammo enum range
AMMO_CROWBAR = 50
AMMO_SIPISTOL = 51
AMMO_C4 = 52
AMMO_FLARE = 53
AMMO_KNIFE = 54
AMMO_M249 = 55
AMMO_M16 = 56
AMMO_DISCOMB = 57
AMMO_POLTER = 58
AMMO_TELEPORT = 59
AMMO_RADIO = 60
AMMO_DEFUSER = 61
AMMO_WTESTER = 62
AMMO_BEACON = 63
AMMO_HEALTHSTATION = 64
AMMO_MOLOTOV = 65
AMMO_SMOKE = 66
AMMO_BINOCULARS = 67
AMMO_PUSH = 68
AMMO_STUN = 69
AMMO_CSE = 70
AMMO_DECOY = 71
AMMO_GLOCK = 72

local WeaponNames = nil

function GetWeaponClassNames()
   if not WeaponNames then
      local tbl = {}
      
      for _, v in pairs(weapons.GetList()) do
         if v and v.WeaponID then
            tbl[v.WeaponID] = WEPS.GetClass(v)
         end
      end

      for _, v in pairs(scripted_ents.GetList()) do
         local id = v and (v.WeaponID or (v.t and v.t.WeaponID))
         
         if id then
            tbl[id] = WEPS.GetClass(v)
         end
      end

      WeaponNames = tbl
   end

   return WeaponNames
end

-- reverse lookup from enum to SWEP table
function EnumToSWEP(ammo)
   local e2w = GetWeaponClassNames() or {}
   
   if e2w[ammo] then
      return util.WeaponForClass(e2w[ammo])
   else
      return nil
   end
end

function EnumToSWEPKey(ammo, key)
   local swep = EnumToSWEP(ammo)
   
   return swep and swep[key]
end

-- something the client can display
-- This used to be done with a big table of AMMO_ ids to names, now we just use
-- the weapon PrintNames. This means it is no longer usable from the server (not
-- used there anyway), and means capitalization is slightly less pretty.
function EnumToWep(ammo)
   return EnumToSWEPKey(ammo, "PrintName")
end

-- something cheap to send over the network
function WepToEnum(wep)
   if not IsValid(wep) then return end

   return wep.WeaponID
end