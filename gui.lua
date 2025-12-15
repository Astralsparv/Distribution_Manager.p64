--[[pod_format="raw",created="2025-12-14 14:54:56",modified="2025-12-14 15:20:32",revision=85]]
local function proportions(str)
	set_draw_target(userdata("u8",1,1))
	local w,h=print(str,0,0)
	set_draw_target()
	return w,h
end

function text(gui,data)
	local width,height=proportions(data.label)
	width+=1
	height-=1 --there's some extra space for some reason
	local o=gui:attach{
		x=data.x,
		y=data.y,
		label=data.label,
		width=width,
		height=height,
		bg=data.bg,
		fg=data.fg or 7,
		draw=function(self)
			if (self.bg) then
				rectfill(0,0,self.width-1,self.height-1,self.bg)
			end
			print(self.label,1,1,self.fg)
		end,
		tap=data.tap
	}
	return width,height,o
end

function checkbox(gui,data)
	local width,height=proportions(data.label)
	width+=5 --one character (space between label and checkbox
	width+=8 --one off character (checkbox)
	height-=1 --there's some extra space for some reason
	local o=gui:attach{
		x=data.x,
		y=data.y,
		label=data.label,
		width=width,
		height=height,
		bg=data.bg,
		fg=data.fg or 7,
		active=data.active or false,
		draw=function(self)
			if (self.bg) then
				rectfill(0,0,self.width-1,self.height-1,self.bg)
			end
			if (self.active) then
				print("\^:007e425a5a427e00 "..self.label,0,0,self.fg)
			else
				print("\^:007e424242427e00 "..self.label,0,0,self.fg)
			end
		end,
		tap=function(self)
			self.active=not self.active
		end,
		cursor="pointer"
	}
	return width,height,o
end

function button(gui,data)
	local width,height=proportions(data.label)
	width+=1
	height-=1 --there's some extra space for some reason
	local o=gui:attach{
		x=data.x,
		y=data.y,
		label=data.label,
		width=width,
		height=height,
		bg=data.bg or 1,
		fg=data.fg or 7,
		draw=function(self)
			rectfill(0,0,self.width-1,self.height-1,self.bg)
			print(self.label,1,1,self.fg)
		end,
		tap=data.tap,
		cursor="pointer"
	}
	return width,height,o
end