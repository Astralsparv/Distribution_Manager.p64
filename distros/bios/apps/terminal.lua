--[[pod_format="raw",author="zep",created="2023-10-07 14:33:59",icon=userdata("u8",16,16,"0000000000000000000000000000000000000001010101010101010100000000000001070707070707070707010000000001070101010101010101010701000001070101010101010101010101070100010701010101070101010101010701000107010101010107010101010107010001070101010101010701010101070100010701010101010701010101010701000107010101010701010101010107010001070101010101010101010101070100011d07010101010101010101071d0100011d1d0707070707070707071d1d010000011d1d1d1d1d1d1d1d1d1d1d0100000000011d1d1d1d1d1d1d1d1d0100000000000001010101010101010100000000"),modified="2025-07-09 22:28:11",notes="",revision=154,stored="2024-03-09 10:31:21",title="Terminal",version=""]]
--[[

	terminal.lua
	(c) Lexaloffle Games LLP

	-- ** terminal is also an application launcher. manages cproj / decides permissions **

	-- to consider: line entry in terminal can be a bitmap
		// can already use p8scii! works but need to improve workflow for encoding characters (and maybe use P8-style unicode replacements)
		// alternative: could support pod_type="image" style lines using same rule a text editor widget

]]


local _envdat = env()

-- set preferred window size unless about to corun a program (which should be the one to create the window w/ size, icon)
-- this window size might be overwritten by env().window_attribs
if (not _envdat.corun_program) then
	window{
		width=260, -- 0.1.0e: changed to 240 (was 320). be more boxy. 5*52, 4*65
		height=160,
		icon = userdata"[gfx]0907000707000000070000777777777770000077770000077770000077777777777[/gfx]"
	}
end

-- 0.2.1c: by providing a history file, multiple instances of terminal can share the same merged command history
-- pwc_output windows (the default fullscreen window, and windows created with ctrl+r) automatically share /ram/system/history.pod
local history_file = _envdat.history
if (not history_file and _envdat.window_attribs and _envdat.window_attribs.pwc_output) then
	history_file = "/ram/system/history.pod"
end
--printh("terminal history file: "..tostring(history_file))


if (pwd() == "/system/apps") cd("/") -- start in root instead of location of terminal.lua


-- 0.1.1e: set starting path via commandline
if fullpath(_envdat.argv[1]) then
	cd(fullpath(_envdat.argv[1]))
end

-- 0.2.0e: set starting path via env().path
if _envdat.path then
	cd(_envdat.path)
end

--- *** NO GLOBALS ***   --   don't want to collide with co-running program

local cmd=""

local line={}
local lineh={}
local lines_at_corun_resume = 0
local add_line = function() end
local history={}
local history_pos = 1
local scroll_y = 0
local char_h = peek(0x4002)
local char_w = peek(0x4000)
local cursor_pos = 0
local disp_w, disp_h = 480, 270 -- assume full size (needed for ctrl-r terminal program)
local back_page = userdata("u8", 480, 270)
local last_total_text_h = 0
local max_lines = 256 -- to do: increase w/ more efficient rendering (cache variable line offsets)
local left_margin = 2

local terminal_draw 
local terminal_update

local corun_draw, corun_update

local input_prompt
local blocking_proc_id

local terminal_cor
local corun_cor

local running_corun = false
local corun_windowed_bit = 0x0
local pwd_on_suspend = nil

-- to do: nice way to get a local copy of needed api
-- co-running program should be free to redefine any of these

local env = env
local blit = blit
local cls = cls
local set_draw_target = set_draw_target
local send_message = send_message
local window = window
local note = note
local on_event = on_event
local cocreate = cocreate
local coresume = coresume
local costatus = costatus
local readtext = readtext
local peektext = peektext
local fstat = fstat
local fullpath = fullpath
local fetch = fetch
local store = store
local add = add
local type = type
local mid = mid
local min = min
local max = max
local del = del
local deli = deli
local load = load
local rectfill = rectfill
local rect = rect
local env = env
local cd = cd
local time = time
local print = print
local printh = printh
local exit = exit
local split = split
local set_clipboard = set_clipboard
local get_clipboard = get_clipboard
local tostring = tostring


local _has_focus = true
on_event("gained_focus", function() _has_focus = true end)
on_event("lost_focus", function() _has_focus = false end)


