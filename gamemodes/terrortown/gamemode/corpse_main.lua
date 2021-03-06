---- Corpse functions

-- namespaced because we have no ragdoll metatable
CORPSE = {}

ttt_include("corpse_shd")

--- networked data abstraction layer
local dti = CORPSE.dti

function CORPSE.SetFound(rag, state)
	--rag:SetNWBool("found", state)
	rag:SetDTBool(dti.BOOL_FOUND, state)
end

function CORPSE.SetPlayerNick(rag, ply_or_name)
	-- don't have datatable strings, so use a dt entity for common case of
	-- still-connected player, and if the player is gone, fall back to nw string
	local name = ply_or_name

	if IsValid(ply_or_name) then
		name = ply_or_name:Nick()

		rag:SetDTEntity(dti.ENT_PLAYER, ply_or_name)
	end

	rag:SetNWString("nick", name)
end

function CORPSE.SetCredits(rag, credits)
	--rag:SetNWInt("credits", credits)
	rag:SetDTInt(dti.INT_CREDITS, credits)
end

--- ragdoll creation and search

-- If detective mode, announce when someone's body is found
local bodyfound = CreateConVar("ttt_announce_body_found", "1", {FCVAR_NOTIFY, FCVAR_ARCHIVE})

function GM:TTTCanIdentifyCorpse(ply, corpse)
	-- return true to allow corpse identification, false to disallow
	-- TODO removed b"was_traitor". Team is available with corpse.was_team
	return true
end

local function IdentifyBody(ply, rag)
	if not ply:IsTerror() then return end

	-- simplified case for those who die and get found during prep
	if GetRoundState() == ROUND_PREP then
		CORPSE.SetFound(rag, true)

		return
	end

	if not hook.Run("TTTCanIdentifyCorpse", ply, rag) then return end

	local finder = ply:Nick()
	local nick = CORPSE.GetPlayerNick(rag, "")

	-- Announce body
	if bodyfound:GetBool() and not CORPSE.GetFound(rag, false) then
		local subrole = rag.was_role
		local team = rag.was_team
		local rd = GetRoleByIndex(subrole)
		local roletext = "body_found_" .. rd.abbr

		if GetGlobalBool("ttt2_confirm_team") then
			LANG.Msg("body_found_team", {finder = finder, victim = nick, role = LANG.Param(roletext), team = LANG.Param(team)})
		else
			LANG.Msg("body_found", {finder = finder, victim = nick, role = LANG.Param(roletext)})
		end
	end

	-- Register find
	if not CORPSE.GetFound(rag, false) then -- will return either false or a valid ply
		local deadply = player.GetBySteamID64(rag.sid64)
		if deadply then
			deadply:SetNWBool("body_found", true)

			SendPlayerToEveryone(deadply) -- confirm player for everyone

			SCORE:HandleBodyFound(ply, deadply)
		end

		hook.Call("TTTBodyFound", GAMEMODE, ply, deadply, rag)

		CORPSE.SetFound(rag, true)
	end

	if GetConVar("ttt2_confirm_killlist"):GetBool() then
		-- Handle kill list
		for _, vicsid in ipairs(rag.kills) do
			-- filter out disconnected (and bots !)
			local vic = player.GetBySteamID64(vicsid)

			-- is this an unconfirmed dead?
			if IsValid(vic) and not vic:GetNWBool("body_found", false) then
				LANG.Msg("body_confirm", {finder = finder, victim = vic:Nick()})

				SendPlayerToEveryone(vic) -- confirm player for everyone

				vic:SetNWBool("body_found", true) -- update scoreboard status

				-- however, do not mark body as found. This lets players find the
				-- body later and get the benefits of that
				--local vicrag = vic.server_ragdoll
				--CORPSE.SetFound(vicrag, true)
			end
		end
	end
end

