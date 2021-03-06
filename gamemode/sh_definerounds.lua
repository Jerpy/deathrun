ROUND_WAITING = 3
ROUND_PREP = 4
ROUND_ACTIVE = 5
ROUND_OVER = 6

-- win constants
WIN_STALEMATE = 1
WIN_RUNNER = TEAM_RUNNER
WIN_DEATH = TEAM_DEATH

if SERVER then
	RoundDuration = CreateConVar("deathrun_round_duration", 60*5, FCVAR_REPLICATED, "How many seconds each round should last, not including preptime.")
	PrepDuration = CreateConVar("deathrun_preptime_duration", 5, FCVAR_REPLICATED, "How many seconds preptime should go for.")
	FinishDuration = CreateConVar("deathrun_finishtime_duration", 10, FCVAR_REPLICATED, "How many seconds to wait before starting a new round.")
	DeathRatio = CreateConVar("deathrun_death_ratio", 0.15, FCVAR_REPLICATED, "What fraction of players are Deaths.")
end
RoundLimit = CreateConVar("deathrun_round_limit", 6, FCVAR_REPLICATED, "How many rounds to play before changing the map.")

-- for the round timer
-- have a shared ROUND_TIMER variable which continuously counts down each 0.2 second
-- timer going every 0.2s updating ROUND_TIMER so we have a precision of 1/5th of a second ?????
-- network each time the timer is set, but calculate the timer on server and client individually

ROUND_TIMER = ROUND_TIMER or 0

function ROUND:GetTimer() 
	return ROUND_TIMER or 0
end

timer.Create("DeathrunRoundTimerCalculate", 0.2, 0, function()
	ROUND_TIMER = ROUND_TIMER - 0.2
	if ROUND_TIMER < 0 then ROUND_TIMER = 0 end

	--print( ROUND_TIMER )
end)

if SERVER then
	util.AddNetworkString("DeathrunSyncRoundTimer")
	util.AddNetworkString("DeathrunSendMVPs")
	function ROUND:SetTimer( s )
		ROUND_TIMER = s
		net.Start("DeathrunSyncRoundTimer")
		net.WriteInt( s, 16 )
		net.Broadcast()
	end
else
	net.Receive("DeathrunSyncRoundTimer", function( len, ply )
		ROUND_TIMER = net.ReadInt( 16 )
	end)
end

local rounds_played = 0

local DeathTeamStreaks = {}