--corunning coroutines

local coco = {}


function _init()

	-- don't pause fullscreen terminal when not corunning pwc
	if (not _envdat.corun_program) then
		window{
			pauseable = false,
			title = "Terminal"
		}
	end

	-- add_line("picotron terminal // "..flr(stat(0)).." bytes used")

end


-- scroll just enough to make sure command prompt is visible
local function show_last_line()

	local hh = 0
	for i=1,#lineh do
		hh += lineh[i]
	end
	last_total_text_h = hh

	local old_scroll_y = scroll_y
	
	scroll_y = mid(scroll_y, 
		last_total_text_h - disp_h + 18, -- puts prompt at bottom of screen 
		last_total_text_h + char_h -  5  -- puts prompt at top of screen (same as ctrl-l)
	)

	--[[
	if (old_scroll_y ~= scroll_y) then
		printh("old_scroll_y -> scroll_y  (disp_h, last_total_text_h, btm, top): "..
			pod{old_scroll_y, scroll_y, disp_h, last_total_text_h, last_total_text_h - disp_h + 18, last_total_text_h + char_h -  5})
	end
	]]
	
end


-- to do: string format for custom prompts?
-- for now, create a return value so that can use sedit
local function get_prompt()
	if (input_prompt) return input_prompt.str -- reading some user text
	local result 
	result = "\f6"..(_envdat.sandbox and "[sandboxed] " or "")..pwd().."\f7> "

	return result -- custom prompt goes here
end


local function resume_corun_program()
	lines_at_corun_resume = #line
	running_corun = true

	send_message(3, {event="set_haltable_proc_id", haltable_proc_id = pid()})

	-- window manager remebers if that window was ever pauseable
	send_message(3, {event="resume_pwc", haltable_proc_id = pid()})

	if (corun_update or corun_draw) then
		if (corun_draw)   _draw = corun_draw
		if (corun_update) _update = corun_update
	end

	poke(0x547f, peek(0x547f) | corun_windowed_bit)

	if (pwd_on_suspend) cd(pwd_on_suspend)
end


--[[

	return control to terminal

]]
local function suspend_corun_program()

