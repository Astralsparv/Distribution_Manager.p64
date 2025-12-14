
-- populate tooltray with widgets found in widgets.pod

local widgets = fetch"/appdata/system/widgets.pod"

-- default widgets if no file exists
-- (for no widgets, need to manually remove owl & clock, or store("/appdata/system/widgets.pod",{}) 
if (not widgets) then
	widgets = fetch"/system/misc/default_widgets.pod"
	store("/appdata/system/widgets.pod", widgets)
end


for i=1,#widgets do
	local widget = widgets[i]

	--printh("loading widget: "..pod(widget))
	create_process(widget.prog,{
		window_attribs = {workspace = "tooltray", x=widget.x, y=widget.y, width=widget.width, height=widget.height, had_frame=widget.had_frame},
		location = widget.location
	})
end