hook.Add("PlayerInitialSpawn", "DeathrunCleanupSinglePlayer", function( ply )
	if #player.GetAll() <= 1 then
		game.CleanUpMap()
		DR:ChatBroadcast("Cleaned up the map.")
	end
end)
ROUND:AddState( ROUND_WAITING,
	function()
		print("Round State: WAITING")

		hook.Call("DeathrunBeginWaiting", nil )

		if SERVER then
			for k,ply in ipairs(player.GetAllPlaying()) do
				ply:StripWeapons()
				ply:StripAmmo()

				ply:SetTeam( TEAM_RUNNER )
				ply:Spawn()


			end

			
			timer.Create("DeathrunWaitingStateCheck", 5, 0, function()
				--print("Waiting for players...", #player.GetAllPlaying() )
				if #player.GetAllPlaying() >= 2 then
					ROUND:RoundSwitch( ROUND_PREP )
					timer.Destroy( "DeathrunWaitingStateCheck" )
				end
			end)
		end

	end,
	function()
	--thinking
	end,
	function()
		print("Exiting: WAITING")
	end
)
ROUND:AddState( ROUND_PREP,
	function()
		print("Round State: PREP")
		hook.Call("DeathrunBeginPrep", nil )
		if CLIENT then
			if GetConVar("deathrun_round_cues"):GetBool() == true then
				surface.PlaySound("ui/achievement_earned.wav") -- round start cue
			end
		end

		if SERVER then
			game.CleanUpMap()

			timer.Simple( PrepDuration:GetInt(), function()
				ROUND:RoundSwitch( ROUND_ACTIVE )
			end)

			ROUND:SetTimer( PrepDuration:GetInt() )

			for k,ply in ipairs(player.GetAll()) do
				if not ply:ShouldStaySpectating() then -- for some reason we need to do this otherwise people spawn as spec when they shouldnt!
					ply:SetTeam( TEAM_RUNNER )
				end
				DeathTeamStreaks[ply:SteamID()] = DeathTeamStreaks[ply:SteamID()] or 0
			end

			PrintTable(DeathTeamStreaks)

			-- let's pick deaths at random, but ignore if they have been death the 2 previous rounds
			local deaths = {}
			local deathsNeeded = math.ceil(DeathRatio:GetFloat() * #player.GetAllPlaying())
			local runners = {}
			local pool = table.Copy( player.GetAllPlaying() )

			

			for k,v in ipairs(pool) do -- here we remove all the players who were ever death twice in a row
				v:KillSilent()

				if DeathTeamStreaks[v:SteamID()] > 1 then
					table.remove( pool, k )
					table.insert( runners, v )
					DeathTeamStreaks[v:SteamID()] = 0
				end
			end



			local timesLooped = 0

			while #deaths < deathsNeeded and timesLooped < 100 do
				local randnum = math.random(#pool)
				if pool[randnum] then
					table.insert( deaths, pool[randnum] )
					table.remove( pool, randnum )
				end
			end



			if timesLooped >= 100 then
				print("---WARNING!!!!! WHILE LOOP EXCEEDED ALLOWED LOOP TIME!!!!-----")
			end

			runners = table.Copy( pool )
			pool = {}
			
			--now, spawn all deaths
			for k,death in ipairs( deaths ) do
				death:StripWeapons()
				death:StripAmmo()

				death:SetTeam( TEAM_DEATH )
				death:Spawn()

				DeathTeamStreaks[death:SteamID()] = DeathTeamStreaks[death:SteamID()] + 1
			end

			--now, spawn all runners
			for k,runner in ipairs( runners ) do
				runner:StripWeapons()
				runner:StripAmmo()

				runner:SetTeam( TEAM_RUNNER )
				runner:Spawn()
				DeathTeamStreaks[runner:SteamID()] = 0
			end

			-- make sure nobody is dead??????
			for k,v in ipairs(player.GetAllPlaying()) do
				if not v:Alive() then
					v:Spawn()
				end
			end

			for k,ply in ipairs(player.GetAll()) do
				print( ply:Nick(), team.GetName(ply:Team()) )
			end

		end
	end,
	function()

	end,
	function()
		print("Exiting: PREP")
	end
)
ROUND:AddState( ROUND_ACTIVE,
	function()
		print("Round State: ACTIVE")
		hook.Call("DeathrunBeginActive", nil )
		if SERVER then
			ROUND:SetTimer( RoundDuration:GetInt() )
		end
	end,
	function()
		if SERVER then
			if #player.GetAllPlaying() < 2 then
				ROUND:RoundSwitch( ROUND_WAITING )
				return
			end
			local deaths = {}
			local runners = {}

			for k,v in ipairs(player.GetAllPlaying()) do
				if v:Alive() then
					if v:Team() == TEAM_RUNNER then
						table.insert(runners, v)
					elseif v:Team() == TEAM_DEATH then
						table.insert( deaths, v )
					end
				end
			end

			if #deaths == 0 and #runners == 0 then
				ROUND:FinishRound( WIN_STALEMATE )
			elseif #deaths == 0 then
				ROUND:FinishRound( WIN_RUNNER )
			elseif #runners == 0 then
				ROUND:FinishRound( WIN_DEATH )
			end

		end
	end,
	function()
		print("Exiting: ACTIVE")
	end
)
ROUND:AddState( ROUND_OVER,
	function()
		print("Round State: OVER")
		hook.Call("DeathrunBeginOver", nil )
		rounds_played = rounds_played + 1
		if SERVER then
			if rounds_played < RoundLimit:GetInt() then
				DR:ChatBroadcast("Round "..tostring(rounds_played).." over. "..tostring(RoundLimit:GetInt() - rounds_played).." rounds to go!")
				ROUND:SetTimer(FinishDuration:GetInt())
				timer.Simple(FinishDuration:GetInt(), function()
					ROUND:RoundSwitch( ROUND_PREP )
				end)
			else
				local shouldswitch = hook.Call("DeathrunShouldMapSwitch") or true
				
				if shouldswitch == true then
					DR:ChatBroadcast("Round limit reached. Initiating RTV...")
					timer.Simple(3, function()
						MV:BeginMapVote()
					end)
				end
			end
		end
	end,
	function()
	--thinking
	end,
	function()
		print("Exiting: OVER")
	end
)

if SERVER then
	function ROUND:FinishRound( winteam )
		ROUND:RoundSwitch( ROUND_OVER )
		DR:ChatBroadcast("Round over! "..( winteam == WIN_RUNNER and team.GetName( TEAM_RUNNER ).." win!" or winteam == WIN_DEATH and team.GetName( TEAM_DEATH ).." win!" or "Stalemate! Unbelievable!" ) )
		--calculate MVPs
		net.Start("DeathrunSendMVPs")

		local mvps = {}
		for k,v in ipairs( team.GetPlayers(winteam) ) do
			if v:Alive() then
				table.insert(mvps,v:Nick().." survived the round!")
			end
		end
		local data = {}
		data.mvps = table.Copy(mvps)
		data.duration = FinishDuration:GetInt() -- how long we want to show this screen for, in seconds (temporary?)
		data.winteam = winteam

		net.WriteTable( data )
		net.Broadcast()
	end

	--initial round

	hook.Add("InitPostEntity", "DeathrunInitialRoundState", function()
		ROUND:RoundSwitch( ROUND_WAITING )
	end)
end