--	if (corun_cor) printh("@@ suspend_corun_program // corun_cor "..tostring(costatus(corun_cor)))

	-- 0.2.0i: copy whatever is on the screen after corun (unless was using print / input to add lines -- don't want to copy that)
	--> can run a program like: vid() circfill(200,100,50,12) and be left with the graphical output in back page
	if (#line == lines_at_corun_resume) blit(get_display(), back_page)
--	if (#line == 0) blit(get_display(), back_page)

	-- stop resuming corun_cor
	running_corun = false

	-- kill all audio channels
	note()


	-- consume keypresses
	readtext(true)
	send_message(pid(), {event = "reset_kbd"})

	-- tidy up mess of state
	input_prompt = nil
	pressed_enter_while_blocking = false
	cmd = ""

	-- 0.2.0i: can return to nil when _draw / _update not defined
	corun_draw = _draw ~= terminal_draw and _draw or nil
	corun_update = _update ~= terminal_update and _update or nil

	_draw = terminal_draw
	_update = terminal_update
	corun_windowed_bit = peek(0x547f) & 0x8 -- restore this bit on resume

	blocking_proc_id = nil

	window{pauseable = false}

	-- back to last directory that user chose
	pwd_on_suspend = pwd()
	local pwd1 = fetch("/ram/system/pwd.pod")
	if (pwd1) then cd(pwd1) end

	set_draw_target()

	show_last_line()

end



local function get_file_extension(s)

	if (type(s) ~= "string") return nil
	return s:ext()

end


local function try_multiple_extensions(prog_name)
	--printh(" - - - - trying multiple entensions for: "..tostr(prog_name))

	if (type(prog_name) ~= "string") return nil

	local res =
		--(fstat(prog_name) and prog_name and get_file_extension(prog_name)) or  --  needs extension because don't want regular folder to match
		(fstat(prog_name) and prog_name:ext() and prog_name) or  --  needs extension because don't want regular folder to match
		(fstat(prog_name..".lua") and prog_name..".lua") or
		-- only .p64 carts can be run without specifying extension (would be overkill; reduce ambiguity)
		-- also: don't automatically append .p64 when checking a bbs:// or anywhen:// address -- causes e.g. checking server for cd.p64
		(not (fullpath(prog_name) and fullpath(prog_name):prot()) and fstat(prog_name..".p64") and prog_name..".p64") or 
		nil
	--printh(" - - - - - - - - -")
	return res

end


--[[
	find a program 

	look in /system/util, /system/apps, /appdata/system/util and finally current path

	to do: some kind of customisable $PATH? would be nice to avoid the need for that
]]
local function resolve_program_path(prog_name)

	if (type(prog_name) ~= "string") return nil

	-- check for illegal filename chars -> probably a lua command
	if (string.find(prog_name, "\"", 1, true)) return nil 

	-- need explicit exension when running protocol path
	-- (anywhen paths can't rely on try_multiple_extensions failing because doesn't test actual existence. to do: fix ~ is dangerous!)
	if (prog_name:prot()) then
		local ext = prog_name:ext()
		return (ext and ext:is_cart() or ext=="lua") and prog_name or nil
	end

	 -- shorthand; too complex to make #foo a first-class alternative to bbs://foo.p64  //  consider: ext(), fullpath()
	if (prog_name[1] == "#") prog_name = "bbs://"..prog_name:sub(2)..".p64"

	-- /appdata/system/util/ can be used to extend built-in apps (same pattern as other collections)
	-- update: not true, other collections (wallpapers) are replaced rather than extended by /appdata

	if (prog_name[1] == "." or prog_name[1] == "/") then
		-- 0.1.1:  ./foo.lua, ../foo.lua, absolute path -> don't search other paths
		return try_multiple_extensions(prog_name) 
	end


	return
		try_multiple_extensions("/system/util/"..prog_name) or
		try_multiple_extensions("/system/apps/"..prog_name) or
		try_multiple_extensions("/appdata/system/util/"..prog_name) or
		try_multiple_extensions(prog_name) -- 0.1.0c: moved last 

end

-- 0.2.0e: use meandering center of execution (including the mainloop in lib/foot.lua)
-- -> no longer need to rely on update / draw callbacks, so reduce the need for special flow logic & disjointed callstacks 
local function corun_program_inside_terminal(prog_name)
	if (not prog_name) return

	local prog_str = fetch(prog_name)
	if (not prog_str) then
		add_line("could not fetch "..prog_name)
		return
	end

	-- inject a foot that runs _init if the program defines one
	-- let terminal draw,update persist until redefined (might be an interactive terminal program which uses them)
	-- also: automatic fullscreen window creation is disabled in foot when corunning -- let the corun program define window
	-- note: don't need a mainloop -- will use the one already provided by terminal's foot
	-- "if (_draw == d0) poke(0x547f, peek(0x547f) & ~0x20)" --need to ctrl+r tests/background_work (because terminal sets that bit at first)

	prog_str = 
			"_init = nil local _draw0 = _draw ; "..
			prog_str.." \n "..
[[
			if (_init) then _init() end
			if (_draw == _draw0) poke(0x547f, peek(0x547f) & ~0x20) -- no _draw defined -> clear bit (see foot)
			if (_draw and not get_display()) then
				-- create fullscreen window
				window()
			end
]]

	local f, err = load(prog_str, "@"..prog_name, "t", _ENV)

	
	if (f) then
		-- kick off execution -- will resume from _update
		corun_cor = cocreate(f)
		running_corun = true

		-- tricky: need to always run terminal update in background so can bootstrap the corun update
		-- this bit cleared in head.lua set_window_1, so background updates don't remain set when ctrl+r
		poke(0x547f, peek(0x547f) | 0x40);
		poke(0x547f, peek(0x547f) & ~0x8) -- print to terminal until a window is created
	else
		-- syntax error  //  to do: other possible errors?
		send_message(3, {event="report_error", content = "*syntax error"})
		send_message(3, {event="report_error", content = tostr(err)})

		-- don't get stuck in a fullscreen pauseable state
		show_last_line()
		window{pauseable = false}
	end

	scroll_y = 0

end




--[[

	run_program_in_new_process()

	initial pwd is always program path (even for stand-alone .lua scripts), so if planning to run
	from a different directory (e.g. /system/util), program needs to start with cd(env().path)

]]
local function run_program_in_new_process(prog_name, argv)

	local fileview = nil

	-- 0.2.0h: terminal is allowed to grant sandboxed access to argv[1] when it is a resolvable filename
	if fullpath(argv[1]) then
		fileview = {{location=fullpath(argv[1]), mode="RW"}}
	end

	local proc_id, err = create_process(
		prog_name,
		{
			argv = argv,
			path = pwd(), -- used by commandline programs -- cd(env().path)
			window_attribs = {show_in_workspace = true},
			fileview = fileview,

			-- tell new process where to print to  (0.1.1e unless new terminal!)
			print_to_proc_id = prog_name ~= _envdat.argv[0] and pid() or nil,
		}
	)

	if (err) add_line(err)

	-- 0.2.0e: blocking -- until either dead or that process has a window
	-- (via child_completed, child_created_window messages)
	if (proc_id) then
		blocking_proc_id = proc_id
	end

end


--[[

	run_terminal_command

	try in order:

		1. built-in commands (cd / exit etc) that can not be replaced by lua or program names
		2. programs          // can't have spaces in them
		3. lua command

	note: running a program might be in the form of a legal lua statement, but if the program
		doesn't exist, then the lua statement is never executed. e.g.

		ls = 3 -- runs list with args {"=","3"}
		xx = 3 -- assigns 3 to xx (assuming there is no program called xx)

]]

local function run_terminal_command(cmd)

	local prog_name = resolve_program_path(split(cmd," ",false)[1])

--	printh("run_terminal_command program: "..tostr(prog_name))

	local argv = {}
	local argv0 = split(cmd," ",false) -- to do: quoted strings! wildcard expansion!

	local index = 0 -- 0-based so that 1 is first argument
	for i=1,#argv0 do
		if (argv0[i] ~= "") then -- 0.1.1e: don't pass "" arguments (e.g. trailing space). dangerous!
			argv[index] = argv0[i]
			index += 1
		end
	end

	-----

	if (argv[0] ~= "." and cmd ~= "") frame_by_frame_mode = false
	
	if (argv[0] == "." or (cmd == "" and frame_by_frame_mode)) then

		if (not corun_update and not corun_update) then
			-- to do: support this if can unify coresume_until_flipped
			add_line("no draw / update callbacks found")
			return
		end

		frame_by_frame_mode = true
		if (corun_update) corun_update()
		if (corun_draw) corun_draw()
		flip()
		blit(get_display(), back_page) -- copy whatever is on screen
	
	elseif (argv[0] == "cd") then

		local result = cd(argv[1])
		if (result) then add_line(result) end -- result is an error message

	elseif (cmd == "exit") then

		exit(0)
		
	elseif (cmd == "cls") then

		set_draw_target(back_page)
		cls()
		set_draw_target()
		line={} lineh={} -- 0.2.1c: clear text
		scroll_y = last_total_text_h

	elseif (cmd == "reset") then

		reset()
		window{pauseable=false}
		vid(0)

	elseif (cmd == "resume") then

		if (corun_cor) then
			resume_corun_program()
		else
			print("nothing to resume")
		end

	elseif (prog_name) then

		run_program_in_new_process(prog_name, argv) -- could do filename expansion etc. for arguments

	else
		-- last: try lua

		local f, err = load(cmd, nil, "t", _ENV)

		if (f) then
		
			-- run loaded lua as a coroutine
			terminal_cor = cocreate(f)

		else

			-- try to differenciate between syntax error /command not found

			local near_msg = "syntax error near"
			if (near_msg == sub(err, 5, 5 + #near_msg - 1)) then
				-- caused by e.g.: "foo" or "foo -a" or "foo a.png" when foo doesn't resolve to a program
				add_line "command not found"
			else
				add_line(err)
			end

		end

	end

end



add_line = function(s)
	s = tostr(s)
	if (not s) then return end

	if (#line > max_lines) then
		deli(line, 1)		
		deli(lineh, 1)
	end

	if (#line >= 1 and sub(line[#line],-1) == "\000") then
		-- append to previous line; roughly match behaviour of cursor when printing to display
		-- kinda inefficient if do many appends, but simplifies height calculation.
		line[#line] = sub(line[#line], 1, -2)..s
		-- update height
		local xx,yy = print(line[#line], 0, 10000)
		lineh[#lineh] = max(4, yy and yy-10000)
	elseif #line >= 1 and (s[1] == "\r" or (s[1] == "\f" and s[3] == "\r")) then -- and (line[#line-1][1] == "\r" or line[#line-1][3] == "\r") then
		-- \r has a special meaning in this context -- "replace previous line"
		-- replace previous line; roughly match behaviour of cursor when printing to display
		-- kinda inefficient if do many appends, but simplifies height calculation.
		line[#line] = s
		-- update height
		local xx,yy = print(line[#line], 0, 10000)
		lineh[#lineh] = max(4, yy and yy-10000)
	else
		local xx,yy = print(s, 0, 10000)
		add(line,  s)
		add(lineh, max(4, yy and yy-10000))
	end

	show_last_line()

	

--	printh(pod{line=#line, num_lineh=#lineh, added_lineh=lineh[#lineh], last_total_text_h=last_total_text_h})

end


-- ** incredibly inefficient! to do: need to replace with string matching
local function find_common_prefix(s0, s1)

	if (type(s0) ~= "string") then return nil end
	if (type(s1) ~= "string") then return nil end

	if (s0 == s1) then return s0 end

	local len = 0
	while(sub(s0,1,len+1) == sub(s1,1,len+1)) do
		len = len + 1
		--printh(len)
	end

	return sub(s0,1,len)
end

--[[
	
	tab_complete_filename

	0.1.1e: can handle protocol locations
	
]]
local function tab_complete_filename()

	if (cmd == "") then return end

	-- get string
	local args = split(cmd, " \"", false)  -- also split on " to allow tab-completing filenames inside strings
	local prefix = args[#args] or ""

	-- construct path prefix  -- everything (canonical path) except the filename
	local prefix = fullpath(prefix)
	if (not prefix) return -- bad path

	local prot = prefix:prot(true) -- true to only check string prefix
	local prot_str = prot and (prot.."://") or ""
	if (prot) then
		prefix = prefix:sub(#prot+3)
	end


	local pathseg = split(prefix,"/",false)
	local path_part = ""
	for i=1,#pathseg-1 do
		path_part = path_part .. "/" .. pathseg[i]
	end
	if (path_part == "") then path_part = "/" end -- canonical filename special case

	prefix = (pathseg and pathseg[#pathseg]) or "/"


	-- printh("@@@ listing: "..prot_str..path_part)
	local files = ls(prot_str..path_part)

	if (not files) return

	-- find matches

	local segment = nil
	local matches = 0
	local single_filename = nil

	for i=1,#files do
		-- printh(prefix.." :: "..files[i])
		if (sub(files[i], 1, #prefix) == prefix) then
			matches = matches + 1
			local candidate = sub(files[i], #prefix + 1) -- remainder

			-- set segment to starting sequence common to candidate and segment
			segment = segment and find_common_prefix(candidate, segment) or candidate
			single_filename = path_part.."/"..files[i] -- used when single match is found
		end
	end

	if (segment) then
		cmd = cmd .. segment
		cursor_pos = cursor_pos + #segment
	end

	-- show files if >= 2
	if (matches > 1) then
		add_line("-- "..matches.." matching files --")
		for i=1,#files do
			if (sub(files[i], 1, #prefix) == prefix) then
				add_line(files[i])
			end
		end
	elseif single_filename and fstat(single_filename) == "folder" then
		-- trailing slash when a single match is a folder
		-- for folders with an extension, need to already match the full name;
		--> press tab once for foo.p64 and once more for foo.p64/)
		-- the vast majority of the time, user wants to refer to the cart itself
		if not single_filename:ext() or prefix == sub(cmd,-#prefix) 
		then
			cmd ..= "/"
			cursor_pos += 1
		end
	end

end


local tv_frames = 
{	[0] =
	userdata"[gfx]0907000707000000070000777777777770000077770070077770000077777777777[/gfx]",
	userdata"[gfx]0907000707000000070000777777777770070077770707077770070077777777777[/gfx]",
	userdata"[gfx]0907000707000000070000777777777770707077770000077770707077777777777[/gfx]",
}

function coresume_until_flipped(c)

	if corun_draw then

		-- corunning a program that has a _draw function defined
		-->  should be allowed to yield() at top level more than once per frame (e.g. used by print / input / fetch)

		while true do
			local res,err = coresume(c)
			if costatus(c) == "suspended" and stat(984) == 0 then
				-- yielded but didn't flip yet; go around again
			else
				-- finished
				return res,err
			end
		end

	else
		-- corunning without a draw function 
		--> run until halted or finished [to do: or _draw function defined?]
		-- to do: would be nice to use same pattern as above; but custom mainloop from terminal vs separate process is quite different
		while true do
			local res,err = coresume(c)
			--printh("costatus: "..pod{costatus(c), running_corun})
			if costatus(c) == "suspended" and running_corun then
				-- yielded but still running; go through terminal update/draw to allow input / print
				return
			else
				-- finished
				return res,err
			end
		end

	end
end


function _update()


	-- something corunning 

	if (corun_cor and running_corun)
	then
		if (costatus(corun_cor) == "suspended") then

			local res,err = coresume_until_flipped(corun_cor)

			if (err) then
				-- errors that occur when running at top level (including _init)  are caught here;
				-- can't access callstack (?) so just report single line error
				send_message(3, {event="report_error", content = "*runtime error"})
				send_message(3, {event="report_error", content = tostring(err)}) 
				send_message(3, {event="report_error", content = debug.traceback(corun_cor)}) 

				--printh("@@ "..err)
			end
		end

		-- finished running corun program

		if (costatus(corun_cor) ~= "running" and costatus(corun_cor) ~= "suspended") then

			-- let it keep "running" when _draw or _update was defined
			-- the /coroutine/ has finished running, but the program is running using terminal's mainloop
			-- and the newly defined _update and/or _draw callbacks
			if (_draw ~= terminal_draw or _update ~= terminal_update) then
				-- ditch callback that was not defined by the corun program
				-- dummy callbacks so that foot doesn't need to care about callbacks disappearing
				if (_draw == terminal_draw) _draw = function() end
				if (_update == terminal_update) _update = function() end
			else
				-- otherwise immediately stop (e.g. custom mainloop or a terminal script)
				suspend_corun_program()
				corun_cor = nil
			end
			
		end

		if (not input_prompt) return
	end

	-- something running in terminal (ALMOST DUPE)

	if (terminal_cor) then

		--printh("running terminal_cor")
		if (not input_prompt) set_draw_target(back_page)
		poke(0x547f, peek(0x547f) & ~0x8) -- print to terminal until a window is created  --  pset(100,100,8)?pget(100,100)
		local res,err = coresume(terminal_cor)
		set_draw_target()

		if (err) then
			add_line("\feRUNTIME ERROR")
			add_line(err)
			printh("## "..err)
		end

		-- finished running terminal command
		if (costatus(terminal_cor) ~= "running" and costatus(terminal_cor) ~= "suspended") then
			terminal_cor = nil
			input_prompt = nil
			readtext(true)
			send_message(pid(), {event = "reset_kbd"})
			cmd = ""
			
		end

	end


	if (key("ctrl")) then

		if keyp("l") then
			set_draw_target(back_page)
			cls()
			set_draw_target()
			scroll_y = last_total_text_h + 5
		end

		if keyp("v") then

			local str = get_clipboard()
			cmd = sub(cmd, 1, cursor_pos) .. str .. sub(cmd, cursor_pos+1)
			cursor_pos = cursor_pos + #str

		end

		if keyp("c") then

			set_clipboard(cmd)
			
		end

		if keyp("x") then

			set_clipboard(cmd)
			cmd = ""
			cursor_pos = 0
			
		end

		if (keyp("e")) cursor_pos = #cmd

		-- clear text intput queue; don't let anything else pass through
		-- readtext(true) -- 0.1.0f: wrong! ctrl sometimes used for text entry (altgr), and anyway ctrl-* shouldn't ever produce textinput event
	end

	-- single character response to blocking input
	if (input_prompt and input_prompt.single_char and peektext()) then
		local k = readtext()
		send_message(input_prompt.pid, {event = "input_response", response = k})
		if (not input_prompt.hide) add_line(get_prompt()..k) -- show what was entered
		input_prompt = nil
		cmd = ""
		return
	end

	-- can read chars for command unless already pressed enter while blocking
	-- (want to buffer next typed command, but only up until pressed enter -- give up and discard after that)
	while (peektext() and not (pressed_enter_while_blocking and not input_prompt)) do
		local k = readtext()

		-- insert at cursor
		if (not halted_t or time() > halted_t + 0.25) -- ignore input right after stop() -- annoying
		then 
			cmd = sub(cmd, 1, cursor_pos) .. k .. sub(cmd, cursor_pos+1)
			cursor_pos = cursor_pos + 1
			show_last_line()
		end
	end

	-- tab completion and histroy navigation: not available for input() or otherwise running a blocking program
	if (not blocking_proc_id) then

		if (keyp("tab")) then
			tab_complete_filename();
		end

		if (keyp("up")) then
			history[history_pos] = cmd
			history_pos = mid(1, history_pos-1, #history	)
			cmd = history[history_pos]
			cursor_pos = #cmd
		end

		if (keyp("down")) then
			history[history_pos] = cmd
			history_pos = mid(1, history_pos+1, #history)
			cmd = history[history_pos]
			cursor_pos = #cmd
		end

	end

	if (keyp("left")) then
		cursor_pos = mid(0, cursor_pos - 1, #cmd)
	end

	if (keyp("right")) then
		cursor_pos = mid(0, cursor_pos + 1, #cmd)
	end

	if (keyp("home") or (key("ctrl") and keyp("a"))) cursor_pos = 0
	if (keyp("end")) cursor_pos = #cmd

	if (keyp("backspace") and #cmd > 0) then
		cmd = sub(cmd, 1, max(0,cursor_pos-1))..sub(cmd, cursor_pos+1)
		cursor_pos = mid(0, cursor_pos - 1, #cmd)
	end

	if (keyp("delete") or (key("ctrl") and keyp("d"))) then
		cmd = sub(cmd, 1, max(0,cursor_pos))..sub(cmd, cursor_pos+2)
	end


	--if (input_prompt) printh(t()) -- check framerate for debugging keyp("enter") responsivity

	if (keyp("enter")) then

		-- not waiting for input and there is a blocking process running -- don't process command
		-- (and note that enter was pressed, to stop reading further additions to cmd)
		if (blocking_proc_id and not input_prompt) then
			pressed_enter_while_blocking = true
			return
		end

		if (input_prompt) then
			-- send back to calling program
			send_message(input_prompt.pid, {event = "input_response", response = cmd})
			if (not input_prompt.hide) add_line(get_prompt()..cmd) -- show what was entered
			input_prompt = nil
			cmd = ""
			return
		end


		if (cmd ~= "" or not frame_by_frame_mode) then
			add_line(get_prompt()..cmd)
		end

		
		-- execute the command

		run_terminal_command(cmd)
		show_last_line()

		-- add to history

		if (history[#history] == "") then 
			history[#history] = cmd
		elseif cmd ~= "" then
			add(history, cmd)
		end

		-- store history if there is one

		if (history_file and cmd ~= "") then
			store(history_file, {pid(), history, pwd()}) 
			store("/ram/system/pwd.pod", pwd())
		end

		history_pos = #history+1

		-- reset the prompt

		cmd = ""
		cursor_pos = #cmd -- cursor at end of command

	end

	


end
terminal_update = _update


function _draw()

	local disp = get_display()
	if (disp) disp_w, disp_h = disp:width(), disp:height()
	
	--if (running_corun) printh("_draw running_corun")
--	printh("terminal draw "..time())

--	local show_terminal_layer = input_prompt or not running_corun
	local show_terminal_layer = true -- 0.2.0e: always draw -- center of execution doesn't reach here when when terminal layer isn't wanted

	if show_terminal_layer then

		camera()
		clip()
		cls()
		blit(back_page, nil, 0, 0, 0, 0, 480, 270)
	

	-- experiment: run painto / dots3d in terminal
--[[
	if (running_proc_id) then
		_blit_process_video(running_proc_id, 0, 0)
	end
]]

	--scroll_y = mid(0, scroll_y, #line * char_h - disp_h)

	--printh("disp_h: "..disp_h.." scroll_y: "..scroll_y.." max: "..(#line * char_h - disp_h))


		local x = left_margin
		local y = 7 - scroll_y

		local y0 = y

		-- to do: could cache wrapped strings
		-- and/or add a picotron-specific p8scii address for rhs wrap
		--local wrap_prefix = "\006r"..chr(ord("a") + max(6, disp_w \ 4 - 10))
		local wrap_prefix = ""
		
		poke(0x5f36, (@0x5f36) | 0x80) -- turn on wrap

		for i=1,#line do
			--printh(i..": "..scroll_y)
			_, y = print(line[i], x, y, 7)
			--_, y = print("\^ow5a"..line[i], x, y, 7) -- kinda messy (and too expensive?)
		end

		y = y or 0

		last_total_text_h = y - y0


		-- poke(0x5f36, (@0x5f36) | 0x80) -- turn on wrap

		camera()

		-- show prompt when not waiting for a program to complete
		if (not blocking_proc_id or input_prompt) then

			local prefix = "\^owff"..wrap_prefix..get_prompt() -- show outline only when entering text
			print(prefix..cmd.."\0", x, y, 7)
			print(prefix..sub(cmd,1,cursor_pos).."\0", x, y, 7)

			local cx, cy = peek4(0x54f0, 2)
			if (cx > disp_w - peek(0x4000)) cx,cy = peek4(0x54f8), cy + peek(0x4002) -- where next character is (probably) going to be after warpping

			-- show cursor when window is active (no cursor for input prompt when reading single char)
			if (_has_focus and (not input_prompt or not (input_prompt.single_char and input_prompt.str == ""))) then
				if (time()%1 < .5) then
					rectfill(cx, cy, cx+char_w-1, cy+char_h-4, 14)
				end
			end

		end

	end

end
terminal_draw = _draw


-- can stop blocking when child completed
on_event("child_completed", function(msg)
	if (msg.proc_id == blocking_proc_id) then
		blocking_proc_id = nil
		suspend_corun_program()
	end
end)
-- .. or created a window
on_event("child_created_window", function(msg)
	if (msg.proc_id == blocking_proc_id) then
		blocking_proc_id = nil
		suspend_corun_program()
	end
end)

on_event("print", function(msg)
	add_line(msg.content)	
end)

on_event("input", function(msg)
	
	input_prompt = {
		str = msg.prompt,
		pid = msg._from,
		hide = msg.hide,
		single_char = msg.single_char
	}
end)


-- window manager can tell guest program to halt
-- (usually by pressing escape)
on_event("halt", function(msg)
	if (corun_cor) then
		suspend_corun_program() -- can resume later
	end
	if (msg.description) print(msg.description)
	halted_t = time()
end)



--scroll_y = 0

-- run e.g. pwc output
if (_envdat.corun_program) then
	corun_program_inside_terminal(_envdat.corun_program)
end


function load_history(do_cd)
	if (not history_file) return
	local hdat = fetch(history_file)

	if type(hdat) == "table" and hdat[1] ~= pid()  -- don't reload if this process wrote the file
	then
		-- printh(" > loading history // pwd: "..hdat[3])
		history = hdat[2]
		--if (do_cd) cd(hdat[3]) -- only on startup
		history_pos = #history + 1
		scroll_y = 0
	end
end

-- pwc_output: always load history_f if it exists
-- used to be env().reload_history, but covaries and means the same thing
if history_file then
	load_history(true)
	on_event("modified:"..history_file, load_history)
end


on_event("mousewheel", function(msg)
	scroll_y = scroll_y - msg.wheel_y * char_h * 2
end)

--[[
	ctrl-shift-r (wm) to live-reload lua files or gfx files
]]
on_event("reload_src", function(msg)

	-- security: only accept from window manager
	if (msg._from ~= 3) then
		return
	end

	local src_file = msg.location

	if (src_file:ext() == "lua") then

		local prog_str = fetch(src_file)
		if (not prog_str) return
		local f = load(prog_str, "@"..src_file, "t", _ENV)

		if (f) then
			f()
			notify("reloaded src file: "..src_file:basename())
		else
			-- to do: how to return error?
			notify("could not compile")
		end
	end

	if (src_file:ext() == "gfx") then
		-- 0.2.0i: reload  spritebank

		local num = tonum(src_file:basename():sub(1,2)) or tonum(src_file:basename():sub(1,1))
		if (num and num >= 0 and num < 32) then
			local g = fetch(src_file)
			if g and type(g) == "table" then
				for i=0,255 do
					if type(g[i]) == "table" and type(g[i].bmp) == "userdata" then
						set_spr(num*256 + i, g[i].bmp)
					end
				end
			end
		end
	end


end)


on_event("resize", function(msg)
	show_last_line()
end)