local function ttt_confirm_death(ply, cmd, args)
	if not IsValid(ply) then return end

	if #args < 2 then return end

	local eidx = tonumber(args[1])
	local id = tonumber(args[2])
	local long_range = (args[3] and tonumber(args[3]) == 1) and true or false

	if not eidx or not id then return end

	if not ply.search_id or ply.search_id.id ~= id or ply.search_id.eidx ~= eidx then
		ply.search_id = nil

		return
	end

	ply.search_id = nil

	local rag = Entity(eidx)

	if IsValid(rag) and (rag:GetPos():Distance(ply:GetPos()) < 128 or long_range) and not CORPSE.GetFound(rag, false) then
		IdentifyBody(ply, rag)
	end
end
concommand.Add("ttt_confirm_death", ttt_confirm_death)

-- Call detectives to a corpse
local function ttt_call_detective(ply, cmd, args)
	if not IsValid(ply) then return end

	if #args ~= 1 then return end

	if not ply:IsActive() then return end

	local eidx = tonumber(args[1])

	if not eidx then return end

	local rag = Entity(eidx)

	if IsValid(rag) and rag:GetPos():Distance(ply:GetPos()) < 128 then
		if CORPSE.GetFound(rag, false) then
			-- show indicator in radar to detectives
			net.Start("TTT_CorpseCall")
			net.WriteVector(rag:GetPos())
			net.Send(GetRoleChatFilter(ROLE_DETECTIVE, true))

			LANG.Msg("body_call", {player = ply:Nick(), victim = CORPSE.GetPlayerNick(rag, "someone")})
		else
			LANG.Msg(ply, "body_call_error")
		end
	end
end
concommand.Add("ttt_call_detective", ttt_call_detective)

local function bitsRequired(num)
	local bits, max = 0, 1

	while max <= num do
		bits = bits + 1 -- increase
		max = max + max -- double
	end

	return bits
end

function GM:TTTCanSearchCorpse(ply, corpse, is_covert, is_long_range)
	-- return true to allow corpse search, false to disallow.
	-- TODO removed last param is_traitor -> accessable with corpse.was_team
	return true
end

-- Send a usermessage to client containing search results
function CORPSE.ShowSearch(ply, rag, covert, long_range)
	if not IsValid(ply) or not IsValid(rag) then return end

	if rag:IsOnFire() then
		LANG.Msg(ply, "body_burning")

		return
	end

	if not hook.Run("TTTCanSearchCorpse", ply, rag, covert, long_range) then return end

	-- init a heap of data we'll be sending
	local nick = CORPSE.GetPlayerNick(rag)
	local subrole = rag.was_role
	local team = rag.was_team
	local eq = rag.equipment or EQUIP_NONE
	local c4 = rag.bomb_wire or - 1
	local dmg = rag.dmgtype or DMG_GENERIC
	local wep = rag.dmgwep or ""
	local words = rag.last_words or ""
	local hshot = rag.was_headshot or false
	local dtime = rag.time or 0

	local owner = player.GetBySteamID64(rag.sid64)
	owner = IsValid(owner) and owner:EntIndex() or - 1

	-- basic sanity check
	if not nick or not eq or not subrole or not team then return end

	if GetConVar("ttt_identify_body_woconfirm"):GetBool() and DetectiveMode() and not covert then
		IdentifyBody(ply, rag)
	end

	local credits = CORPSE.GetCredits(rag, 0)

	if ply:IsActiveShopper() and not ply:GetSubRoleData().preventFindCredits and credits > 0 and not long_range then
		LANG.Msg(ply, "body_credits", {num = credits})

		ply:AddCredits(credits)

		CORPSE.SetCredits(rag, 0)

		ServerLog(ply:Nick() .. " took " .. credits .. " credits from the body of " .. nick .. "\n")

		SCORE:HandleCreditFound(ply, nick, credits)
	end

	-- time of death relative to current time (saves bits)
	if dtime ~= 0 then
		dtime = math.Round(CurTime() - dtime)
	end

	-- identifier so we know whether a ttt_confirm_death was legit
	ply.search_id = {eidx = rag:EntIndex(), id = rag:EntIndex() + dtime}

	-- time of dna sample decay relative to current time
	local stime = 0

	if rag.killer_sample then
		stime = math.max(0, rag.killer_sample.t - CurTime())
	end

	-- build list of people this player killed
	local kill_entids = {}

	for _, vicsid in ipairs(rag.kills) do
		-- also send disconnected players as a marker
		local vic = player.GetBySteamID64(vicsid)

		table.insert(kill_entids, IsValid(vic) and vic:EntIndex() or - 1)
	end

	local lastid = -1

	if rag.lastid and ply:IsActive() and ply:GetBaseRole() == ROLE_DETECTIVE then
		-- if the person this victim last id'd has since disconnected, send -1 to
		-- indicate this
		lastid = IsValid(rag.lastid.ent) and rag.lastid.ent:EntIndex() or - 1
	end

	-- Send a message with basic info
	net.Start("TTT_RagdollSearch")
	net.WriteUInt(rag:EntIndex(), 16) -- 16 bits
	net.WriteUInt(owner, 8) -- 128 max players. (8 bits)
	net.WriteString(nick)
	net.WriteUInt(eq, 16) -- Equipment (16 = max.)
	net.WriteUInt(subrole, ROLE_BITS) -- (... bits)
	net.WriteString(team)
	net.WriteInt(c4, bitsRequired(C4_WIRE_COUNT) + 1) -- -1 -> 2^bits (default c4: 4 bits)
	net.WriteUInt(dmg, 30) -- DMG_BUCKSHOT is the highest. (30 bits)
	net.WriteString(wep)
	net.WriteBit(hshot) -- (1 bit)
	net.WriteInt(dtime, 16)
	net.WriteInt(stime, 16)

	net.WriteUInt(#kill_entids, 8)

	for _, idx in ipairs(kill_entids) do
		net.WriteUInt(idx, 8) -- first game.MaxPlayers() of entities are for players.
	end

	net.WriteUInt(lastid, 8)

	-- Who found this, so if we get this from a detective we can decide not to
	-- show a window
	net.WriteUInt(ply:EntIndex(), 8)
	net.WriteString(words)

	net.WriteBit(long_range)

	-- 133 + string data + #kill_entids * 8 + team + 1
	-- 200 + ?

	-- If found by detective, send to all, else just the finder
	if ply:IsActiveRole(ROLE_DETECTIVE) then
		net.Broadcast()
	else
		net.Send(ply)
	end
end


-- Returns a sample for use in dna scanner if the kill fits certain constraints,
-- else returns nil
local function GetKillerSample(victim, attacker, dmg)
	-- only guns and melee damage, not explosions
	if not dmg:IsBulletDamage() and not dmg:IsDamageType(DMG_SLASH) and not dmg:IsDamageType(DMG_CLUB) then return end

	if not IsValid(victim) or not IsValid(attacker) or not attacker:IsPlayer() then return end

	-- NPCs for which a player is damage owner (meaning despite the NPC dealing
	-- the damage, the attacker is a player) should not cause the player's DNA to
	-- end up on the corpse.
	local infl = dmg:GetInflictor()

	if IsValid(infl) and infl:IsNPC() then return end

	local dist = victim:GetPos():Distance(attacker:GetPos())

	if not ConVarExists("ttt_killer_dna_range") or dist > GetConVar("ttt_killer_dna_range"):GetInt() then return end

	local sample = {}
	sample.killer = attacker
	sample.killer_sid = attacker:SteamID64()
	sample.victim = victim
	sample.t = CurTime() + (-1 * (0.019 * dist) ^ 2 + (ConVarExists("ttt_killer_dna_basetime") and GetConVar("ttt_killer_dna_basetime"):GetInt() or 0))

	return sample
end

local crimescene_keys = {
	"Fraction",
	"HitBox",
	"Normal",
	"HitPos",
	"StartPos"
}

local poseparams = {
	"aim_yaw",
	"move_yaw",
	"aim_pitch"
}

local function GetSceneDataFromPlayer(ply)
	local data = {
		pos = ply:GetPos(),
		ang = ply:GetAngles(),
		sequence = ply:GetSequence(),
		cycle = ply:GetCycle()
	}

	for _, param in ipairs(poseparams) do
		data[param] = ply:GetPoseParameter(param)
	end

	return data
end

local function GetSceneData(victim, attacker, dmginfo)
	-- only for guns for now, hull traces don't work well etc
	if not dmginfo:IsBulletDamage() then return end

	local scene = {}

	if victim.hit_trace then
		scene.hit_trace = table.CopyKeys(victim.hit_trace, crimescene_keys)
	else
		return scene
	end

	scene.victim = GetSceneDataFromPlayer(victim)

	if IsValid(attacker) and attacker:IsPlayer() then
		scene.killer = GetSceneDataFromPlayer(attacker)

		local att = attacker:LookupAttachment("anim_attachment_RH")
		local angpos = attacker:GetAttachment(att)

		if not angpos then
			scene.hit_trace.StartPos = attacker:GetShootPos()
		else
			scene.hit_trace.StartPos = angpos.Pos
		end
	end

	return scene
end

local rag_collide = CreateConVar("ttt_ragdoll_collide", "0", {FCVAR_NOTIFY, FCVAR_ARCHIVE})

realdamageinfo = 0

-- Creates client or server ragdoll depending on settings
function CORPSE.Create(ply, attacker, dmginfo)
	if not IsValid(ply) then return end

	local rag = ents.Create("prop_ragdoll")

	if not IsValid(rag) then return end

	rag:SetPos(ply:GetPos())
	rag:SetModel(ply:GetModel())
	rag:SetAngles(ply:GetAngles())
	rag:SetColor(ply:GetColor())

	rag:Spawn()
	rag:Activate()

	-- nonsolid to players, but can be picked up and shot
	rag:SetCollisionGroup(rag_collide:GetBool() and COLLISION_GROUP_WEAPON or COLLISION_GROUP_DEBRIS_TRIGGER)

	-- flag this ragdoll as being a player's
	rag.player_ragdoll = true
	rag.sid = ply:SteamID()
	rag.sid64 = ply:SteamID64()
	rag.uqid = ply:UniqueID() -- backwards compatibility use rag.sid64 instead

	-- network data
	CORPSE.SetPlayerNick(rag, ply)
	CORPSE.SetFound(rag, false)
	CORPSE.SetCredits(rag, ply:GetCredits())

	-- if someone searches this body they can find info on the victim and the
	-- death circumstances
	rag.equipment = ply:GetEquipmentItems()
	rag.was_role = ply:GetSubRole()
	rag.was_team = ply:GetTeam()
	rag.bomb_wire = ply.bomb_wire
	rag.dmgtype = dmginfo:GetDamageType()

	local wep = util.WeaponFromDamage(dmginfo)
	rag.dmgwep = IsValid(wep) and wep:GetClass() or ""

	rag.was_headshot = ply.was_headshot and dmginfo:IsBulletDamage()
	rag.time = CurTime()
	rag.kills = table.Copy(ply.kills)
	rag.killer_sample = GetKillerSample(ply, attacker, dmginfo)

	-- crime scene data
	rag.scene = GetSceneData(ply, attacker, dmginfo)

	-- position the bones
	local num = (rag:GetPhysicsObjectCount() - 1)
	local v = ply:GetVelocity()

	-- bullets have a lot of force, which feels better when shooting props,
	-- but makes bodies fly, so dampen that here
	if dmginfo:IsDamageType(DMG_BULLET) or dmginfo:IsDamageType(DMG_SLASH) then
		v:Mul(0.2)
	end

	hook.Run("TTT2ModifyRagdollVelocity", ply, rag, v)

	for i = 0, num do
		local bone = rag:GetPhysicsObjectNum(i)

		if IsValid(bone) then
			local bp, ba = ply:GetBonePosition(rag:TranslatePhysBoneToBone(i))

			if bp and ba then
				bone:SetPos(bp)
				bone:SetAngles(ba)
			end

			-- not sure if this will work:
			bone:SetVelocity(v)
		end
	end

	-- create advanced death effects (knives)
	if ply.effect_fn then
		-- next frame, after physics is happy for this ragdoll
		local efn = ply.effect_fn

		timer.Simple(0, function()
			efn(rag)
		end)
	end

	hook.Run("TTTOnCorpseCreated", rag, ply)

	return rag -- we'll be speccing this
end
